// Draws one window: the engine's image layer, then the editor's UI over it.
//
// The UI arrives from the off-screen browser as an IOSurface, is copied into a texture the
// compositor owns, and is blended premultiplied over whatever the engine last presented. Where
// the page is transparent the image shows through, so pixels the engine renders reach the screen
// without passing through the page, its IPC, or Chromium's compositor.
#pragma once

#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

struct FotufilmCompositorStats {
  unsigned long long frames;
  unsigned long long browserFrames;
  // The last UI copy's main-thread time and GPU time, the last wait for a drawable, and the last
  // composite's encoding and submission, in µs.
  double lastCopyMicroseconds;
  double lastCopyGpuMicroseconds;
  double lastDrawableWaitMicroseconds;
  double lastCompositeMicroseconds;
  bool sharedTextures;
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

// The image layer, in view points from the top left. A nil texture with a non-empty rectangle
// draws a moving test pattern, to check alignment and latency before an engine is attached.
- (void)setImageTexture:(id<MTLTexture>)texture rect:(CGRect)rect;
- (void)clearImage;

// Watches one point of the window: every change is composited at once and the pixel there read
// back, and the time a changed pixel's composite was committed is recorded, so latency is
// measured on the pixels themselves (cef/README.md, Checks). A NaN point stops watching.
- (void)probePoint:(CGPoint)point;
// The value when the probe was armed, then each change: {time (ms, CACurrentMediaTime), value
// (the pixel's bytes in hex, BGRA8 or RGBA16F)}.
- (NSArray<NSDictionary*>*)probeChanges;

// Composites at the next refresh. Frames are drawn only when something changed.
- (void)setNeedsDisplay;
// Draw every refresh, for content that moves on its own (the test pattern).
@property(nonatomic) BOOL continuous;
// Stops the frame clock; call before the layer goes away.
- (void)invalidate;

@end
