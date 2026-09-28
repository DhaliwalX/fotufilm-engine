#import "platform/mac/image_presenter.h"

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <functional>

namespace fotufilm {
namespace {

IOSurfaceRef NewIOSurface(int width, int height, SurfaceFormat format) {
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
    : PooledPresenter(
          [](std::function<void()> task) {
            auto shared = std::make_shared<std::function<void()>>(std::move(task));
            dispatch_async(dispatch_get_main_queue(), ^{
              (*shared)();
            });
          },
          std::move(show)),
      device_(device) {}

std::unique_ptr<PresentationSurface> MacImagePresenter::CreateSurface(int width, int height,
                                                                      SurfaceFormat format) {
  IOSurfaceRef memory = NewIOSurface(width, height, format);
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
  id<MTLTexture> texture = [device_ newTextureWithDescriptor:descriptor iosurface:memory plane:0];
  if (!texture) {
    CFRelease(memory);
    return nullptr;
  }
  return std::make_unique<MacSurface>(memory, texture, format);
}

}  // namespace fotufilm
