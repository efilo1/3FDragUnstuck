#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <stdatomic.h>

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef device, void *contacts, int contactCount, double timestamp, int frame);
typedef MTDeviceRef (*MTDeviceCreateDefaultFunction)(void);
typedef CFArrayRef (*MTDeviceCreateListFunction)(void);
typedef int (*MTRegisterContactFrameCallbackFunction)(MTDeviceRef device, MTContactCallbackFunction callback);
typedef int (*MTDeviceStartFunction)(MTDeviceRef device, int flags);

typedef struct {
    MTDeviceRef device;
    int maxContacts;
} DeviceState;

static atomic_bool gEnabled = true;
static atomic_bool gShiftOverrideEnabled = true;
static atomic_ullong gOverrideModifierMask = kCGEventFlagMaskAlternate;
static atomic_llong gLastPostMillis = 0;
static os_unfair_lock gStateLock = OS_UNFAIR_LOCK_INIT;
static DeviceState gDeviceStates[16];
static int gDeviceStateCount = 0;
static NSString *const ShiftOverrideEnabledKey = @"ShiftOverrideEnabled";
static NSString *const OverrideModifierKey = @"OverrideModifier";
static NSString *const OverrideModifierShift = @"Shift";
static NSString *const OverrideModifierControl = @"Control";
static NSString *const OverrideModifierOption = @"Option";
static NSString *const OverrideModifierFn = @"Fn";

static CGEventFlags modifierMaskForName(NSString *name) {
    if ([name isEqualToString:OverrideModifierShift]) {
        return kCGEventFlagMaskShift;
    }
    if ([name isEqualToString:OverrideModifierControl]) {
        return kCGEventFlagMaskControl;
    }
    if ([name isEqualToString:OverrideModifierFn]) {
        return kCGEventFlagMaskSecondaryFn;
    }
    return kCGEventFlagMaskAlternate;
}

static long long nowMillis(void) {
    return (long long)(CFAbsoluteTimeGetCurrent() * 1000.0);
}

static void postLeftMouseUp(void) {
    CGEventRef current = CGEventCreate(NULL);
    if (current == NULL) {
        return;
    }

    CGPoint location = CGEventGetLocation(current);
    CFRelease(current);

    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == NULL) {
        return;
    }

    CGEventRef event = CGEventCreateMouseEvent(source, kCGEventLeftMouseUp, location, kCGMouseButtonLeft);
    CFRelease(source);
    if (event == NULL) {
        return;
    }

    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static int contactFrameCallback(MTDeviceRef device, void *contacts, int contactCount, double timestamp, int frame) {
    (void)contacts;
    (void)timestamp;
    (void)frame;

    os_unfair_lock_lock(&gStateLock);
    DeviceState *state = NULL;
    for (int i = 0; i < gDeviceStateCount; i++) {
        if (gDeviceStates[i].device == device) {
            state = &gDeviceStates[i];
            break;
        }
    }

    if (state == NULL) {
        os_unfair_lock_unlock(&gStateLock);
        return 0;
    }

    if (!atomic_load(&gEnabled)) {
        state->maxContacts = 0;
        os_unfair_lock_unlock(&gStateLock);
        return 0;
    }

    if (contactCount > 0) {
        state->maxContacts = MAX(state->maxContacts, contactCount);
        os_unfair_lock_unlock(&gStateLock);
        return 0;
    }

    BOOL shouldPost = state->maxContacts == 3;
    state->maxContacts = 0;
    os_unfair_lock_unlock(&gStateLock);

    if (!shouldPost) {
        return 0;
    }

    if (atomic_load(&gShiftOverrideEnabled) &&
        (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & atomic_load(&gOverrideModifierMask))) {
        return 0;
    }

    long long now = nowMillis();
    long long last = atomic_load(&gLastPostMillis);
    if (now - last < 80) {
        return 0;
    }
    atomic_store(&gLastPostMillis, now);

    postLeftMouseUp();
    return 0;
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *enabledItem;
@property(nonatomic, strong) NSMenuItem *shiftOverrideItem;
@property(nonatomic, strong) NSMenuItem *overrideModifierItem;
@property(nonatomic, strong) NSMenuItem *shiftModifierItem;
@property(nonatomic, strong) NSMenuItem *controlModifierItem;
@property(nonatomic, strong) NSMenuItem *optionModifierItem;
@property(nonatomic, strong) NSMenuItem *fnModifierItem;
@property(nonatomic, strong) NSMenuItem *accessibilityItem;
@property(nonatomic, strong) NSMenuItem *hideMenuBarIconItem;
@property(nonatomic, assign) CFArrayRef deviceList;
@property(nonatomic, assign) void *multitouchHandle;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        ShiftOverrideEnabledKey: @YES,
        OverrideModifierKey: OverrideModifierOption
    }];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    atomic_store(&gShiftOverrideEnabled, [defaults boolForKey:ShiftOverrideEnabledKey]);
    atomic_store(&gOverrideModifierMask, modifierMaskForName([defaults stringForKey:OverrideModifierKey]));
    [self setupStatusItem];
    [self requestAccessibilityIfNeeded:NO];
    [self startMultitouchCallback];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    (void)flag;
    [self showMenuBarIcon];
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    if (self.deviceList != NULL) {
        CFRelease(self.deviceList);
        self.deviceList = NULL;
    }
    if (self.multitouchHandle != NULL) {
        dlclose(self.multitouchHandle);
        self.multitouchHandle = NULL;
    }
}

