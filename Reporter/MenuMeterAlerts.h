//
//  MenuMeterAlerts.h
//
//  Threshold alerting: watch the values the reporter already samples, and post a
//  desktop notification when one stays over its limit.
//
//  Phase 1 has no settings UI. Thresholds are read straight from preferences, so
//  they are set from Terminal, e.g.
//
//      defaults write com.yujitach.MenuMeters AlertsEnabled -bool true
//      defaults write com.yujitach.MenuMeters AlertTemperatureC -float 60
//
//  A threshold of 0 (the default) means that metric is not watched.
//
//  This file is part of MenuMeters, GPL v2. See LICENSE.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Section names the reporter uses in its snapshot, so it knows which ones to
// collect for alerting even when they are switched off for reporting.
extern NSString * const kMenuMeterAlertSectionCPU;
extern NSString * const kMenuMeterAlertSectionTemperature;
extern NSString * const kMenuMeterAlertSectionDisk;
extern NSString * const kMenuMeterAlertSectionNetwork;

@interface MenuMeterAlerts : NSObject

+ (instancetype)sharedAlerts;

// YES when the master switch is on AND at least one threshold is armed. The
// reporter samples on a timer whenever this is YES, even with no reporting URL.
@property (nonatomic, readonly) BOOL isEnabled;

// Which snapshot sections the armed thresholds actually need. The reporter adds
// these to whatever reporting is already collecting, so arming a temperature
// alert does not force an SMC read when no alert needs one.
@property (nonatomic, readonly) NSSet<NSString *> *requiredSections;

// How a notification was last delivered, for logging and for the Phase 2 UI.
// Atomic: set on whichever queue delivery finished on, read from the UI.
@property (atomic, readonly, copy) NSString *deliveryRouteDescription;

// Human-readable list of the armed thresholds, for the settings tab.
@property (nonatomic, readonly, copy) NSString *armedSummary;

// What the last sample actually saw, keyed by metric name ("temperature",
// "cpu", "disk", "network"), already formatted. nil until a sample has been
// taken -- which is itself the useful signal that nothing is sampling yet.
@property (atomic, readonly, copy, nullable) NSDictionary<NSString *, NSString *> *lastObservedValues;

// Idempotent; safe to call repeatedly. Main thread.
- (void)prepare;

// Posts a notification immediately, bypassing thresholds, streaks and cooldown.
// The completion reports which route delivered it, and runs on the main thread.
- (void)sendTestNotificationWithCompletion:(nullable void (^)(BOOL delivered, NSString *route))completion;

// Evaluates one sample. Must be called on the reporter's serial work queue: the
// streak and cooldown state below is not otherwise synchronised.
- (void)evaluateSnapshot:(NSDictionary *)snapshot;

@end

NS_ASSUME_NONNULL_END
