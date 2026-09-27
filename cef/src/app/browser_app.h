// The browser process's CefApp: registers the editor's scheme, hands renderers the switches they
// need, and asks the platform for a window once CEF is running.
#pragma once

#include <functional>
#include <string>

#include "include/cef_app.h"

namespace fotufilm {

class BrowserApp : public CefApp, public CefBrowserProcessHandler {
 public:
  struct Options {
    std::string web_root;          // The bundled web build, served as fotufilm://app/.
    std::string dev_origin;        // A trusted development server, or empty.
    std::string transport_global;  // The window property the transport is installed as.
  };

  BrowserApp(Options options, std::function<void()> on_ready);

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  void OnRegisterCustomSchemes(
      CefRawPtr<CefSchemeRegistrar> registrar) override;
  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override;
  void OnContextInitialized() override;
  void OnBeforeChildProcessLaunch(
      CefRefPtr<CefCommandLine> command_line) override;

 private:
  const Options options_;
  std::function<void()> on_ready_;
  IMPLEMENT_REFCOUNTING(BrowserApp);
};

// Every other process: renderers install the bridge; all of them know the scheme.
class ChildApp : public CefApp {
 public:
  ChildApp();
  void OnRegisterCustomSchemes(
      CefRawPtr<CefSchemeRegistrar> registrar) override;
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return renderer_;
  }

 private:
  CefRefPtr<CefRenderProcessHandler> renderer_;
  IMPLEMENT_REFCOUNTING(ChildApp);
};

}  // namespace fotufilm
