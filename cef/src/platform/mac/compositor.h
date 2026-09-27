// Draws one window: the engine's image layer, then the editor's UI over it.
//
// The UI arrives from the off-screen browser as an IOSurface, is copied into a texture the
// compositor owns, and is blended premultiplied over whatever the engine last presented. Where
// the page is transparent the image shows through, so pixels the engine renders reach the screen
// without passing through the page, its IPC, or Chromium's compositor.
//
// Colour: the drawable is Display P3. The page, drawn in sRGB, is converted in the blend. While
// a frame on show carries light above SDR white and the screen has room for it, the drawable is
// extended-linear Display P3 in half floats with EDR requested; otherwise 8-bit.
#pragma once

#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <string>

#include "presentation/image_layer.h"

struct FotufilmCompositorStats {
  unsigned long long frames;
  unsigned long long browserFrames;
  unsigned long long imageFrames;
  // The last UI copy's main-thread time and GPU time, the last wait for a drawable, and the last
  // composite's encoding and submission, in µs.
  double lastCopyMicroseconds;
  double lastCopyGpuMicroseconds;
  double lastDrawableWaitMicroseconds;
  double lastCompositeMicroseconds;
  bool sharedTextures;
  // Whether the drawable is extended range now.
  bool extendedRange;
};

@interface FotufilmCompositor : NSObject

- (instancetype)initWithLayer:(CAMetalLayer*)layer;

@property(nonatomic, readonly) id<MTLDevice> device;
@property(nonatomic, readonly) struct FotufilmCompositorStats stats;

// The view's size in points and its backing scale.
- (void)resizeToPoints:(CGSize)size scale:(CGFloat)scale;

// Copies a browser frame, which is valid only during OnAcceleratedPaint. The copy is queued ahead
// of the next composite; the surface is held until the GPU has read it.
- (void)copyBrowserSurface:(IOSurfaceRef)surface;
// Uploads a software browser frame: BGRA, premultiplied, top row first.
- (void)uploadBrowserPixels:(const void*)pixels
                      width:(int)width
                     height:(int)height;

// A frame the engine presented (presentation/image_layer.h). Main thread.
- (void)presentFrame:(fotufilm::PresentedFrame)frame layer:(const std::string&)layer;
// Where the page shows the image layer now. It takes effect with the next browser frame, which
// is the one that carries the page's matching layout, or shortly after if none comes.
- (void)placeImageLayer:(fotufilm::ImageLayerGeometry)geometry;
// A moving test pattern in `rect` (view points from the top left), to check alignment and
// latency before an engine is attached; an empty rectangle removes it.
- (void)showTestPattern:(CGRect)rect;

// Watches one point of the window: every change is composited at once and the pixel there read
// back, and the time a changed pixel's composite was committed is recorded, so latency is
// measured on the pixels themselves (cef/README.md, Checks). A NaN point stops watching.
- (void)probePoint:(CGPoint)point;
// The value when the probe was armed, then each change: {time (ms, CACurrentMediaTime), value
// (the pixel's bytes in hex, BGRA8 or RGBA16F)}.
- (NSArray<NSDictionary*>*)probeChanges;

// Composites what the next refresh would show into a file in the temporary directory and hands
// back its path: 8-bit Display P3 PNG, or a half-float extended-linear Display P3 TIFF while the
// drawable is extended range. For checks of what reaches the screen, page and image together.
- (void)snapshot:(void (^)(NSString* path))done;

// Composites at the next refresh. Frames are drawn only when something changed.
- (void)setNeedsDisplay;
// Draw every refresh, for content that moves on its own (the test pattern).
@property(nonatomic) BOOL continuous;
// Stops the frame clock; call before the layer goes away.
- (void)invalidate;

@end
