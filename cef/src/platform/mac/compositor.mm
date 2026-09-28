#import "platform/mac/compositor.h"

#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <mach/mach_time.h>
#include <simd/simd.h>

#include <memory>
#include <vector>

#import "platform/mac/image_presenter.h"

namespace {

// How the image layer and the page are encoded, in the shaders' terms.
enum Encoding : uint32_t {
  // Display P3 (or sRGB, for the page) with the sRGB transfer.
  kTransfer = 0,
  // Extended-linear Display P3.
  kLinear = 1,
};

// One quad: `rect` in normalised device coordinates (x0, y0, x1, y1), the texture coordinates
// it spans, how its source is encoded and how the drawable is.
struct Quad {
  simd_float4 rect;
  simd_float4 uv;
  float time;
  uint32_t source;
  uint32_t target;
  // How much of the picture covers what is beneath it (a crossfade).
  float opacity;
};

NSString* const kShaders = @R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Quad { float4 rect; float4 uv; float time; uint source; uint target; float opacity; };
struct Varying { float4 position [[position]]; float2 uv; };

vertex Varying quad_vertex(uint vid [[vertex_id]], constant Quad& quad [[buffer(0)]]) {
  const float2 corner = float2(vid & 1, vid >> 1);
  Varying out;
  out.position = float4(mix(quad.rect.xy, quad.rect.zw, corner), 0, 1);
  out.uv = mix(quad.uv.xy, quad.uv.zw, corner);
  return out;
}

float3 decode(float3 c) {
  c = max(c, 0.0);
  return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

float3 encode(float3 l) {
  l = clamp(l, 0.0, 1.0);
  return select(1.055 * pow(l, 1.0 / 2.4) - 0.055, l * 12.92, l <= 0.0031308);
}

// Linear sRGB to linear Display P3 (both D65), by columns.
constant float3x3 kSRGBToP3 = float3x3(float3(0.822462, 0.033194, 0.017083),
                                       float3(0.177538, 0.966806, 0.072397),
                                       float3(0.0, 0.0, 0.910520));

// A presented picture, already Display P3: re-encoded only when the drawable is the other kind.
fragment float4 image_fragment(Varying in [[stage_in]], constant Quad& quad [[buffer(0)]],
                               texture2d<float> source [[texture(0)]]) {
  constexpr sampler linear(filter::linear, address::clamp_to_edge);
  float3 c = source.sample(linear, in.uv).rgb;
  if (quad.source != quad.target) c = quad.target == 1 ? decode(c) : encode(c);
  return float4(c, quad.opacity);
}

// The page: premultiplied sRGB, converted to the drawable's Display P3 and blended over the
// image. In an 8-bit drawable the blend happens on encoded values, as a browser's does.
fragment float4 page_fragment(Varying in [[stage_in]], constant Quad& quad [[buffer(0)]],
                              texture2d<float> source [[texture(0)]]) {
  constexpr sampler linear(filter::linear, address::clamp_to_edge);
  const float4 c = source.sample(linear, in.uv);
  if (c.a <= 0.0) return float4(0.0);
  const float3 p3 = kSRGBToP3 * decode(c.rgb / c.a);
  const float3 out = quad.target == 1 ? p3 : encode(p3);
  return float4(out * c.a, c.a);
}

// A moving grid with a sweep, so any lag between the page and this layer is visible.
fragment float4 pattern_fragment(Varying in [[stage_in]], constant Quad& quad [[buffer(0)]]) {
  const float2 cell = floor(in.uv * 12.0);
  const float checker = fmod(cell.x + cell.y, 2.0);
  const float sweep = step(abs(fract(in.uv.x - quad.time * 0.25) - 0.5), 0.01);
  const float3 base = mix(float3(0.16, 0.18, 0.22), float3(0.26, 0.29, 0.34), checker);
  const float3 c = mix(base, float3(1.0, 0.55, 0.1), sweep);
  return float4(quad.target == 1 ? decode(c) : c, 1.0);
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

MTLPixelFormat DrawableFormat(bool extended) {
  return extended ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
}

}  // namespace

// The three pipelines for one drawable format.
@interface FotufilmPipelines : NSObject
@property(nonatomic) id<MTLRenderPipelineState> image;
@property(nonatomic) id<MTLRenderPipelineState> page;
@property(nonatomic) id<MTLRenderPipelineState> pattern;
@end
@implementation FotufilmPipelines
@end

@interface FotufilmCompositor () <CAMetalDisplayLinkDelegate>
@end

@implementation FotufilmCompositor {
  CAMetalLayer* _layer;
  id<MTLCommandQueue> _queue;
  FotufilmPipelines* _standard;
  FotufilmPipelines* _extended;
  id<MTLTexture> _ui;
  std::unique_ptr<fotufilm::CompositorCore> _core;
  CAMetalDisplayLink* _link API_AVAILABLE(macos(14.0));
  id<MTLTexture> _probeTarget;
}

- (instancetype)initWithLayer:(CAMetalLayer*)layer {
  if (!(self = [super init])) return nil;
  _layer = layer;
  _device = MTLCreateSystemDefaultDevice();
  _queue = [_device newCommandQueue];
  _core = std::make_unique<fotufilm::CompositorCore>(CACurrentMediaTime());
  _layer.device = _device;
  _layer.framebufferOnly = YES;
  _layer.opaque = YES;
  [self useExtendedRange:NO];
  // Three drawables: one on screen, one queued for the next refresh, one free to draw into.
  // Composites are limited to one per refresh, so the queue never deepens and adds no latency,
  // while with two the main thread waited a whole refresh for a drawable.
  _layer.maximumDrawableCount = 3;
  _layer.displaySyncEnabled = YES;
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
  id<MTLLibrary> library = [_device newLibraryWithSource:kShaders options:nil error:&error];
  NSAssert(library, @"Compositor shaders failed: %@", error);
  _standard = [self pipelines:library format:DrawableFormat(false)];
  _extended = [self pipelines:library format:DrawableFormat(true)];
  return self;
}

- (fotufilm::CompositorCore*)core {
  return _core.get();
}

- (FotufilmPipelines*)pipelines:(id<MTLLibrary>)library format:(MTLPixelFormat)format {
  NSError* error = nil;
  FotufilmPipelines* pipelines = [FotufilmPipelines new];
  MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction = [library newFunctionWithName:@"quad_vertex"];
  descriptor.colorAttachments[0].pixelFormat = format;
  descriptor.fragmentFunction = [library newFunctionWithName:@"pattern_fragment"];
  pipelines.pattern = [_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
  // A picture fading in covers the one beneath it by its opacity.
  descriptor.fragmentFunction = [library newFunctionWithName:@"image_fragment"];
  MTLRenderPipelineColorAttachmentDescriptor* fade = descriptor.colorAttachments[0];
  fade.blendingEnabled = YES;
  fade.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  fade.sourceAlphaBlendFactor = MTLBlendFactorOne;
  fade.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  fade.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  pipelines.image = [_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
  // Chromium's frames are premultiplied.
  descriptor.fragmentFunction = [library newFunctionWithName:@"page_fragment"];
  MTLRenderPipelineColorAttachmentDescriptor* blend = descriptor.colorAttachments[0];
  blend.blendingEnabled = YES;
  blend.sourceRGBBlendFactor = MTLBlendFactorOne;
  blend.sourceAlphaBlendFactor = MTLBlendFactorOne;
  blend.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  blend.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  pipelines.page = [_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
  NSAssert(pipelines.image && pipelines.pattern && pipelines.page,
           @"Compositor pipelines failed: %@", error);
  return pipelines;
}

// Switches the drawable between 8-bit Display P3 and extended-linear Display P3 with EDR.
- (void)useExtendedRange:(BOOL)extended {
  const MTLPixelFormat format = DrawableFormat(extended);
  if (_layer.colorspace && _layer.pixelFormat == format) return;
  _layer.pixelFormat = format;
  CGColorSpaceRef space = CGColorSpaceCreateWithName(
      extended ? kCGColorSpaceExtendedLinearDisplayP3 : kCGColorSpaceDisplayP3);
  _layer.colorspace = space;
  CGColorSpaceRelease(space);
  _layer.wantsExtendedDynamicRangeContent = extended;
  _core->SetExtendedRange(extended);
}

- (void)resizeToPoints:(CGSize)size scale:(CGFloat)scale {
  _core->Resize(size.width, size.height, scale);
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
  __weak FotufilmCompositor* weakSelf = self;
  [commands addCompletedHandler:^(id<MTLCommandBuffer> done) {
    IOSurfaceDecrementUseCount(surface);
    CFRelease(surface);
    const double gpu = (done.GPUEndTime - done.GPUStartTime) * 1e6;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (FotufilmCompositor* strong = weakSelf) strong->_core->BrowserCopyFinished(gpu);
    });
  }];
  [commands commit];
  _core->BrowserFrame(int(width), int(height), true, Microseconds(start, mach_absolute_time()));
  [self setNeedsDisplay];
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
  _core->BrowserFrame(width, height, false, Microseconds(start, mach_absolute_time()));
  [self setNeedsDisplay];
}

// While probing, every change is also composited at once into a texture of the drawable's size
// and the probed pixel read back from it, timed when that composite is committed. The display
// link's own composite follows at the next refresh, so what this measures is the path up to the
// frame the screen will show, less at most one refresh; and it holds while the window is covered
// or the screen is locked, when the system slows the display link down.
- (void)probeComposite {
  _core->ProbeStarted();
  if (!_core->probing() || !_core->HasArea()) return;
  const CFTimeInterval now = CACurrentMediaTime();
  const bool extended = _core->WantsExtendedRange(now);
  const fotufilm::CompositePlan plan = _core->Plan(now, extended);
  const MTLPixelFormat format = DrawableFormat(extended);
  if (_probeTarget.width != NSUInteger(plan.width) ||
      _probeTarget.height != NSUInteger(plan.height) || _probeTarget.pixelFormat != format) {
    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:plan.width
                                                          height:plan.height
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget;
    descriptor.storageMode = MTLStorageModePrivate;
    _probeTarget = [_device newTextureWithDescriptor:descriptor];
  }
  id<MTLCommandBuffer> commands = [_queue commandBuffer];
  [self encode:plan into:_probeTarget commands:commands];
  const auto [x, y] = _core->ProbePixel();
  const NSUInteger bytes = extended ? 8 : 4;
  id<MTLBuffer> buffer = [_device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
  id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
  [blit copyFromTexture:_probeTarget
               sourceSlice:0
               sourceLevel:0
              sourceOrigin:MTLOriginMake(x, y, 0)
                sourceSize:MTLSizeMake(1, 1, 1)
                  toBuffer:buffer
         destinationOffset:0
    destinationBytesPerRow:bytes
  destinationBytesPerImage:bytes];
  [blit endEncoding];
  // Command buffers complete in order, so changes are recorded in order.
  const CFTimeInterval committed = CACurrentMediaTime();
  __weak FotufilmCompositor* weakSelf = self;
  [commands addCompletedHandler:^(id<MTLCommandBuffer>) {
    const uint8_t* read = static_cast<const uint8_t*>(buffer.contents);
    std::string hex;
    char digits[3];
    for (NSUInteger i = 0; i < bytes; ++i) {
      snprintf(digits, sizeof digits, "%02x", read[i]);
      hex += digits;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      if (FotufilmCompositor* strong = weakSelf) strong->_core->RecordProbe(committed * 1000, hex);
    });
  }];
  [commands commit];
}

- (void)snapshot:(void (^)(NSString* path))done {
  if (!_core->HasArea()) return done(nil);
  const CFTimeInterval now = CACurrentMediaTime();
  const bool extended = _core->WantsExtendedRange(now);
  const fotufilm::CompositePlan plan = _core->Plan(now, extended);
  const NSUInteger width = plan.width, height = plan.height;
  MTLTextureDescriptor* descriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:DrawableFormat(extended)
                                                         width:width
                                                        height:height
                                                     mipmapped:NO];
  descriptor.usage = MTLTextureUsageRenderTarget;
  descriptor.storageMode = MTLStorageModeShared;
  id<MTLTexture> target = [_device newTextureWithDescriptor:descriptor];
  id<MTLCommandBuffer> commands = [_queue commandBuffer];
  [self encode:plan into:target commands:commands];
  [commands addCompletedHandler:^(id<MTLCommandBuffer>) {
    const size_t bytes = extended ? 8 : 4, row = width * bytes;
    NSMutableData* pixels = [NSMutableData dataWithLength:row * height];
    [target getBytes:pixels.mutableBytes
         bytesPerRow:row
          fromRegion:MTLRegionMake2D(0, 0, width, height)
         mipmapLevel:0];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(
        extended ? kCGColorSpaceExtendedLinearDisplayP3 : kCGColorSpaceDisplayP3);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    const CGBitmapInfo info =
        extended ? CGBitmapInfo(kCGBitmapFloatComponents | kCGBitmapByteOrder16Little |
                                kCGImageAlphaNoneSkipLast)
                 : CGBitmapInfo(kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
    CGImageRef image = CGImageCreate(width, height, extended ? 16 : 8, bytes * 8, row, space, info,
                                     provider, nullptr, false, kCGRenderingIntentDefault);
    NSString* path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"fotufilm-composite-%@.%@",
                                                                  NSUUID.UUID.UUIDString,
                                                                  extended ? @"tiff" : @"png"]];
    CGImageDestinationRef file = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path],
        (__bridge CFStringRef)(extended ? UTTypeTIFF : UTTypePNG).identifier, 1, nullptr);
    BOOL written = NO;
    if (file && image) {
      CGImageDestinationAddImage(file, image, nullptr);
      written = CGImageDestinationFinalize(file);
    }
    if (file) CFRelease(file);
    if (image) CGImageRelease(image);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    dispatch_async(dispatch_get_main_queue(), ^{
      done(written ? path : nil);
    });
  }];
  [commands commit];
}

