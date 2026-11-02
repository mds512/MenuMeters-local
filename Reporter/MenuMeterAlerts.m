//
//  MenuMeterAlerts.m
//
//  This file is part of MenuMeters, GPL v2. See LICENSE.
//

#import "MenuMeterAlerts.h"

#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>

NSString * const kMenuMeterAlertsDidChangeNotification = @"MenuMeterAlertsDidChange";

NSString * const kMenuMeterAlertSectionCPU         = @"cpu";
NSString * const kMenuMeterAlertSectionTemperature = @"temperature";
NSString * const kMenuMeterAlertSectionDisk        = @"disk";
NSString * const kMenuMeterAlertSectionNetwork     = @"network";

// Preference keys. Deliberately plain, because Phase 1 sets them with `defaults
// write` and a person has to type them.
static NSString * const kAlertsEnabledPref        = @"AlertsEnabled";
static NSString * const kAlertTemperaturePref     = @"AlertTemperatureC";
static NSString * const kAlertCPUPref             = @"AlertCPUPercent";
static NSString * const kAlertDiskPref            = @"AlertDiskPercent";
static NSString * const kAlertNetworkPref         = @"AlertNetworkBytesPerSec";
static NSString * const kAlertCooldownPref        = @"AlertCooldownSeconds";
static NSString * const kAlertConsecutivePref     = @"AlertConsecutiveSamples";

@interface MenuMeterAlerts ()
// Written from a notification-authorization callback on an arbitrary queue and
// read on the sampling queue, hence atomic.
@property (atomic, assign) BOOL notificationsAuthorized;
@property (atomic, copy) NSString *deliveryRouteDescription;
@property (atomic, copy, nullable) NSDictionary<NSString *, NSString *> *lastObservedValues;
@end

@implementation MenuMeterAlerts {
    // Touched only from the reporter's serial work queue. See -evaluateSnapshot:.
    NSMutableDictionary<NSString *, NSNumber *> *streaks;
    NSMutableDictionary<NSString *, NSDate *>   *lastNotified;
}

+ (instancetype)sharedAlerts {
    static MenuMeterAlerts *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[MenuMeterAlerts alloc] init]; });
    return shared;
}

- (id)init {
    self = [super init];
    if (!self) return nil;
    streaks = [NSMutableDictionary dictionary];
    lastNotified = [NSMutableDictionary dictionary];
    _deliveryRouteDescription = @"not yet delivered";
    return self;
}

#pragma mark - Settings

// Every setting is a plain preference, so the Notifs tab and `defaults write`
// are interchangeable. Writes post a change notification because the reporter's
// sampling timer only runs while isActive, and toggling that has to restart it.

- (void)notifyChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:kMenuMeterAlertsDidChangeNotification
                                                        object:self];
}

- (double)limitForKey:(NSString *)key {
    double value = [[NSUserDefaults standardUserDefaults] doubleForKey:key];
    return (value > 0) ? value : 0;   // 0 or negative means "not watched"
}

- (void)setLimit:(double)value forKey:(NSString *)key {
    double clean = (value > 0) ? value : 0;
    if (fabs([self limitForKey:key] - clean) < 0.0001) return;
    [[NSUserDefaults standardUserDefaults] setDouble:clean forKey:key];
    [self notifyChanged];
}

- (BOOL)enabled { return [[NSUserDefaults standardUserDefaults] boolForKey:kAlertsEnabledPref]; }
- (void)setEnabled:(BOOL)value {
    if (self.enabled == value) return;
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:kAlertsEnabledPref];
    [self notifyChanged];
}

- (double)temperatureLimitC { return [self limitForKey:kAlertTemperaturePref]; }
- (void)setTemperatureLimitC:(double)v { [self setLimit:v forKey:kAlertTemperaturePref]; }

- (double)cpuLimitPercent { return [self limitForKey:kAlertCPUPref]; }
- (void)setCpuLimitPercent:(double)v { [self setLimit:v forKey:kAlertCPUPref]; }

