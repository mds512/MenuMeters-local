//
//  MenuMeterReporter.m
//
//  This file is part of MenuMeters, GPL v2. See LICENSE.
//

#import "MenuMeterReporter.h"
#import "MenuMeterReporterSettings.h"
#import "MenuMeterReporterSetupWindowController.h"

#import "MenuMeterCPUStats.h"
#import "MenuMeterMemStats.h"
#import "MenuMeterNetStats.h"
#import "MenuMeterDefaults.h"
#import "MenuMeterCPU.h"
#import "TemperatureReader.h"

#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/storage/IOBlockStorageDriver.h>
#import <sys/mount.h>
#import <sys/param.h>
#import <sys/sysctl.h>

NSString * const kMenuMeterReporterStatusDidChangeNotification = @"MenuMeterReporterStatusDidChange";

// A sensor that cannot be read comes back as absolute zero (Intel) or a bogus
// value; anything at or below this is treated as "no reading".
static const float kMenuMeterReporterNoTemperature = -270.0f;

// How long to wait on the user's endpoint before giving up on one sample.
static const NSTimeInterval kMenuMeterReporterRequestTimeout = 15.0;

@interface MenuMeterReporter ()
@property (atomic, copy, nullable) NSString *lastStatusMessage;
@property (atomic, nullable) NSDate *lastSuccessDate;
@end

@implementation MenuMeterReporter {
    // Collectors. Each keeps its own delta state, so the reporter samples
    // independently of whichever menu meters the user has switched on.
    MenuMeterCPUStats   *cpuStats;
    MenuMeterMemStats   *memStats;
    MenuMeterNetStats   *netStats;

    // Disk IO is sampled here rather than through MenuMeterDiskIO, which only
    // reports an idle/read/write enum and not the byte counters we want.
    io_iterator_t        blockDeviceIterator;
    uint64_t             previousDiskRead, previousDiskWrite;
    BOOL                 haveDiskBaseline;

    NSDate              *lastSampleDate;
    NSTimer             *timer;
    NSURLSession        *session;
    dispatch_queue_t     workQueue;

    MenuMeterReporterSetupWindowController *setupController;
}

+ (instancetype)sharedReporter {
    static MenuMeterReporter *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[MenuMeterReporter alloc] init];
    });
    return shared;
}

- (id)init {
    self = [super init];
    if (!self) return nil;

    cpuStats = [[MenuMeterCPUStats alloc] init];
    memStats = [[MenuMeterMemStats alloc] init];
    netStats = [[MenuMeterNetStats alloc] init];

    // Everything is sampled and sent on this one serial queue, which is also what
    // makes the non-thread-safe bits below (getmntinfo, the collectors' delta
    // state, the IOKit iterator) safe to use.
    workQueue = dispatch_queue_create("com.yujitach.MenuMeters.reporter", DISPATCH_QUEUE_SERIAL);

    // Ephemeral: no cookie jar, no on-disk cache, no credential storage.
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.HTTPShouldSetCookies = NO;
    config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    config.URLCache = nil;
    config.timeoutIntervalForRequest = kMenuMeterReporterRequestTimeout;
    session = [NSURLSession sessionWithConfiguration:config];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(settingsChanged:)
                                                 name:kMenuMeterReporterSettingsDidChangeNotification
                                               object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (blockDeviceIterator) IOObjectRelease(blockDeviceIterator);
}

#pragma mark - Scheduling

- (void)settingsChanged:(NSNotification *)notification {
    [self start];
}

- (void)start {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
        return;
    }

    MenuMeterReporterSettings *settings = [MenuMeterReporterSettings sharedSettings];
    if (!settings.isConfigured) {
        // Nothing configured: stay completely off the network.
        [timer invalidate];
        timer = nil;
        return;
    }

    // Saving settings fires one change notification per field, so this method is
    // called in bursts. Leave an already-correct timer alone, or every keystroke
    // in the settings pane would trigger another POST.
    NSTimeInterval interval = settings.intervalSeconds;
    BOOL wasRunning = (timer != nil);
    if (wasRunning && fabs(timer.timeInterval - interval) < 0.001) {
        return;
    }

    [timer invalidate];
    timer = [NSTimer scheduledTimerWithTimeInterval:interval
                                             target:self
                                           selector:@selector(timerFired:)
                                           userInfo:nil
                                            repeats:YES];
    // Lets the OS coalesce our wakeups with others, which matters on battery.
    timer.tolerance = interval * 0.1;

    if (!wasRunning) {
        // Send one sample straight away when reporting is first switched on, so
        // the user finds out immediately whether their endpoint works. Changing
        // the interval later only reschedules; it does not re-send.
        [self timerFired:nil];
    }
}

