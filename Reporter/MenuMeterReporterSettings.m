//
//  MenuMeterReporterSettings.m
//
//  This file is part of MenuMeters, GPL v2. See LICENSE.
//

#import "MenuMeterReporterSettings.h"

NSString * const kMenuMeterReporterSettingsDidChangeNotification = @"MenuMeterReporterSettingsDidChange";

// Defaults keys. Prefixed like the rest of MenuMeters' preferences.
static NSString * const kReporterEnabledPref          = @"ReporterEnabled";
static NSString * const kReporterURLPref              = @"ReporterURL";
static NSString * const kReporterIntervalPref         = @"ReporterInterval";
static NSString * const kReporterAuthHeaderNamePref   = @"ReporterAuthHeaderName";
static NSString * const kReporterAuthHeaderValuePref  = @"ReporterAuthHeaderValue";
static NSString * const kReporterDeviceIDPref         = @"ReporterDeviceID";
static NSString * const kReporterIncludeSystemPref    = @"ReporterIncludeSystem";
static NSString * const kReporterIncludeCPUPref       = @"ReporterIncludeCPU";
static NSString * const kReporterIncludeTempPref      = @"ReporterIncludeTemperature";
static NSString * const kReporterIncludeMemoryPref    = @"ReporterIncludeMemory";
static NSString * const kReporterIncludeDiskPref      = @"ReporterIncludeDisk";
static NSString * const kReporterIncludeNetworkPref   = @"ReporterIncludeNetwork";
static NSString * const kReporterAllTempSensorsPref   = @"ReporterAllTemperatureSensors";
static NSString * const kReporterSetupCompletedPref   = @"ReporterSetupCompleted";

@implementation MenuMeterReporterSettings

+ (instancetype)sharedSettings {
    static MenuMeterReporterSettings *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[MenuMeterReporterSettings alloc] init];
    });
    return shared;
}

- (id)init {
    self = [super init];
    if (!self) return nil;
    // Sections all default to on; nothing is transmitted anyway until there is a URL.
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kReporterEnabledPref        : @NO,
        kReporterURLPref            : @"",
        kReporterIntervalPref       : @(kMenuMeterReporterIntervalDefault),
        kReporterAuthHeaderNamePref : @"",
        kReporterAuthHeaderValuePref: @"",
        kReporterDeviceIDPref       : @"",
        kReporterIncludeSystemPref  : @YES,
        kReporterIncludeCPUPref     : @YES,
        kReporterIncludeTempPref    : @YES,
        kReporterIncludeMemoryPref  : @YES,
        kReporterIncludeDiskPref    : @YES,
        kReporterIncludeNetworkPref : @YES,
        kReporterAllTempSensorsPref : @NO,
        kReporterSetupCompletedPref : @NO,
    }];
    return self;
}

#pragma mark - Generic accessors

- (BOOL)boolForKey:(NSString *)key {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

- (void)setBool:(BOOL)value forKey:(NSString *)key {
    if ([self boolForKey:key] == value) return;
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
    [self notifyChanged];
}

- (NSString *)stringForKey:(NSString *)key {
    NSString *value = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

- (void)setString:(NSString *)value forKey:(NSString *)key {
    NSString *clean = value ? value : @"";
    if ([[self stringForKey:key] isEqualToString:clean]) return;
    [[NSUserDefaults standardUserDefaults] setObject:clean forKey:key];
    [self notifyChanged];
}

- (void)notifyChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:kMenuMeterReporterSettingsDidChangeNotification
                                                        object:self];
}

#pragma mark - Settings

- (BOOL)enabled                       { return [self boolForKey:kReporterEnabledPref]; }
- (void)setEnabled:(BOOL)v            { [self setBool:v forKey:kReporterEnabledPref]; }

