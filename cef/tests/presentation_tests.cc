// The portable presentation half on its own, with no CEF, GPU or window: what every platform's
// compositor decides and how presented surfaces are pooled. cef/tests/run.sh builds and runs it.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "presentation/compositor_core.h"
#include "presentation/pooled_presenter.h"

using namespace fotufilm;

namespace {

int failures = 0;

#define CHECK(condition)                                                     \
  do {                                                                       \
    if (!(condition)) {                                                      \
      std::fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #condition); \
      ++failures;                                                            \
    }                                                                        \
  } while (0)

bool Near(double a, double b) { return std::fabs(a - b) < 1e-5; }

class FakeSurface : public PresentationSurface {
 public:
  FakeSurface(int width, int height, SurfaceFormat format)
      : width_(width), height_(height), format_(format),
        pixels_(size_t(width) * height * BytesPerPixel(format)) {}
  int width() const override { return width_; }
  int height() const override { return height_; }
  SurfaceFormat format() const override { return format_; }
  void* pixels() override { return pixels_.data(); }
  size_t row_bytes() const override { return size_t(width_) * BytesPerPixel(format_); }
  void* native_handle() override { return this; }
  void BeginWriting() override { ++begun; }
  void EndWriting() override { ++ended; }
  int begun = 0, ended = 0;

 private:
  int width_, height_;
  SurfaceFormat format_;
  std::vector<uint8_t> pixels_;
};

std::shared_ptr<PresentationSurface> Surface(int width = 64, int height = 48) {
  return std::make_shared<FakeSurface>(width, height, SurfaceFormat::kRgba8DisplayP3);
}

PresentedFrame Frame(uint64_t id, std::shared_ptr<PresentationSurface> surface,
                     bool motion = false, bool extended = false) {
  PresentedFrame frame;
  frame.id = id;
  frame.surface = std::move(surface);
  frame.scope = "photo";
  frame.motion = motion;
  frame.extended = extended;
  return frame;
}

ImageLayerGeometry Placed(uint64_t frame, LayerRect rect = {10, 20, 64, 48},
                          LayerRect clip = {0, 0, 200, 100}) {
  ImageLayerGeometry geometry;
  geometry.clip = clip;
  geometry.layers.push_back({"preview", frame, 0, rect});
  return geometry;
}

std::vector<CompositeQuad> Images(const CompositePlan& plan) {
  std::vector<CompositeQuad> images;
  for (const auto& quad : plan.quads)
    if (quad.kind == CompositeQuad::Kind::kImage) images.push_back(quad);
  return images;
}

void SurfacePoolReuses() {
  SurfacePool pool(2);
  int created = 0;
  auto create = [&](int w, int h, SurfaceFormat f) {
    ++created;
    return std::make_unique<FakeSurface>(w, h, f);
  };
  PresentationSurface* first = nullptr;
  {
    auto surface = pool.Acquire(32, 16, SurfaceFormat::kRgba8DisplayP3, create);
    first = surface.get();
    CHECK(static_cast<FakeSurface*>(first)->begun == 1);
  }
  CHECK(pool.free_count() == 1);
  CHECK(static_cast<FakeSurface*>(first)->ended == 1);
  auto again = pool.Acquire(32, 16, SurfaceFormat::kRgba8DisplayP3, create);
  CHECK(again.get() == first);
  CHECK(created == 1);
  // Another size or format makes a new one.
  auto other = pool.Acquire(32, 16, SurfaceFormat::kRgba16FloatExtendedLinearP3, create);
  CHECK(other.get() != first);
  CHECK(created == 2);
  CHECK(!pool.Acquire(0, 16, SurfaceFormat::kRgba8DisplayP3, create));
  // Beyond the limit, released surfaces are freed rather than kept.
  auto a = pool.Acquire(8, 8, SurfaceFormat::kRgba8DisplayP3, create);
  again.reset();
  other.reset();
  a.reset();
  CHECK(pool.free_count() == 2);
}

class FakePresenter : public PooledPresenter {
 public:
  FakePresenter(std::deque<std::function<void()>>* queue, Sink show)
      : PooledPresenter([queue](std::function<void()> task) { queue->push_back(std::move(task)); },
                        std::move(show)) {}