- (double)diskLimitPercent { return [self limitForKey:kAlertDiskPref]; }
- (void)setDiskLimitPercent:(double)v { [self setLimit:v forKey:kAlertDiskPref]; }

- (double)networkLimitBytesPerSecond { return [self limitForKey:kAlertNetworkPref]; }
- (void)setNetworkLimitBytesPerSecond:(double)v { [self setLimit:v forKey:kAlertNetworkPref]; }

- (NSTimeInterval)cooldownSeconds {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:kAlertCooldownPref]) return kMenuMeterAlertCooldownDefault;
    NSTimeInterval value = [defaults doubleForKey:kAlertCooldownPref];
    return (value < kMenuMeterAlertCooldownMin) ? kMenuMeterAlertCooldownMin : value;
}

- (void)setCooldownSeconds:(NSTimeInterval)value {
    NSTimeInterval clamped = (value < kMenuMeterAlertCooldownMin) ? kMenuMeterAlertCooldownMin : value;
    if (fabs(self.cooldownSeconds - clamped) < 0.001) return;
    [[NSUserDefaults standardUserDefaults] setDouble:clamped forKey:kAlertCooldownPref];
    [self notifyChanged];
}

- (NSInteger)consecutiveSamples {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:kAlertConsecutivePref]) return kMenuMeterAlertConsecutiveDefault;
    NSInteger value = [defaults integerForKey:kAlertConsecutivePref];
    if (value < kMenuMeterAlertConsecutiveMin) return kMenuMeterAlertConsecutiveMin;
    if (value > kMenuMeterAlertConsecutiveMax) return kMenuMeterAlertConsecutiveMax;
    return value;
}

- (void)setConsecutiveSamples:(NSInteger)value {
    NSInteger clamped = value;
    if (clamped < kMenuMeterAlertConsecutiveMin) clamped = kMenuMeterAlertConsecutiveMin;
    if (clamped > kMenuMeterAlertConsecutiveMax) clamped = kMenuMeterAlertConsecutiveMax;
    if (self.consecutiveSamples == clamped) return;
    [[NSUserDefaults standardUserDefaults] setInteger:clamped forKey:kAlertConsecutivePref];
    [self notifyChanged];
}

- (NSSet<NSString *> *)requiredSections {
    NSMutableSet *needed = [NSMutableSet set];
    if (!self.enabled) return needed;
    if (self.temperatureLimitC > 0)          [needed addObject:kMenuMeterAlertSectionTemperature];
    if (self.cpuLimitPercent > 0)            [needed addObject:kMenuMeterAlertSectionCPU];
    if (self.diskLimitPercent > 0)           [needed addObject:kMenuMeterAlertSectionDisk];
    if (self.networkLimitBytesPerSecond > 0) [needed addObject:kMenuMeterAlertSectionNetwork];
    return needed;
}

- (BOOL)isActive {
    return self.requiredSections.count > 0;
}

- (NSString *)armedSummary {
    if (!self.enabled) {
        return NSLocalizedString(@"Alerts are switched off.", @"alert");
    }
    NSMutableArray *parts = [NSMutableArray array];
    double value = 0;
    if ((value = self.temperatureLimitC) > 0) {
        [parts addObject:[NSString stringWithFormat:NSLocalizedString(@"temperature above %.0f °C", @"alert"), value]];
    }
    if ((value = self.cpuLimitPercent) > 0) {
        [parts addObject:[NSString stringWithFormat:NSLocalizedString(@"CPU above %.0f%%", @"alert"), value]];
    }
    if ((value = self.diskLimitPercent) > 0) {
        [parts addObject:[NSString stringWithFormat:NSLocalizedString(@"disk above %.0f%% full", @"alert"), value]];
    }
    if ((value = self.networkLimitBytesPerSecond) > 0) {
        [parts addObject:[NSString stringWithFormat:NSLocalizedString(@"network above %@/s", @"alert"),
                          [self humanBytes:value]]];
    }
    if (parts.count == 0) {
        return NSLocalizedString(@"Alerts are on, but no threshold is set, so nothing is watched.", @"alert");
    }
    return [NSString stringWithFormat:NSLocalizedString(@"Watching: %@. Re-notifies at most every %.0f min, after %ld samples in a row.", @"alert"),
            [parts componentsJoinedByString:@", "], self.cooldownSeconds / 60.0, (long)self.consecutiveSamples];
}

