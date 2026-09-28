#include "app/windowed_host.h"

#include <fstream>
#include <iterator>

#include "app/file_panels.h"
#include "include/cef_app.h"
#include "include/cef_image.h"
#include "include/wrapper/cef_helpers.h"

namespace fotufilm {
namespace {

constexpr int kKeyQ = 0x51;
constexpr int kKeyW = 0x57;
constexpr int kKeyF11 = 0x7A;

// The editor's browser keeps the Alloy style, as the off-screen one on the Mac has: no Chrome
// toolbar, bubbles or page menus around the editor.
class BrowserViewDelegate : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_ALLOY; }
  IMPLEMENT_REFCOUNTING(BrowserViewDelegate);
};

class TopLevelDelegate : public CefWindowDelegate {
 public:
  TopLevelDelegate(CefRefPtr<CefBrowserView> view, std::string icon)
      : view_(view), icon_(std::move(icon)) {}

  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    window->AddChildView(view_);
    if (CefRefPtr<CefImage> image = Icon()) {
      window->SetWindowIcon(image);
      window->SetWindowAppIcon(image);
    }
    window->CenterWindow(CefSize(1440, 900));
    window->Show();
    view_->RequestFocus();
  }

  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    view_ = nullptr;
    CefQuitMessageLoop();
  }

  // The page may still be saving; the browser closes first and the window with it.
  bool CanClose(CefRefPtr<CefWindow>) override {
    CefRefPtr<CefBrowser> browser = view_ ? view_->GetBrowser() : nullptr;
    return !browser || browser->GetHost()->TryCloseBrowser();
  }

  CefSize GetPreferredSize(CefRefPtr<CefView>) override { return CefSize(1440, 900); }
  CefSize GetMinimumSize(CefRefPtr<CefView>) override { return CefSize(960, 600); }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_ALLOY; }

 private:
  CefRefPtr<CefImage> Icon() const {
    if (icon_.empty()) return nullptr;
    std::ifstream in(icon_, std::ios::binary);
    const std::string png((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (png.empty()) return nullptr;
    CefRefPtr<CefImage> image = CefImage::CreateImage();
    return image->AddPNG(1.0f, png.data(), png.size()) ? image : nullptr;
  }

  CefRefPtr<CefBrowserView> view_;
  const std::string icon_;
  IMPLEMENT_REFCOUNTING(TopLevelDelegate);
};

}  // namespace

WindowedHost::WindowedHost(Dispatcher& dispatcher, Options options)
    : options_(std::move(options)), client_(new Client(&dispatcher, this)) {
  Register(dispatcher);
}

void WindowedHost::Show() {
  CEF_REQUIRE_UI_THREAD();
  view_ = CefBrowserView::CreateBrowserView(client_, options_.url, CefBrowserSettings(), nullptr,
                                            nullptr, new BrowserViewDelegate());
  window_ = CefWindow::CreateTopLevelWindow(new TopLevelDelegate(view_, options_.icon));
}

void WindowedHost::Open(const std::vector<std::string>& paths) {
  pending_.insert(pending_.end(), paths.begin(), paths.end());
  Deliver();
}

void WindowedHost::Deliver() {
  CefRefPtr<CefBrowser> browser = client_->browser();
  if (!listening_ || pending_.empty() || !browser) return;
  CefRefPtr<CefListValue> paths = CefListValue::Create();
  for (const std::string& path : pending_) paths->SetString(paths->GetSize(), path);
  pending_.clear();
  CefRefPtr<CefDictionaryValue> detail = CefDictionaryValue::Create();
  detail->SetList("paths", paths);
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(detail);
  Dispatcher::Emit(browser->GetMainFrame(), "open", value);
  if (window_) window_->Activate();
}

bool WindowedHost::UnhandledKey(const CefKeyEvent& event) {
  const bool control = (event.modifiers & EVENTFLAG_CONTROL_DOWN) != 0;
  if (!window_) return false;
  if (control && (event.windows_key_code == kKeyQ || event.windows_key_code == kKeyW)) {
    window_->Close();
    return true;
  }
  if (event.windows_key_code == kKeyF11) {
    window_->SetFullscreen(!window_->IsFullscreen());
    return true;
  }
  return false;
}

void WindowedHost::SetTitle(const std::string& title) {
  if (window_) window_->SetTitle(title.empty() ? "Fotufilm" : title);
}

void WindowedHost::BrowserClosed() {
  if (window_) window_->Close();
  window_ = nullptr;
  view_ = nullptr;
}

void WindowedHost::Register(Dispatcher& dispatcher) {
  using Thread = Dispatcher::Thread;
  auto echo = [](const Call& call, std::shared_ptr<Reply> reply) {
    if (call.payload_length)
      reply->Resolve(call.params, call.payload, call.payload_length);
    else
      reply->Resolve(call.params);
  };
  dispatcher.Register("echo", Thread::kEngine, echo);
  dispatcher.Register("echoUi", Thread::kUi, echo);

  dispatcher.Register("commandsReady", Thread::kUi,
                      [this](const Call&, std::shared_ptr<Reply> reply) {
                        listening_ = true;
                        Deliver();
                        reply->Resolve(nullptr);
                      });
  // The page grey-outs and ticks are for a menu bar, which this window does not have.
  auto ignore = [](const Call&, std::shared_ptr<Reply> reply) { reply->Resolve(nullptr); };
  dispatcher.Register("menuState", Thread::kUi, ignore);
  dispatcher.Register("windowChrome", Thread::kUi, ignore);

  dispatcher.Register(
      "openPanel", Thread::kUi, [this](const Call& call, std::shared_ptr<Reply> reply) {
        std::string kind = "all";
        if (call.params && call.params->GetType() == VTYPE_DICTIONARY)
          kind = call.params->GetDictionary()->GetString("kind").ToString();
        ChooseFilesToOpen(browser(), kind, [this, reply](std::vector<std::string> paths) {
          CefRefPtr<CefValue> chosen = CefValue::Create();
          chosen->SetBool(!paths.empty());
          Open(paths);
          reply->Resolve(chosen);
        });
      });
}

}  // namespace fotufilm
