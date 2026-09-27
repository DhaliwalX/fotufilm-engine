// What the compositor draws beneath the page: the frames the engine presented, placed where the
// page last said the photograph is. Platform-neutral; every compositor keeps one and draws its
// Draws() in order, clipped to clip(). UI thread only.
#pragma once

#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "include/cef_values.h"
#include "presentation/presentation.h"

namespace fotufilm {

// View points (CSS pixels) from the top left of the page.
struct LayerRect {
  double x = 0, y = 0, width = 0, height = 0;
  bool Empty() const { return width <= 0 || height <= 0; }
};

// One picture the page places: a slot's developed frame and its undeveloped one.
struct LayerPlacement {
  std::string slot;
  uint64_t frame = 0;
  uint64_t original = 0;
  LayerRect rect;
};

// The page's `setImageLayer`: {clip: [x, y, w, h], source: "developed" | "original",
// layers: [{slot, frame, original, rect: [x, y, w, h]}]}, bottom layer first.
struct ImageLayerGeometry {
  LayerRect clip;
  bool original = false;
  std::vector<LayerPlacement> layers;
};

// Reads the page's geometry. The diagnostics page's older form, {x, y, width, height}, asks for
// the test pattern in that rectangle instead: `pattern` is set and the geometry left empty.
ImageLayerGeometry ParseImageLayerGeometry(CefRefPtr<CefDictionaryValue> fields,
                                           LayerRect* pattern);

class ImageLayer {
 public:
  struct Draw {
    std::shared_ptr<PresentationSurface> surface;
    LayerRect rect;
    bool extended = false;
  };

  // A frame the engine presented in `layer` ("preview", "preview.original", "detail", …).
  void Present(const std::string& layer, PresentedFrame frame);
  // Where the page shows the layers now.
  void Place(ImageLayerGeometry geometry);
  const ImageLayerGeometry& geometry() const { return geometry_; }

  // What to draw, bottom first. A slot shows the frame the page placed, or a newer one of the
  // same size and scope, so an edit reaches the screen without waiting for the page.
  std::vector<Draw> Draws() const;
  const LayerRect& clip() const { return geometry_.clip; }

 private:
  const PresentedFrame* Choose(const std::string& layer, uint64_t named) const;
  void Prune();

  ImageLayerGeometry geometry_;
  std::map<std::string, std::deque<PresentedFrame>> frames_;
};

}  // namespace fotufilm