- (void)sendTestNotificationWithCompletion:(void (^)(BOOL, NSString *))completion {
    [self prepare];
    [self deliverTitle:NSLocalizedString(@"MenuMeters test", @"alert")
                  body:NSLocalizedString(@"If you can see this, threshold alerts can reach you.", @"alert")
            completion:^(BOOL delivered, NSString *route) {
        if (!completion) return;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(delivered, route); });
    }];
}

#pragma mark - Evaluation

- (void)evaluateSnapshot:(NSDictionary *)snapshot {

    if (!snapshot) return;

    // Recorded purely so the Notifs tab can show what the engine is actually
    // seeing. If this stays empty, nothing is sampling.
    NSMutableDictionary *observed = [NSMutableDictionary dictionary];
    double limit = 0;

    // --- Temperature ---
    limit = self.temperatureLimitC;
    if (limit > 0) {
        NSNumber *celsius = snapshot[kMenuMeterAlertSectionTemperature][@"celsius"];
        [self considerMetric:@"temperature"
                       value:celsius
                       limit:limit
                     breached:(celsius != nil && celsius.doubleValue > limit)
                       title:NSLocalizedString(@"MenuMeters: temperature", @"alert")
                        body:[NSString stringWithFormat:
                              NSLocalizedString(@"%@ is at %.1f °C, over the %.0f °C limit.", @"alert"),
                              snapshot[kMenuMeterAlertSectionTemperature][@"sensor_display_name"]
                                  ?: snapshot[kMenuMeterAlertSectionTemperature][@"sensor"]
                                  ?: NSLocalizedString(@"Temperature", @"alert"),
                              celsius.doubleValue, limit]];
        observed[@"temperature"] = celsius
            ? [NSString stringWithFormat:@"%.1f °C (limit %.0f °C)", celsius.doubleValue, limit]
            : NSLocalizedString(@"no reading from the selected sensor", @"alert");
    }

    // --- CPU ---
    limit = self.cpuLimitPercent;
    if (limit > 0) {
        NSNumber *percent = snapshot[kMenuMeterAlertSectionCPU][@"total_percent"];
        [self considerMetric:@"cpu"
                       value:percent
                       limit:limit
                     breached:(percent != nil && percent.doubleValue > limit)
                       title:NSLocalizedString(@"MenuMeters: CPU", @"alert")
                        body:[NSString stringWithFormat:
                              NSLocalizedString(@"CPU is at %.0f%%, over the %.0f%% limit.", @"alert"),
                              percent.doubleValue, limit]];
        observed[@"cpu"] = percent
            ? [NSString stringWithFormat:@"%.0f%% (limit %.0f%%)", percent.doubleValue, limit]
            : NSLocalizedString(@"no reading", @"alert");
    }

    // --- Disk: the fullest mounted volume ---
    limit = self.diskLimitPercent;
    if (limit > 0) {
        NSString *fullestName = nil;
        double fullestPercent = -1;
        for (NSDictionary *volume in snapshot[kMenuMeterAlertSectionDisk][@"volumes"]) {
            NSNumber *used = volume[@"used_percent"];
            if (used && used.doubleValue > fullestPercent) {
                fullestPercent = used.doubleValue;
                fullestName = volume[@"name"] ?: volume[@"mount_point"];
            }
        }
        [self considerMetric:@"disk"
                       value:(fullestPercent >= 0 ? @(fullestPercent) : nil)
                       limit:limit
                     breached:(fullestPercent > limit)
                       title:NSLocalizedString(@"MenuMeters: disk", @"alert")
                        body:[NSString stringWithFormat:
                              NSLocalizedString(@"%@ is %.0f%% full, over the %.0f%% limit.", @"alert"),
                              fullestName ?: NSLocalizedString(@"A volume", @"alert"),
                              fullestPercent, limit]];
        observed[@"disk"] = (fullestPercent >= 0)
            ? [NSString stringWithFormat:@"%@ %.0f%% full (limit %.0f%%)",
               fullestName ?: @"?", fullestPercent, limit]
            : NSLocalizedString(@"no volumes read", @"alert");
    }

    // --- Network: whichever direction is busier ---
    limit = self.networkLimitBytesPerSecond;
    if (limit > 0) {
        NSDictionary *totals = snapshot[kMenuMeterAlertSectionNetwork][@"totals"];
        NSNumber *in = totals[@"bytes_in_per_sec"];
        NSNumber *out = totals[@"bytes_out_per_sec"];
        BOOL haveRate = (in != nil || out != nil);
        double inRate = in.doubleValue, outRate = out.doubleValue;
        BOOL downBusier = (inRate >= outRate);
        double busiest = downBusier ? inRate : outRate;
        [self considerMetric:@"network"
                       value:(haveRate ? @(busiest) : nil)
                       limit:limit
                     breached:(haveRate && busiest > limit)
                       title:NSLocalizedString(@"MenuMeters: network", @"alert")
                        body:[NSString stringWithFormat:
                              NSLocalizedString(@"Network %@ is %@/s, over the %@/s limit.", @"alert"),
                              downBusier ? NSLocalizedString(@"download", @"alert")
                                         : NSLocalizedString(@"upload", @"alert"),
                              [self humanBytes:busiest], [self humanBytes:limit]]];
        observed[@"network"] = haveRate
            ? [NSString stringWithFormat:@"%@/s %@ (limit %@/s)", [self humanBytes:busiest],
               downBusier ? @"down" : @"up", [self humanBytes:limit]]
            : NSLocalizedString(@"no rate yet (needs two samples)", @"alert");
    }

    self.lastObservedValues = observed;
}

