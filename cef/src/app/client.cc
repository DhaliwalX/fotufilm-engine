#include "app/client.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <set>

#include "include/wrapper/cef_helpers.h"

namespace fotufilm {

Client::Client(Dispatcher* dispatcher, ViewDelegate* view)
    : dispatcher_(dispatcher), off_screen_(true), view_(view), window_(view) {}

Client::Client(Dispatcher* dispatcher, WindowDelegate* window)
    : dispatcher_(dispatcher), off_screen_(false), view_(nullptr), window_(window) {}

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
  if (window_) window_->BrowserClosed();
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
  if (window_) window_->SetTitle(title.ToString());
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
  return window_ && event.type == KEYEVENT_RAWKEYDOWN &&
         window_->UnhandledKey(event);
}

void Client::OnBeforeContextMenu(CefRefPtr<CefBrowser>,
                                 CefRefPtr<CefFrame>,
                                 CefRefPtr<CefContextMenuParams> params,
                                 CefRefPtr<CefMenuModel> model) {
  // Keep text editing (cut, copy, paste) in fields; drop Chromium's page menu (Back, Reload…).
  if (!(params->GetTypeFlags() & CM_TYPEFLAG_EDITABLE)) model->Clear();
}

bool Client::OnFileDialog(CefRefPtr<CefBrowser>,
                          FileDialogMode mode,
                          const CefString&,
                          const CefString&,
                          const std::vector<CefString>& accept_filters,
                          const std::vector<CefString>& accept_extensions,
                          const std::vector<CefString>&,
                          CefRefPtr<CefFileDialogCallback> callback) {
  // Only opening is the page's; saving and folders go through the host's own calls.
  if (!window_ || (mode != FILE_DIALOG_OPEN && mode != FILE_DIALOG_OPEN_MULTIPLE)) return false;
  // Every accepted type at once. CEF's own dialog offers each filter as a separate format and
  // starts on the first, so a page that accepts ".tif,.nef,…" greys out everything but TIFF.
  FileChoice choice;
  choice.multiple = mode == FILE_DIALOG_OPEN_MULTIPLE;
  std::set<std::string> extensions, mime_types;
  auto add_extension = [&](std::string extension) {
    extension.erase(0, extension.find_first_not_of(" ."));
    std::transform(extension.begin(), extension.end(), extension.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    if (!extension.empty()) extensions.insert(extension);
  };
  for (size_t index = 0; index < accept_filters.size(); ++index) {
    const std::string filter = accept_filters[index].ToString();
    if (filter.find('/') != std::string::npos) mime_types.insert(filter);
    else if (!filter.empty() && filter.find('|') == std::string::npos) add_extension(filter);
    // A MIME type's known extensions, or a "Description|.a;.b" filter's.
    std::string expansion = index < accept_extensions.size()
                                ? accept_extensions[index].ToString()
                                : std::string();
    if (const size_t bar = filter.find('|'); bar != std::string::npos && expansion.empty())
      expansion = filter.substr(bar + 1);
    for (size_t start = 0; start < expansion.size();) {
      const size_t end = std::min(expansion.find(';', start), expansion.size());
      add_extension(expansion.substr(start, end - start));
      start = end + 1;
    }
  }
  choice.extensions.assign(extensions.begin(), extensions.end());
  choice.mime_types.assign(mime_types.begin(), mime_types.end());
  return window_->ChooseFiles(choice, [callback](std::vector<std::string> paths) {
    if (paths.empty()) return callback->Cancel();
    callback->Continue(std::vector<CefString>(paths.begin(), paths.end()));
  });
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
