#import "platform/mac/compositor.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include <mach/mach_time.h>
#include <simd/simd.h>

namespace {

// One quad per layer: `rect` in normalised device coordinates (x0, y0, x1, y1) and the texture
// coordinates it spans.
struct Quad {
  simd_float4 rect;
  simd_float4 uv;
  float time;
};

NSString* const kShaders = @R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Quad { float4 rect; float4 uv; float time; };
struct Varying { float4 position [[position]]; float2 uv; };

vertex Varying quad_vertex(uint vid [[vertex_id]], constant Quad& quad [[buffer(0)]]) {
  const float2 corner = float2(vid & 1, vid >> 1);
  Varying out;
  out.position = float4(mix(quad.rect.xy, quad.rect.zw, corner), 0, 1);
  out.uv = mix(quad.uv.xy, quad.uv.zw, corner);
  return out;
}

fragment float4 texture_fragment(Varying in [[stage_in]],
                                 texture2d<float> source [[texture(0)]]) {
  constexpr sampler linear(filter::linear, address::clamp_to_edge);
  return source.sample(linear, in.uv);
}

// A moving grid with a sweep, so any lag between the page and this layer is visible.
fragment float4 pattern_fragment(Varying in [[stage_in]], constant Quad& quad [[buffer(0)]]) {
  const float2 cell = floor(in.uv * 12.0);
  const float checker = fmod(cell.x + cell.y, 2.0);
  const float sweep = step(abs(fract(in.uv.x - quad.time * 0.25) - 0.5), 0.01);
  const float3 base = mix(float3(0.16, 0.18, 0.22), float3(0.26, 0.29, 0.34), checker);
  return float4(mix(base, float3(1.0, 0.55, 0.1), sweep), 1.0);
}
)METAL";

double Microseconds(uint64_t start, uint64_t end) {
  static mach_timebase_info_data_t timebase = [] {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    return info;
  }();
  return double(end - start) * timebase.numer / timebase.denom / 1000.0;
}

}  // namespace

@interface FotufilmCompositor () <CAMetalDisplayLinkDelegate>
@end

@implementation FotufilmCompositor {
  CAMetalLayer* _layer;
  id<MTLCommandQueue> _queue;
  id<MTLRenderPipelineState> _texturePipeline;
  id<MTLRenderPipelineState> _uiPipeline;
  id<MTLRenderPipelineState> _patternPipeline;
  id<MTLTexture> _ui;
  id<MTLTexture> _image;
  CGRect _imageRect;
  CGSize _points;
  CGFloat _scale;
  uint64_t _start;
  struct FotufilmCompositorStats _stats;
  CAMetalDisplayLink* _link API_AVAILABLE(macos(14.0));
  BOOL _dirty;
}

