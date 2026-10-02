#include "presentation/compositor_core.h"

#include <algorithm>
#include <cmath>

namespace fotufilm {

void CompositorCore::Resize(double width, double height, double scale) {
  width_ = width;
  height_ = height;
  scale_ = scale > 0 ? scale : 1;
}

int CompositorCore::pixel_width() const { return static_cast<int>(width_ * scale_); }
int CompositorCore::pixel_height() const { return static_cast<int>(height_ * scale_); }

void CompositorCore::BrowserFrame(int width, int height, bool shared_texture, double copy_us) {
  page_width_ = width;
  page_height_ = height;
  stats_.last_copy_us = copy_us;
  stats_.browser_frames++;
  stats_.shared_textures = shared_texture;
  ApplyPlacement();
}

void CompositorCore::Present(const std::string& layer, PresentedFrame frame) {
  image_layer_.Present(layer, std::move(frame));
  stats_.image_frames++;
  dirty_ = true;
}

namespace {

bool SameRect(const LayerRect& a, const LayerRect& b) {
  return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;
}

// The part of the clip the photograph covers: what the page cuts out of its backgrounds.
LayerRect Hole(const ImageLayerGeometry& geometry) {
  if (geometry.layers.empty()) return {};
  const LayerRect& photo = geometry.layers.front().rect;
  const LayerRect& clip = geometry.clip;
  const double x = std::max(photo.x, clip.x), y = std::max(photo.y, clip.y);
  const double right = std::min(photo.x + photo.width, clip.x + clip.width);
  const double bottom = std::min(photo.y + photo.height, clip.y + clip.height);
  if (right <= x || bottom <= y) return {};
  return {x, y, right - x, bottom - y};
}

LayerRect Origin(const ImageLayerGeometry& geometry) {
  return geometry.layers.empty() ? LayerRect{} : geometry.layers.front().rect;
}

}  // namespace

void CompositorCore::Place(ImageLayerGeometry geometry, double now) {
  const ImageLayerGeometry& shown = image_layer_.geometry();
  if (tracing_) {
    const LayerRect at = Origin(geometry);
    const int note = pending_placement_ ? 3 : !SameRect(geometry.clip, shown.clip) ? 1
                     : !SameRect(Hole(geometry), Hole(shown)) ? 2 : 0;
    traced_placements_.push_back({now * 1000, at.x, at.y, note});
  }
  if (!pending_placement_) {
    if (SameRect(geometry.clip, shown.clip) && SameRect(Hole(geometry), Hole(shown))) {
      image_layer_.Place(std::move(geometry));
      dirty_ = true;
      return;
    }
    pending_since_ = now;
  }
  // A newer placement replaces one still waiting, and waits no longer than it would have.
  pending_placement_ = std::move(geometry);
}

bool CompositorCore::PlacementDue(double now) const {
  return pending_placement_ && now - pending_since_ >= kPlacementWaitSeconds;
}

void CompositorCore::ApplyPlacement() {
  if (pending_placement_) {
    image_layer_.Place(std::move(*pending_placement_));
    pending_placement_.reset();
  }
  dirty_ = true;
}

void CompositorCore::ShowTestPattern(LayerRect rect) {
  pattern_ = rect.Empty() ? LayerRect{} : rect;
  dirty_ = true;
}

void CompositorCore::Probe(std::optional<std::pair<double, double>> point) {
  probing_ = point && !std::isnan(point->first) && !std::isnan(point->second);
  if (probing_) {
    probe_x_ = point->first;
    probe_y_ = point->second;
  }
  probe_value_.reset();
  probe_changes_.clear();
}

std::pair<int, int> CompositorCore::ProbePixel() const {
  const int width = std::max(pixel_width(), 1), height = std::max(pixel_height(), 1);
  const int x = std::min(width - 1, static_cast<int>(std::max(0.0, probe_x_ * scale_)));
  const int y = std::min(height - 1, static_cast<int>(std::max(0.0, probe_y_ * scale_)));
  return {x, y};
}

void CompositorCore::RecordProbe(double time_ms, const std::string& value) {
  if (!probing_) return;
  // The first value is recorded too: it is what the changes are measured against.
  if (probe_value_ != value) probe_changes_.push_back({time_ms, value});
  probe_value_ = value;
}

bool CompositorCore::Invalidate() {
  dirty_ = true;
  if (!probing_ || probe_scheduled_) return false;
  probe_scheduled_ = true;
  return true;
}

bool CompositorCore::Refresh(double now) {
  if (PlacementDue(now)) ApplyPlacement();
  return NeedsComposite();
}

bool CompositorCore::WantsExtendedRange(double now) {
  if (showing_test_pattern()) return false;
  for (const auto& draw : image_layer_.Draws(now))
    if (draw.extended) return true;
  return false;
}

DeviceRect CompositorCore::ToDevice(const LayerRect& rect) const {
  const double width = std::max(width_, 1.0), height = std::max(height_, 1.0);
  return {static_cast<float>(rect.x / width * 2 - 1), static_cast<float>(1 - rect.y / height * 2),
          static_cast<float>((rect.x + rect.width) / width * 2 - 1),
          static_cast<float>(1 - (rect.y + rect.height) / height * 2)};
}

CompositePlan CompositorCore::Plan(double now, bool extended) {
  CompositePlan plan;
  plan.extended = extended;
  plan.width = pixel_width();
  plan.height = pixel_height();
  plan.time = static_cast<float>(now - start_);
  if (showing_test_pattern()) {
    CompositeQuad quad;
    quad.kind = CompositeQuad::Kind::kPattern;
    quad.rect = ToDevice(pattern_);
    plan.quads.push_back(quad);
  }

  // The engine's frames, clipped to the page's canvas.
  const auto draws = image_layer_.Draws(now);
  const LayerRect& clip = image_layer_.clip();
  const double left = std::max(0.0, clip.x * scale_), top = std::max(0.0, clip.y * scale_);
  const double right = std::min(double(plan.width), (clip.x + clip.width) * scale_);
  const double bottom = std::min(double(plan.height), (clip.y + clip.height) * scale_);
  if (!draws.empty() && !clip.Empty() && right > left && bottom > top) {
    plan.scissor = PixelRect{static_cast<int>(left), static_cast<int>(top),
                             static_cast<int>(right - left), static_cast<int>(bottom - top)};
    for (const auto& draw : draws) {
      CompositeQuad quad;
      quad.kind = CompositeQuad::Kind::kImage;
      quad.rect = ToDevice(draw.rect);
      quad.linear_source = draw.extended;
      quad.opacity = draw.opacity;
      quad.surface = draw.surface;
      plan.quads.push_back(std::move(quad));
    }
  }

  if (page_width_ > 0 && page_height_ > 0) {
    // The page's frame at its own pixel size from the top left, so a resize in flight shows an
    // edge rather than a stretched UI.
    CompositeQuad quad;
    quad.kind = CompositeQuad::Kind::kPage;
    quad.rect = ToDevice({0, 0, page_width_ / scale_, page_height_ / scale_});
    plan.quads.push_back(quad);
  }
  return plan;
}

void CompositorCore::TraceComposites(bool on) {
  tracing_ = on;
  traced_composites_.clear();
  traced_placements_.clear();
}

void CompositorCore::TraceComposite(double now) {
  if (!tracing_) return;
  const LayerRect at = Origin(image_layer_.geometry());
  traced_composites_.push_back({now * 1000, at.x, at.y});
}

void CompositorCore::Composited(double drawable_wait_us, double composite_us) {
  stats_.frames++;
  stats_.last_drawable_wait_us = drawable_wait_us;
  stats_.last_composite_us = composite_us;
}

bool CompositorCore::KeepDrawing(double now) {
  const bool more = image_layer_.Fading(now) || image_layer_.Pending();
  if (more) dirty_ = true;
  return more;
}

}  // namespace fotufilm
