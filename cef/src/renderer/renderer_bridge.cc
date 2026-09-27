#include "renderer/renderer_bridge.h"

#include <cstring>
#include <string_view>

#include "app/scheme.h"
#include "bridge/protocol.h"
#include "include/cef_command_line.h"
#include "include/cef_parser.h"
#include "include/cef_shared_process_message_builder.h"
#include "include/cef_v8.h"
#include "renderer/bridge_script.h"
#include "switches.h"

namespace fotufilm {
namespace {

// Calls from page script into the renderer: send(seq, id, method, json[, buffer, offset,
// length]) and listen(callback).
class HostFunctions : public CefV8Handler {
 public:
  HostFunctions(CefRefPtr<RendererBridge> bridge,
                CefRefPtr<CefFrame> frame,
                CefRefPtr<CefV8Context> context,
                int context_id)
      : bridge_(bridge), frame_(frame), context_(context), id_(context_id) {}

  bool Execute(const CefString& name,
               CefRefPtr<CefV8Value>,
               const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>& result,
               CefString& exception) override {
    if (name == "listen") {
      if (arguments.size() != 1 || !arguments[0]->IsFunction()) {
        exception = "listen() takes one function.";
        return true;
      }
      bridge_->Listen(id_, frame_->GetIdentifier().ToString(), context_,
                      arguments[0]);
      return true;
    }
    if (name != "send") return false;
    if (arguments.size() < 4 || !arguments[0]->IsInt() ||
        !arguments[1]->IsString() || !arguments[2]->IsString() ||
        !arguments[3]->IsString()) {
      exception = "send() takes a sequence number, id, method and JSON.";
      return true;
    }
    const int seq = bridge_->Track(id_, arguments[0]->GetIntValue());
    if (arguments.size() == 4) {
      CefRefPtr<CefProcessMessage> message =
          CefProcessMessage::Create(bridge::kCall);
      CefRefPtr<CefListValue> list = message->GetArgumentList();
      list->SetInt(bridge::kCallSeq, seq);
      list->SetString(bridge::kCallId, arguments[1]->GetStringValue());
      list->SetString(bridge::kCallMethod, arguments[2]->GetStringValue());
      list->SetString(bridge::kCallParams, arguments[3]->GetStringValue());
      frame_->SendProcessMessage(PID_BROWSER, message);
      return true;
    }
    if (arguments.size() != 7 || !arguments[4]->IsArrayBuffer() ||
        !arguments[5]->IsUInt() || !arguments[6]->IsUInt()) {
      exception = "A payload is an ArrayBuffer, an offset and a length.";
      return true;
    }
    const size_t offset = arguments[5]->GetUIntValue(),
                 length = arguments[6]->GetUIntValue();
    if (offset + length > arguments[4]->GetArrayBufferByteLength()) {
      exception = "The payload range lies outside its buffer.";
      return true;
    }
    // The header carries what the list would; the payload is written once, into the region the
    // browser process maps.
    CefRefPtr<CefDictionaryValue> header = CefDictionaryValue::Create();
    header->SetInt("seq", seq);
    header->SetString("id", arguments[1]->GetStringValue());
    header->SetString("method", arguments[2]->GetStringValue());
    header->SetString("params", arguments[3]->GetStringValue());
    CefRefPtr<CefValue> value = CefValue::Create();
    value->SetDictionary(header);
    const std::string json =
        CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
    CefRefPtr<CefSharedProcessMessageBuilder> builder =
        CefSharedProcessMessageBuilder::Create(
            bridge::kCall, bridge::FrameSize(json.size(), length));
    if (!builder || !builder->IsValid()) {
      exception = "Shared memory for the payload could not be allocated.";
      return true;
    }
    uint8_t* payload = bridge::WriteFrameHeader(builder->Memory(), json, length);
    std::memcpy(payload,
                static_cast<const uint8_t*>(arguments[4]->GetArrayBufferData()) +
                    offset,
                length);
    frame_->SendProcessMessage(PID_BROWSER, builder->Build());
    return true;
  }

 private:
  CefRefPtr<RendererBridge> bridge_;
  CefRefPtr<CefFrame> frame_;
  CefRefPtr<CefV8Context> context_;
  const int id_;
  IMPLEMENT_REFCOUNTING(HostFunctions);
};

std::string Origin(const std::string& url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) return {};
  return CefString(&parts.origin).ToString();
}

}  // namespace

void RendererBridge::OnWebKitInitialized() {
  CefRefPtr<CefCommandLine> command_line =
      CefCommandLine::GetGlobalCommandLine();
  dev_origin_ = command_line->GetSwitchValue(switches::kDevOrigin).ToString();
  global_name_ =
      command_line->GetSwitchValue(switches::kTransportGlobal).ToString();
  if (global_name_.empty()) global_name_ = switches::kDefaultTransportGlobal;
}

bool RendererBridge::Trusted(const std::string& url) const {
  // Origins compare without a trailing slash: "fotufilm://app".
  std::string origin = Origin(url);
  while (!origin.empty() && origin.back() == '/') origin.pop_back();
  return origin == kAppOrigin || (!dev_origin_.empty() && origin == dev_origin_);
}