- (instancetype)initWithLayer:(CAMetalLayer*)layer {
  if (!(self = [super init])) return nil;
  _layer = layer;
  _device = MTLCreateSystemDefaultDevice();
  _queue = [_device newCommandQueue];
  _layer.device = _device;
  _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  // The page is drawn in sRGB; so is this layer, until the image layer carries wider colour.
  CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  _layer.colorspace = srgb;
  CGColorSpaceRelease(srgb);
  _layer.framebufferOnly = YES;
  _layer.opaque = YES;
  // Three drawables: one on screen, one queued for the next refresh, one free to draw into.
  // Composites are limited to one per refresh, so the queue never deepens and adds no latency,
  // while with two the main thread waited a whole refresh for a drawable.
  _layer.maximumDrawableCount = 3;
  _layer.displaySyncEnabled = YES;
  _start = mach_absolute_time();
  if (@available(macOS 14.0, *)) {
    // One frame clock for every composite: it hands over a drawable timed for the next refresh,
    // so the main thread never waits for one, and it sleeps while nothing changes.
    _link = [[CAMetalDisplayLink alloc] initWithMetalLayer:_layer];
    _link.delegate = self;
    _link.preferredFrameLatency = 1;
    const float fastest = NSScreen.mainScreen.maximumFramesPerSecond ?: 60;
    _link.preferredFrameRateRange = CAFrameRateRangeMake(fastest, fastest, fastest);
    _link.paused = YES;
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  }

  NSError* error = nil;
  id<MTLLibrary> library = [_device newLibraryWithSource:kShaders
                                                 options:nil
                                                   error:&error];
  NSAssert(library, @"Compositor shaders failed: %@", error);
  MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction = [library newFunctionWithName:@"quad_vertex"];
  descriptor.colorAttachments[0].pixelFormat = _layer.pixelFormat;
  descriptor.fragmentFunction = [library newFunctionWithName:@"texture_fragment"];
  _texturePipeline = [_device newRenderPipelineStateWithDescriptor:descriptor
                                                             error:&error];
  descriptor.fragmentFunction = [library newFunctionWithName:@"pattern_fragment"];
  _patternPipeline = [_device newRenderPipelineStateWithDescriptor:descriptor
                                                             error:&error];
  // Chromium's frames are premultiplied.
  descriptor.fragmentFunction = [library newFunctionWithName:@"texture_fragment"];
  MTLRenderPipelineColorAttachmentDescriptor* blend = descriptor.colorAttachments[0];
  blend.blendingEnabled = YES;
  blend.sourceRGBBlendFactor = MTLBlendFactorOne;
  blend.sourceAlphaBlendFactor = MTLBlendFactorOne;
  blend.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  blend.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  _uiPipeline = [_device newRenderPipelineStateWithDescriptor:descriptor
                                                        error:&error];
  NSAssert(_texturePipeline && _patternPipeline && _uiPipeline,
           @"Compositor pipelines failed: %@", error);
  return self;
}

- (struct FotufilmCompositorStats)stats {
  return _stats;
}

- (void)resizeToPoints:(CGSize)size scale:(CGFloat)scale {
  _points = size;
  _scale = scale;
  _layer.contentsScale = scale;
  _layer.drawableSize = CGSizeMake(size.width * scale, size.height * scale);
}

- (id<MTLTexture>)uiTextureWidth:(NSUInteger)width height:(NSUInteger)height {
  if (_ui.width != width || _ui.height != height) {
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:width
                                    height:height
                                 mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    _ui = [_device newTextureWithDescriptor:descriptor];
  }
  return _ui;
}

- (void)copyBrowserSurface:(IOSurfaceRef)surface {
  const uint64_t start = mach_absolute_time();
  const NSUInteger width = IOSurfaceGetWidth(surface),
                   height = IOSurfaceGetHeight(surface);
  MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:width
                                  height:height
                               mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> source = [_device newTextureWithDescriptor:descriptor
                                                  iosurface:surface
                                                      plane:0];
  if (!source) return;
  id<MTLTexture> target = [self uiTextureWidth:width height:height];
  id<MTLCommandBuffer> commands = [_queue commandBuffer];
  id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
  [blit copyFromTexture:source toTexture:target];
  [blit endEncoding];
  // The surface goes back to Chromium's pool when OnAcceleratedPaint returns. Waiting here for the
  // copy blocked the main thread, and with it input, for 1–9 ms a frame. Instead the surface stays
  // retained and marked in use until the GPU has read it; the pool holds several frames, and the
  // copy runs within about a millisecond, long before the pool comes back round to it. The
  // composite that follows is on the same queue, so it always sees the finished copy.
  CFRetain(surface);
  IOSurfaceIncrementUseCount(surface);
  [commands addCompletedHandler:^(id<MTLCommandBuffer> done) {
    IOSurfaceDecrementUseCount(surface);
    CFRelease(surface);
    const double gpu = (done.GPUEndTime - done.GPUStartTime) * 1e6;
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_stats.lastCopyGpuMicroseconds = gpu;
    });
  }];
  [commands commit];
  _stats.lastCopyMicroseconds = Microseconds(start, mach_absolute_time());
  _stats.browserFrames++;
  _stats.sharedTextures = true;
}

