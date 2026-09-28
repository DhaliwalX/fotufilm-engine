#include "app/browser_app.h"

#include "app/scheme.h"
#include "renderer/renderer_bridge.h"
#include "switches.h"

namespace fotufilm {

BrowserApp::BrowserApp(Options options, std::function<void()> on_ready)
    : options_(std::move(options)), on_ready_(std::move(on_ready)) {}

void BrowserApp::OnRegisterCustomSchemes(
    CefRawPtr<CefSchemeRegistrar> registrar) {
  RegisterCustomSchemes(registrar);
}

void BrowserApp::OnBeforeCommandLineProcessing(
    const CefString& process_type,
    CefRefPtr<CefCommandLine> command_line) {
  if (!process_type.empty()) return;
  // The editor paints its own UI; none of Chromium's first-run, sync or media-routing services
  // are wanted, and each costs start-up time.
  command_line->AppendSwitch("disable-extensions");
  command_line->AppendSwitch("no-first-run");
  command_line->AppendSwitch("disable-sync");
  command_line->AppendSwitchWithValue("disable-features",
                                      "MediaRouter,Translate");
#if defined(__APPLE__)
  // Chromium keeps its cookie key in the login keychain. The editor stores nothing secret in
  // cookies, and a keychain that is locked, or a prompt nobody answers, stalls every request.
  command_line->AppendSwitch("use-mock-keychain");
#endif
}

void BrowserApp::OnContextInitialized() {
  RegisterAppSchemeHandler(options_.web_root);
  if (on_ready_) on_ready_();
}

void BrowserApp::OnBeforeChildProcessLaunch(
    CefRefPtr<CefCommandLine> command_line) {
  if (!options_.dev_origin.empty())
    command_line->AppendSwitchWithValue(switches::kDevOrigin,
                                        options_.dev_origin);
  command_line->AppendSwitchWithValue(switches::kTransportGlobal,
                                      options_.transport_global);
  if (!options_.capabilities.empty())
    command_line->AppendSwitchWithValue(switches::kCapabilities,
                                        options_.capabilities);
}

ChildApp::ChildApp() : renderer_(new RendererBridge()) {}

void ChildApp::OnRegisterCustomSchemes(
    CefRawPtr<CefSchemeRegistrar> registrar) {
  RegisterCustomSchemes(registrar);
}

}  // namespace fotufilm