- (void)stop {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self stop]; });
        return;
    }
    [timer invalidate];
    timer = nil;
}

- (void)timerFired:(NSTimer *)firedTimer {
    dispatch_async(workQueue, ^{
        MenuMeterReporterSettings *settings = [MenuMeterReporterSettings sharedSettings];
        if (!settings.isConfigured) return;
        NSDictionary *payload = [self collectSnapshot];
        [self postPayload:payload completion:nil];
    });
}

#pragma mark - Sending

- (void)sendNowWithCompletion:(void (^)(BOOL, NSString *))completion {
    dispatch_async(workQueue, ^{
        MenuMeterReporterSettings *settings = [MenuMeterReporterSettings sharedSettings];
        if (settings.url == nil) {
            [self finishWithSuccess:NO
                            message:NSLocalizedString(@"No valid URL. Enter an http:// or https:// address.",
                                                      @"reporter status")
                         completion:completion];
            return;
        }
        NSDictionary *payload = [self collectSnapshot];
        [self postPayload:payload completion:completion];
    });
}

- (void)postPayload:(NSDictionary *)payload completion:(void (^)(BOOL, NSString *))completion {
    MenuMeterReporterSettings *settings = [MenuMeterReporterSettings sharedSettings];
    NSURL *url = settings.url;
    if (!url) {
        [self finishWithSuccess:NO
                        message:NSLocalizedString(@"No valid URL.", @"reporter status")
                     completion:completion];
        return;
    }

    // dataWithJSONObject: raises rather than returning an error for an invalid
    // object graph, and this runs on a background queue where an exception would
    // take the app down. Check first.
    if (![NSJSONSerialization isValidJSONObject:payload]) {
        [self finishWithSuccess:NO
                        message:NSLocalizedString(@"Internal error: payload is not valid JSON.",
                                                  @"reporter status")
                     completion:completion];
        return;
    }

    NSError *error = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (!body) {
        [self finishWithSuccess:NO
                        message:[NSString stringWithFormat:NSLocalizedString(@"Could not encode payload: %@",
                                                                            @"reporter status"),
                                 error.localizedDescription]
                     completion:completion];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    request.timeoutInterval = kMenuMeterReporterRequestTimeout;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"MenuMeters" forHTTPHeaderField:@"User-Agent"];

    NSString *headerName = settings.authHeaderName;
    NSString *headerValue = settings.authHeaderValue;
    if (headerName.length > 0 && headerValue.length > 0) {
        [request setValue:headerValue forHTTPHeaderField:headerName];
    }

    NSURLSessionDataTask *task =
    [session dataTaskWithRequest:request
               completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        if (taskError) {
            [self finishWithSuccess:NO
                            message:[NSString stringWithFormat:NSLocalizedString(@"Failed: %@", @"reporter status"),
                                     taskError.localizedDescription]
                         completion:completion];
            return;
        }
        NSInteger status = 0;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            status = ((NSHTTPURLResponse *)response).statusCode;
        }
        if (status >= 200 && status < 300) {
            self.lastSuccessDate = [NSDate date];
            [self finishWithSuccess:YES
                            message:[NSString stringWithFormat:NSLocalizedString(@"Sent %lu bytes, server replied %ld.",
                                                                                 @"reporter status"),
                                     (unsigned long)body.length, (long)status]
                         completion:completion];
        } else {
            [self finishWithSuccess:NO
                            message:[NSString stringWithFormat:NSLocalizedString(@"Server replied %ld.",
                                                                                 @"reporter status"),
                                     (long)status]
                         completion:completion];
        }
    }];
    [task resume];
}

- (void)finishWithSuccess:(BOOL)success
                  message:(NSString *)message
               completion:(void (^)(BOOL, NSString *))completion {
    self.lastStatusMessage = message;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kMenuMeterReporterStatusDidChangeNotification
                                                            object:self];
        if (completion) completion(success, message);
    });
}

#pragma mark - First run

- (void)presentFirstRunSetupIfNeeded {
    if ([MenuMeterReporterSettings sharedSettings].setupCompleted) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self presentFirstRunSetupIfNeeded]; });
        return;
    }
    setupController = [[MenuMeterReporterSetupWindowController alloc] init];
    [setupController present];
}

