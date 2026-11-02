//
//  MenuMeterAlerts.h
//
//  Threshold alerting: watch the values the reporter already samples, and post a
//  desktop notification when one stays over its limit.
//
//  Settings live in the Notifs tab. They are plain preferences underneath, so
//  they can still be set from Terminal if that is easier:
//
//      defaults write com.yujitach.MenuMeters AlertsEnabled -bool true
//      defaults write com.yujitach.MenuMeters AlertTemperatureC -float 60
//
//  A limit of 0 means that metric is not watched.
//
//  This file is part of MenuMeters, GPL v2. See LICENSE.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted when any setting below changes, so the reporter can start or stop the
// sampling timer. Alerts are the only reason it runs when reporting is off.
extern NSString * const kMenuMeterAlertsDidChangeNotification;

// Section names the reporter uses in its snapshot, so it knows which ones to
// collect for alerting even when they are switched off for reporting.
extern NSString * const kMenuMeterAlertSectionCPU;
extern NSString * const kMenuMeterAlertSectionTemperature;
extern NSString * const kMenuMeterAlertSectionDisk;
extern NSString * const kMenuMeterAlertSectionNetwork;

// Bounds, shared with the settings UI so it can clamp the same way.
#define kMenuMeterAlertCooldownMin        60.0
#define kMenuMeterAlertCooldownDefault    600.0
#define kMenuMeterAlertConsecutiveMin     1
#define kMenuMeterAlertConsecutiveMax     20
#define kMenuMeterAlertConsecutiveDefault 2

@interface MenuMeterAlerts : NSObject

+ (instancetype)sharedAlerts;

#pragma mark Settings

// Master switch. Nothing is watched and nothing is sampled while this is off,
// whatever the limits below say.
@property (nonatomic, assign) BOOL enabled;

// 0 means "do not watch this". Network is in bytes per second.
@property (nonatomic, assign) double temperatureLimitC;
@property (nonatomic, assign) double cpuLimitPercent;
@property (nonatomic, assign) double diskLimitPercent;
@property (nonatomic, assign) double networkLimitBytesPerSecond;

// Shortest gap between two notifications about the same metric while it stays
// over the line. Clamped to at least kMenuMeterAlertCooldownMin.
@property (nonatomic, assign) NSTimeInterval cooldownSeconds;

// How many samples in a row have to breach before anything is sent, so a
// momentary spike stays quiet. Clamped to the Min/Max above.
@property (nonatomic, assign) NSInteger consecutiveSamples;

#pragma mark State

// YES when the master switch is on AND at least one limit is set. The reporter
// samples on a timer whenever this is YES, even with no reporting URL.
@property (nonatomic, readonly) BOOL isActive;

// Which snapshot sections the armed limits actually need, so arming a
// temperature alert is the only thing that causes an SMC read.
@property (nonatomic, readonly) NSSet<NSString *> *requiredSections;

// One line describing what is being watched, for the settings tab.
@property (nonatomic, readonly, copy) NSString *armedSummary;

// What the last sample saw, keyed by metric name, already formatted. nil until
// a sample has been taken -- itself the useful signal that nothing is sampling.
@property (atomic, readonly, copy, nullable) NSDictionary<NSString *, NSString *> *lastObservedValues;

// How a notification was last delivered. Atomic: set on whichever queue
// delivery finished on, read from the UI.
@property (atomic, readonly, copy) NSString *deliveryRouteDescription;

#pragma mark Actions

// Idempotent; safe to call repeatedly. Main thread.
- (void)prepare;

// Posts a notification immediately, bypassing limits, streaks and cooldown.
// The completion reports which route delivered it, and runs on the main thread.
- (void)sendTestNotificationWithCompletion:(nullable void (^)(BOOL delivered, NSString *route))completion;

// Evaluates one sample. Must be called on the reporter's serial work queue: the
// streak and cooldown state is not otherwise synchronised.
- (void)evaluateSnapshot:(NSDictionary *)snapshot;

@end

NS_ASSUME_NONNULL_END
