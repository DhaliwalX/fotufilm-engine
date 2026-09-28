#include "presentation/pooled_presenter.h"

#include <algorithm>

namespace fotufilm {

std::shared_ptr<PresentationSurface> SurfacePool::Acquire(int width, int height,
                                                          SurfaceFormat format,
                                                          const Create& create) {
  if (width <= 0 || height <= 0) return nullptr;
  std::unique_ptr<PresentationSurface> surface;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    auto& free = state_->free;
    auto match = std::find_if(free.begin(), free.end(), [&](const auto& s) {
      return s->width() == width && s->height() == height && s->format() == format;
    });
    if (match != free.end()) {
      surface = std::move(*match);
      free.erase(match);
    }
  }
  if (!surface) surface = create(width, height, format);
  if (!surface) return nullptr;
  surface->BeginWriting();
  // The last reference, the compositor's once the GPU has read the frame, hands it back.
  std::weak_ptr<State> pool = state_;
  return std::shared_ptr<PresentationSurface>(
      surface.release(), [pool](PresentationSurface* done) {
        std::unique_ptr<PresentationSurface> owned(done);
        owned->EndWriting();
        if (auto shared = pool.lock()) {
          std::lock_guard<std::mutex> lock(shared->mutex);
          if (shared->free.size() < shared->limit) shared->free.push_back(std::move(owned));
        }
      });
}

size_t SurfacePool::free_count() const {
  std::lock_guard<std::mutex> lock(state_->mutex);
  return state_->free.size();
}

std::shared_ptr<PresentationSurface> PooledPresenter::Acquire(int width, int height,
                                                              SurfaceFormat format) {
  return pool_.Acquire(width, height, format, [this](int w, int h, SurfaceFormat f) {
    return CreateSurface(w, h, f);
  });
}

uint64_t PooledPresenter::Present(const std::string& layer, PresentedFrame frame) {
  if (!frame.surface) return 0;
  frame.surface->EndWriting();
  frame.id = ++next_id_;
  const uint64_t id = frame.id;
  auto shared = std::make_shared<PresentedFrame>(std::move(frame));
  post_([show = show_, layer, shared] { show(layer, std::move(*shared)); });
  return id;
}

}  // namespace fotufilm
