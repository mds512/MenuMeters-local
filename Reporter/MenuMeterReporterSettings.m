//
//  MenuMeterReporterSettings.m
//
//  This file is part of MenuMeters, GPL v2. See LICENSE.
//

#import "MenuMeterReporterSettings.h"

#import <Security/Security.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <os/lock.h>

NSString * const kMenuMeterReporterSettingsDidChangeNotification = @"MenuMeterReporterSettingsDidChange";

///////////////////////////////////////////////////////////////
//
//	Keychain storage for the auth header value
//
//	Generic-password item in the login keychain. The data-protection keychain is
//	not usable here: it needs an application-identifier entitlement, which an
//	ad-hoc signed build does not have.
//
///////////////////////////////////////////////////////////////

static NSString * const kKeychainService = @"com.yujitach.MenuMeters.reporter";
static NSString * const kKeychainAccount = @"ReporterAuthHeaderValue";

static NSMutableDictionary *ReporterKeychainQuery(void) {
    return [@{ (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
               (__bridge id)kSecAttrService: kKeychainService,
               (__bridge id)kSecAttrAccount: kKeychainAccount } mutableCopy];
}

// Returns nil both when there is no item and when the read failed; the caller
// cannot do anything useful with the difference.
static NSString *ReporterKeychainLoad(void) {
    NSMutableDictionary *query = ReporterKeychainQuery();
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef found = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &found);
    if (status != errSecSuccess || !found) return nil;

    NSData *data = CFBridgingRelease(found);
    if (![data isKindOfClass:[NSData class]]) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// An empty value deletes the item rather than storing a blank secret.
static BOOL ReporterKeychainSave(NSString *value) {
    NSMutableDictionary *query = ReporterKeychainQuery();

    if (value.length == 0) {
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
        return (status == errSecSuccess || status == errSecItemNotFound);
    }

    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return NO;

    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                    (__bridge CFDictionaryRef)@{ (__bridge id)kSecValueData: data });
    if (status == errSecItemNotFound) {
        NSMutableDictionary *item = ReporterKeychainQuery();
        item[(__bridge id)kSecValueData] = data;
        item[(__bridge id)kSecAttrLabel] = @"MenuMeters reporting auth header";
        item[(__bridge id)kSecAttrDescription] = @"Value of the optional HTTP header MenuMeters sends with each metrics POST.";
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    return (status == errSecSuccess);
}

///////////////////////////////////////////////////////////////
//
//	Local-network test, mirroring what NSAllowsLocalNetworking permits
//
///////////////////////////////////////////////////////////////

static BOOL ReporterHostIsLocalNetwork(NSString *host) {
    if (host.length == 0) return NO;
    NSString *lower = host.lowercaseString;

    // Loopback, and .local / unqualified names resolved over mDNS.
    if ([lower isEqualToString:@"localhost"]) return YES;
    if ([lower hasSuffix:@".local"]) return YES;
    if ([lower rangeOfString:@"."].location == NSNotFound &&
        [lower rangeOfString:@":"].location == NSNotFound) {
        return YES;   // unqualified hostname, e.g. "nas"
    }

    // Strip the brackets NSURL keeps around a literal IPv6 host.
    if ([lower hasPrefix:@"["] && [lower hasSuffix:@"]"] && lower.length > 2) {
        lower = [lower substringWithRange:NSMakeRange(1, lower.length - 2)];
    }

    struct in6_addr addr6;
    if (inet_pton(AF_INET6, lower.UTF8String, &addr6) == 1) {
        const uint8_t *b = addr6.s6_addr;
        if (IN6_IS_ADDR_LOOPBACK(&addr6)) return YES;
        if ((b[0] & 0xfe) == 0xfc) return YES;                    // fc00::/7  unique-local
        if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return YES;     // fe80::/10 link-local
        return NO;
    }

    struct in_addr addr4;
    if (inet_pton(AF_INET, lower.UTF8String, &addr4) == 1) {
        uint32_t a = ntohl(addr4.s_addr);
        if ((a >> 24) == 127) return YES;                          // 127.0.0.0/8
        if ((a >> 24) == 10) return YES;                           // 10.0.0.0/8
        if ((a >> 20) == ((172 << 4) | 1)) return YES;             // 172.16.0.0/12
        if ((a >> 16) == ((192 << 8) | 168)) return YES;           // 192.168.0.0/16
        if ((a >> 16) == ((169 << 8) | 254)) return YES;           // 169.254.0.0/16
        return NO;
    }

    // A fully-qualified name we cannot classify without resolving it. Treat as
    // public, which is the safe direction: https is then required.
    return NO;
}

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

@implementation MenuMeterReporterSettings {
    // The keychain is read on every POST, and a keychain hit is not free (and on
    // an ad-hoc signed build can prompt), so the value is cached in memory.
    // Guarded because the reporter reads it on its work queue while the settings
    // UI writes it on the main thread.
    NSString        *cachedAuthHeaderValue;
    BOOL             haveCachedAuthHeaderValue;
    os_unfair_lock   authLock;
}

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

    authLock = OS_UNFAIR_LOCK_INIT;

    // kReporterAuthHeaderValuePref is deliberately absent: that value lives in
    // the keychain now, and registering a default here would mask the migration
    // below by making the old key always look non-empty.
    // Sections all default to on; nothing is transmitted anyway until there is a URL.
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kReporterEnabledPref        : @NO,
        kReporterURLPref            : @"",
        kReporterIntervalPref       : @(kMenuMeterReporterIntervalDefault),
        kReporterAuthHeaderNamePref : @"",
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

    [self migrateAuthHeaderValueOutOfDefaults];

    return self;
}

