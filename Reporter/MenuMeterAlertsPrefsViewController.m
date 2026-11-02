//
//  MenuMeterAlertsPrefsViewController.m
//
//  This file is part of MenuMeters, GPL v2. See LICENSE.
//

#import "MenuMeterAlertsPrefsViewController.h"
#import "MenuMeterAlerts.h"

// The network limit is stored in bytes per second, but nobody wants to type
// 8000000, so the field is in MB/s.
static const double kBytesPerMB = 1000.0 * 1000.0;

@implementation MenuMeterAlertsPrefsViewController {
    NSButton    *enabledCheckbox;
    NSTextField *temperatureField;
    NSTextField *cpuField;
    NSTextField *diskField;
    NSTextField *networkField;
    NSTextField *cooldownField;
    NSTextField *consecutiveField;

    NSButton    *testButton;
    NSTextField *testResultLabel;
    NSTextField *armedLabel;
    NSTextField *observedLabel;
    NSTimer     *refreshTimer;

    // Loading the fields fires their actions, and saving posts a change
    // notification that would reload the fields out from under whoever is
    // typing. Same pattern as the Reporting tab.
    BOOL         updatingUI;
    BOOL         savingToSettings;
}

- (void)dealloc {
    [refreshTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - View construction

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 548, 606)];

    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:root.topAnchor constant:20],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:root.bottomAnchor constant:-20],
    ]];

    // --- Limits ------------------------------------------------------------
    [stack addArrangedSubview:[self labelWithText:NSLocalizedString(@"Tell me when something goes over a limit",
                                                                     @"alerts prefs") bold:YES]];

    enabledCheckbox = [self checkboxWithTitle:NSLocalizedString(@"Enable alerts", @"alerts prefs")
                                       action:@selector(settingChanged:)];
    [stack addArrangedSubview:enabledCheckbox];

    temperatureField = [self numberField];
    cpuField         = [self numberField];
    diskField        = [self numberField];
    networkField     = [self numberField];

    [stack addArrangedSubview:[self row:NSLocalizedString(@"Temperature over", @"alerts prefs")
                                  field:temperatureField
                                   unit:NSLocalizedString(@"°C", @"alerts prefs")]];
    [stack addArrangedSubview:[self row:NSLocalizedString(@"CPU usage over", @"alerts prefs")
                                  field:cpuField
                                   unit:NSLocalizedString(@"%", @"alerts prefs")]];
    [stack addArrangedSubview:[self row:NSLocalizedString(@"Any volume over", @"alerts prefs")
                                  field:diskField
                                   unit:NSLocalizedString(@"% full", @"alerts prefs")]];
    [stack addArrangedSubview:[self row:NSLocalizedString(@"Network traffic over", @"alerts prefs")
                                  field:networkField
                                   unit:NSLocalizedString(@"MB/s (either direction)", @"alerts prefs")]];

    [stack addArrangedSubview:[self wrappingLabelWithText:
        NSLocalizedString(@"Leave a limit at 0 to ignore that reading. Temperature uses the sensor chosen "
                          "in the CPU tab.", @"alerts prefs")]];

    // --- Rate limiting -----------------------------------------------------
    [stack addArrangedSubview:[self spacer]];

    cooldownField = [self numberField];
    consecutiveField = [self numberField];

    [stack addArrangedSubview:[self row:NSLocalizedString(@"Repeat at most every", @"alerts prefs")
                                  field:cooldownField
                                   unit:NSLocalizedString(@"minutes, while it stays over", @"alerts prefs")]];
    [stack addArrangedSubview:[self row:NSLocalizedString(@"Only after", @"alerts prefs")
                                  field:consecutiveField
                                   unit:NSLocalizedString(@"samples in a row are over the limit", @"alerts prefs")]];
    [stack addArrangedSubview:[self wrappingLabelWithText:
        NSLocalizedString(@"Requiring more than one sample stops a brief spike — a backup starting, Spotlight "
                          "indexing — from notifying you. Readings are taken on the interval set in the "
                          "Reporting tab.", @"alerts prefs")]];

    // --- Test --------------------------------------------------------------
    [stack addArrangedSubview:[self spacer]];
    [stack addArrangedSubview:[self labelWithText:NSLocalizedString(@"Test", @"alerts prefs") bold:YES]];

    testButton = [self pushButtonWithTitle:NSLocalizedString(@"Send a test notification", @"alerts prefs")
                                    action:@selector(sendTest:)];
    [stack addArrangedSubview:testButton];

    testResultLabel = [self wrappingLabelWithText:@""];
    testResultLabel.textColor = [NSColor secondaryLabelColor];
    [stack addArrangedSubview:testResultLabel];

    // --- Live state --------------------------------------------------------
    [stack addArrangedSubview:[self spacer]];
    [stack addArrangedSubview:[self labelWithText:NSLocalizedString(@"Status", @"alerts prefs") bold:YES]];

    armedLabel = [self wrappingLabelWithText:@""];
    armedLabel.textColor = [NSColor secondaryLabelColor];
    [stack addArrangedSubview:armedLabel];

    observedLabel = [self wrappingLabelWithText:@""];
    observedLabel.textColor = [NSColor secondaryLabelColor];
    [stack addArrangedSubview:observedLabel];

    self.view = root;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(externalChange:)
                                                 name:kMenuMeterAlertsDidChangeNotification
                                               object:nil];

    [self loadSettingsIntoFields];
    [self refreshStatus];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    [self loadSettingsIntoFields];
    [self refreshStatus];
    // Only ticks while this tab is on screen.
    refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                    target:self
                                                  selector:@selector(refreshStatus)
                                                  userInfo:nil
                                                   repeats:YES];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    [refreshTimer invalidate];
    refreshTimer = nil;
}

