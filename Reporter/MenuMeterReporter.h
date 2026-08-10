//
//  MenuMeterReporter.h
//
//  Gathers the same numbers the menu meters show and POSTs them as JSON to a
//  URL the user configures. This is the ONLY outbound network path in the app.
//
//  This file is part of MenuMeters, GPL v2. See LICENSE.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted (on the main thread) after every send attempt, successful or not, so the
// settings UI can show the result. Object is the reporter.
extern NSString * const kMenuMeterReporterStatusDidChangeNotification;

@interface MenuMeterReporter : NSObject

+ (instancetype)sharedReporter;

// Begins (or re-schedules) the periodic send. Safe to call repeatedly. Does
// nothing on the wire while reporting is disabled or no URL is set.
- (void)start;
- (void)stop;

// Collects one sample now and hands back the JSON-ready payload. Blocking, so
// call it off the main thread when you can; the settings preview accepts the hit.
- (NSDictionary *)collectSnapshot;

// Pretty-printed JSON for the payload preview in settings.
- (void)collectSnapshotJSONWithCompletion:(void (^)(NSString *json))completion;

// Collects and sends one sample immediately, regardless of the timer. Used by the
// "Send test now" button. completion runs on the main thread.
- (void)sendNowWithCompletion:(nullable void (^)(BOOL success, NSString *message))completion;

// Shows the one-time setup window if the user has never been through it.
- (void)presentFirstRunSetupIfNeeded;

// Human-readable result of the last send attempt, for display in settings.
@property (atomic, readonly, copy, nullable) NSString *lastStatusMessage;
@property (atomic, readonly, nullable) NSDate *lastSuccessDate;

@end

NS_ASSUME_NONNULL_END
