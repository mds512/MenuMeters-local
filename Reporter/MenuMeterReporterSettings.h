//
//  MenuMeterReporterSettings.h
//
//  User settings for the local metrics reporter.
//
//  MenuMeters makes exactly one kind of outbound network request: a POST of the
//  metrics below to a URL the user types in. Nothing is sent anywhere until that
//  URL is set, and there is no other network code anywhere in the app.
//
//  This file is part of MenuMeters, GPL v2. See LICENSE.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted whenever any setting below changes, so the reporter can reschedule and
// any open settings UI can refresh itself.
extern NSString * const kMenuMeterReporterSettingsDidChangeNotification;

// Bounds for the send interval, in seconds.
#define kMenuMeterReporterIntervalMin      5.0
#define kMenuMeterReporterIntervalMax      86400.0
#define kMenuMeterReporterIntervalDefault  60.0

@interface MenuMeterReporterSettings : NSObject

+ (instancetype)sharedSettings;

// Master switch. Reporting is off until the user turns it on.
@property (nonatomic, assign) BOOL enabled;

// Destination. Empty until the user provides one.
@property (nonatomic, copy) NSString *urlString;

// How often to POST, in seconds. Clamped to [kMenuMeterReporterIntervalMin, kMenuMeterReporterIntervalMax].
@property (nonatomic, assign) double intervalSeconds;

// Optional single extra request header, e.g. "Authorization" / "Bearer abc123".
//
// The name is an ordinary preference. The VALUE is a credential, so it is kept in
// the login keychain rather than in NSUserDefaults, where it used to sit in
// cleartext in ~/Library/Preferences and get swept into backups and prefs sync.
// Any value left behind by an older build is migrated into the keychain and
// deleted from the defaults on first launch.
//
// Note: the keychain item is owned by this app's code signature. Because these
// builds are ad-hoc signed, a rebuild is a different identity, so macOS will ask
// once per build whether MenuMeters may read the item. "Always Allow" is fine.
@property (nonatomic, copy) NSString *authHeaderName;
@property (nonatomic, copy) NSString *authHeaderValue;

// YES when the keychain refused to store the value, so the UI can say so instead
// of silently dropping the credential. Reset on the next successful write.
@property (nonatomic, readonly) BOOL authHeaderValueStorageFailed;

// Identifier for this machine, chosen by the user, sent as "device_id" in every
// payload. Blank falls back to the hostname so the field is never empty on the
// receiving end.
@property (nonatomic, copy) NSString *deviceID;

// Which sections to include in the payload.
@property (nonatomic, assign) BOOL includeSystem;
@property (nonatomic, assign) BOOL includeCPU;
@property (nonatomic, assign) BOOL includeTemperature;
@property (nonatomic, assign) BOOL includeMemory;
@property (nonatomic, assign) BOOL includeDisk;
@property (nonatomic, assign) BOOL includeNetwork;

// Read every temperature sensor rather than just the one selected in the CPU tab.
// Off by default: on Intel each sensor read opens and closes the SMC, so reading
// them all every interval is not free.
@property (nonatomic, assign) BOOL includeAllTemperatureSensors;

// Set once the user has been shown (and dismissed) the first-run setup window,
// so it is never shown again whether or not they configured anything.
@property (nonatomic, assign) BOOL setupCompleted;

// nil unless urlString parses into an http/https URL.
@property (nonatomic, readonly, nullable) NSURL *url;

// YES when url is a plain-http URL pointing somewhere other than the local
// network. App Transport Security blocks those (see MenuMeters-Info.plist), so
// the reporter checks this first and reports a readable reason rather than
// letting the request fail with an opaque -1022.
@property (nonatomic, readonly) BOOL urlIsBlockedInsecureHTTP;

// YES when reporting is switched on AND a usable, sendable URL is set.
@property (nonatomic, readonly) BOOL isConfigured;

// This machine's real hostname, reported alongside the device ID.
@property (nonatomic, readonly) NSString *hostname;

// What will actually be sent as "device_id": the user's value, or the hostname.
@property (nonatomic, readonly) NSString *effectiveDeviceID;

@end

NS_ASSUME_NONNULL_END
