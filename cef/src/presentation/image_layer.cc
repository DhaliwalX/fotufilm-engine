#include "presentation/image_layer.h"

#include <algorithm>

namespace fotufilm {
namespace {

// JSON numbers arrive as integers when they are whole.
double Number(CefRefPtr<CefValue> value) {
  if (!value) return 0;
  switch (value->GetType()) {
    case VTYPE_INT: return value->GetInt();
    case VTYPE_DOUBLE: return value->GetDouble();
    default: return 0;
  }
}

double Field(CefRefPtr<CefDictionaryValue> fields, const char* key) {
  return fields && fields->HasKey(key) ? Number(fields->GetValue(key)) : 0;
}

LayerRect Rect(CefRefPtr<CefListValue> list) {
  if (!list || list->GetSize() != 4) return {};
  return {Number(list->GetValue(0)), Number(list->GetValue(1)), Number(list->GetValue(2)),
          Number(list->GetValue(3))};
}

// Frame ids travel as JSON numbers; ids stay far below 2^53.
uint64_t Id(CefRefPtr<CefDictionaryValue> fields, const char* key) {
  const double id = Field(fields, key);
  return id > 0 ? static_cast<uint64_t>(id) : 0;
}

// Frames of a layer kept beyond the ones the page names.
constexpr size_t kKeptFrames = 2;

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

ImageLayerGeometry ParseImageLayerGeometry(CefRefPtr<CefDictionaryValue> fields,
                                           LayerRect* pattern) {
  ImageLayerGeometry geometry;
  if (!fields) return geometry;
  if (!fields->HasKey("layers")) {
    if (pattern)
      *pattern = {Field(fields, "x"), Field(fields, "y"), Field(fields, "width"),
                  Field(fields, "height")};
    return geometry;
  }
  geometry.clip = Rect(fields->GetList("clip"));
  geometry.original = fields->GetString("source") == "original";
  if (CefRefPtr<CefListValue> layers = fields->GetList("layers")) {
    for (size_t index = 0; index < layers->GetSize(); ++index) {
      CefRefPtr<CefDictionaryValue> layer = layers->GetDictionary(index);
      if (!layer) continue;
      LayerPlacement placement;
      placement.slot = layer->GetString("slot").ToString();
      placement.frame = Id(layer, "frame");
      placement.original = Id(layer, "original");
      placement.rect = Rect(layer->GetList("rect"));
      if (!placement.slot.empty() && !placement.rect.Empty())
        geometry.layers.push_back(std::move(placement));
    }
  }
  return geometry;
}

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
  if (placed == frames.end()) return named < latest.id ? &latest : nullptr;
  if (latest.id > placed->id && latest.scope == placed->scope &&
      latest.surface->width() == placed->surface->width() &&
      latest.surface->height() == placed->surface->height())
    return &latest;
  return &*placed;
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
    Shown slot = found == shown_.end() ? Shown{draw} : found->second;
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
    std::deque<PresentedFrame> kept;
    for (size_t index = 0; index < frames.size(); ++index) {
      const bool recent = index + kKeptFrames >= frames.size();
      if (recent || (keep && frames[index].id == keep)) kept.push_back(frames[index]);
    }
    frames.swap(kept);
  }
}

}  // namespace fotufilm
