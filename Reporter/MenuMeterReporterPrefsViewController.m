//
//  MenuMeterReporterPrefsViewController.m
//
//  This file is part of MenuMeters, GPL v2. See LICENSE.
//

#import "MenuMeterReporterPrefsViewController.h"
#import "MenuMeterReporterSettings.h"
#import "MenuMeterReporter.h"

@implementation MenuMeterReporterPrefsViewController {
    NSButton    *enabledCheckbox;
    NSTextField *urlField;
    NSTextField *intervalField;
    NSStepper   *intervalStepper;
    NSTextField *intervalHint;
    NSTextField *headerNameField;
    NSTextField *headerValueField;
    NSTextField *deviceIDField;

    NSButton    *includeSystemCheckbox;
    NSButton    *includeCPUCheckbox;
    NSButton    *includeTemperatureCheckbox;
    NSButton    *includeMemoryCheckbox;
    NSButton    *includeDiskCheckbox;
    NSButton    *includeNetworkCheckbox;
    NSButton    *allSensorsCheckbox;

    NSButton    *sendNowButton;
    NSTextField *statusLabel;
    NSTextView  *previewView;

    // Set while pushing UI values into the settings object. Each property setter
    // posts a change notification, and without this the handler would reload the
    // fields out from under whoever is typing in them.
    BOOL         updatingUI;
    BOOL         savingToSettings;
}