#pragma mark - Settings <-> fields

- (void)loadSettingsIntoFields {
    MenuMeterAlerts *alerts = [MenuMeterAlerts sharedAlerts];
    updatingUI = YES;

    enabledCheckbox.state = alerts.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    temperatureField.stringValue = [self stringFromNumber:alerts.temperatureLimitC];
    cpuField.stringValue         = [self stringFromNumber:alerts.cpuLimitPercent];
    diskField.stringValue        = [self stringFromNumber:alerts.diskLimitPercent];
    networkField.stringValue     = [self stringFromNumber:alerts.networkLimitBytesPerSecond / kBytesPerMB];
    cooldownField.stringValue    = [self stringFromNumber:alerts.cooldownSeconds / 60.0];
    consecutiveField.stringValue = [NSString stringWithFormat:@"%ld", (long)alerts.consecutiveSamples];

    updatingUI = NO;
    [self updateEnabledState];
}

- (IBAction)settingChanged:(id)sender {
    if (updatingUI) return;

    MenuMeterAlerts *alerts = [MenuMeterAlerts sharedAlerts];
    savingToSettings = YES;

    alerts.temperatureLimitC          = temperatureField.doubleValue;
    alerts.cpuLimitPercent            = cpuField.doubleValue;
    alerts.diskLimitPercent           = diskField.doubleValue;
    alerts.networkLimitBytesPerSecond = networkField.doubleValue * kBytesPerMB;
    alerts.cooldownSeconds            = cooldownField.doubleValue * 60.0;
    alerts.consecutiveSamples         = consecutiveField.integerValue;

    // Last, so the limits are already stored when the reporter is told to start.
    alerts.enabled = (enabledCheckbox.state == NSControlStateValueOn);

    savingToSettings = NO;

    // Show whatever clamping the settings object applied, rather than leaving a
    // value on screen that was not the one saved.
    [self loadSettingsIntoFields];
    [self refreshStatus];
}

- (void)externalChange:(NSNotification *)notification {
    // Our own writes come back here; ignore those or the fields would reload
    // while they are being edited.
    if (savingToSettings) return;
    [self loadSettingsIntoFields];
    [self refreshStatus];
}

- (void)updateEnabledState {
    BOOL on = (enabledCheckbox.state == NSControlStateValueOn);
    for (NSTextField *field in @[temperatureField, cpuField, diskField,
                                 networkField, cooldownField, consecutiveField]) {
        field.enabled = on;
    }
}

#pragma mark - Actions

