// What a window's compositor decides, whatever draws it: when to composite, what goes where, in
// which range, and what the latency probe and the stats have seen. The platform half (Metal on
// macOS; Vulkan or D3D elsewhere) owns the GPU, the drawable and the frame clock, and draws each
// CompositePlan in order:
//
//   1. the test pattern, if the diagnostics page asked for one;
//   2. the engine's frames, bottom first, clipped to `scissor`, each at its opacity;
//   3. the page, premultiplied sRGB, over everything.
//
// Colour: the drawable is Display P3. While a frame on show carries light above SDR white the
// plan asks for an extended-linear Display P3 drawable in half floats; otherwise 8-bit with the
// sRGB transfer. A quad whose source is in the other encoding is converted as it is drawn, and the
// page is converted from sRGB to Display P3 in the blend (see the Mac shaders for the reference).
//
// Pure C++ with no platform or CEF dependency, so every host shares it and its tests run anywhere
// (cef/tests/presentation_tests.cc). UI thread only.
#pragma once

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "presentation/image_layer.h"

namespace fotufilm {

struct CompositorStats {
  uint64_t frames = 0;
  uint64_t browser_frames = 0;
  uint64_t image_frames = 0;
  // The last UI copy's UI-thread time and GPU time, the last wait for a drawable, and the last
  // composite's encoding and submission, in µs.
  double last_copy_us = 0;
  double last_copy_gpu_us = 0;
  double last_drawable_wait_us = 0;
  double last_composite_us = 0;
  // Whether the browser's frames arrive as shared GPU textures rather than in memory.
  bool shared_textures = false;
  // Whether the drawable is extended range now.
  bool extended_range = false;
};

// One change the latency probe saw: when its composite was committed (ms, the host's clock) and
// the pixel's bytes in hex (BGRA8 or RGBA16F, as the drawable stores them).
struct ProbeChange {
  double time_ms = 0;
  std::string value;
};

// Normalised device coordinates: x from -1 (left) to 1, y from 1 (top) to -1.
struct DeviceRect {
  float x0 = 0, y0 = 0, x1 = 0, y1 = 0;
};

struct PixelRect {
  int x = 0, y = 0, width = 0, height = 0;
};

struct CompositeQuad {
  enum class Kind { kPattern, kImage, kPage };
  Kind kind = Kind::kImage;
  DeviceRect rect;
  // Extended-linear Display P3 rather than transfer-encoded (the page is always encoded).
  bool linear_source = false;
  // How much of the picture covers what is beneath it (a crossfade).
  float opacity = 1;
  // The engine's frame, for kImage; the GPU must hold it until it has read it.
  std::shared_ptr<PresentationSurface> surface;
};

struct CompositePlan {
  // The drawable's encoding: extended-linear Display P3 rather than 8-bit.
  bool extended = false;
  // The drawable in pixels.
  int width = 0, height = 0;
  // Seconds since the compositor started, which moves the test pattern.
  float time = 0;
  // Where the engine's frames may draw: the page's canvas, in drawable pixels.
  std::optional<PixelRect> scissor;
  std::vector<CompositeQuad> quads;
};

class CompositorCore {
 public:
  // How long a placement waits for the browser frame that carries the page's matching layout.
  static constexpr double kPlacementWaitSeconds = 0.05;

  // `start` is the host clock's time now, in seconds.
  explicit CompositorCore(double start = 0) : start_(start) {}

  // The view in points and its backing scale.
  void Resize(double width, double height, double scale);
  bool HasArea() const { return width_ >= 1 && height_ >= 1; }
  int pixel_width() const;
  int pixel_height() const;
  double scale() const { return scale_; }

  // A browser frame of `width` x `height` pixels has been copied for the next composite. The
  // placement waiting for it takes effect with it.
  void BrowserFrame(int width, int height, bool shared_texture, double copy_us);
  void BrowserCopyFinished(double gpu_us) { stats_.last_copy_gpu_us = gpu_us; }

  // A frame the engine presented (presentation/presentation.h).
  void Present(const std::string& layer, PresentedFrame frame);
  // Where the page shows the image layer now. It waits for the next browser frame, or until
  // PlacementDue says it has waited long enough for a layout change that repaints nothing.
  void Place(ImageLayerGeometry geometry, double now);
  bool PlacementDue(double now) const;
  void ApplyPlacement();
  // The moving test pattern in `rect` (view points); an empty rectangle removes it.
  void ShowTestPattern(LayerRect rect);
  bool showing_test_pattern() const { return !pattern_.Empty(); }

  // Arms the latency probe at a point of the view, in points; disarmed with none.
  void Probe(std::optional<std::pair<double, double>> point);
  bool probing() const { return probing_; }
  // The probed pixel in a drawable of the view's pixel size.
  std::pair<int, int> ProbePixel() const;
  // A probe composite's value, committed at `time_ms`: kept when it differs from the last.
  void RecordProbe(double time_ms, const std::string& value);
  const std::vector<ProbeChange>& probe_changes() const { return probe_changes_; }

  // Something changed: the platform composites at its next refresh. Answers whether it should
  // also run a probe composite now (once per change while probing; see ProbeStarted).
  bool Invalidate();
  void ProbeStarted() { probe_scheduled_ = false; }
  bool dirty() const { return dirty_; }
  // Draw every refresh, for content that moves on its own (the test pattern).
  bool continuous() const { return continuous_; }
  void set_continuous(bool continuous) { continuous_ = continuous; }
  // Whether the next refresh has anything to draw.
  bool NeedsComposite() const { return dirty_ || continuous_; }
  // At a refresh of the frame clock: applies a placement whose wait is over, and answers whether
  // the refresh has anything to draw. When it has not, the clock may sleep until SetNeedsDisplay.
  bool Refresh(double now);

  // One composite, in this order: Tick; WantsExtendedRange (a change of range takes effect with a
  // drawable made in the new format, so the one in hand is let go); ClearDirty; Plan for that
  // range; Composited once it is committed; and KeepDrawing, which says whether the next refresh
  // must draw again (a crossfade, or a movie's queued frame). Probe composites and snapshots only
  // Plan.
  void Tick() { image_layer_.Tick(); }
  bool WantsExtendedRange(double now);
  void SetExtendedRange(bool extended) { stats_.extended_range = extended; }
  void ClearDirty() { dirty_ = false; }
  CompositePlan Plan(double now, bool extended);
  void Composited(double drawable_wait_us, double composite_us);
  bool KeepDrawing(double now);

  const CompositorStats& stats() const { return stats_; }
  const ImageLayer& image_layer() const { return image_layer_; }

 private:
  DeviceRect ToDevice(const LayerRect& rect) const;

  double start_;
  double width_ = 0, height_ = 0, scale_ = 1;
  // The page's last frame, in pixels.
  int page_width_ = 0, page_height_ = 0;
  ImageLayer image_layer_;
  std::optional<ImageLayerGeometry> pending_placement_;
  double pending_since_ = 0;
  LayerRect pattern_;
  bool dirty_ = false;
  bool continuous_ = false;
  bool probing_ = false;
  bool probe_scheduled_ = false;
  double probe_x_ = 0, probe_y_ = 0;
  std::optional<std::string> probe_value_;
  std::vector<ProbeChange> probe_changes_;
  CompositorStats stats_;
};

}  // namespace fotufilm
