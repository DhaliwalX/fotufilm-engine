// The macOS presenter: the engine writes into IOSurfaces, which the compositor samples as Metal
// textures without a copy (Apple silicon shares the memory between the CPU and the GPU).
#pragma once

#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "presentation/presentation.h"

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
  void EndWriting() override;

  // Locks the surface for the engine's writes.
  void BeginWriting();
  id<MTLTexture> texture() const { return texture_; }

 private:
  IOSurfaceRef surface_;
  id<MTLTexture> texture_;
  SurfaceFormat format_;
  bool locked_ = false;
};

class MacImagePresenter : public ImagePresenter {
 public:
  // `show` runs on the main thread with each presented frame.
  using Sink = std::function<void(const std::string& layer, PresentedFrame frame)>;

  MacImagePresenter(id<MTLDevice> device, Sink show);

  std::shared_ptr<PresentationSurface> Acquire(int width, int height,
                                               SurfaceFormat format) override;
  uint64_t Present(const std::string& layer, PresentedFrame frame) override;
  float Headroom() override { return headroom_.load(); }

  // The window's screen's EDR headroom, set on the main thread when the screen changes.
  void SetHeadroom(float headroom) { headroom_.store(headroom); }

 private:
  // Surfaces whose frames have left the screen and whose GPU reads have finished, for reuse.
  struct Pool {
    ~Pool() {
      for (MacSurface* surface : free) delete surface;
    }
    std::mutex mutex;
    std::vector<MacSurface*> free;
  };

  id<MTLDevice> device_;
  Sink show_;
  std::shared_ptr<Pool> pool_ = std::make_shared<Pool>();
  std::atomic<uint64_t> next_id_{0};
  std::atomic<float> headroom_{1.f};
};

}  // namespace fotufilm
