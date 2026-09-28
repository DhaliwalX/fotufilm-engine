#include "presentation/image_layer.h"

#include <algorithm>

namespace fotufilm {
namespace {

// Frames of a layer kept beyond the ones the page names: enough for a playing movie's queue.
constexpr size_t kKeptFrames = 4;

// Whether `a` would sit where `b` does: the same photograph and tool at the same size.
bool SamePlace(const PresentedFrame& a, const PresentedFrame& b) {
  return a.scope == b.scope && a.surface->width() == b.surface->width() &&
         a.surface->height() == b.surface->height();
}

// CSS cubic-bezier(0.25, 0.1, 0.25, 1), the Mac app's `Motion.smooth`: progress at time `t`.
double Smooth(double t) {
  if (t <= 0) return 0;
  if (t >= 1) return 1;
  constexpr double x1 = 0.25, y1 = 0.1, x2 = 0.25, y2 = 1;
  auto bezier = [](double a, double b, double s) {
    return 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s;
  };
  double low = 0, high = 1, s = t;
  for (int step = 0; step < 32; ++step) {
    s = (low + high) / 2;
    (bezier(x1, x2, s) < t ? low : high) = s;
  }
  return bezier(y1, y2, s);
}

}  // namespace

void ImageLayer::Present(const std::string& layer, PresentedFrame frame) {
  if (!frame.surface) return;
  frames_[layer].push_back(std::move(frame));
  Prune();
}

void ImageLayer::Place(ImageLayerGeometry geometry) {
  geometry_ = std::move(geometry);
  Prune();
}

const PresentedFrame* ImageLayer::Choose(const std::string& layer, uint64_t named) const {
  auto found = frames_.find(layer);
  if (found == frames_.end() || found->second.empty()) return nullptr;
  const auto& frames = found->second;
  const PresentedFrame& latest = frames.back();
  auto placed = std::find_if(frames.begin(), frames.end(),
                             [named](const PresentedFrame& f) { return f.id == named; });
  // A frame the page has not seen yet stands in for the one it placed when it would sit in the
  // same place: the same size, the same photograph and tool.
  const PresentedFrame* chosen = nullptr;
  if (placed == frames.end()) chosen = named < latest.id ? &latest : nullptr;
  else chosen = latest.id > placed->id && SamePlace(latest, *placed) ? &latest : &*placed;
  // A playing movie shows its frames in turn, at the pace `Tick` sets.
  auto paced = paced_.find(layer);
  if (chosen && chosen->motion && paced != paced_.end()) {
    for (const PresentedFrame& frame : frames)
      if (frame.id == paced->second && frame.id <= chosen->id && SamePlace(frame, *chosen))
        return &frame;
  }
  return chosen;
}

// Frames of a playing movie waiting behind `shown` in `frames`, oldest first.
static std::vector<const PresentedFrame*> Waiting(const std::deque<PresentedFrame>& frames,
                                                  uint64_t shown) {
  std::vector<const PresentedFrame*> waiting;
  const PresentedFrame& latest = frames.back();
  for (const PresentedFrame& frame : frames)
    if (frame.motion && frame.id > shown && SamePlace(frame, latest)) waiting.push_back(&frame);
  return waiting;
}

void ImageLayer::Tick() {
  for (const auto& [layer, frames] : frames_) {
    if (frames.empty() || !frames.back().motion) {
      paced_.erase(layer);
      continue;
    }
    auto paced = paced_.find(layer);
    const bool showing = paced != paced_.end() &&
        std::any_of(frames.begin(), frames.end(),
                    [&](const PresentedFrame& f) { return f.id == paced->second; });
    if (!showing) {
      paced_[layer] = frames.back().id;
      continue;
    }
    // One new frame a composite, so two that arrive within one refresh are both seen; a queue
    // that has grown past one waiting frame is let go to its last but one, bounding the delay.
    const auto waiting = Waiting(frames, paced->second);
    if (!waiting.empty())
      paced->second = waiting[waiting.size() >= 3 ? waiting.size() - 2 : 0]->id;
  }
}

bool ImageLayer::Pending() const {
  for (const auto& [layer, shown] : paced_) {
    auto frames = frames_.find(layer);
    if (frames != frames_.end() && !frames->second.empty() &&
        !Waiting(frames->second, shown).empty())
      return true;
  }
  return false;
}

std::vector<ImageLayer::Draw> ImageLayer::Draws(double now) {
  std::vector<Draw> draws;
  std::map<std::string, Shown> shown;
  for (const LayerPlacement& placement : geometry_.layers) {
    const bool original = geometry_.original;
    const PresentedFrame* frame =
        Choose(original ? placement.slot + ".original" : placement.slot,
               original ? placement.original : placement.frame);
    if (!frame) continue;
    Draw draw{frame->surface, placement.rect, frame->extended};
    auto found = shown_.find(placement.slot);
    Shown slot = found == shown_.end() ? Shown{draw, {}, -1} : found->second;
    // A new picture where one was showing fades in over it; the first one simply appears, and
    // a movie's next frame cuts in.
    if (slot.current.surface != draw.surface) {
      slot.previous = frame->motion ? Draw{} : slot.current;
      slot.since = frame->motion ? -1 : now;
    }
    slot.current = draw;
    const double progress = slot.since < 0 ? 1 : (now - slot.since) / kCrossfadeSeconds;
    if (progress < 1 && slot.previous.surface) {
      draws.push_back(slot.previous);
      draw.opacity = static_cast<float>(Smooth(progress));
    } else {
      slot.previous = {};
      slot.since = -1;
    }
    draws.push_back(draw);
    shown[placement.slot] = std::move(slot);
  }
  // A slot the page no longer places lets its pictures go.
  shown_.swap(shown);
  return draws;
}

bool ImageLayer::Fading(double now) const {
  for (const auto& [slot, shown] : shown_)
    if (shown.previous.surface && now - shown.since < kCrossfadeSeconds) return true;
  return false;
}

// Keeps what the page names, anything newer, and the last few of every layer; the rest go back
// to their pool once the GPU has finished reading them.
void ImageLayer::Prune() {
  std::map<std::string, uint64_t> named;
  for (const LayerPlacement& placement : geometry_.layers) {
    named[placement.slot] = placement.frame;
    named[placement.slot + ".original"] = placement.original;
  }
  for (auto& [layer, frames] : frames_) {
    auto found = named.find(layer);
    const uint64_t keep = found == named.end() ? 0 : found->second;
    auto paced = paced_.find(layer);
    const uint64_t showing = paced == paced_.end() ? 0 : paced->second;
    std::deque<PresentedFrame> kept;
    for (size_t index = 0; index < frames.size(); ++index) {
      const bool recent = index + kKeptFrames >= frames.size();
      const uint64_t id = frames[index].id;
      if (recent || (keep && id == keep) || (showing && id == showing))
        kept.push_back(frames[index]);
    }
    frames.swap(kept);
  }
}

}  // namespace fotufilm
