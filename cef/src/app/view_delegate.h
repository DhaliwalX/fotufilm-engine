// What the browser needs from the platform window that shows it. An off-screen browser's window
// (ViewDelegate) owns the compositor: the browser's frames arrive there as textures and are drawn
// over the engine's image. Off-screen browsers do not return the system event for a key, so that
// window matches an unhandled key to the one it last sent.
#pragma once

#include <string>

#include "include/cef_render_handler.h"

namespace fotufilm {

// What any window that shows the browser handles, whether Chromium paints into it (Linux and
// Windows, windowed) or the window composites the browser's frames itself (ViewDelegate).
class WindowDelegate {
 public:
  virtual ~WindowDelegate() = default;
  // A key the page did not consume, to be offered to the window's shortcuts or menu bar.
  virtual bool UnhandledKey(const CefKeyEvent& event) = 0;
  virtual void SetTitle(const std::string& title) = 0;
  virtual void BrowserClosed() = 0;
};

class ViewDelegate : public WindowDelegate {
 public:

  // The view in device-independent pixels, and its backing scale.
  virtual CefRect ViewRect() = 0;
  virtual float ScaleFactor() = 0;
  virtual CefPoint ScreenPoint(const CefPoint& view_point) = 0;

  // A browser frame shared as a GPU texture, valid only during the call.
  virtual void AcceleratedPaint(const CefAcceleratedPaintInfo& info) = 0;
  // A browser frame in memory: BGRA, premultiplied, top row first. Used when shared textures are
  // unavailable.
  virtual void SoftwarePaint(const void* pixels, int width, int height) = 0;

  virtual void SetCursor(CefCursorHandle cursor, cef_cursor_type_t type) = 0;
  // What the page would do with the files being dragged over it (none, copy, link…), for the
  // platform's drag cursor and to know whether a drop was taken.
  virtual void UpdateDragOperation(cef_drag_operations_mask_t operation) = 0;
};

}  // namespace fotufilm