- (void)setupStatusItem {
    if (self.statusItem != nil) {
        return;
    }

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"3F";
    self.statusItem.button.toolTip = @"3FDragUnstuck";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.delegate = self;

    self.enabledItem = [[NSMenuItem alloc] initWithTitle:@"Enabled" action:@selector(toggleEnabled:) keyEquivalent:@""];
    self.enabledItem.target = self;
    self.enabledItem.state = NSControlStateValueOn;
    [menu addItem:self.enabledItem];

    self.shiftOverrideItem = [[NSMenuItem alloc] initWithTitle:@"Override Enabled" action:@selector(toggleShiftOverride:) keyEquivalent:@""];
    self.shiftOverrideItem.target = self;
    self.shiftOverrideItem.state = atomic_load(&gShiftOverrideEnabled) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:self.shiftOverrideItem];

    self.overrideModifierItem = [[NSMenuItem alloc] initWithTitle:@"Override Modifier" action:nil keyEquivalent:@""];
    NSMenu *modifierMenu = [[NSMenu alloc] initWithTitle:@"Override Modifier"];
    self.shiftModifierItem = [[NSMenuItem alloc] initWithTitle:@"Shift" action:@selector(selectOverrideModifier:) keyEquivalent:@""];
    self.controlModifierItem = [[NSMenuItem alloc] initWithTitle:@"Control" action:@selector(selectOverrideModifier:) keyEquivalent:@""];
    self.optionModifierItem = [[NSMenuItem alloc] initWithTitle:@"Option" action:@selector(selectOverrideModifier:) keyEquivalent:@""];
    self.fnModifierItem = [[NSMenuItem alloc] initWithTitle:@"Fn (Globe)" action:@selector(selectOverrideModifier:) keyEquivalent:@""];
    self.shiftModifierItem.target = self;
    self.controlModifierItem.target = self;
    self.optionModifierItem.target = self;
    self.fnModifierItem.target = self;
    self.shiftModifierItem.representedObject = OverrideModifierShift;
    self.controlModifierItem.representedObject = OverrideModifierControl;
    self.optionModifierItem.representedObject = OverrideModifierOption;
    self.fnModifierItem.representedObject = OverrideModifierFn;
    [modifierMenu addItem:self.shiftModifierItem];
    [modifierMenu addItem:self.controlModifierItem];
    [modifierMenu addItem:self.optionModifierItem];
    [modifierMenu addItem:self.fnModifierItem];
    self.overrideModifierItem.submenu = modifierMenu;
    [self updateOverrideModifierMenuState];
    [menu addItem:self.overrideModifierItem];

    self.accessibilityItem = [[NSMenuItem alloc] initWithTitle:@"Accessibility Permission Required" action:@selector(requestAccessibilityPermission:) keyEquivalent:@""];
    self.accessibilityItem.target = self;
    [menu addItem:self.accessibilityItem];

    self.hideMenuBarIconItem = [[NSMenuItem alloc] initWithTitle:@"Hide Menu Bar Icon" action:@selector(hideMenuBarIcon:) keyEquivalent:@""];
    self.hideMenuBarIconItem.target = self;
    [menu addItem:self.hideMenuBarIconItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:quit];

    self.statusItem.menu = menu;
}

- (void)showMenuBarIcon {
    [self setupStatusItem];
    [self requestAccessibilityIfNeeded:NO];
}

