// The page's calls about what the window shows, answered the same way on every platform:
//
//   setImageLayer        where the page shows the engine's image layer (web/src/backend/macos),
//                        or the diagnostics page's test pattern
//   compositorStats      frame counts and the last composite's costs
//   compositorSnapshot   what the screen shows, page and image together, as a temporary file
//   probePixel           arms the latency probe at a point of the window ({} stops it)
//   probeReport          the changes seen there and the host's clock, in milliseconds
//
// A platform window implements WindowCompositor around its CompositorCore and registers these
// with its dispatcher.
#pragma once

#include <functional>
#include <memory>
#include <string>

#include "bridge/dispatcher.h"
#include "presentation/compositor_core.h"

namespace fotufilm {

// What a platform's compositor offers the portable half. UI thread only.
class WindowCompositor {
 public:
  virtual ~WindowCompositor() = default;
  virtual CompositorCore& core() = 0;
  // Composites at the next refresh; runs a probe composite at once when core().Invalidate()
  // asks for one.
  virtual void SetNeedsDisplay() = 0;
  // Runs `task` on the UI thread after `seconds`.
  virtual void RunAfter(double seconds, std::function<void()> task) = 0;
  // The host's clock in seconds: fades, placement waits and probe times are measured on it.
  virtual double Now() = 0;
  // Composites what the next refresh would show into a temporary file and hands back its path,
  // or an empty string. 8-bit Display P3 PNG, or half-float extended-linear TIFF when extended.
  virtual void Snapshot(std::function<void(const std::string& path)> done) = 0;
  // How far above SDR white the window's display can go now; 1 without EDR.
  virtual float Headroom() = 0;
};

// Where the page shows the image layer now. It takes effect with the next browser frame, which
// carries the page's matching layout, or once CompositorCore::kPlacementWaitSeconds have passed
// for a layout change that repaints nothing.
void PlaceImageLayer(const std::shared_ptr<WindowCompositor>& compositor,
                     ImageLayerGeometry geometry);

// Reads the page's setImageLayer. The diagnostics page's older form, {x, y, width, height}, asks
// for the test pattern in that rectangle instead: `pattern` is set and the geometry left empty.
ImageLayerGeometry ParseImageLayerGeometry(CefRefPtr<CefDictionaryValue> fields,
                                           LayerRect* pattern);

// Registers the calls above. `window` answers the compositor of the window the page is in, or
// null once it has gone.
void RegisterPresentationMethods(Dispatcher& dispatcher,
                                 std::function<std::shared_ptr<WindowCompositor>()> window);

}  // namespace fotufilm
