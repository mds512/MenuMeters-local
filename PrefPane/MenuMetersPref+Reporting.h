//
//  MenuMetersPref+Reporting.h
//
//  Appends the "Reporting" tab to the settings window. Kept as a category so the
//  large, heavily localized MenuMetersPref.xib does not have to be touched.
//
//  This file is part of MenuMeters, GPL v2. See LICENSE.
//

#import "MenuMetersPref.h"

@interface MenuMetersPref (Reporting)
- (void)setupReportingTab;
@end