- (void)dealloc {
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

    // --- Intro -------------------------------------------------------------
    NSTextField *heading = [self labelWithText:NSLocalizedString(@"Send metrics to your own server",
                                                                 @"reporting prefs") bold:YES];
    [stack addArrangedSubview:heading];

    NSTextField *blurb = [self wrappingLabelWithText:
        NSLocalizedString(@"This build of MenuMeters has no update checks, no analytics and no other "
                          "network access of any kind. When you switch this on, it POSTs a JSON snapshot "
                          "of the readings below to the address you enter here, and to nowhere else.",
                          @"reporting prefs")];
    [stack addArrangedSubview:blurb];
    [blurb.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    enabledCheckbox = [self checkboxWithTitle:NSLocalizedString(@"Send metrics periodically",
                                                                @"reporting prefs")
                                       action:@selector(settingChanged:)];
    [stack addArrangedSubview:enabledCheckbox];

    // --- Destination -------------------------------------------------------
    urlField = [self textFieldWithPlaceholder:@"https://example.com/metrics"];
    [self addRow:NSLocalizedString(@"URL:", @"reporting prefs")
         control:urlField
      labelWidth:110
       container:stack];

    intervalField = [self textFieldWithPlaceholder:@"60"];
    [intervalField.widthAnchor constraintEqualToConstant:70].active = YES;
    intervalField.alignment = NSTextAlignmentRight;

    intervalStepper = [[NSStepper alloc] initWithFrame:NSZeroRect];
    intervalStepper.translatesAutoresizingMaskIntoConstraints = NO;
    intervalStepper.minValue = kMenuMeterReporterIntervalMin;
    intervalStepper.maxValue = kMenuMeterReporterIntervalMax;
    intervalStepper.increment = 5;
    intervalStepper.valueWraps = NO;
    intervalStepper.target = self;
    intervalStepper.action = @selector(stepperChanged:);

    intervalHint = [self labelWithText:@"" bold:NO];
    intervalHint.textColor = [NSColor secondaryLabelColor];

    NSStackView *intervalRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    intervalRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    intervalRow.spacing = 6;
    intervalRow.translatesAutoresizingMaskIntoConstraints = NO;
    [intervalRow addArrangedSubview:[self fixedLabel:NSLocalizedString(@"Send every:", @"reporting prefs")
                                               width:110]];
    [intervalRow addArrangedSubview:intervalField];
    [intervalRow addArrangedSubview:intervalStepper];
    [intervalRow addArrangedSubview:[self labelWithText:NSLocalizedString(@"seconds", @"reporting prefs")
                                                   bold:NO]];
    [intervalRow addArrangedSubview:intervalHint];
    [stack addArrangedSubview:intervalRow];

    // --- Optional extras ---------------------------------------------------
    headerNameField = [self textFieldWithPlaceholder:@"Authorization"];
    headerValueField = [self textFieldWithPlaceholder:@"Bearer …"];
    NSStackView *headerRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    headerRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    headerRow.spacing = 6;
    headerRow.translatesAutoresizingMaskIntoConstraints = NO;
    [headerRow addArrangedSubview:[self fixedLabel:NSLocalizedString(@"Extra header:", @"reporting prefs")
                                             width:110]];
    [headerRow addArrangedSubview:headerNameField];
    [headerRow addArrangedSubview:headerValueField];
    [stack addArrangedSubview:headerRow];
    [headerRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [headerValueField.widthAnchor constraintGreaterThanOrEqualToAnchor:headerNameField.widthAnchor
                                                           multiplier:1.5].active = YES;

    deviceIDField = [self textFieldWithPlaceholder:
                     [MenuMeterReporterSettings sharedSettings].hostname];
    [self addRow:NSLocalizedString(@"Device ID:", @"reporting prefs")
         control:deviceIDField
      labelWidth:110
       container:stack];

    // --- What to include ---------------------------------------------------
    [stack addArrangedSubview:[self labelWithText:NSLocalizedString(@"Include in each payload:",
                                                                    @"reporting prefs") bold:YES]];

    includeSystemCheckbox = [self checkboxWithTitle:NSLocalizedString(@"System", @"reporting prefs")
                                             action:@selector(settingChanged:)];
    includeCPUCheckbox = [self checkboxWithTitle:NSLocalizedString(@"CPU", @"reporting prefs")
                                          action:@selector(settingChanged:)];
    includeTemperatureCheckbox = [self checkboxWithTitle:NSLocalizedString(@"Temperature", @"reporting prefs")
                                                  action:@selector(settingChanged:)];
    includeMemoryCheckbox = [self checkboxWithTitle:NSLocalizedString(@"Memory", @"reporting prefs")
                                             action:@selector(settingChanged:)];
    includeDiskCheckbox = [self checkboxWithTitle:NSLocalizedString(@"Disk", @"reporting prefs")
                                           action:@selector(settingChanged:)];
    includeNetworkCheckbox = [self checkboxWithTitle:NSLocalizedString(@"Network", @"reporting prefs")
                                              action:@selector(settingChanged:)];

    NSStackView *includeRow1 = [[NSStackView alloc] initWithFrame:NSZeroRect];
    includeRow1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    includeRow1.spacing = 18;
    includeRow1.translatesAutoresizingMaskIntoConstraints = NO;
    [includeRow1 addArrangedSubview:includeSystemCheckbox];
    [includeRow1 addArrangedSubview:includeCPUCheckbox];
    [includeRow1 addArrangedSubview:includeTemperatureCheckbox];
    [stack addArrangedSubview:includeRow1];

    NSStackView *includeRow2 = [[NSStackView alloc] initWithFrame:NSZeroRect];
    includeRow2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    includeRow2.spacing = 18;
    includeRow2.translatesAutoresizingMaskIntoConstraints = NO;
    [includeRow2 addArrangedSubview:includeMemoryCheckbox];
    [includeRow2 addArrangedSubview:includeDiskCheckbox];
    [includeRow2 addArrangedSubview:includeNetworkCheckbox];
    [stack addArrangedSubview:includeRow2];

    allSensorsCheckbox = [self checkboxWithTitle:
                          NSLocalizedString(@"Read every temperature sensor, not just the one chosen in the CPU tab",
                                            @"reporting prefs")
                                          action:@selector(settingChanged:)];
    [stack addArrangedSubview:allSensorsCheckbox];

    // --- Test and preview --------------------------------------------------
    sendNowButton = [self pushButtonWithTitle:NSLocalizedString(@"Send test now", @"reporting prefs")
                                       action:@selector(sendTestNow:)];
    NSButton *refreshPreviewButton = [self pushButtonWithTitle:NSLocalizedString(@"Refresh preview",
                                                                                 @"reporting prefs")
                                                        action:@selector(refreshPreview:)];
    statusLabel = [self labelWithText:@"" bold:NO];
    statusLabel.textColor = [NSColor secondaryLabelColor];

    NSStackView *buttonRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    buttonRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttonRow.spacing = 10;
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    [buttonRow addArrangedSubview:sendNowButton];
    [buttonRow addArrangedSubview:refreshPreviewButton];
    [buttonRow addArrangedSubview:statusLabel];
    [stack addArrangedSubview:buttonRow];

    NSScrollView *previewScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    previewScroll.translatesAutoresizingMaskIntoConstraints = NO;
    previewScroll.hasVerticalScroller = YES;
    previewScroll.borderType = NSBezelBorder;

    previewView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 500, 200)];
    previewView.editable = NO;
    previewView.richText = NO;
    previewView.font = [NSFont userFixedPitchFontOfSize:10];
    previewView.autoresizingMask = NSViewWidthSizable;
    previewScroll.documentView = previewView;

    [stack addArrangedSubview:previewScroll];
    [previewScroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [previewScroll.heightAnchor constraintGreaterThanOrEqualToConstant:150].active = YES;

    // --- Version -----------------------------------------------------------
    // MenuMeters is an LSUIElement app, so it has no menu bar and no About box;
    // the main-menu nib's Help menu is never shown. This is the one place the
    // build is actually visible without resorting to Finder's Get Info.
    NSString *shortVersion = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"];
    NSString *buildVersion = [NSBundle mainBundle].infoDictionary[@"CFBundleVersion"];
    NSString *versionText;
    if (shortVersion.length && buildVersion.length) {
        versionText = [NSString stringWithFormat:NSLocalizedString(@"MenuMeters version %@ (build %@)",
                                                                   @"reporting prefs"),
                       shortVersion, buildVersion];
    } else {
        versionText = NSLocalizedString(@"MenuMeters version unknown", @"reporting prefs");
    }
    NSTextField *versionLabel = [self labelWithText:versionText bold:NO];
    versionLabel.textColor = [NSColor secondaryLabelColor];
    versionLabel.selectable = YES;   // so it can be copied into a bug report
    [stack addArrangedSubview:versionLabel];

    self.view = root;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(externalChange:)
                                                 name:kMenuMeterReporterSettingsDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(statusChanged:)
                                                 name:kMenuMeterReporterStatusDidChangeNotification
                                               object:nil];

    [self reloadFromSettings];
    [self refreshPreview:nil];
}

