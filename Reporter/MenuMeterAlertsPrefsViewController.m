//
//  MenuMeterAlertsPrefsViewController.m
//
//  This file is part of MenuMeters, GPL v2. See LICENSE.
//

#import "MenuMeterAlertsPrefsViewController.h"
#import "MenuMeterAlerts.h"

@implementation MenuMeterAlertsPrefsViewController {
    NSButton    *testButton;
    NSTextField *testResultLabel;
    NSTextField *armedLabel;
    NSTextField *observedLabel;
    NSTimer     *refreshTimer;
}

- (void)dealloc {
    [refreshTimer invalidate];
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

    // --- Can we notify at all? ---------------------------------------------
    [stack addArrangedSubview:[self labelWithText:NSLocalizedString(@"Test notifications", @"alerts prefs")
                                             bold:YES]];
    [stack addArrangedSubview:[self wrappingLabelWithText:
        NSLocalizedString(@"MenuMeters can tell you when a reading goes over a limit you set. This build is "
                          "not signed by Apple, so macOS may refuse it permission to use Notification Centre. "
                          "Press the button: if a notification appears, alerts can reach you. If it arrives "
                          "from \"Script Editor\", the fallback route is being used, which works just as well.",
                          @"alerts prefs")]];

    testButton = [self pushButtonWithTitle:NSLocalizedString(@"Send a test notification", @"alerts prefs")
                                    action:@selector(sendTest:)];
    [stack addArrangedSubview:testButton];

    testResultLabel = [self wrappingLabelWithText:@""];
    testResultLabel.textColor = [NSColor secondaryLabelColor];
    [stack addArrangedSubview:testResultLabel];

    // --- What the engine is doing right now --------------------------------
    [stack addArrangedSubview:[self spacer]];
    [stack addArrangedSubview:[self labelWithText:NSLocalizedString(@"Current alert settings", @"alerts prefs")
                                             bold:YES]];

    armedLabel = [self wrappingLabelWithText:@""];
    armedLabel.textColor = [NSColor secondaryLabelColor];
    [stack addArrangedSubview:armedLabel];

    observedLabel = [self wrappingLabelWithText:@""];
    observedLabel.textColor = [NSColor secondaryLabelColor];
    [stack addArrangedSubview:observedLabel];

    [stack addArrangedSubview:[self spacer]];
    [stack addArrangedSubview:[self wrappingLabelWithText:
        NSLocalizedString(@"There is no settings UI for the thresholds yet. Until there is, set them in "
                          "Terminal and restart MenuMeters:\n"
                          "    defaults write com.yujitach.MenuMeters AlertsEnabled -bool true\n"
                          "    defaults write com.yujitach.MenuMeters AlertTemperatureC -float 60\n"
                          "    defaults write com.yujitach.MenuMeters AlertCPUPercent -float 85\n"
                          "    defaults write com.yujitach.MenuMeters AlertDiskPercent -float 90\n"
                          "A value of 0 means that reading is not watched.", @"alerts prefs")]];

    self.view = root;
    [self refresh];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    [self refresh];
    // Cheap, and only while this tab is actually on screen.
    refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                    target:self
                                                  selector:@selector(refresh)
                                                  userInfo:nil
                                                   repeats:YES];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    [refreshTimer invalidate];
    refreshTimer = nil;
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

- (void)refresh {
    MenuMeterAlerts *alerts = [MenuMeterAlerts sharedAlerts];
    armedLabel.stringValue = alerts.armedSummary;

    NSDictionary *observed = alerts.lastObservedValues;
    if (observed.count == 0) {
        // The engine only samples when at least one threshold is armed, so this
        // is the expected text whenever nothing is being watched.
        observedLabel.stringValue = NSLocalizedString(@"Nothing measured yet. With a threshold set, a reading "
                                                      "should appear here within a minute of launching.",
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