- (void)hideMenuBarIcon:(id)sender {
    (void)sender;
    if (self.statusItem == nil) {
        return;
    }

    [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
    self.statusItem = nil;
    self.enabledItem = nil;
    self.shiftOverrideItem = nil;
    self.overrideModifierItem = nil;
    self.shiftModifierItem = nil;
    self.controlModifierItem = nil;
    self.optionModifierItem = nil;
    self.fnModifierItem = nil;
    self.accessibilityItem = nil;
    self.hideMenuBarIconItem = nil;
}

- (void)toggleEnabled:(id)sender {
    (void)sender;
    BOOL enabled = !atomic_load(&gEnabled);
    atomic_store(&gEnabled, enabled);
    self.enabledItem.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)toggleShiftOverride:(id)sender {
    (void)sender;
    BOOL enabled = !atomic_load(&gShiftOverrideEnabled);
    atomic_store(&gShiftOverrideEnabled, enabled);
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:ShiftOverrideEnabledKey];
    self.shiftOverrideItem.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)selectOverrideModifier:(id)sender {
    NSString *name = [sender representedObject];
    if (name == nil) {
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:name forKey:OverrideModifierKey];
    atomic_store(&gOverrideModifierMask, modifierMaskForName(name));
    [self updateOverrideModifierMenuState];
}

- (void)updateOverrideModifierMenuState {
    NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:OverrideModifierKey];
    self.shiftModifierItem.state = [name isEqualToString:OverrideModifierShift] ? NSControlStateValueOn : NSControlStateValueOff;
    self.controlModifierItem.state = [name isEqualToString:OverrideModifierControl] ? NSControlStateValueOn : NSControlStateValueOff;
    self.optionModifierItem.state = [name isEqualToString:OverrideModifierOption] ? NSControlStateValueOn : NSControlStateValueOff;
    self.fnModifierItem.state = [name isEqualToString:OverrideModifierFn] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    [self requestAccessibilityIfNeeded:NO];
}

- (void)requestAccessibilityPermission:(id)sender {
    (void)sender;
    if ([self requestAccessibilityIfNeeded:YES]) {
        NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

- (BOOL)requestAccessibilityIfNeeded:(BOOL)prompt {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @(prompt)};
    BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    if (self.accessibilityItem != nil) {
        self.accessibilityItem.title = trusted ? @"Accessibility Permission Granted" : @"Accessibility Permission Required";
        self.accessibilityItem.state = trusted ? NSControlStateValueOn : NSControlStateValueOff;
    }
    return trusted;
}

- (void)startMultitouchCallback {
    const char *path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/A/MultitouchSupport";
    self.multitouchHandle = dlopen(path, RTLD_LAZY);
    if (self.multitouchHandle == NULL) {
        NSLog(@"Failed to load MultitouchSupport: %s", dlerror());
        self.statusItem.button.title = @"3F!";
        return;
    }

    MTDeviceCreateDefaultFunction createDefault = (MTDeviceCreateDefaultFunction)dlsym(self.multitouchHandle, "MTDeviceCreateDefault");
    MTDeviceCreateListFunction createList = (MTDeviceCreateListFunction)dlsym(self.multitouchHandle, "MTDeviceCreateList");
    MTRegisterContactFrameCallbackFunction registerCallback = (MTRegisterContactFrameCallbackFunction)dlsym(self.multitouchHandle, "MTRegisterContactFrameCallback");
    MTDeviceStartFunction startDevice = (MTDeviceStartFunction)dlsym(self.multitouchHandle, "MTDeviceStart");

    if (createDefault == NULL || registerCallback == NULL || startDevice == NULL) {
        NSLog(@"Failed to resolve MultitouchSupport symbols");
        self.statusItem.button.title = @"3F!";
        return;
    }

    NSMutableArray<NSValue *> *devices = [NSMutableArray array];
    if (createList != NULL) {
        self.deviceList = createList();
        if (self.deviceList != NULL) {
            CFIndex count = CFArrayGetCount(self.deviceList);
            for (CFIndex i = 0; i < count; i++) {
                MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(self.deviceList, i);
                if (device != NULL) {
                    [devices addObject:[NSValue valueWithPointer:device]];
                }
            }
        }
    }

    if (devices.count == 0) {
        MTDeviceRef defaultDevice = createDefault();
        if (defaultDevice != NULL) {
            [devices addObject:[NSValue valueWithPointer:defaultDevice]];
        }
    }

    if (devices.count == 0) {
        NSLog(@"No multitouch devices found");
        self.statusItem.button.title = @"3F!";
        return;
    }

    os_unfair_lock_lock(&gStateLock);
    gDeviceStateCount = 0;
    for (NSValue *value in devices) {
        if (gDeviceStateCount >= 16) {
            break;
        }
        gDeviceStates[gDeviceStateCount].device = [value pointerValue];
        gDeviceStates[gDeviceStateCount].maxContacts = 0;
        gDeviceStateCount++;
    }
    os_unfair_lock_unlock(&gStateLock);

    for (NSValue *value in devices) {
        MTDeviceRef device = [value pointerValue];
        registerCallback(device, contactFrameCallback);
        startDevice(device, 0);
    }
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