#pragma mark - Control factories

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

- (NSTextField *)fixedLabel:(NSString *)text width:(CGFloat)width {
    NSTextField *label = [self labelWithText:text bold:NO];
    [label.widthAnchor constraintEqualToConstant:width].active = YES;
    label.alignment = NSTextAlignmentRight;
    return label;
}

- (NSTextField *)wrappingLabelWithText:(NSString *)text {
    NSTextField *label = [self labelWithText:text bold:NO];
    label.textColor = [NSColor secondaryLabelColor];
    label.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    [label.cell setWraps:YES];
    label.preferredMaxLayoutWidth = 500;
    return label;
}

- (NSTextField *)textFieldWithPlaceholder:(NSString *)placeholder {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.placeholderString = placeholder ?: @"";
    // Commit on Enter and on losing focus, so a typed value is never silently lost.
    [field.cell setSendsActionOnEndEditing:YES];
    field.target = self;
    field.action = @selector(settingChanged:);
    return field;
}

- (NSButton *)checkboxWithTitle:(NSString *)title action:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setButtonType:NSButtonTypeSwitch];
    button.title = title;
    button.target = self;
    button.action = action;
    return button;
}

- (NSButton *)pushButtonWithTitle:(NSString *)title action:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setButtonType:NSButtonTypeMomentaryPushIn];
    button.bezelStyle = NSBezelStyleRounded;
    button.title = title;
    button.target = self;
    button.action = action;
    return button;
}

// Adds the row to the container itself: a width constraint between the row and
// the stack can only be activated once they share an ancestor.
- (void)addRow:(NSString *)labelText
       control:(NSView *)control
    labelWidth:(CGFloat)labelWidth
     container:(NSStackView *)container {
    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 6;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addArrangedSubview:[self fixedLabel:labelText width:labelWidth]];
    [row addArrangedSubview:control];
    [container addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:container.widthAnchor].active = YES;
}

#pragma mark - Settings <-> UI

- (void)reloadFromSettings {
    updatingUI = YES;
    MenuMeterReporterSettings *settings = [MenuMeterReporterSettings sharedSettings];

    enabledCheckbox.state = settings.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    urlField.stringValue = settings.urlString;
    intervalField.doubleValue = settings.intervalSeconds;
    intervalStepper.doubleValue = settings.intervalSeconds;
    headerNameField.stringValue = settings.authHeaderName;
    headerValueField.stringValue = settings.authHeaderValue;
    deviceIDField.stringValue = settings.deviceID;

    includeSystemCheckbox.state = settings.includeSystem ? NSControlStateValueOn : NSControlStateValueOff;
    includeCPUCheckbox.state = settings.includeCPU ? NSControlStateValueOn : NSControlStateValueOff;
    includeTemperatureCheckbox.state = settings.includeTemperature ? NSControlStateValueOn : NSControlStateValueOff;
    includeMemoryCheckbox.state = settings.includeMemory ? NSControlStateValueOn : NSControlStateValueOff;
    includeDiskCheckbox.state = settings.includeDisk ? NSControlStateValueOn : NSControlStateValueOff;
    includeNetworkCheckbox.state = settings.includeNetwork ? NSControlStateValueOn : NSControlStateValueOff;
    allSensorsCheckbox.state = settings.includeAllTemperatureSensors ? NSControlStateValueOn : NSControlStateValueOff;

    [self updateIntervalHint];
    [self updateStatusLabel];
    updatingUI = NO;
}

