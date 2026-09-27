// The renderer half of the bridge: gives the editor page its transport and hands the browser's
// replies back to it.
//
// A frame can hold several script contexts (the page's own, and isolated worlds such as a
// debugger's), and each one that installs the transport gets its own listener. Calls are
// numbered renderer-wide, so a reply always returns to the context that asked.
#pragma once

#include <map>
#include <string>
#include <utility>

#include "include/cef_render_process_handler.h"

namespace fotufilm {

class RendererBridge : public CefRenderProcessHandler {
 public:
  // Reads the switches the browser passed, once the renderer's command line exists.
  void OnWebKitInitialized() override;
  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override;
  void OnContextReleased(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override;
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override;

  // For the page functions: register a context's listener, and number a call it sends.
  void Listen(int context, std::string frame, CefRefPtr<CefV8Context> v8,
              CefRefPtr<CefV8Value> listener);
  int Track(int context, int page_seq);

 private:
  struct Listener {
    std::string frame;
    CefRefPtr<CefV8Context> context;
    CefRefPtr<CefV8Value> function;
  };
  bool Trusted(const std::string& url) const;

  std::string dev_origin_;
  std::string global_name_;
  int next_context_ = 0;
  int next_seq_ = 0;
  std::map<int, Listener> listeners_;
  // Renderer-wide call number -> (context, the page's own number).
  std::map<int, std::pair<int, int>> calls_;

  IMPLEMENT_REFCOUNTING(RendererBridge);
};

}  // namespace fotufilm
