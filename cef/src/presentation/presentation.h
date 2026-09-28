// Native presentation: the engine develops the editor's photograph into surfaces the host lends,
// and the host's compositor draws them beneath the page, which leaves the photograph's area
// transparent. No picture crosses to the page, is encoded or is decoded on its way to the screen.
//
// These interfaces are the platform-neutral half. A platform supplies the memory (an IOSurface on
// macOS, a D3D11 shared texture's upload buffer on Windows, a dmabuf on Linux) by implementing
// PresentationSurface and ImagePresenter, and draws what ImageLayer (image_layer.h) chooses.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace fotufilm {

// FOTUFILM_SURFACE_* in fotufilm.h.
enum class SurfaceFormat : int32_t {
  // Display P3 with the sRGB transfer, 8 bits a channel, RGBA.
  kRgba8DisplayP3 = 0,
  // Extended-linear Display P3, half floats, RGBA: 1 is SDR white, above it EDR headroom.
  kRgba16FloatExtendedLinearP3 = 1,
};

inline size_t BytesPerPixel(SurfaceFormat format) {
  return format == SurfaceFormat::kRgba8DisplayP3 ? 4 : 8;
}

// One picture's memory. The engine writes it through `pixels` between the presenter's Acquire and
// Present; the compositor reads it after. The last reference returns it to its platform's pool.
class PresentationSurface {
 public:
  virtual ~PresentationSurface() = default;
  virtual int width() const = 0;
  virtual int height() const = 0;
  virtual SurfaceFormat format() const = 0;
  // CPU-writable while acquired.
  virtual void* pixels() = 0;
  virtual size_t row_bytes() const = 0;
  // The platform's shareable handle (IOSurfaceRef, HANDLE, dmabuf fd), for GPU writers.
  virtual void* native_handle() = 0;
  // Called once the engine has written it, before the compositor may read it.
  virtual void EndWriting() {}
};

// A written surface on its way to the screen.
struct PresentedFrame {
  uint64_t id = 0;
  std::shared_ptr<PresentationSurface> surface;
  // What the page shows it as (the photograph and its tool): a newer frame of the same size and
  // scope may replace a placed one before the page has placed it.
  std::string scope;
  // Extended range: values above 1 are light above SDR white.
  bool extended = false;
  // A frame of a moving picture: it replaces the one before at once rather than fading in.
  bool motion = false;
};

// What a platform's compositor offers the engine. Acquire, Present and Headroom are called on the
// engine thread; Present hands the frame to the compositor's own thread.
class ImagePresenter {
 public:
  virtual ~ImagePresenter() = default;
  virtual std::shared_ptr<PresentationSurface> Acquire(int width, int height,
                                                       SurfaceFormat format) = 0;
  // Shows `frame` in `layer` ("preview", "preview.original", "detail", …); returns its id.
  virtual uint64_t Present(const std::string& layer, PresentedFrame frame) = 0;
  // How far above SDR white the display showing the image can go; 1 without EDR.
  virtual float Headroom() = 0;
};

}  // namespace fotufilm