- (void)uploadBrowserPixels:(const void*)pixels
                      width:(int)width
                     height:(int)height {
  const uint64_t start = mach_absolute_time();
  id<MTLTexture> target = [self uiTextureWidth:width height:height];
  [target replaceRegion:MTLRegionMake2D(0, 0, width, height)
            mipmapLevel:0
              withBytes:pixels
            bytesPerRow:width * 4];
  _stats.lastCopyMicroseconds = Microseconds(start, mach_absolute_time());
  _stats.browserFrames++;
  _stats.sharedTextures = false;
}

- (void)setImageTexture:(id<MTLTexture>)texture rect:(CGRect)rect {
  _image = texture;
  _imageRect = rect;
}

- (void)clearImage {
  _image = nil;
  _imageRect = CGRectNull;
}

// Points from the top left to normalised device coordinates.
- (simd_float4)deviceRect:(CGRect)rect {
  const CGFloat width = MAX(_points.width, 1), height = MAX(_points.height, 1);
  return simd_make_float4(rect.origin.x / width * 2 - 1,
                          1 - rect.origin.y / height * 2,
                          CGRectGetMaxX(rect) / width * 2 - 1,
                          1 - CGRectGetMaxY(rect) / height * 2);
}

- (void)setNeedsDisplay {
  _dirty = YES;
  if (@available(macOS 14.0, *)) {
    if (_link) {
      _link.paused = NO;
      return;
    }
  }
  [self drawInto:nil];
}

- (void)invalidate {
  if (@available(macOS 14.0, *)) {
    [_link invalidate];
    _link = nil;
  }
}

- (void)setContinuous:(BOOL)continuous {
  _continuous = continuous;
  if (continuous) [self setNeedsDisplay];
}

- (void)metalDisplayLink:(CAMetalDisplayLink*)link
             needsUpdate:(CAMetalDisplayLinkUpdate*)update API_AVAILABLE(macos(14.0)) {
  if (!_dirty && !_continuous) {
    link.paused = YES;
    return;
  }
  [self drawInto:update.drawable];
}

// Draws the image layer and the page into `drawable`, or into the layer's next drawable where no
// display link hands one over.
- (void)drawInto:(id<CAMetalDrawable>)drawable {
  if (_points.width < 1 || _points.height < 1) return;
  _dirty = NO;
  const uint64_t start = mach_absolute_time();
  if (!drawable) drawable = [_layer nextDrawable];
  if (!drawable) return;
  const uint64_t acquired = mach_absolute_time();
  _stats.lastDrawableWaitMicroseconds = Microseconds(start, acquired);
  MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = drawable.texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
  id<MTLCommandBuffer> commands = [_queue commandBuffer];
  id<MTLRenderCommandEncoder> encoder =
      [commands renderCommandEncoderWithDescriptor:pass];

  Quad quad{};
  quad.time = float(Microseconds(_start, start) / 1e6);
  if (!CGRectIsNull(_imageRect) && !CGRectIsEmpty(_imageRect)) {
    quad.rect = [self deviceRect:_imageRect];
    quad.uv = simd_make_float4(0, 0, 1, 1);
    [encoder setRenderPipelineState:_image ? _texturePipeline : _patternPipeline];
    [encoder setVertexBytes:&quad length:sizeof quad atIndex:0];
    if (_image)
      [encoder setFragmentTexture:_image atIndex:0];
    else
      [encoder setFragmentBytes:&quad length:sizeof quad atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  }
  if (_ui) {
    // The page's frame at its own pixel size from the top left, so a resize in flight shows an
    // edge rather than a stretched UI.
    const CGRect rect = CGRectMake(0, 0, _ui.width / _scale, _ui.height / _scale);
    quad.rect = [self deviceRect:rect];
    quad.uv = simd_make_float4(0, 0, 1, 1);
    [encoder setRenderPipelineState:_uiPipeline];
    [encoder setVertexBytes:&quad length:sizeof quad atIndex:0];
    [encoder setFragmentTexture:_ui atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  }
  [encoder endEncoding];
  [commands presentDrawable:drawable];
  [commands commit];
  _stats.frames++;
  _stats.lastCompositeMicroseconds = Microseconds(acquired, mach_absolute_time());
}

@end