- (NSString *)urlString               { return [self stringForKey:kReporterURLPref]; }
- (void)setUrlString:(NSString *)v {
    // Tolerate a pasted URL with stray whitespace.
    [self setString:[v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
             forKey:kReporterURLPref];
}

- (double)intervalSeconds {
    double value = [[NSUserDefaults standardUserDefaults] doubleForKey:kReporterIntervalPref];
    if (value < kMenuMeterReporterIntervalMin) return kMenuMeterReporterIntervalDefault;
    if (value > kMenuMeterReporterIntervalMax) return kMenuMeterReporterIntervalMax;
    return value;
}

- (void)setIntervalSeconds:(double)v {
    double clamped = v;
    if (clamped < kMenuMeterReporterIntervalMin) clamped = kMenuMeterReporterIntervalMin;
    if (clamped > kMenuMeterReporterIntervalMax) clamped = kMenuMeterReporterIntervalMax;
    if (fabs([self intervalSeconds] - clamped) < 0.001) return;
    [[NSUserDefaults standardUserDefaults] setDouble:clamped forKey:kReporterIntervalPref];
    [self notifyChanged];
}

- (NSString *)authHeaderName          { return [self stringForKey:kReporterAuthHeaderNamePref]; }
- (void)setAuthHeaderName:(NSString *)v {
    [self setString:[v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
             forKey:kReporterAuthHeaderNamePref];
}

- (NSString *)authHeaderValue         { return [self stringForKey:kReporterAuthHeaderValuePref]; }
- (void)setAuthHeaderValue:(NSString *)v { [self setString:v forKey:kReporterAuthHeaderValuePref]; }

- (NSString *)deviceID                { return [self stringForKey:kReporterDeviceIDPref]; }
- (void)setDeviceID:(NSString *)v {
    [self setString:[v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
             forKey:kReporterDeviceIDPref];
}

- (BOOL)includeSystem                 { return [self boolForKey:kReporterIncludeSystemPref]; }
- (void)setIncludeSystem:(BOOL)v      { [self setBool:v forKey:kReporterIncludeSystemPref]; }

- (BOOL)includeCPU                    { return [self boolForKey:kReporterIncludeCPUPref]; }
- (void)setIncludeCPU:(BOOL)v         { [self setBool:v forKey:kReporterIncludeCPUPref]; }

- (BOOL)includeTemperature            { return [self boolForKey:kReporterIncludeTempPref]; }
- (void)setIncludeTemperature:(BOOL)v { [self setBool:v forKey:kReporterIncludeTempPref]; }

- (BOOL)includeMemory                 { return [self boolForKey:kReporterIncludeMemoryPref]; }
- (void)setIncludeMemory:(BOOL)v      { [self setBool:v forKey:kReporterIncludeMemoryPref]; }

- (BOOL)includeDisk                   { return [self boolForKey:kReporterIncludeDiskPref]; }
- (void)setIncludeDisk:(BOOL)v        { [self setBool:v forKey:kReporterIncludeDiskPref]; }

- (BOOL)includeNetwork                { return [self boolForKey:kReporterIncludeNetworkPref]; }
- (void)setIncludeNetwork:(BOOL)v     { [self setBool:v forKey:kReporterIncludeNetworkPref]; }

- (BOOL)includeAllTemperatureSensors  { return [self boolForKey:kReporterAllTempSensorsPref]; }
- (void)setIncludeAllTemperatureSensors:(BOOL)v { [self setBool:v forKey:kReporterAllTempSensorsPref]; }

- (BOOL)setupCompleted                { return [self boolForKey:kReporterSetupCompletedPref]; }
- (void)setSetupCompleted:(BOOL)v     { [self setBool:v forKey:kReporterSetupCompletedPref]; }

#pragma mark - Derived

- (NSURL *)url {
    NSString *string = self.urlString;
    if (string.length == 0) return nil;
    NSURL *candidate = [NSURL URLWithString:string];
    if (!candidate.scheme || !candidate.host) return nil;
    NSString *scheme = candidate.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;
    return candidate;
}

- (BOOL)isConfigured {
    return self.enabled && (self.url != nil);
}

- (NSString *)hostname {
    // NSProcessInfo hands back things like "mymac.local"; keep it as-is, it is
    // what the user sees in Sharing preferences.
    NSString *name = [[NSProcessInfo processInfo] hostName];
    return name.length ? name : @"unknown";
}

- (NSString *)effectiveDeviceID {
    NSString *identifier = self.deviceID;
    return identifier.length > 0 ? identifier : self.hostname;
}

@end