// Streak and cooldown bookkeeping, shared by every metric.
//
// The streak keeps counting while the value stays over the line, so once it has
// passed the consecutive-samples requirement the cooldown alone decides when the
// next notification goes out. That is what makes it re-notify every cooldown
// while the condition persists, rather than only once.
- (void)considerMetric:(NSString *)key
                 value:(NSNumber *)value
                 limit:(double)limit
              breached:(BOOL)breached
                 title:(NSString *)title
                  body:(NSString *)body {

    if (!breached) {
        // Recovered, or the section was missing from this sample. Either way the
        // run is broken and the next breach starts counting again from one.
        streaks[key] = @0;
        return;
    }

    NSInteger streak = streaks[key].integerValue + 1;
    streaks[key] = @(streak);
    if (streak < self.consecutiveSamples) return;

    NSDate *previous = lastNotified[key];
    NSDate *now = [NSDate date];
    if (previous && [now timeIntervalSinceDate:previous] < self.cooldownSeconds) return;

    lastNotified[key] = now;
    [self deliverTitle:title body:body];
    NSLog(@"MenuMeterAlerts: %@", body);
}

- (NSString *)humanBytes:(double)bytesPerSecond {
    if (bytesPerSecond >= 1000.0 * 1000.0 * 1000.0) return [NSString stringWithFormat:@"%.1f GB", bytesPerSecond / 1e9];
    if (bytesPerSecond >= 1000.0 * 1000.0)          return [NSString stringWithFormat:@"%.1f MB", bytesPerSecond / 1e6];
    if (bytesPerSecond >= 1000.0)                   return [NSString stringWithFormat:@"%.0f KB", bytesPerSecond / 1e3];
    return [NSString stringWithFormat:@"%.0f B", bytesPerSecond];
}

