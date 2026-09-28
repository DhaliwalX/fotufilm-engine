// The browser half of the bridge: routes each call from the editor to its native handler and
// sends the answer back.
//
// Handlers marked kUi run on the CEF UI thread and must return quickly (window state, layout).
// kEngine handlers run in order on one engine thread, off the UI thread, so a render never delays
// input or painting. Replies may be sent from any thread.
#pragma once

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "include/cef_frame.h"
#include "include/cef_process_message.h"
#include "include/cef_values.h"

namespace fotufilm {

struct Call {
  int seq = 0;
  std::string id;
  std::string method;
  CefRefPtr<CefValue> params;
  // Bytes sent beside the message. They point into the shared region the call holds, valid for as
  // long as the Call is.
  const uint8_t* payload = nullptr;
  size_t payload_length = 0;
  CefRefPtr<CefSharedMemoryRegion> region;
  // Set by a "cancel" call with the same id.
  std::shared_ptr<std::atomic<bool>> cancelled =
      std::make_shared<std::atomic<bool>>(false);
};

// Answers one call exactly once; later answers are ignored.
class Reply {
 public:
  Reply(CefRefPtr<CefFrame> frame, int seq) : frame_(frame), seq_(seq) {}

  void Resolve(CefRefPtr<CefValue> result);
  // The payload reaches the page as `result.payload`, an ArrayBuffer.
  void Resolve(CefRefPtr<CefValue> result, const void* payload, size_t length);
  void Reject(const std::string& message, const std::string& name = "Error");

  // The page the answer goes to, for progress events on the way.
  CefRefPtr<CefFrame> frame() const { return frame_; }

 private:
  void Send(bool ok, const std::string& json, const void* payload,
            size_t length);

  CefRefPtr<CefFrame> frame_;
  const int seq_;
  std::atomic<bool> sent_{false};
};

class Dispatcher {
 public:
  enum class Thread { kUi, kEngine };
  using Handler = std::function<void(const Call&, std::shared_ptr<Reply>)>;

  Dispatcher();
  ~Dispatcher();

  void Register(const std::string& method, Thread thread, Handler handler);

  // UI thread. Returns false for messages that are not bridge calls.
  bool OnProcessMessage(CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefProcessMessage> message);

  // Delivers a DOM event ("fotufilm-native-<name>", or "fotufilm-native-progress") to the page.
  static void Emit(CefRefPtr<CefFrame> frame, const std::string& name,
                   CefRefPtr<CefValue> detail);

  // Runs on the UI thread when a "cancel" names the call the engine thread is answering, so the
  // engine can stop mid-develop rather than finish work nobody wants.
  void SetCancelHook(std::function<void()> hook) { cancel_hook_ = std::move(hook); }

  // Queues work behind the engine thread's calls, for a UI handler that has finished its part.
  void PostEngine(std::function<void()> task);

  // Queues the rest of a call a UI handler has begun (an export after its save panel) as an
  // engine call: a "cancel" with its id reaches it, and the cancel hook while it runs.
  void PostCall(std::shared_ptr<Call> call, std::function<void()> task);

  // Stops the engine thread after the work already queued.
  void Shutdown();

 private:
  struct Route {
    Thread thread;
    Handler handler;
  };
  void RunEngine();
  // Queues `task` for `call` on the engine thread. The mutex is held.
  void Enqueue(std::shared_ptr<Call> call, std::function<void()> task);

  std::map<std::string, Route> routes_;
  std::mutex mutex_;
  std::condition_variable wake_;
  std::deque<std::function<void()>> queue_;
  // Calls still running, by message id, so "cancel" can reach them.
  std::multimap<std::string, std::weak_ptr<std::atomic<bool>>> running_;
  bool stopping_ = false;
  // The id of the call the engine thread is answering, if any.
  std::string current_;
  std::function<void()> cancel_hook_;
  std::thread engine_;
};

std::string ToJson(CefRefPtr<CefValue> value);

}  // namespace fotufilm
