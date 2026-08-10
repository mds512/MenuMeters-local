//
//  MenuMeterReporterSetupWindowController.h
//
//  Shown once, on first launch, so the user can point MenuMeters at their own
//  server (or decline). Everything here can be changed later in Settings →
//  Reporting.
//
//  This file is part of MenuMeters, GPL v2. See LICENSE.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface MenuMeterReporterSetupWindowController : NSWindowController
- (void)present;
@end

NS_ASSUME_NONNULL_END
