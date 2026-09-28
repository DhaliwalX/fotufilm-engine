// The editor in an ordinary window on CEF Views, painted by Chromium: the Linux host, and the
// Windows one to come. The page draws the photograph itself (no `imageLayer`); the window answers
// the page's window calls:
//
//   commandsReady   the editor listens; files opened before it did go to it now
//   openPanel       {kind}: the open panel (app/file_panels.h); the files arrive as a native open
//   menuState       what the editor's commands are doing; kept for the window's shortcuts
//   windowChrome    the toolbar's place, which a window with its own title bar does not need
//   echo, echoUi    the diagnostics page's round trips, on the engine and the UI thread
//
// Ctrl+Q and Ctrl+W close the window, F11 toggles full screen; the page handles every other key.
#pragma once

#include <string>
#include <vector>

#include "app/client.h"
#include "bridge/dispatcher.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"

namespace fotufilm {

class WindowedHost : public WindowDelegate {
 public:
  struct Options {
    std::string url;
    // The window's icon, a PNG; empty for none.
    std::string icon;
  };

  WindowedHost(Dispatcher& dispatcher, Options options);

  // UI thread, once CEF is running: opens the window, which ends the message loop when it closes.
  void Show();

  // Files for the editor to open (the command line, the open panel); held until it listens.
  void Open(const std::vector<std::string>& paths);

  CefRefPtr<CefBrowser> browser() const { return client_->browser(); }

  // WindowDelegate
  bool UnhandledKey(const CefKeyEvent& event) override;
  void SetTitle(const std::string& title) override;
  void BrowserClosed() override;

 private:
  void Register(Dispatcher& dispatcher);
  void Deliver();

  const Options options_;
  CefRefPtr<Client> client_;
  CefRefPtr<CefBrowserView> view_;
  CefRefPtr<CefWindow> window_;
  std::vector<std::string> pending_;
  bool listening_ = false;
};

}  // namespace fotufilm