- (IBAction)settingChanged:(id)sender {
    if (updatingUI) return;
    savingToSettings = YES;
    MenuMeterReporterSettings *settings = [MenuMeterReporterSettings sharedSettings];

    settings.urlString = urlField.stringValue;
    settings.intervalSeconds = intervalField.doubleValue;
    settings.authHeaderName = headerNameField.stringValue;
    settings.authHeaderValue = headerValueField.stringValue;
    settings.deviceID = deviceIDField.stringValue;

    settings.includeSystem = (includeSystemCheckbox.state == NSControlStateValueOn);
    settings.includeCPU = (includeCPUCheckbox.state == NSControlStateValueOn);
    settings.includeTemperature = (includeTemperatureCheckbox.state == NSControlStateValueOn);
    settings.includeMemory = (includeMemoryCheckbox.state == NSControlStateValueOn);
    settings.includeDisk = (includeDiskCheckbox.state == NSControlStateValueOn);
    settings.includeNetwork = (includeNetworkCheckbox.state == NSControlStateValueOn);
    settings.includeAllTemperatureSensors = (allSensorsCheckbox.state == NSControlStateValueOn);

    // Enabled goes last, so the URL and interval are already stored by the time
    // the reporter is told to start.
    settings.enabled = (enabledCheckbox.state == NSControlStateValueOn);
    savingToSettings = NO;

    // Reflect any clamping the settings object applied.
    updatingUI = YES;
    intervalField.doubleValue = settings.intervalSeconds;
    intervalStepper.doubleValue = settings.intervalSeconds;
    updatingUI = NO;

    [self updateIntervalHint];

    if (settings.enabled && settings.url == nil && urlField.stringValue.length > 0) {
        statusLabel.stringValue = NSLocalizedString(@"That does not look like an http:// or https:// URL.",
                                                    @"reporting prefs");
        statusLabel.textColor = [NSColor systemRedColor];
    } else if (settings.urlIsBlockedInsecureHTTP) {
        // ATS only allows plain http on the local network, so say so here rather
        // than letting the first send fail with something cryptic.
        statusLabel.stringValue = NSLocalizedString(@"Plain http:// is only allowed on your local network. Use https:// for anything else.",
                                                    @"reporting prefs");
        statusLabel.textColor = [NSColor systemRedColor];
    } else if (settings.authHeaderValueStorageFailed) {
        statusLabel.stringValue = NSLocalizedString(@"The header value could not be saved to the keychain, so it will be forgotten when MenuMeters quits.",
                                                    @"reporting prefs");
        statusLabel.textColor = [NSColor systemRedColor];
    }
}

- (IBAction)stepperChanged:(id)sender {
    if (updatingUI) return;
    intervalField.doubleValue = intervalStepper.doubleValue;
    [self settingChanged:sender];
}

- (void)externalChange:(NSNotification *)notification {
    // Only for changes made elsewhere, e.g. the first-run setup window.
    if (updatingUI || savingToSettings) return;
    [self reloadFromSettings];
}

- (void)updateIntervalHint {
    double seconds = [MenuMeterReporterSettings sharedSettings].intervalSeconds;
    NSString *text;
    if (seconds < 60) {
        text = @"";
    } else if (seconds < 3600) {
        text = [NSString stringWithFormat:NSLocalizedString(@"(every %.0f min)", @"reporting prefs"), seconds / 60.0];
    } else {
        text = [NSString stringWithFormat:NSLocalizedString(@"(every %.1f h)", @"reporting prefs"), seconds / 3600.0];
    }
    intervalHint.stringValue = text;
}

#pragma mark - Actions

- (IBAction)sendTestNow:(id)sender {
    statusLabel.stringValue = NSLocalizedString(@"Sending…", @"reporting prefs");
    sendNowButton.enabled = NO;
    [[MenuMeterReporter sharedReporter] sendNowWithCompletion:^(BOOL success, NSString *message) {
        self->sendNowButton.enabled = YES;
        self->statusLabel.stringValue = message ?: @"";
        self->statusLabel.textColor = success ? [NSColor secondaryLabelColor] : [NSColor systemRedColor];
    }];
}

- (IBAction)refreshPreview:(id)sender {
    [[MenuMeterReporter sharedReporter] collectSnapshotJSONWithCompletion:^(NSString *json) {
        [self->previewView setString:json ?: @""];
    }];
}

- (void)statusChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateStatusLabel]; });
}

- (void)updateStatusLabel {
    NSString *message = [MenuMeterReporter sharedReporter].lastStatusMessage;
    if (message.length) statusLabel.stringValue = message;
}

@end
