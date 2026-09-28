// Draws one window on macOS: the Metal half of the compositor. What to draw and when is decided by
// the portable CompositorCore (presentation/compositor_core.h); this owns the Metal device, the
// layer's drawables and the display link, and encodes each plan.
//
// The UI arrives from the off-screen browser as an IOSurface, is copied into a texture the
// compositor owns, and is blended premultiplied over whatever the engine last presented. Where
// the page is transparent the image shows through, so pixels the engine renders reach the screen
// without passing through the page, its IPC, or Chromium's compositor.
#pragma once

#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <functional>
#include <string>

#include "presentation/compositor_core.h"
#include "presentation/presentation_methods.h"

@interface FotufilmCompositor : NSObject

- (instancetype)initWithLayer:(CAMetalLayer*)layer;

@property(nonatomic, readonly) id<MTLDevice> device;
// The decisions; change them on the main thread, then call setNeedsDisplay.
@property(nonatomic, readonly) fotufilm::CompositorCore* core;

// The view's size in points and its backing scale.
- (void)resizeToPoints:(CGSize)size scale:(CGFloat)scale;

// Copies a browser frame, which is valid only during OnAcceleratedPaint. The copy is queued ahead
// of the next composite; the surface is held until the GPU has read it.
- (void)copyBrowserSurface:(IOSurfaceRef)surface;
// Uploads a software browser frame: BGRA, premultiplied, top row first.
- (void)uploadBrowserPixels:(const void*)pixels
                      width:(int)width
                     height:(int)height;

// Composites what the next refresh would show into a file in the temporary directory and hands
// back its path: 8-bit Display P3 PNG, or a half-float extended-linear Display P3 TIFF while the
// drawable is extended range. For checks of what reaches the screen, page and image together.
- (void)snapshot:(void (^)(NSString* path))done;

// Composites at the next refresh. Frames are drawn only when something changed.
- (void)setNeedsDisplay;
// Stops the frame clock; call before the layer goes away.
- (void)invalidate;

@end

namespace fotufilm {

// The portable presentation calls' view of a window's compositor (presentation_methods.h).
class MacWindowCompositor : public WindowCompositor {
 public:
  MacWindowCompositor(FotufilmCompositor* compositor, std::function<float()> headroom);

  CompositorCore& core() override;
  void SetNeedsDisplay() override;
  void RunAfter(double seconds, std::function<void()> task) override;
  double Now() override;
  void Snapshot(std::function<void(const std::string& path)> done) override;
  float Headroom() override { return headroom_(); }

 private:
  __weak FotufilmCompositor* compositor_;
  // Kept so core() stays valid while a late call runs after the window has gone.
  CompositorCore detached_;
  std::function<float()> headroom_;
};

}  // namespace fotufilm