#pragma mark - Collection

- (NSDictionary *)collectSnapshot {
    MenuMeterReporterSettings *settings = [MenuMeterReporterSettings sharedSettings];

    NSDate *now = [NSDate date];
    NSTimeInterval elapsed = lastSampleDate ? [now timeIntervalSinceDate:lastSampleDate] : 0;
    if (elapsed <= 0) elapsed = settings.intervalSeconds;

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"schema"] = @"menumeters.metrics.v1";
    payload[@"device_id"] = settings.effectiveDeviceID;
    payload[@"host"] = settings.hostname;
    payload[@"timestamp"] = [self istTimestampForDate:now];
    payload[@"timestamp_unix"] = @((long long)[now timeIntervalSince1970]);
    payload[@"interval_seconds"] = @(elapsed);

    if (settings.includeSystem)      payload[@"system"] = [self systemSection];
    if (settings.includeCPU)         payload[@"cpu"] = [self cpuSection];
    if (settings.includeTemperature) {
        NSDictionary *temperature = [self temperatureSection];
        if (temperature) payload[@"temperature"] = temperature;
    }
    if (settings.includeMemory)      payload[@"memory"] = [self memorySection];
    if (settings.includeDisk)        payload[@"disk"] = [self diskSectionOverInterval:elapsed];
    if (settings.includeNetwork)     payload[@"network"] = [self networkSectionOverInterval:elapsed];

    lastSampleDate = now;
    return payload;
}

- (void)collectSnapshotJSONWithCompletion:(void (^)(NSString *))completion {
    dispatch_async(workQueue, ^{
        NSDictionary *payload = [self collectSnapshot];
        NSData *data = [NSJSONSerialization isValidJSONObject:payload]
                     ? [NSJSONSerialization dataWithJSONObject:payload
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:nil]
                     : nil;
        NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                              : @"(could not encode payload)";
        dispatch_async(dispatch_get_main_queue(), ^{ completion(json); });
    });
}

// Every timestamp this app emits is Indian Standard Time with an explicit offset.
- (NSString *)istTimestampForDate:(NSDate *)date {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Kolkata"];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssXXXXX";
    });
    return [formatter stringFromDate:date];
}

#pragma mark - Sections

