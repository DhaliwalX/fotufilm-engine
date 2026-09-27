#import "platform/mac/image_presenter.h"

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <algorithm>

namespace fotufilm {
namespace {

// Released surfaces kept for reuse: two slots of developed and undeveloped frames, a few deep.
constexpr size_t kPoolLimit = 8;

IOSurfaceRef CreateSurface(int width, int height, SurfaceFormat format) {
  const size_t bytes = BytesPerPixel(format);
  const size_t row = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * bytes);
  const OSType pixel = format == SurfaceFormat::kRgba8DisplayP3
                           ? kCVPixelFormatType_32RGBA
                           : kCVPixelFormatType_64RGBAHalf;
  NSDictionary* properties = @{
    (id)kIOSurfaceWidth : @(width),
    (id)kIOSurfaceHeight : @(height),
    (id)kIOSurfaceBytesPerElement : @(bytes),
    (id)kIOSurfaceBytesPerRow : @(row),
    (id)kIOSurfaceAllocSize : @(IOSurfaceAlignProperty(kIOSurfaceAllocSize, row * height)),
    (id)kIOSurfacePixelFormat : @(pixel),
  };
  return IOSurfaceCreate((__bridge CFDictionaryRef)properties);
}

}  // namespace

MacSurface::MacSurface(IOSurfaceRef surface, id<MTLTexture> texture, SurfaceFormat format)
    : surface_(surface), texture_(texture), format_(format) {}

MacSurface::~MacSurface() {
  EndWriting();
  texture_ = nil;
  CFRelease(surface_);
}

int MacSurface::width() const { return static_cast<int>(IOSurfaceGetWidth(surface_)); }
int MacSurface::height() const { return static_cast<int>(IOSurfaceGetHeight(surface_)); }
void* MacSurface::pixels() { return IOSurfaceGetBaseAddress(surface_); }
size_t MacSurface::row_bytes() const { return IOSurfaceGetBytesPerRow(surface_); }

void MacSurface::BeginWriting() {
  if (locked_) return;
  IOSurfaceLock(surface_, 0, nullptr);
  locked_ = true;
}

void MacSurface::EndWriting() {
  if (!locked_) return;
  IOSurfaceUnlock(surface_, 0, nullptr);
  locked_ = false;
}

MacImagePresenter::MacImagePresenter(id<MTLDevice> device, Sink show)
    : device_(device), show_(std::move(show)) {}

std::shared_ptr<PresentationSurface> MacImagePresenter::Acquire(int width, int height,
                                                                SurfaceFormat format) {
  if (width <= 0 || height <= 0) return nullptr;
  MacSurface* surface = nullptr;
  {
    std::lock_guard<std::mutex> lock(pool_->mutex);
    auto& free = pool_->free;
    auto match = std::find_if(free.begin(), free.end(), [&](MacSurface* s) {
      return s->width() == width && s->height() == height && s->format() == format;
    });
    if (match != free.end()) {
      surface = *match;
      free.erase(match);
    }
  }
  if (!surface) {
    IOSurfaceRef memory = CreateSurface(width, height, format);
    if (!memory) return nullptr;
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:format == SurfaceFormat::kRgba8DisplayP3
                                               ? MTLPixelFormatRGBA8Unorm
                                               : MTLPixelFormatRGBA16Float
                                     width:width
                                    height:height
                                 mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device_ newTextureWithDescriptor:descriptor
                                                     iosurface:memory
                                                         plane:0];
    if (!texture) {
      CFRelease(memory);
      return nullptr;
    }
    surface = new MacSurface(memory, texture, format);
  }
  surface->BeginWriting();
  // The last reference, the compositor's once the GPU has read the frame, hands it back.
  std::weak_ptr<Pool> pool = pool_;
  return std::shared_ptr<PresentationSurface>(surface, [pool](PresentationSurface* done) {
    auto* mac = static_cast<MacSurface*>(done);
    mac->EndWriting();
    if (auto shared = pool.lock()) {
      std::lock_guard<std::mutex> lock(shared->mutex);
      if (shared->free.size() < kPoolLimit) {
        shared->free.push_back(mac);
        return;
      }
    }
    delete mac;
  });
}

uint64_t MacImagePresenter::Present(const std::string& layer, PresentedFrame frame) {
  if (!frame.surface) return 0;
  frame.surface->EndWriting();
  frame.id = ++next_id_;
  const uint64_t id = frame.id;
  Sink show = show_;
  auto shared = std::make_shared<PresentedFrame>(std::move(frame));
  std::string name = layer;
  dispatch_async(dispatch_get_main_queue(), ^{
    show(name, std::move(*shared));
  });
  return id;
}

}  // namespace fotufilm
