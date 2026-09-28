// The presenter every platform shares: surfaces are pooled and reused once the compositor has let
// go of them, and presented frames are numbered and handed to the UI thread. A platform supplies
// only how a surface is made (CreateSurface) and how work reaches its UI thread (the `post`
// function: dispatch_async to the main queue on macOS, CefPostTask(TID_UI) elsewhere).
//
// Reusing surfaces matters as much as sharing them: a 4K half-float frame is 64 MB, and an edit
// in motion presents one every refresh. Pure C++; its tests run anywhere.
#pragma once

#include <atomic>
#include <cstddef>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "presentation/presentation.h"

namespace fotufilm {

// Released surfaces kept for reuse, matched by size and format.
class SurfacePool {
 public:
  // Two slots of developed and undeveloped frames, a few deep.
  static constexpr size_t kDefaultLimit = 8;

  explicit SurfacePool(size_t limit = kDefaultLimit) : state_(std::make_shared<State>(limit)) {}

  using Create = std::function<std::unique_ptr<PresentationSurface>(int, int, SurfaceFormat)>;
  // A surface of this size and format, reused when one is free, lent for writing
  // (BeginWriting). The last reference ends the writing and hands it back to the pool.
  std::shared_ptr<PresentationSurface> Acquire(int width, int height, SurfaceFormat format,
                                               const Create& create);
  size_t free_count() const;

 private:
  struct State {
    explicit State(size_t limit) : limit(limit) {}
    const size_t limit;
    mutable std::mutex mutex;
    std::vector<std::unique_ptr<PresentationSurface>> free;
  };
  std::shared_ptr<State> state_;
};

class PooledPresenter : public ImagePresenter {
 public:
  // Runs a task on the UI thread.
  using Post = std::function<void(std::function<void()>)>;
  // Receives each presented frame on the UI thread.
  using Sink = std::function<void(const std::string& layer, PresentedFrame frame)>;

  PooledPresenter(Post post, Sink show) : post_(std::move(post)), show_(std::move(show)) {}

  std::shared_ptr<PresentationSurface> Acquire(int width, int height,
                                               SurfaceFormat format) override;
  uint64_t Present(const std::string& layer, PresentedFrame frame) override;
  float Headroom() override { return headroom_.load(); }

  // The window's screen's EDR headroom, set on the UI thread when the screen changes.
  void SetHeadroom(float headroom) { headroom_.store(headroom); }

 protected:
  // A new surface, or null when the platform cannot make one.
  virtual std::unique_ptr<PresentationSurface> CreateSurface(int width, int height,
                                                             SurfaceFormat format) = 0;

 private:
  Post post_;
  Sink show_;
  SurfacePool pool_;
  std::atomic<uint64_t> next_id_{0};
  std::atomic<float> headroom_{1.f};
};

}  // namespace fotufilm
