#include "engine/engine_bridge.h"

#include "include/cef_parser.h"

namespace fotufilm {
namespace {

// web/src/backend/desktop/host.js and lenses.js; the engine answers the ones it implements.
constexpr const char* kMethods[] = {
    "prepare",          "import",         "preview",          "release",
    "render",           "stages",         "analyseNegative",  "convertNegative",
    "suggestNegativeFilms", "autoAdjust", "printFrame",       "lensPlan",
    "sampleScene",      "beginVideo",
    "appendVideo",      "importVideo",    "lensCatalogue",    "importLensCatalogue",
    "removeLensCatalogue", "importPath",   "copyImage",        "exportOptions",
    // The strip's pictures of photographs opened together, decoded only when chosen.
    "thumbnail",
    "suggestFilm",      "recordFilmChoice", "forgetFilmChoices",
    // The Resolve and Final Cut plug-ins. An install holds the engine thread until the copy is
    // done and macOS has registered it, as the Mac app's menu item holds its own.
    "plugins",          "installPlugin",    "revealPlugin",
    // Community film packs, installed where the Mac app keeps them.
    "filmPacks",        "importFilmPack", "removeFilmPack",
    // Check for Updates: each answers at once with where the check or download stands.
    "updateCheck",      "updateStatus",   "updateInstall",    "updateCancel",
    "updateNotes",
    // The negative-scan session (web/src/negative-scan/): a scan opens once and every preview,
    // border sample and the imported positive is a print of it to the page's recipe.
    "negativeScanOpen", "negativeScanRender", "negativeScanSampleBorder",
    "negativeScanDetectFrame", "negativeScanCommit", "negativeLightFrames",
    "negativeAddLightFrame", "negativeRemoveLightFrame",
    // The picture the compositor shows, for the histogram (presentation/presentation.h).
    "presentedImage",
};

}  // namespace

EngineBridge::EngineBridge(Dispatcher& dispatcher) : dispatcher_(dispatcher) {
  for (const char* method : kMethods)
    dispatcher.Register(method, Dispatcher::Thread::kEngine,
                        [this](const Call& call, std::shared_ptr<Reply> reply) {
                          Handle(call, std::move(reply));
                        });
  // Choosing the destination is the host's; encoding and writing are the engine's.
  for (const char* method : {"export", "exportVideo", "exportOriginal"})
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

namespace {

// fotufilm_presenter's callbacks, onto an ImagePresenter. A lent surface travels as a heap-held
// reference in `fotufilm_surface.host` until it is presented or discarded.
ImagePresenter* PresenterOf(void* context) {
  return static_cast<std::shared_ptr<ImagePresenter>*>(context)->get();
}

float PresenterHeadroom(void* context) { return PresenterOf(context)->Headroom(); }

int32_t PresenterAcquire(void* context, uint32_t width, uint32_t height, int32_t format,
                         fotufilm_surface* surface) {
  if (format != FOTUFILM_SURFACE_RGBA8_DISPLAY_P3 &&
      format != FOTUFILM_SURFACE_RGBA16F_EXTENDED_LINEAR_P3)
    return FOTUFILM_ERROR;
  auto lent = PresenterOf(context)->Acquire(static_cast<int>(width), static_cast<int>(height),
                                            static_cast<SurfaceFormat>(format));
  if (!lent || !lent->pixels()) return FOTUFILM_ERROR;
  surface->width = static_cast<uint32_t>(lent->width());
  surface->height = static_cast<uint32_t>(lent->height());
  surface->format = static_cast<int32_t>(lent->format());
  surface->pixels = lent->pixels();
  surface->row_bytes = lent->row_bytes();
  surface->native = lent->native_handle();
  surface->host = new std::shared_ptr<PresentationSurface>(std::move(lent));
  return FOTUFILM_OK;
}

uint64_t PresenterPresent(void* context, const char* layer, const fotufilm_surface* surface,
                          const char* info_json) {
  if (!surface || !surface->host) return 0;
  std::unique_ptr<std::shared_ptr<PresentationSurface>> lent(
      static_cast<std::shared_ptr<PresentationSurface>*>(surface->host));
  PresentedFrame frame;
  frame.surface = std::move(*lent);
  frame.extended = frame.surface->format() == SurfaceFormat::kRgba16FloatExtendedLinearP3;
  CefRefPtr<CefValue> info = CefParseJSON(info_json ? info_json : "{}", JSON_PARSER_RFC);
  if (info && info->GetType() == VTYPE_DICTIONARY) {
    frame.scope = info->GetDictionary()->GetString("scope").ToString();
    frame.motion = info->GetDictionary()->GetBool("motion");
  }
  return PresenterOf(context)->Present(layer ? layer : "", std::move(frame));
}

void PresenterDiscard(void*, const fotufilm_surface* surface) {
  if (surface) delete static_cast<std::shared_ptr<PresentationSurface>*>(surface->host);
}

}  // namespace

void EngineBridge::SetPresenter(std::shared_ptr<ImagePresenter> presenter) {
  dispatcher_.PostEngine([this, presenter = std::move(presenter)]() mutable {
    presenter_ = std::move(presenter);
    callbacks_ = {};
    if (presenter_) {
      callbacks_.context = &presenter_;
      callbacks_.headroom = PresenterHeadroom;
      callbacks_.acquire = PresenterAcquire;
      callbacks_.present = PresenterPresent;
      callbacks_.discard = PresenterDiscard;
    }
    if (engine_) fotufilm_engine_set_presenter(engine_, presenter_ ? &callbacks_ : nullptr);
  });
}

fotufilm_engine* EngineBridge::Engine(std::string& error) {
  if (engine_ || !failure_.empty()) {
    error = failure_;
    return engine_;
  }
  char* message = nullptr;
  engine_ = fotufilm_engine_create(&message);
  if (!engine_) failure_ = message ? message : "The engine could not start.";
  if (engine_ && presenter_) fotufilm_engine_set_presenter(engine_, &callbacks_);
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