// Older builds kept the header value in NSUserDefaults in cleartext. Move any
// surviving value into the keychain and clear the old key. If the keychain write
// fails we leave the defaults value alone rather than destroying the user's
// credential; the next successful write finishes the job.
- (void)migrateAuthHeaderValueOutOfDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id legacy = [defaults objectForKey:kReporterAuthHeaderValuePref];
    if (![legacy isKindOfClass:[NSString class]] || [legacy length] == 0) {
        // Nothing stored, but an empty string may still be on disk from an older
        // build. Harmless, and removing it keeps the plist tidy.
        if (legacy) [defaults removeObjectForKey:kReporterAuthHeaderValuePref];
        return;
    }

    if (ReporterKeychainSave(legacy)) {
        [defaults removeObjectForKey:kReporterAuthHeaderValuePref];
        os_unfair_lock_lock(&authLock);
        cachedAuthHeaderValue = [legacy copy];
        haveCachedAuthHeaderValue = YES;
        os_unfair_lock_unlock(&authLock);
        NSLog(@"MenuMeterReporter: moved the stored auth header value into the keychain.");
    } else {
        _authHeaderValueStorageFailed = YES;
        NSLog(@"MenuMeterReporter: could not move the auth header value into the keychain; leaving it in preferences.");
    }
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

- (NSString *)authHeaderValue {
    os_unfair_lock_lock(&authLock);
    if (haveCachedAuthHeaderValue) {
        NSString *cached = cachedAuthHeaderValue;
        os_unfair_lock_unlock(&authLock);
        return cached ?: @"";
    }
    os_unfair_lock_unlock(&authLock);

    // Read outside the lock: SecItemCopyMatching can block on a user prompt, and
    // holding a spinlock across that would be wrong.
    NSString *loaded = ReporterKeychainLoad();
    if (!loaded) {
        // Fall back to a value a failed migration left behind, so the feature
        // keeps working rather than silently losing the credential.
        NSString *legacy = [self stringForKey:kReporterAuthHeaderValuePref];
        if (legacy.length > 0) loaded = legacy;
    }

    os_unfair_lock_lock(&authLock);
    cachedAuthHeaderValue = [loaded copy];
    haveCachedAuthHeaderValue = YES;
    os_unfair_lock_unlock(&authLock);

    return loaded ?: @"";
}

- (void)setAuthHeaderValue:(NSString *)v {
    NSString *clean = v ? v : @"";
    if ([[self authHeaderValue] isEqualToString:clean]) return;

    BOOL stored = ReporterKeychainSave(clean);
    _authHeaderValueStorageFailed = !stored;

    os_unfair_lock_lock(&authLock);
    cachedAuthHeaderValue = [clean copy];
    // Cache it either way. If the keychain refused, the value still has to work
    // for this session rather than being thrown away a line after the user typed
    // it; authHeaderValueStorageFailed is what tells them it will not survive a
    // restart.
    haveCachedAuthHeaderValue = YES;
    os_unfair_lock_unlock(&authLock);

    if (stored) {
        // Never leave a copy of a credential behind in the plist.
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kReporterAuthHeaderValuePref];
    } else {
        NSLog(@"MenuMeterReporter: keychain refused to store the auth header value.");
    }

    [self notifyChanged];
}

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

- (BOOL)urlIsBlockedInsecureHTTP {
    NSURL *candidate = self.url;
    if (!candidate) return NO;
    if (![candidate.scheme.lowercaseString isEqualToString:@"http"]) return NO;
    return !ReporterHostIsLocalNetwork(candidate.host);
}

- (BOOL)isConfigured {
    return self.enabled && (self.url != nil) && !self.urlIsBlockedInsecureHTTP;
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