- (void)setNeedsDisplay {
  if (_core->Invalidate()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self probeComposite];
    });
  }
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

- (void)metalDisplayLink:(CAMetalDisplayLink*)link
             needsUpdate:(CAMetalDisplayLinkUpdate*)update API_AVAILABLE(macos(14.0)) {
  if (!_core->Refresh(CACurrentMediaTime())) {
    link.paused = YES;
    return;
  }
  [self drawInto:update.drawable];
}

// Draws a plan into `target`, in the target's encoding.
- (void)encode:(const fotufilm::CompositePlan&)plan
          into:(id<MTLTexture>)target
      commands:(id<MTLCommandBuffer>)commands {
  FotufilmPipelines* pipelines = plan.extended ? _extended : _standard;
  MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = target;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
  id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];

  // The GPU holds the engine's frames until it has read them.
  auto held = std::make_shared<std::vector<std::shared_ptr<fotufilm::PresentationSurface>>>();
  const MTLScissorRect whole{0, 0, target.width, target.height};
  for (const fotufilm::CompositeQuad& item : plan.quads) {
    using Kind = fotufilm::CompositeQuad::Kind;
    Quad quad{};
    quad.rect = simd_make_float4(item.rect.x0, item.rect.y0, item.rect.x1, item.rect.y1);
    quad.uv = simd_make_float4(0, 0, 1, 1);
    quad.time = plan.time;
    quad.target = plan.extended ? kLinear : kTransfer;
    quad.source = item.linear_source ? kLinear : kTransfer;
    quad.opacity = item.opacity;
    id<MTLTexture> texture = nil;
    switch (item.kind) {
      case Kind::kPattern:
        [encoder setRenderPipelineState:pipelines.pattern];
        break;
      case Kind::kImage: {
        if (!plan.scissor) continue;
        const fotufilm::PixelRect& clip = *plan.scissor;
        [encoder setScissorRect:(MTLScissorRect){NSUInteger(clip.x), NSUInteger(clip.y),
                                                 NSUInteger(clip.width), NSUInteger(clip.height)}];
        [encoder setRenderPipelineState:pipelines.image];
        texture = static_cast<fotufilm::MacSurface*>(item.surface.get())->texture();
        held->push_back(item.surface);
        break;
      }
      case Kind::kPage:
        [encoder setScissorRect:whole];
        [encoder setRenderPipelineState:pipelines.page];
        texture = _ui;
        break;
    }
    [encoder setVertexBytes:&quad length:sizeof quad atIndex:0];
    [encoder setFragmentBytes:&quad length:sizeof quad atIndex:0];
    if (texture) [encoder setFragmentTexture:texture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  }
  [encoder endEncoding];
  if (!held->empty()) {
    [commands addCompletedHandler:^(id<MTLCommandBuffer>) {
      held->clear();
    }];
  }
}

