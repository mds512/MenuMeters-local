//
//  MenuMetersPref+Alerts.h
//
//  This file is part of MenuMeters, GPL v2. See LICENSE.
//

#import "MenuMetersPref.h"

NS_ASSUME_NONNULL_BEGIN

@interface MenuMetersPref (Alerts)

// Adds the "Notifs" tab. Must run before the toolbar is built.
- (void)setupAlertsTab;

@end

NS_ASSUME_NONNULL_END