 protected:
  std::unique_ptr<PresentationSurface> CreateSurface(int w, int h, SurfaceFormat f) override {
    return std::make_unique<FakeSurface>(w, h, f);
  }
};

void PresenterNumbersAndHandsOver() {
  std::deque<std::function<void()>> ui;
  std::vector<std::pair<std::string, uint64_t>> shown;
  FakePresenter presenter(&ui, [&](const std::string& layer, PresentedFrame frame) {
    shown.push_back({layer, frame.id});
  });
  auto surface = presenter.Acquire(16, 16, SurfaceFormat::kRgba8DisplayP3);
  auto* fake = static_cast<FakeSurface*>(surface.get());
  const uint64_t one = presenter.Present("preview", Frame(0, surface));
  const uint64_t two = presenter.Present("detail", Frame(0, presenter.Acquire(
      16, 16, SurfaceFormat::kRgba8DisplayP3)));
  CHECK(one == 1 && two == 2);
  CHECK(fake->ended == 1);
  // Nothing reaches the compositor until the UI thread runs.
  CHECK(shown.empty());
  while (!ui.empty()) {
    ui.front()();
    ui.pop_front();
  }
  CHECK(shown.size() == 2 && shown[0].first == "preview" && shown[1].second == 2);
  CHECK(presenter.Present("preview", PresentedFrame{}) == 0);
  CHECK(Near(presenter.Headroom(), 1));
  presenter.SetHeadroom(4);
  CHECK(Near(presenter.Headroom(), 4));
}

void PlacementWaitsForTheBrowserFrame() {
  CompositorCore core(100);
  core.Resize(200, 100, 2);
  core.Present("preview", Frame(1, Surface()));
  core.Place(Placed(1), 100);
  CHECK(Images(core.Plan(100, false)).empty());
  CHECK(!core.PlacementDue(100.01));
  CHECK(core.PlacementDue(100 + CompositorCore::kPlacementWaitSeconds + 1e-6));
  // The page's frame carries the layout: the placement takes effect with it.
  core.BrowserFrame(400, 200, true, 12);
  CHECK(!core.PlacementDue(200));
  CHECK(Images(core.Plan(100.1, false)).size() == 1);
  CHECK(core.stats().browser_frames == 1 && core.stats().shared_textures);
  // Or when the wait is over, at a refresh.
  core.Place(ImageLayerGeometry{}, 101);
  CHECK(core.Refresh(101.2));
  CHECK(Images(core.Plan(101.2, false)).empty());
}

void PanUnderAnUnchangedHolePlacesAtOnce() {
  CompositorCore core(100);
  core.Resize(200, 100, 2);
  core.Present("preview", Frame(1, Surface()));
  core.Place(Placed(1, {-50, -50, 400, 300}), 100);
  core.BrowserFrame(400, 200, true, 12);
  // Zoomed past the clip, the hole stays the clip: nothing on the page moves with the photo.
  core.Place(Placed(1, {-80, -60, 400, 300}), 100.01);
  CHECK(!core.PlacementDue(100.01));
  auto images = Images(core.Plan(100.01, false));
  CHECK(images.size() == 1 && Near(images[0].rect.x0, -1.8));
  // A photo smaller than the clip moves its hole, so it still waits for the page.
  core.Place(Placed(1, {10, 20, 64, 48}), 100.02);
  core.Place(Placed(1, {12, 20, 64, 48}), 100.03);
  CHECK(Near(Images(core.Plan(100.03, false))[0].rect.x0, -1.8));
  CHECK(core.PlacementDue(100.02 + CompositorCore::kPlacementWaitSeconds + 1e-6));
}


void PlanPlacesInDeviceAndPixelSpace() {
  CompositorCore core(0);
  core.Resize(200, 100, 2);
  core.ShowTestPattern({0, 0, 100, 50});
  core.Present("preview", Frame(1, Surface()));
  core.Place(Placed(1, {50, 25, 100, 50}, {-10, 10, 150, 200}), 0);
  core.BrowserFrame(300, 200, false, 0);
  const CompositePlan plan = core.Plan(2.5, false);
  CHECK(plan.width == 400 && plan.height == 200);
  CHECK(Near(plan.time, 2.5));
  CHECK(plan.quads.size() == 3);
  CHECK(plan.quads[0].kind == CompositeQuad::Kind::kPattern);
  CHECK(plan.quads[1].kind == CompositeQuad::Kind::kImage);
  CHECK(plan.quads[2].kind == CompositeQuad::Kind::kPage);
  const DeviceRect& image = plan.quads[1].rect;
  CHECK(Near(image.x0, -0.5) && Near(image.y0, 0.5) && Near(image.x1, 0.5) && Near(image.y1, -0.5));
  // The clip in pixels, cut to the drawable.
  CHECK(plan.scissor && plan.scissor->x == 0 && plan.scissor->y == 20 &&
        plan.scissor->width == 280 && plan.scissor->height == 180);
  // The page at its own pixel size from the top left: 300 x 200 pixels are 150 x 100 points.
  const DeviceRect& page = plan.quads[2].rect;
  CHECK(Near(page.x0, -1) && Near(page.y0, 1) && Near(page.x1, 0.5) && Near(page.y1, -1));
  core.ShowTestPattern({});
  CHECK(core.Plan(3, false).quads.size() == 2);
}

void ExtendedRangeFollowsTheFrames() {
  CompositorCore core(0);
  core.Resize(200, 100, 1);
  core.Present("preview", Frame(1, Surface(), false, true));
  core.Place(Placed(1), 0);
  core.BrowserFrame(200, 100, true, 0);
  CHECK(core.WantsExtendedRange(0));
  CHECK(Images(core.Plan(0, true))[0].linear_source);
  // The test pattern is drawn in SDR.
  core.ShowTestPattern({0, 0, 10, 10});
  CHECK(!core.WantsExtendedRange(0));
}

void ReplacedStillsCrossfade() {
  CompositorCore core(0);
  core.Resize(200, 100, 1);
  core.Present("preview", Frame(1, Surface()));
  core.Place(Placed(1), 0);
  core.BrowserFrame(200, 100, true, 0);
  CHECK(Images(core.Plan(0, false)).size() == 1);
  CHECK(!core.KeepDrawing(0));
  // An edit's newer frame of the same size and scope replaces the placed one at once, fading in.
  core.Present("preview", Frame(2, Surface()));
  auto images = Images(core.Plan(1, false));
  CHECK(images.size() == 2);
  CHECK(Near(images[0].opacity, 1) && images[1].opacity < 0.05f);
  CHECK(core.KeepDrawing(1.1));
  images = Images(core.Plan(1.1, false));
  CHECK(images.size() == 2 && images[1].opacity > 0.3f && images[1].opacity < 1);
  CHECK(Images(core.Plan(1 + ImageLayer::kCrossfadeSeconds + 1e-6, false)).size() == 1);
  CHECK(!core.KeepDrawing(1 + ImageLayer::kCrossfadeSeconds + 1e-6));
}

void MovieFramesAreShownInTurn() {
  CompositorCore core(0);
  core.Resize(200, 100, 1);
  core.Present("preview", Frame(1, Surface(), true));
  core.Place(Placed(1), 0);
  core.BrowserFrame(200, 100, true, 0);
  core.Tick();
  auto first = Images(core.Plan(0, false));
  CHECK(first.size() == 1);
  // Two frames land within one refresh: each composite moves on by one, and they cut in.
  auto two = Surface(), three = Surface();
  core.Present("preview", Frame(2, two, true));
  core.Present("preview", Frame(3, three, true));
  CHECK(core.KeepDrawing(0.01));
  core.Tick();
  auto shown = Images(core.Plan(0.016, false));
  CHECK(shown.size() == 1 && shown[0].surface == two && Near(shown[0].opacity, 1));
  CHECK(core.KeepDrawing(0.016));
  core.Tick();
  shown = Images(core.Plan(0.033, false));
  CHECK(shown.size() == 1 && shown[0].surface == three);
  CHECK(!core.KeepDrawing(0.033));
}

void ProbeRecordsChanges() {
  CompositorCore core(0);
  core.Resize(100, 50, 2);
  CHECK(!core.Invalidate());
  core.Probe(std::make_pair(30.0, 999.0));
  CHECK(core.probing());
  CHECK(core.ProbePixel() == std::make_pair(60, 99));
  // One probe composite per change until it has run.
  CHECK(core.Invalidate());
  CHECK(!core.Invalidate());
  core.ProbeStarted();
  CHECK(core.Invalidate());
  core.RecordProbe(1, "00000000");
  core.RecordProbe(2, "00000000");
  core.RecordProbe(3, "ff000000");
  CHECK(core.probe_changes().size() == 2 && Near(core.probe_changes()[1].time_ms, 3));
  core.Probe(std::nullopt);
  CHECK(!core.probing() && core.probe_changes().empty());
  core.RecordProbe(4, "00");
  CHECK(core.probe_changes().empty());
}

void RefreshSleepsWhenNothingChanged() {
  CompositorCore core(0);
  core.Resize(100, 50, 1);
  CHECK(!core.Refresh(0));
  core.Invalidate();
  CHECK(core.Refresh(0));
  core.ClearDirty();
  CHECK(!core.Refresh(0));
  core.set_continuous(true);
  CHECK(core.Refresh(0));
  core.Composited(3, 4);
  CHECK(core.stats().frames == 1 && Near(core.stats().last_composite_us, 4));
}

}  // namespace

int main() {
  SurfacePoolReuses();
  PresenterNumbersAndHandsOver();
  PlacementWaitsForTheBrowserFrame();
  PanUnderAnUnchangedHolePlacesAtOnce();
  PlanPlacesInDeviceAndPixelSpace();
  ExtendedRangeFollowsTheFrames();
  ReplacedStillsCrossfade();
  MovieFramesAreShownInTurn();
  ProbeRecordsChanges();
  RefreshSleepsWhenNothingChanged();
  if (failures) {
    std::fprintf(stderr, "%d presentation checks failed\n", failures);
    return 1;
  }
  std::printf("presentation checks passed\n");
  return 0;
}
