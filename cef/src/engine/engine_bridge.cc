#include "engine/engine_bridge.h"

#include "include/cef_parser.h"

namespace fotufilm {
namespace {

// web/src/backend/macos/host.js and lenses.js; the engine answers the ones it implements.
constexpr const char* kMethods[] = {
    "prepare",          "import",         "preview",          "release",
    "render",           "stages",         "analyseNegative",  "convertNegative",
    "suggestNegativeFilms", "autoAdjust", "printFrame",       "lensPlan",
    "sampleScene",      "beginVideo",
    "appendVideo",      "importVideo",    "lensCatalogue",    "importLensCatalogue",
    "removeLensCatalogue", "importPath",   "copyImage",        "exportOptions",
};

}  // namespace

EngineBridge::EngineBridge(Dispatcher& dispatcher) : dispatcher_(dispatcher) {
  for (const char* method : kMethods)
    dispatcher.Register(method, Dispatcher::Thread::kEngine,
                        [this](const Call& call, std::shared_ptr<Reply> reply) {
                          Handle(call, std::move(reply));
                        });
  // Choosing the destination is the host's; encoding and writing are the engine's.
  for (const char* method : {"export", "exportVideo"})
    dispatcher.Register(method, Dispatcher::Thread::kUi,
                        [this](const Call& call, std::shared_ptr<Reply> reply) {
                          Export(call, std::move(reply));
                        });
  // A cancel for the call being answered stops the develop inside the engine; calls still
  // queued see their own flag before they start.
  dispatcher.SetCancelHook([this] {
    if (engine_) fotufilm_engine_cancel(engine_);
  });
}

std::string EngineBridge::Capabilities() {
  char* json = fotufilm_capabilities();
  if (!json) return {};
  std::string capabilities(json);
  fotufilm_free(json);
  return capabilities;
}

EngineBridge::~EngineBridge() {
  if (engine_) fotufilm_engine_destroy(engine_);
}

fotufilm_engine* EngineBridge::Engine(std::string& error) {
  if (engine_ || !failure_.empty()) {
    error = failure_;
    return engine_;
  }
  char* message = nullptr;
  engine_ = fotufilm_engine_create(&message);
  if (!engine_) failure_ = message ? message : "The engine could not start.";
  fotufilm_free(message);
  error = failure_;
  return engine_;
}

void EngineBridge::Export(const Call& call, std::shared_ptr<Reply> reply) {
  if (!picker_) return reply->Reject("This host cannot choose where to save.");
  CefRefPtr<CefDictionaryValue> fields =
      call.params && call.params->GetType() == VTYPE_DICTIONARY
          ? call.params->GetDictionary()->Copy(false)
          : CefDictionaryValue::Create();
  const std::string filename = fields->GetString("filename").ToString();
  const std::string type = fields->GetString("type").ToString();
  auto pending = std::make_shared<Call>(call);
  picker_(filename, type, [this, pending, fields, reply](const std::string& path) {
    if (path.empty()) return reply->Reject("The export was cancelled.", "AbortError");
    fields->SetString("path", path);
    pending->params = CefValue::Create();
    pending->params->SetDictionary(fields);
    dispatcher_.PostCall(pending, [this, pending, reply] { Handle(*pending, reply); });
  });
}

namespace {

// Where a call's progress goes: the page that made it, under the call's own id, as the
// transport's "fotufilm-native-progress" event.
struct ProgressTarget {
  std::shared_ptr<Reply> reply;
  std::string id;
};

void ReportProgress(void* context, const char* json) {
  const auto* target = static_cast<const ProgressTarget*>(context);
  CefRefPtr<CefDictionaryValue> detail = CefDictionaryValue::Create();
  detail->SetString("id", target->id);
  detail->SetValue("progress", CefParseJSON(json ? json : "null", JSON_PARSER_RFC));
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(detail);
  Dispatcher::Emit(target->reply->frame(), "progress", value);
}

}  // namespace

void EngineBridge::Handle(const Call& call, std::shared_ptr<Reply> reply) {
  if (*call.cancelled) return reply->Reject("The request was cancelled.", "AbortError");
  std::string failure;
  fotufilm_engine* engine = Engine(failure);
  if (!engine) return reply->Reject(failure);

  const std::string params = ToJson(call.params);
  fotufilm_answer answer = {};
  char* error = nullptr;
  ProgressTarget progress{reply, call.id};
  const int32_t status = fotufilm_host_call_progress(
      engine, call.method.c_str(), params.c_str(), call.payload, call.payload_length,
      ReportProgress, &progress, &answer, &error);
  if (status == FOTUFILM_CANCELLED || *call.cancelled) {
    reply->Reject("The request was cancelled.", "AbortError");
  } else if (status != FOTUFILM_OK) {
    reply->Reject(error ? error : "The engine failed.");
  } else {
    CefRefPtr<CefValue> value = CefParseJSON(answer.json ? answer.json : "null",
                                             JSON_PARSER_RFC);
    if (answer.payload_length)
      reply->Resolve(value, answer.payload, answer.payload_length);
    else
      reply->Resolve(value);
  }
  fotufilm_answer_free(&answer);
  fotufilm_free(error);
}

}  // namespace fotufilm
