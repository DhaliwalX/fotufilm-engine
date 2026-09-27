// The editor window on macOS: one Metal-backed view that shows the off-screen browser over the
// engine's image and forwards mouse, keyboard and trackpad input to it.
#pragma once

#import <Cocoa/Cocoa.h>

#include <string>

namespace fotufilm {
class Dispatcher;
}

@interface FotufilmHostWindow : NSObject <NSWindowDelegate, NSMenuItemValidation>

// Opens a window on `url`. `dispatcher` receives the page's calls and outlives the window.
- (instancetype)initWithURL:(const std::string&)url
                 dispatcher:(fotufilm::Dispatcher*)dispatcher;

// Asks the browser to close; the window closes once it has.
- (void)requestClose;
@property(nonatomic, readonly) BOOL closed;
@property(nonatomic, readonly) NSWindow* window;

// Opens files in the editor, by path, once it listens; each is noted in Open Recent.
- (void)openURLs:(NSArray<NSURL*>*)urls;
// Whether the editor, as it last reported, can run `command` now.
- (BOOL)commandEnabled:(NSString*)command;
// Runs one of the editor's commands (web/src/editor/useNativeCommands.js).
- (void)sendCommand:(NSString*)command;
// Whether focus is in one of the page's text fields, which then own Undo and the clipboard.
@property(nonatomic, readonly) BOOL pageEditsText;

@end