- (NSDictionary *)systemSection {
    NSMutableDictionary *system = [NSMutableDictionary dictionary];

    NSString *model = [self sysctlStringForName:"hw.model"];
    if (model) system[@"model"] = model;

    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    system[@"os_version"] = [NSString stringWithFormat:@"%ld.%ld.%ld",
                             (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion];

    NSString *cpuName = [cpuStats cpuName];
    if (cpuName) system[@"cpu"] = cpuName;
    NSString *cpuSpeed = [cpuStats cpuSpeed];
    if (cpuSpeed) system[@"cpu_speed"] = cpuSpeed;
    system[@"cpu_packages"] = @([cpuStats numberOfCPUs]);
    system[@"cpu_cores"] = @([cpuStats numberOfCores]);

#if TARGET_CPU_ARM64
    system[@"architecture"] = @"arm64";
#elif TARGET_CPU_X86_64
    system[@"architecture"] = @"x86_64";
#endif

    NSString *appVersion = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"];
    if (appVersion) system[@"app_version"] = appVersion;

    double uptime = [self uptimeSeconds];
    if (uptime > 0) system[@"uptime_seconds"] = @((long long)uptime);

    return system;
}

- (NSDictionary *)cpuSection {
    NSMutableDictionary *cpu = [NSMutableDictionary dictionary];

    NSArray *loads = [cpuStats currentLoadBySorting:NO];
    if (loads.count) {
        NSMutableArray *perCore = [NSMutableArray arrayWithCapacity:loads.count];
        double userTotal = 0, systemTotal = 0;
        NSUInteger index = 0;
        for (MenuMeterCPULoad *load in loads) {
            // The collector reports fractions of one core; the payload uses percent.
            double userPercent = load.user * 100.0;
            double systemPercent = load.system * 100.0;
            userTotal += userPercent;
            systemTotal += systemPercent;
            [perCore addObject:@{ @"core": @(index),
                                  @"user_percent": @([self round2:userPercent]),
                                  @"system_percent": @([self round2:systemPercent]),
                                  @"total_percent": @([self round2:userPercent + systemPercent]) }];
            index++;
        }
        cpu[@"per_core"] = perCore;
        // Averaged across cores, so 100% means "every core saturated".
        double coreCount = (double)loads.count;
        cpu[@"user_percent"] = @([self round2:userTotal / coreCount]);
        cpu[@"system_percent"] = @([self round2:systemTotal / coreCount]);
        cpu[@"total_percent"] = @([self round2:(userTotal + systemTotal) / coreCount]);
        cpu[@"idle_percent"] = @([self round2:100.0 - ((userTotal + systemTotal) / coreCount)]);
    }

    double averages[3] = {0, 0, 0};
    if (getloadavg(averages, 3) == 3) {
        cpu[@"load_average"] = @{ @"1m":  @([self round2:averages[0]]),
                                  @"5m":  @([self round2:averages[1]]),
                                  @"15m": @([self round2:averages[2]]) };
    }

    // MenuMeterCPUStats only exposes these as a localized sentence, so read the
    // same Mach call directly to keep the payload numeric.
    struct processor_set_load_info loadInfo;
    mach_msg_type_number_t infoCount = PROCESSOR_SET_LOAD_INFO_COUNT;
    processor_set_name_port_t processorSet = MACH_PORT_NULL;
    host_name_port_t host = mach_host_self();
    if (processor_set_default(host, &processorSet) == KERN_SUCCESS) {
        if (processor_set_statistics(processorSet, PROCESSOR_SET_LOAD_INFO,
                                     (processor_set_info_t)&loadInfo, &infoCount) == KERN_SUCCESS) {
            cpu[@"process_count"] = @(loadInfo.task_count);
            cpu[@"thread_count"] = @(loadInfo.thread_count);
        }
        mach_port_deallocate(mach_task_self(), processorSet);
    }
    mach_port_deallocate(mach_task_self(), host);

    NSString *powerLimit = [cpuStats cpuPowerLimitStatus];
    if (powerLimit.length) cpu[@"power_limit_status"] = powerLimit;

    return cpu;
}

- (NSDictionary *)temperatureSection {
    MenuMeterReporterSettings *settings = [MenuMeterReporterSettings sharedSettings];

    // Same sensor the CPU tab's "show CPU temperature" option uses.
    NSString *sensor = [[MenuMeterDefaults sharedMenuMeterDefaults] cpuTemperatureSensor];
    if (!sensor || [sensor isEqualToString:kCPUTemperatureSensorDefault]) {
        sensor = [TemperatureReader defaultSensor];
    }

    NSMutableDictionary *temperature = [NSMutableDictionary dictionary];
    if (sensor) {
        float celsius = [TemperatureReader temperatureOfSensorWithName:sensor];
        if (celsius > kMenuMeterReporterNoTemperature && !isnan(celsius)) {
            temperature[@"sensor"] = sensor;
            NSString *displayName = [TemperatureReader displayNameForSensor:sensor];
            if (displayName) temperature[@"sensor_display_name"] = displayName;
            temperature[@"celsius"] = @([self round2:celsius]);
            temperature[@"fahrenheit"] = @([self round2:celsius * 9.0 / 5.0 + 32.0]);
        }
    }

    if (settings.includeAllTemperatureSensors) {
        NSMutableDictionary *all = [NSMutableDictionary dictionary];
        for (NSString *name in [TemperatureReader sensorNames]) {
            float celsius = [TemperatureReader temperatureOfSensorWithName:name];
            if (celsius > kMenuMeterReporterNoTemperature && !isnan(celsius)) {
                all[name] = @([self round2:celsius]);
            }
        }
        if (all.count) temperature[@"all_sensors_celsius"] = all;
    }

    return temperature.count ? temperature : nil;
}

- (NSDictionary *)memorySection {
    NSMutableDictionary *memory = [NSMutableDictionary dictionary];

    NSDictionary *stats = [memStats memStats];
    if (stats) {
        double total = [stats[@"totalmb"] doubleValue];
        double used = [stats[@"usedmb"] doubleValue];
        memory[@"total_mb"] = @([self round2:total]);
        memory[@"used_mb"] = @([self round2:used]);
        memory[@"free_mb"] = @([self round2:[stats[@"freemb"] doubleValue]]);
        memory[@"active_mb"] = @([self round2:[stats[@"activemb"] doubleValue]]);
        memory[@"inactive_mb"] = @([self round2:[stats[@"inactivemb"] doubleValue]]);
        memory[@"wired_mb"] = @([self round2:[stats[@"wiremb"] doubleValue]]);
        memory[@"compressed_mb"] = @([self round2:[stats[@"compressedmb"] doubleValue]]);
        if (total > 0) memory[@"used_percent"] = @([self round2:used / total * 100.0]);
        memory[@"page_ins"] = stats[@"pageins"] ?: @0;
        memory[@"page_outs"] = stats[@"pageouts"] ?: @0;
        memory[@"page_ins_delta"] = stats[@"deltapageins"] ?: @0;
        memory[@"page_outs_delta"] = stats[@"deltapageouts"] ?: @0;
    }

    NSDictionary *swap = [memStats swapStats];
    if (swap) {
        memory[@"swap"] = @{ @"file_count": swap[@"swapcount"] ?: @0,
                             @"size_mb":    swap[@"swapsizemb"] ?: @0,
                             @"used_mb":    swap[@"swapusedmb"] ?: @0,
                             @"encrypted":  swap[@"swapencrypted"] ?: @NO };
    }

    return memory;
}

- (NSDictionary *)diskSectionOverInterval:(NSTimeInterval)elapsed {
    NSMutableDictionary *disk = [NSMutableDictionary dictionary];

    NSDictionary *io = [self diskIOOverInterval:elapsed];
    if (io) disk[@"io"] = io;

    NSArray *volumes = [self volumes];
    if (volumes) disk[@"volumes"] = volumes;

    return disk;
}

// Cumulative bytes read/written across every block storage driver, plus the rate
// since the previous sample. Same IOKit keys MenuMeterDiskIO uses.
- (NSDictionary *)diskIOOverInterval:(NSTimeInterval)elapsed {
    if (!blockDeviceIterator) {
        kern_return_t err = IOServiceGetMatchingServices(kIOMasterPortDefault,
                                                         IOServiceMatching(kIOBlockStorageDriverClass),
                                                         &blockDeviceIterator);
        if (err != KERN_SUCCESS) return nil;
    }

    uint64_t totalRead = 0, totalWrite = 0;
    io_registry_entry_t driveEntry = MACH_PORT_NULL;
    while ((driveEntry = IOIteratorNext(blockDeviceIterator))) {
        NSDictionary *statistics =
            CFBridgingRelease(IORegistryEntryCreateCFProperty(driveEntry,
                                                              CFSTR(kIOBlockStorageDriverStatisticsKey),
                                                              kCFAllocatorDefault,
                                                              kNilOptions));
        if (statistics) {
            NSNumber *value = statistics[(NSString *)CFSTR(kIOBlockStorageDriverStatisticsBytesReadKey)];
            if (value) totalRead += [value unsignedLongLongValue];
            value = statistics[(NSString *)CFSTR(kIOBlockStorageDriverStatisticsBytesWrittenKey)];
            if (value) totalWrite += [value unsignedLongLongValue];
        }
        IOObjectRelease(driveEntry);
    }
    IOIteratorReset(blockDeviceIterator);

    NSMutableDictionary *io = [NSMutableDictionary dictionary];
    io[@"read_bytes_total"] = @(totalRead);
    io[@"write_bytes_total"] = @(totalWrite);

    // Rates need a previous sample, and drives coming and going can make the
    // totals go backwards; report a rate only when it makes sense.
    if (haveDiskBaseline && elapsed > 0 &&
        totalRead >= previousDiskRead && totalWrite >= previousDiskWrite) {
        io[@"read_bytes_per_sec"] = @([self round2:(double)(totalRead - previousDiskRead) / elapsed]);
        io[@"write_bytes_per_sec"] = @([self round2:(double)(totalWrite - previousDiskWrite) / elapsed]);
    }
    previousDiskRead = totalRead;
    previousDiskWrite = totalWrite;
    haveDiskBaseline = YES;

    return io;
}

- (NSArray *)volumes {
    struct statfs *mounts = NULL;
    int count = getmntinfo(&mounts, MNT_NOWAIT);
    if (count <= 0) return nil;

    NSMutableArray *volumes = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        // Skip the pseudo-filesystems; they have no meaningful capacity.
        const char *type = mounts[i].f_fstypename;
        if (strcmp(type, "devfs") == 0 || strcmp(type, "autofs") == 0 ||
            strcmp(type, "map") == 0 || mounts[i].f_blocks == 0) {
            continue;
        }

        uint64_t blockSize = mounts[i].f_bsize;
        uint64_t total = mounts[i].f_blocks * blockSize;
        // f_bavail is what a normal user can actually use; f_bfree includes
        // reserve blocks and reads as more free space than the Finder shows.
        uint64_t available = mounts[i].f_bavail * blockSize;
        uint64_t used = total - (mounts[i].f_bfree * blockSize);

        NSString *mountPoint = [NSString stringWithUTF8String:mounts[i].f_mntonname];
        if (!mountPoint) continue;   // non-UTF8 mount name; skip rather than ship a hole

        NSMutableDictionary *volume = [NSMutableDictionary dictionary];
        volume[@"mount_point"] = mountPoint;
        volume[@"device"] = [NSString stringWithUTF8String:mounts[i].f_mntfromname];
        volume[@"fs_type"] = [NSString stringWithUTF8String:type];
        volume[@"total_bytes"] = @(total);
        volume[@"free_bytes"] = @(available);
        volume[@"used_bytes"] = @(used);
        volume[@"read_only"] = @((mounts[i].f_flags & MNT_RDONLY) != 0);
        if (total > 0) volume[@"used_percent"] = @([self round2:(double)used / (double)total * 100.0]);

        NSString *name = [[NSFileManager defaultManager] displayNameAtPath:mountPoint];
        if (name) volume[@"name"] = name;

        [volumes addObject:volume];
    }
    return volumes;
}

