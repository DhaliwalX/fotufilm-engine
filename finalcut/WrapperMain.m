// The wrapper application.
//
// It develops nothing. An FxPlug 4 plug-in is an app extension, and macOS registers extensions it
// finds inside applications — so the effect needs an application to live in, and the application
// needs to be launched once for PlugInKit to notice it. This is that application.
//
// Launched by hand it says whether the extension registered, and quits. Launched with `--register`
// — which is how Fotufilm's own installer launches it — it registers and quits without a word,
// because the app that asked for the install is the one reporting to the user.

#import <AppKit/AppKit.h>

@interface FotufilmWrapperDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, assign) BOOL quiet;
@end

@implementation FotufilmWrapperDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Reaching here is the registration: PlugInKit scans an application's PlugIns directory when
    // it launches. Nothing has to be done to the extension itself.
    if (self.quiet) {
        [NSApp terminate:nil];
        return;
    }

    NSURL *plugins = [NSBundle.mainBundle.bundleURL
        URLByAppendingPathComponent:@"Contents/PlugIns" isDirectory:YES];
    NSArray<NSURL *> *contents =
        [NSFileManager.defaultManager contentsOfDirectoryAtURL:plugins
                                   includingPropertiesForKeys:nil
                                                      options:0
                                                        error:nil];
    BOOL found = NO;
    for (NSURL *url in contents) {
        if ([url.pathExtension isEqualToString:@"pluginkit"]) found = YES;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = found ? @"Fotufilm is installed." : @"Fotufilm is incomplete.";
    alert.informativeText =
        found ? @"Quit and reopen Final Cut Pro or Motion. The effect appears under Effects → "
                @"Fotufilm.\n\nThis application only registers the effect with macOS; it has "
                @"nothing else to do."
              : @"The effect extension is missing from this application, so Final Cut Pro will "
                @"not find it. Reinstall Fotufilm.";
    [alert addButtonWithTitle:@"Quit"];
    [alert runModal];
    [NSApp terminate:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application {
    return YES;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL quiet = NO;
        for (int i = 1; i < argc; ++i) {
            if (strcmp(argv[i], "--register") == 0) quiet = YES;
        }

        NSApplication *application = NSApplication.sharedApplication;
        FotufilmWrapperDelegate *delegate = [[FotufilmWrapperDelegate alloc] init];
        delegate.quiet = quiet;
        application.delegate = delegate;
        [application setActivationPolicy:quiet ? NSApplicationActivationPolicyAccessory
                                               : NSApplicationActivationPolicyRegular];
        [application run];
    }
    return 0;
}