void RendererBridge::Listen(int context,
                            std::string frame,
                            CefRefPtr<CefV8Context> v8,
                            CefRefPtr<CefV8Value> listener) {
  listeners_[context] = {std::move(frame), v8, listener};
}

int RendererBridge::Track(int context, int page_seq) {
  const int seq = ++next_seq_;
  calls_[seq] = {context, page_seq};
  return seq;
}

void RendererBridge::OnContextCreated(CefRefPtr<CefBrowser>,
                                      CefRefPtr<CefFrame> frame,
                                      CefRefPtr<CefV8Context> context) {
  // Only the editor's own top-level page talks to the engine.
  if (!frame->IsMain() || !Trusted(frame->GetURL().ToString())) return;
  CefRefPtr<HostFunctions> functions =
      new HostFunctions(this, frame, context, ++next_context_);
  CefRefPtr<CefV8Value> host = CefV8Value::CreateObject(nullptr, nullptr);
  for (const char* name : {"send", "listen"})
    host->SetValue(name, CefV8Value::CreateFunction(name, functions),
                   V8_PROPERTY_ATTRIBUTE_READONLY);

  CefRefPtr<CefV8Value> install;
  CefRefPtr<CefV8Exception> exception;
  if (!context->Eval(kBridgeScript, "fotufilm://host/bridge.js", 1, install,
                     exception) ||
      !install->IsFunction())
    return;
  install->ExecuteFunction(
      nullptr, {host, CefV8Value::CreateString(global_name_)});
}

void RendererBridge::OnContextReleased(CefRefPtr<CefBrowser>,
                                       CefRefPtr<CefFrame>,
                                       CefRefPtr<CefV8Context> context) {
  for (auto listener = listeners_.begin(); listener != listeners_.end();) {
    if (!listener->second.context->IsSame(context)) {
      ++listener;
      continue;
    }
    const int id = listener->first;
    for (auto call = calls_.begin(); call != calls_.end();)
      call = call->second.first == id ? calls_.erase(call) : std::next(call);
    listener = listeners_.erase(listener);
  }
}

bool RendererBridge::OnProcessMessageReceived(
    CefRefPtr<CefBrowser>,
    CefRefPtr<CefFrame> frame,
    CefProcessId,
    CefRefPtr<CefProcessMessage> message) {
  const std::string name = message->GetName().ToString();
  if (name != bridge::kReply && name != bridge::kEvent) return false;
  const bool reply = name == bridge::kReply;

  // Read the message: its number or event name, success, JSON and any payload.
  int seq = 0;
  bool ok = true;
  std::string key, json;
  const uint8_t* payload = nullptr;
  size_t payload_length = 0;
  CefRefPtr<CefSharedMemoryRegion> region = message->GetSharedMemoryRegion();
  if (region) {
    bridge::FrameView view;
    if (!region->IsValid() ||
        !bridge::ReadFrame(region->Memory(), region->Size(), view))
      return true;
    CefRefPtr<CefValue> parsed =
        CefParseJSON(std::string(view.header), JSON_PARSER_RFC);
    if (!parsed || parsed->GetType() != VTYPE_DICTIONARY) return true;
    CefRefPtr<CefDictionaryValue> header = parsed->GetDictionary();
    seq = header->GetInt("seq");
    ok = !reply || header->GetBool("ok");
    key = header->GetString("name").ToString();
    json = header->GetString("json").ToString();
    payload = view.payload;
    payload_length = view.payload_length;
  } else {
    CefRefPtr<CefListValue> list = message->GetArgumentList();
    if (reply) {
      seq = list->GetInt(bridge::kReplySeq);
      ok = list->GetBool(bridge::kReplyOk);
      json = list->GetString(bridge::kReplyJson).ToString();
    } else {
      key = list->GetString(bridge::kEventName).ToString();
      json = list->GetString(bridge::kEventJson).ToString();
    }
  }

  auto arguments = [&](CefRefPtr<CefV8Value> id) {
    // The mapping may be read-only, so script gets its own copy of the bytes.
    return CefV8ValueList{
        CefV8Value::CreateString(reply ? "reply" : "event"), id,
        CefV8Value::CreateBool(ok), CefV8Value::CreateString(json),
        payload ? CefV8Value::CreateArrayBufferWithCopy(
                      const_cast<uint8_t*>(payload), payload_length)
                : CefV8Value::CreateNull()};
  };
  if (reply) {
    const auto call = calls_.find(seq);
    if (call == calls_.end()) return true;
    const auto [context, page_seq] = call->second;
    calls_.erase(call);
    const auto listener = listeners_.find(context);
    if (listener == listeners_.end()) return true;
    // V8 values are made inside the context that receives them.
    if (!listener->second.context->Enter()) return true;
    const CefV8ValueList values = arguments(CefV8Value::CreateInt(page_seq));
    listener->second.function->ExecuteFunction(nullptr, values);
    listener->second.context->Exit();
    return true;
  }
  const std::string target = frame->GetIdentifier().ToString();
  for (const auto& [id, listener] : listeners_) {
    if (listener.frame != target || !listener.context->Enter()) continue;
    const CefV8ValueList values = arguments(CefV8Value::CreateString(key));
    listener.function->ExecuteFunction(nullptr, values);
    listener.context->Exit();
  }
  return true;
}

}  // namespace fotufilm
