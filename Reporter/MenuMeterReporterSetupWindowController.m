//
//  MenuMeterReporterSetupWindowController.m
//
//  This file is part of MenuMeters, GPL v2. See LICENSE.
//

#import "MenuMeterReporterSetupWindowController.h"
#import "MenuMeterReporterSettings.h"
#import "MenuMeterReporter.h"

@interface MenuMeterReporterSetupWindowController () <NSWindowDelegate>
@end

@implementation MenuMeterReporterSetupWindowController {
    NSTextField *urlField;
    NSTextField *deviceIDField;
    NSTextField *intervalField;
    NSTextField *errorLabel;
}

- (id)init {
    NSRect frame = NSMakeRect(0, 0, 520, 360);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = NSLocalizedString(@"MenuMeters", @"reporter setup");
    window.releasedWhenClosed = NO;
    [window center];

    self = [super initWithWindow:window];
    if (!self) return nil;

    window.delegate = self;
    [self buildContentInWindow:window];
    return self;
}

- (void)buildContentInWindow:(NSWindow *)window {
    NSView *content = window.contentView;

    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:24],
    ]];

    NSTextField *heading = [self label:NSLocalizedString(@"Send your metrics somewhere?",
                                                         @"reporter setup")
                                  font:[NSFont boldSystemFontOfSize:15]];
    [stack addArrangedSubview:heading];

    NSTextField *blurb = [self label:
        NSLocalizedString(@"MenuMeters never contacts anyone on its own: no update checks, no analytics, "
                          "nothing. If you run your own dashboard or server, it can POST a JSON snapshot "
                          "of CPU, temperature, memory, disk and network to an address you choose.\n\n"
                          "The device ID is how this Mac identifies itself in each payload; leave it "
                          "blank to use the hostname.\n\n"
                          "Leave the URL blank to keep everything on this Mac. You can change all of "
                          "this later in Settings → Reporting.",
                          @"reporter setup")
                                font:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    blurb.textColor = [NSColor secondaryLabelColor];
    [blurb.cell setWraps:YES];
    blurb.preferredMaxLayoutWidth = 460;
    [stack addArrangedSubview:blurb];
    [blurb.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    urlField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    urlField.translatesAutoresizingMaskIntoConstraints = NO;
    urlField.placeholderString = @"https://example.com/metrics";
    [self addRowWithLabel:NSLocalizedString(@"URL:", @"reporter setup")
                  control:urlField
                container:stack];

    deviceIDField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    deviceIDField.translatesAutoresizingMaskIntoConstraints = NO;
    deviceIDField.placeholderString = [MenuMeterReporterSettings sharedSettings].hostname;
    [self addRowWithLabel:NSLocalizedString(@"Device ID:", @"reporter setup")
                  control:deviceIDField
                container:stack];

    intervalField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    intervalField.translatesAutoresizingMaskIntoConstraints = NO;
    intervalField.doubleValue = kMenuMeterReporterIntervalDefault;
    intervalField.alignment = NSTextAlignmentRight;
    [intervalField.widthAnchor constraintEqualToConstant:70].active = YES;

    NSStackView *intervalRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    intervalRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    intervalRow.spacing = 6;
    intervalRow.translatesAutoresizingMaskIntoConstraints = NO;
    [intervalRow addArrangedSubview:[self fixedLabel:NSLocalizedString(@"Send every:", @"reporter setup")
                                               width:90]];
    [intervalRow addArrangedSubview:intervalField];
    [intervalRow addArrangedSubview:[self label:NSLocalizedString(@"seconds", @"reporter setup")
                                           font:[NSFont systemFontOfSize:[NSFont systemFontSize]]]];
    [stack addArrangedSubview:intervalRow];

    errorLabel = [self label:@"" font:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    errorLabel.textColor = [NSColor systemRedColor];
    [stack addArrangedSubview:errorLabel];

    NSButton *skipButton = [self button:NSLocalizedString(@"Not now", @"reporter setup")
                                 action:@selector(skip:)];
    NSButton *startButton = [self button:NSLocalizedString(@"Start sending", @"reporter setup")
                                  action:@selector(startSending:)];
    startButton.keyEquivalent = @"\r";

    NSStackView *buttonRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    buttonRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttonRow.spacing = 10;
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    [buttonRow addArrangedSubview:skipButton];
    [buttonRow addArrangedSubview:startButton];
    [content addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [buttonRow.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [buttonRow.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-20],
        [buttonRow.topAnchor constraintGreaterThanOrEqualToAnchor:stack.bottomAnchor constant:16],
    ]];
}

#pragma mark - Helpers

- (NSTextField *)label:(NSString *)text font:(NSFont *)font {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.stringValue = text;
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.font = font;
    return label;
}

- (NSTextField *)fixedLabel:(NSString *)text width:(CGFloat)width {
    NSTextField *label = [self label:text font:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
    label.alignment = NSTextAlignmentRight;
    [label.widthAnchor constraintEqualToConstant:width].active = YES;
    return label;
}

- (NSButton *)button:(NSString *)title action:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setButtonType:NSButtonTypeMomentaryPushIn];
    button.bezelStyle = NSBezelStyleRounded;
    button.title = title;
    button.target = self;
    button.action = action;
    return button;
}

- (void)addRowWithLabel:(NSString *)labelText control:(NSView *)control container:(NSStackView *)container {
    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 6;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addArrangedSubview:[self fixedLabel:labelText width:90]];
    [row addArrangedSubview:control];
    [container addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:container.widthAnchor].active = YES;
}

#pragma mark - Presentation

- (void)present {
    // The app is an LSUIElement, so it needs to become a real foreground app for
    // this window to be usable, then drop back afterwards.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window center];
    [self.window makeKeyAndOrderFront:self];
}

- (void)dismiss {
    [self close];
}

// Also covers the red close button, which would otherwise leave setupCompleted
// unset and pop this window again on every launch.
- (void)windowWillClose:(NSNotification *)notification {
    [MenuMeterReporterSettings sharedSettings].setupCompleted = YES;
    completed = YES;

    // The app is normally an LSUIElement. Only drop back to accessory if nothing
    // else is on screen; at first launch the welcome window is usually open too,
    // and hiding that would be rude.
    for (NSWindow *window in [NSApp windows]) {
        if (window != self.window && window.isVisible) return;
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

#pragma mark - Actions

- (IBAction)skip:(id)sender {
    [self dismiss];
}

- (IBAction)startSending:(id)sender {
    MenuMeterReporterSettings *settings = [MenuMeterReporterSettings sharedSettings];

    // Keep the device ID either way; it costs nothing and saves retyping if the
    // user comes back to this in settings later.
    settings.deviceID = deviceIDField.stringValue;

    NSString *url = [urlField.stringValue stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (url.length == 0) {
        // Treat an empty field on "Start sending" the same as declining.
        [self dismiss];
        return;
    }

    settings.urlString = url;
    if (settings.url == nil) {
        errorLabel.stringValue = NSLocalizedString(@"Enter a full http:// or https:// address.",
                                                   @"reporter setup");
        return;
    }

    settings.intervalSeconds = intervalField.doubleValue;
    settings.enabled = YES;
    [self dismiss];
}

@end
