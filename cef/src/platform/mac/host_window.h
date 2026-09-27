// The editor window on macOS: one Metal-backed view that shows the off-screen browser over the
// engine's image and forwards mouse, keyboard and trackpad input to it.
#pragma once

#import <Cocoa/Cocoa.h>

#include <string>

namespace fotufilm {
class Dispatcher;
}

@interface FotufilmHostWindow : NSObject <NSWindowDelegate>

// Opens a window on `url`. `dispatcher` receives the page's calls and outlives the window.
- (instancetype)initWithURL:(const std::string&)url
                 dispatcher:(fotufilm::Dispatcher*)dispatcher;

// Asks the browser to close; the window closes once it has.
- (void)requestClose;
@property(nonatomic, readonly) BOOL closed;

@end