- (IBAction)sendTest:(id)sender {
    testButton.enabled = NO;
    testResultLabel.textColor = [NSColor secondaryLabelColor];
    testResultLabel.stringValue = NSLocalizedString(@"Sending…", @"alerts prefs");

    [[MenuMeterAlerts sharedAlerts] sendTestNotificationWithCompletion:^(BOOL delivered, NSString *route) {
        self->testButton.enabled = YES;
        if (delivered) {
            self->testResultLabel.stringValue =
                [NSString stringWithFormat:NSLocalizedString(@"Sent via %@. If nothing appeared, check "
                                                             "System Settings > Notifications.", @"alerts prefs"),
                 route];
            self->testResultLabel.textColor = [NSColor secondaryLabelColor];
        } else {
            self->testResultLabel.stringValue =
                [NSString stringWithFormat:NSLocalizedString(@"Could not deliver a notification (%@).",
                                                             @"alerts prefs"), route];
            self->testResultLabel.textColor = [NSColor systemRedColor];
        }
    }];
}

- (void)refreshStatus {
    MenuMeterAlerts *alerts = [MenuMeterAlerts sharedAlerts];
    armedLabel.stringValue = alerts.armedSummary;

    NSDictionary *observed = alerts.lastObservedValues;
    if (observed.count == 0) {
        // The engine only samples while something is armed, so this is the
        // expected text when alerts are off rather than a sign of trouble.
        observedLabel.stringValue = NSLocalizedString(@"Nothing measured yet. With a limit set, a reading "
                                                      "should appear here within one sample interval.",
                                                      @"alerts prefs");
        return;
    }

    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *key in [observed.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [lines addObject:[NSString stringWithFormat:@"%@: %@", key, observed[key]]];
    }
    observedLabel.stringValue = [NSString stringWithFormat:NSLocalizedString(@"Last reading — %@", @"alerts prefs"),
                                 [lines componentsJoinedByString:@"   ·   "]];
}

#pragma mark - Small view helpers

// Trims the trailing noise off a double so a field reads "60" and not "60.000000".
- (NSString *)stringFromNumber:(double)value {
    if (fabs(value - round(value)) < 0.001) return [NSString stringWithFormat:@"%.0f", value];
    return [NSString stringWithFormat:@"%.2f", value];
}

- (NSTextField *)numberField {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.alignment = NSTextAlignmentRight;
    field.target = self;
    field.action = @selector(settingChanged:);
    [field.widthAnchor constraintEqualToConstant:70].active = YES;
    return field;
}

- (NSView *)row:(NSString *)title field:(NSTextField *)field unit:(NSString *)unit {
    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    row.alignment = NSLayoutAttributeCenterY;
    row.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *label = [self labelWithText:title bold:NO];
    [label.widthAnchor constraintEqualToConstant:160].active = YES;
    label.alignment = NSTextAlignmentRight;

    [row addArrangedSubview:label];
    [row addArrangedSubview:field];
    [row addArrangedSubview:[self labelWithText:unit bold:NO]];
    return row;
}

- (NSButton *)checkboxWithTitle:(NSString *)title action:(SEL)action {
    NSButton *box = [[NSButton alloc] initWithFrame:NSZeroRect];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    [box setButtonType:NSButtonTypeSwitch];
    box.title = title;
    box.target = self;
    box.action = action;
    return box;
}

- (NSTextField *)labelWithText:(NSString *)text bold:(BOOL)bold {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.stringValue = text;
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.font = bold ? [NSFont boldSystemFontOfSize:[NSFont systemFontSize]]
                      : [NSFont systemFontOfSize:[NSFont systemFontSize]];
    return label;
}

- (NSTextField *)wrappingLabelWithText:(NSString *)text {
    NSTextField *label = [self labelWithText:text bold:NO];
    label.selectable = YES;        // so a result can be pasted into a bug report
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.maximumNumberOfLines = 0;
    label.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label.widthAnchor constraintLessThanOrEqualToConstant:500].active = YES;
    return label;
}

- (NSButton *)pushButtonWithTitle:(NSString *)title action:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.title = title;
    button.bezelStyle = NSBezelStyleRounded;
    button.target = self;
    button.action = action;
    return button;
}

- (NSView *)spacer {
    NSView *view = [[NSView alloc] initWithFrame:NSZeroRect];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [view.heightAnchor constraintEqualToConstant:6].active = YES;
    return view;
}

@end
