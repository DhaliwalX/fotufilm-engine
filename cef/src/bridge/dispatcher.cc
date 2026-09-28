#include "bridge/dispatcher.h"

#include <cstring>

#include "bridge/protocol.h"
#include "include/base/cef_callback.h"
#include "include/cef_parser.h"
#include "include/cef_shared_process_message_builder.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"

namespace fotufilm {
namespace {

void SendOnUi(CefRefPtr<CefFrame> frame, CefRefPtr<CefProcessMessage> message) {
  if (!message) return;
  if (CefCurrentlyOn(TID_UI)) {
    if (frame->IsValid()) frame->SendProcessMessage(PID_RENDERER, message);
    return;
  }
  CefPostTask(TID_UI, base::BindOnce(&SendOnUi, frame, message));
}

CefRefPtr<CefValue> Parse(const std::string& json) {
  CefRefPtr<CefValue> value =
      json.empty() ? nullptr : CefParseJSON(json, JSON_PARSER_RFC);
  if (!value) {
    value = CefValue::Create();
    value->SetDictionary(CefDictionaryValue::Create());
  }
  return value;
}

}  // namespace

std::string ToJson(CefRefPtr<CefValue> value) {
  if (!value) return "null";
  return CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
}

void Reply::Resolve(CefRefPtr<CefValue> result) {
  Send(true, ToJson(result), nullptr, 0);
}

void Reply::Resolve(CefRefPtr<CefValue> result, const void* payload,
                    size_t length) {
  Send(true, ToJson(result), payload, length);
}

void Reply::Reject(const std::string& message, const std::string& name) {
  CefRefPtr<CefDictionaryValue> error = CefDictionaryValue::Create();
  error->SetString("message", message);
  error->SetString("name", name);
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(error);
  Send(false, ToJson(value), nullptr, 0);
}

void Reply::Send(bool ok, const std::string& json, const void* payload,
                 size_t length) {
  if (sent_.exchange(true)) return;
  if (!payload) {
    CefRefPtr<CefProcessMessage> message =
        CefProcessMessage::Create(bridge::kReply);
    CefRefPtr<CefListValue> list = message->GetArgumentList();
    list->SetInt(bridge::kReplySeq, seq_);
    list->SetBool(bridge::kReplyOk, ok);
    list->SetString(bridge::kReplyJson, json);
    SendOnUi(frame_, message);
    return;
  }
  CefRefPtr<CefDictionaryValue> header = CefDictionaryValue::Create();
  header->SetInt("seq", seq_);
  header->SetBool("ok", ok);
  header->SetString("json", json);
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(header);
  const std::string text = ToJson(value);
  // The bytes are copied once, here on the calling thread, into the region the renderer maps.
  CefRefPtr<CefSharedProcessMessageBuilder> builder =
      CefSharedProcessMessageBuilder::Create(bridge::kReply,
                                             bridge::FrameSize(text.size(), length));
  if (!builder || !builder->IsValid()) {
    sent_ = false;
    Reject("Shared memory for the reply could not be allocated.");
    return;
  }
  std::memcpy(bridge::WriteFrameHeader(builder->Memory(), text, length),
              payload, length);
  SendOnUi(frame_, builder->Build());
}

Dispatcher::Dispatcher() : engine_([this] { RunEngine(); }) {}

Dispatcher::~Dispatcher() { Shutdown(); }

void Dispatcher::Shutdown() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_) return;
    stopping_ = true;
  }
  wake_.notify_all();
  if (engine_.joinable()) engine_.join();
}

void Dispatcher::Register(const std::string& method, Thread thread,
                          Handler handler) {
  routes_[method] = {thread, std::move(handler)};
}

void Dispatcher::PostEngine(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_) return;
    queue_.emplace_back(std::move(task));
  }
  wake_.notify_one();
}

void Dispatcher::PostCall(std::shared_ptr<Call> call, std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_) return;
    Enqueue(std::move(call), std::move(task));
  }
  wake_.notify_one();
}

void Dispatcher::Enqueue(std::shared_ptr<Call> call, std::function<void()> task) {
  running_.emplace(call->id, call->cancelled);
  queue_.emplace_back([this, call, task = std::move(task)] {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      current_ = call->id;
    }
    task();
    std::lock_guard<std::mutex> lock(mutex_);
    current_.clear();
    const auto [first, last] = running_.equal_range(call->id);
    for (auto entry = first; entry != last; ++entry)
      if (entry->second.lock() == call->cancelled) {
        running_.erase(entry);
        break;
      }
  });
}

void Dispatcher::RunEngine() {
  for (;;) {
    std::function<void()> task;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      wake_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
      if (queue_.empty()) return;
      task = std::move(queue_.front());
      queue_.pop_front();
    }
    task();
  }
}

bool Dispatcher::OnProcessMessage(CefRefPtr<CefFrame> frame,
                                  CefRefPtr<CefProcessMessage> message) {
  if (message->GetName() != bridge::kCall) return false;
  auto call = std::make_shared<Call>();
  if (CefRefPtr<CefSharedMemoryRegion> region =
          message->GetSharedMemoryRegion()) {
    bridge::FrameView view;
    if (!region->IsValid() ||
        !bridge::ReadFrame(region->Memory(), region->Size(), view))
      return true;
    CefRefPtr<CefValue> header = Parse(std::string(view.header));
    if (header->GetType() != VTYPE_DICTIONARY) return true;
    CefRefPtr<CefDictionaryValue> fields = header->GetDictionary();
    call->seq = fields->GetInt("seq");
    call->id = fields->GetString("id").ToString();
    call->method = fields->GetString("method").ToString();
    call->params = Parse(fields->GetString("params").ToString());
    call->region = region;
    call->payload = view.payload;
    call->payload_length = view.payload_length;
  } else {
    CefRefPtr<CefListValue> list = message->GetArgumentList();
    call->seq = list->GetInt(bridge::kCallSeq);
    call->id = list->GetString(bridge::kCallId).ToString();
    call->method = list->GetString(bridge::kCallMethod).ToString();
    call->params = Parse(list->GetString(bridge::kCallParams).ToString());
  }
  auto reply = std::make_shared<Reply>(frame, call->seq);

  if (call->method == "cancel") {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto [first, last] = running_.equal_range(call->id);
    for (auto entry = first; entry != last; ++entry)
      if (auto flag = entry->second.lock()) *flag = true;
    if (cancel_hook_ && !call->id.empty() && call->id == current_) cancel_hook_();
    reply->Resolve(nullptr);
    return true;
  }
  const auto route = routes_.find(call->method);
  if (route == routes_.end()) {
    reply->Reject("This host does not provide " + call->method + "().",
                  "NotSupportedError");
    return true;
  }
  if (route->second.thread == Thread::kUi) {
    route->second.handler(*call, reply);
    return true;
  }
  Handler handler = route->second.handler;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_) return true;
    Enqueue(call, [handler, call, reply] { handler(*call, reply); });
  }
  wake_.notify_one();
  return true;
}

void Dispatcher::Emit(CefRefPtr<CefFrame> frame, const std::string& name,
                      CefRefPtr<CefValue> detail) {
  CefRefPtr<CefProcessMessage> message =
      CefProcessMessage::Create(bridge::kEvent);
  CefRefPtr<CefListValue> list = message->GetArgumentList();
  list->SetString(bridge::kEventName, name);
  list->SetString(bridge::kEventJson, ToJson(detail));
  SendOnUi(frame, message);
}

}  // namespace fotufilm
