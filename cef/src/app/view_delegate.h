// What the off-screen browser needs from the platform window that shows it. The window owns the
// compositor: the browser's frames arrive here as textures and are drawn over the engine's image.
#pragma once

#include <string>

#include "include/cef_render_handler.h"

namespace fotufilm {

class ViewDelegate {
 public:
  virtual ~ViewDelegate() = default;

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
  // A key the page did not consume, to be offered to the menu bar. Off-screen browsers do not
  // return the system event, so the window matches it to the key it last sent.
  virtual bool UnhandledKey(const CefKeyEvent& event) = 0;
  virtual void SetTitle(const std::string& title) = 0;
  virtual void BrowserClosed() = 0;
};

}  // namespace fotufilm