#pragma mark - Delivery

- (void)prepare {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(macOS 10.14, *)) {
            // currentNotificationCenter raises for a bundle with no identifier,
            // which is the case when the binary is run outside an .app wrapper.
            if ([NSBundle mainBundle].bundleIdentifier.length == 0) {
                NSLog(@"MenuMeterAlerts: no bundle identifier; using the osascript fallback.");
                return;
            }
            @try {
                UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
                [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                                      completionHandler:^(BOOL granted, NSError *error) {
                    self.notificationsAuthorized = granted;
                    if (!granted) {
                        // Expected on an ad-hoc signed build that macOS does not
                        // recognise as a stable identity. The fallback covers it.
                        NSLog(@"MenuMeterAlerts: notification authorization refused (%@); "
                              @"falling back to osascript.", error.localizedDescription ?: @"denied");
                    }
                }];
            }
            @catch (NSException *exception) {
                NSLog(@"MenuMeterAlerts: notification centre unavailable (%@); using the osascript fallback.",
                      exception.reason);
            }
        }
    });
}

- (void)deliverTitle:(NSString *)title body:(NSString *)body {
    [self deliverTitle:title body:body completion:nil];
}

- (void)deliverTitle:(NSString *)title body:(NSString *)body completion:(void (^)(BOOL, NSString *))completion {

    if (self.notificationsAuthorized) {
        if (@available(macOS 10.14, *)) {
            @try {
                UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
                content.title = title;
                content.body = body;
                content.sound = [UNNotificationSound defaultSound];

                UNNotificationRequest *request =
                    [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString]
                                                         content:content
                                                         trigger:nil];
                [[UNUserNotificationCenter currentNotificationCenter]
                    addNotificationRequest:request
                     withCompletionHandler:^(NSError *error) {
                    if (error) {
                        NSLog(@"MenuMeterAlerts: notification refused (%@); retrying via osascript.",
                              error.localizedDescription);
                        BOOL ok = [self deliverViaOsascriptTitle:title body:body];
                        if (completion) completion(ok, self.deliveryRouteDescription);
                        return;
                    }
                    self.deliveryRouteDescription = @"Notification Centre";
                    if (completion) completion(YES, self.deliveryRouteDescription);
                }];
                return;
            }
            @catch (NSException *exception) {
                NSLog(@"MenuMeterAlerts: notification post failed (%@).", exception.reason);
            }
        }
    }

    BOOL ok = [self deliverViaOsascriptTitle:title body:body];
    if (completion) completion(ok, self.deliveryRouteDescription);
}

// Fallback for a build macOS will not grant notification rights to. The
// notification is posted by Script Editor rather than MenuMeters, so it shows
// that name, but it does get through without a signed, registered identity.
//
// Run with an argument vector, never a shell: the volume name interpolated into
// the message comes from the filesystem and is not ours to trust.
- (BOOL)deliverViaOsascriptTitle:(NSString *)title body:(NSString *)body {

    NSString *script = [NSString stringWithFormat:@"display notification \"%@\" with title \"%@\"",
                        [self appleScriptQuoted:body], [self appleScriptQuoted:title]];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/osascript";
    task.arguments = @[@"-e", script];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    @try {
        [task launch];
        [task waitUntilExit];
    }
    @catch (NSException *exception) {
        NSLog(@"MenuMeterAlerts: could not run osascript (%@).", exception.reason);
        self.deliveryRouteDescription = @"delivery failed";
        return NO;
    }

    BOOL ok = (task.terminationStatus == 0);
    self.deliveryRouteDescription = ok ? @"Script Editor (fallback)" : @"delivery failed";
    return ok;
}

// Escapes a string for an AppleScript double-quoted literal. Backslash first,
// or it would double the backslashes added for the quotes. Newlines are folded
// to spaces because such a literal cannot span lines.
- (NSString *)appleScriptQuoted:(NSString *)text {
    NSString *escaped = text ?: @"";
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    return escaped;
}

@end