- (NSDictionary *)networkSectionOverInterval:(NSTimeInterval)elapsed {
    NSDictionary *stats = [netStats netStatsForInterval:elapsed];
    if (!stats) return nil;

    NSMutableArray *interfaces = [NSMutableArray array];
    uint64_t sumIn = 0, sumOut = 0;
    double sumInRate = 0, sumOutRate = 0;

    for (NSString *name in stats) {
        // Loopback traffic tells the user nothing about their machine's link.
        if ([name hasPrefix:@"lo"]) continue;

        NSDictionary *interfaceStats = stats[name];
        uint64_t totalIn = [interfaceStats[@"totalin"] unsignedLongLongValue];
        uint64_t totalOut = [interfaceStats[@"totalout"] unsignedLongLongValue];

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"name"] = name;
        entry[@"bytes_in_total"] = @(totalIn);
        entry[@"bytes_out_total"] = @(totalOut);

        // deltain/deltaout are bytes since our previous sample, absent on the
        // very first one.
        if (interfaceStats[@"deltain"] && elapsed > 0) {
            double inRate = [interfaceStats[@"deltain"] unsignedLongLongValue] / elapsed;
            double outRate = [interfaceStats[@"deltaout"] unsignedLongLongValue] / elapsed;
            entry[@"bytes_in_per_sec"] = @([self round2:inRate]);
            entry[@"bytes_out_per_sec"] = @([self round2:outRate]);
            sumInRate += inRate;
            sumOutRate += outRate;
        }

        sumIn += totalIn;
        sumOut += totalOut;
        [interfaces addObject:entry];
    }

    return @{ @"interfaces": interfaces,
              @"totals": @{ @"bytes_in_total": @(sumIn),
                            @"bytes_out_total": @(sumOut),
                            @"bytes_in_per_sec": @([self round2:sumInRate]),
                            @"bytes_out_per_sec": @([self round2:sumOutRate]) } };
}

#pragma mark - Small helpers

// Keeps the JSON readable instead of carrying 15 digits of float noise.
- (double)round2:(double)value {
    if (isnan(value) || isinf(value)) return 0;
    return round(value * 100.0) / 100.0;
}

- (double)uptimeSeconds {
    struct timeval bootTime;
    size_t size = sizeof(bootTime);
    int mib[2] = { CTL_KERN, KERN_BOOTTIME };
    if (sysctl(mib, 2, &bootTime, &size, NULL, 0) != 0 || bootTime.tv_sec == 0) return 0;
    return [[NSDate date] timeIntervalSince1970] - (double)bootTime.tv_sec;
}

- (NSString *)sysctlStringForName:(const char *)name {
    size_t size = 0;
    if (sysctlbyname(name, NULL, &size, NULL, 0) != 0 || size == 0) return nil;
    char *buffer = malloc(size);
    if (!buffer) return nil;
    NSString *result = nil;
    if (sysctlbyname(name, buffer, &size, NULL, 0) == 0) {
        result = [NSString stringWithUTF8String:buffer];
    }
    free(buffer);
    return result;
}

@end
