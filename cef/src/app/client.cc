#include "app/client.h"

#include <cstdio>

#include "include/wrapper/cef_helpers.h"

namespace fotufilm {

Client::Client(Dispatcher* dispatcher, ViewDelegate* view)
    : dispatcher_(dispatcher), view_(view) {}

bool Client::OnProcessMessageReceived(CefRefPtr<CefBrowser>,
                                      CefRefPtr<CefFrame> frame,
                                      CefProcessId,
                                      CefRefPtr<CefProcessMessage> message) {
  return dispatcher_->OnProcessMessage(frame, message);
}

bool Client::OnBeforePopup(CefRefPtr<CefBrowser>,
                           CefRefPtr<CefFrame>,
                           int,
                           const CefString&,
                           const CefString&,
                           WindowOpenDisposition,
                           bool,
                           const CefPopupFeatures&,
                           CefWindowInfo&,
                           CefRefPtr<CefClient>&,
                           CefBrowserSettings&,
                           CefRefPtr<CefDictionaryValue>&,
                           bool*) {
  // The editor opens no windows of its own.
  return true;
}

void Client::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  browser_ = browser;
}

void Client::OnBeforeClose(CefRefPtr<CefBrowser>) {
  CEF_REQUIRE_UI_THREAD();
  browser_ = nullptr;
  if (view_) view_->BrowserClosed();
}

void Client::GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) {
  // CEF needs a non-empty rectangle even before the window has a size.
  rect = view_ ? view_->ViewRect() : CefRect();
  if (rect.width <= 0 || rect.height <= 0) rect = CefRect(0, 0, 1, 1);
}

bool Client::GetScreenPoint(CefRefPtr<CefBrowser>,
                            int view_x,
                            int view_y,
                            int& screen_x,
                            int& screen_y) {
  if (!view_) return false;
  const CefPoint point = view_->ScreenPoint(CefPoint(view_x, view_y));
  screen_x = point.x;
  screen_y = point.y;
  return true;
}

bool Client::GetScreenInfo(CefRefPtr<CefBrowser> browser,
                           CefScreenInfo& screen_info) {
  if (!view_) return false;
  CefRect rect;
  GetViewRect(browser, rect);
  screen_info.device_scale_factor = view_->ScaleFactor();
  screen_info.rect = rect;
  screen_info.available_rect = rect;
  return true;
}

void Client::OnPaint(CefRefPtr<CefBrowser>,
                     PaintElementType type,
                     const RectList&,
                     const void* buffer,
                     int width,
                     int height) {
  // Popup widgets (native <select> lists) are not composited yet; the editor draws its own.
  if (view_ && type == PET_VIEW) view_->SoftwarePaint(buffer, width, height);
}

void Client::OnAcceleratedPaint(CefRefPtr<CefBrowser>,
                                PaintElementType type,
                                const RectList&,
                                const CefAcceleratedPaintInfo& info) {
  if (view_ && type == PET_VIEW) view_->AcceleratedPaint(info);
}

void Client::UpdateDragCursor(CefRefPtr<CefBrowser>, DragOperation operation) {
  if (view_) view_->UpdateDragOperation(operation);
}

void Client::OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) {
  if (view_) view_->SetTitle(title.ToString());
}

bool Client::OnCursorChange(CefRefPtr<CefBrowser>,
                            CefCursorHandle cursor,
                            cef_cursor_type_t type,
                            const CefCursorInfo&) {
  if (!view_) return false;
  view_->SetCursor(cursor, type);
  return true;
}

bool Client::OnConsoleMessage(CefRefPtr<CefBrowser>,
                              cef_log_severity_t level,
                              const CefString& message,
                              const CefString& source,
                              int line) {
  if (level >= LOGSEVERITY_WARNING)
    std::fprintf(stderr, "[page] %s (%s:%d)\n", message.ToString().c_str(),
                 source.ToString().c_str(), line);
  return false;
}

bool Client::OnKeyEvent(CefRefPtr<CefBrowser>,
                        const CefKeyEvent& event,
                        CefEventHandle) {
  // Keys reach the page first; what it leaves unhandled goes to the menu bar (Quit, Close…).
  return view_ && event.type == KEYEVENT_RAWKEYDOWN &&
         view_->UnhandledKey(event);
}

void Client::OnBeforeContextMenu(CefRefPtr<CefBrowser>,
                                 CefRefPtr<CefFrame>,
                                 CefRefPtr<CefContextMenuParams> params,
                                 CefRefPtr<CefMenuModel> model) {
  // Keep text editing (cut, copy, paste) in fields; drop Chromium's page menu (Back, Reload…).
  if (!(params->GetTypeFlags() & CM_TYPEFLAG_EDITABLE)) model->Clear();
}

void Client::OnLoadError(CefRefPtr<CefBrowser>,
                         CefRefPtr<CefFrame> frame,
                         ErrorCode error_code,
                         const CefString& error_text,
                         const CefString& failed_url) {
  if (error_code == ERR_ABORTED || !frame->IsMain()) return;
  std::fprintf(stderr, "Could not load %s: %s\n",
               failed_url.ToString().c_str(), error_text.ToString().c_str());
}

}  // namespace fotufilm
