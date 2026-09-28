// The macOS presenter: the engine writes into IOSurfaces, which the compositor samples as Metal
// textures without a copy (Apple silicon shares the memory between the CPU and the GPU). Pooling,
// numbering and the hand-over to the main thread are the shared PooledPresenter's.
#pragma once

#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

#include <memory>

#include "presentation/pooled_presenter.h"

namespace fotufilm {

class MacSurface : public PresentationSurface {
 public:
  MacSurface(IOSurfaceRef surface, id<MTLTexture> texture, SurfaceFormat format);
  ~MacSurface() override;

  int width() const override;
  int height() const override;
  SurfaceFormat format() const override { return format_; }
  void* pixels() override;
  size_t row_bytes() const override;
  void* native_handle() override { return surface_; }
  // Locks the surface for the engine's writes, and unlocks it.
  void BeginWriting() override;
  void EndWriting() override;

  id<MTLTexture> texture() const { return texture_; }

 private:
  IOSurfaceRef surface_;
  id<MTLTexture> texture_;
  SurfaceFormat format_;
  bool locked_ = false;
};

class MacImagePresenter : public PooledPresenter {
 public:
  // `show` runs on the main thread with each presented frame.
  MacImagePresenter(id<MTLDevice> device, Sink show);

 protected:
  std::unique_ptr<PresentationSurface> CreateSurface(int width, int height,
                                                     SurfaceFormat format) override;

 private:
  id<MTLDevice> device_;
};

}  // namespace fotufilm