// Draws the image layer and the page into `drawable`, or into the layer's next drawable where no
// display link hands one over.
- (void)drawInto:(id<CAMetalDrawable>)drawable {
  if (!_core->HasArea()) return;
  _core->Tick();
  // A change of range takes effect from the next drawable, which is made in the new format; the
  // one in hand is let go rather than shown in the wrong colour space.
  const CFTimeInterval now = CACurrentMediaTime();
  const bool extended = _core->WantsExtendedRange(now);
  if (extended != _core->stats().extended_range) {
    [self useExtendedRange:extended];
    if (drawable) return;
  }
  _core->ClearDirty();
  const uint64_t start = mach_absolute_time();
  if (!drawable) drawable = [_layer nextDrawable];
  if (!drawable) return;
  const uint64_t acquired = mach_absolute_time();
  id<MTLCommandBuffer> commands = [_queue commandBuffer];
  [self encode:_core->Plan(now, extended) into:drawable.texture commands:commands];
  [commands presentDrawable:drawable];
  [commands commit];
  _core->Composited(Microseconds(start, acquired), Microseconds(acquired, mach_absolute_time()));
  // A crossfade draws every frame until it is done, and a movie's queued frame the next one.
  if (_core->KeepDrawing(CACurrentMediaTime())) {
    BOOL linked = NO;
    if (@available(macOS 14.0, *)) linked = _link != nil;
    if (!linked) {
      __weak __typeof(self) weak = self;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 60), dispatch_get_main_queue(), ^{
        [weak setNeedsDisplay];
      });
    }
  }
}

@end

namespace fotufilm {

MacWindowCompositor::MacWindowCompositor(FotufilmCompositor* compositor,
                                         std::function<float()> headroom)
    : compositor_(compositor), headroom_(std::move(headroom)) {}

CompositorCore& MacWindowCompositor::core() {
  FotufilmCompositor* compositor = compositor_;
  return compositor ? *compositor.core : detached_;
}

void MacWindowCompositor::SetNeedsDisplay() {
  [compositor_ setNeedsDisplay];
}

void MacWindowCompositor::RunAfter(double seconds, std::function<void()> task) {
  auto shared = std::make_shared<std::function<void()>>(std::move(task));
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(seconds * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   (*shared)();
                 });
}

double MacWindowCompositor::Now() { return CACurrentMediaTime(); }

void MacWindowCompositor::Snapshot(std::function<void(const std::string& path)> done) {
  FotufilmCompositor* compositor = compositor_;
  if (!compositor) return done("");
  auto shared = std::make_shared<std::function<void(const std::string&)>>(std::move(done));
  [compositor snapshot:^(NSString* path) {
    (*shared)(path ? std::string(path.UTF8String) : std::string());
  }];
}

}  // namespace fotufilm
