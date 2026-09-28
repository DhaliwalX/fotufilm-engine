#include "presentation/presentation_methods.h"

#include <cmath>
#include <utility>

namespace fotufilm {
namespace {

// JSON numbers arrive as integers when they are whole.
double Number(CefRefPtr<CefValue> value) {
  if (!value) return 0;
  switch (value->GetType()) {
    case VTYPE_INT: return value->GetInt();
    case VTYPE_DOUBLE: return value->GetDouble();
    default: return 0;
  }
}

double Field(CefRefPtr<CefDictionaryValue> fields, const char* key) {
  return fields && fields->HasKey(key) ? Number(fields->GetValue(key)) : 0;
}

LayerRect Rect(CefRefPtr<CefListValue> list) {
  if (!list || list->GetSize() != 4) return {};
  return {Number(list->GetValue(0)), Number(list->GetValue(1)), Number(list->GetValue(2)),
          Number(list->GetValue(3))};
}

// Frame ids travel as JSON numbers; ids stay far below 2^53.
uint64_t Id(CefRefPtr<CefDictionaryValue> fields, const char* key) {
  const double id = Field(fields, key);
  return id > 0 ? static_cast<uint64_t>(id) : 0;
}

CefRefPtr<CefValue> Dictionary(CefRefPtr<CefDictionaryValue> dictionary) {
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(dictionary);
  return value;
}

CefRefPtr<CefDictionaryValue> Fields(const Call& call) {
  return call.params && call.params->GetType() == VTYPE_DICTIONARY ? call.params->GetDictionary()
                                                                   : nullptr;
}

}  // namespace

ImageLayerGeometry ParseImageLayerGeometry(CefRefPtr<CefDictionaryValue> fields,
                                           LayerRect* pattern) {
  ImageLayerGeometry geometry;
  if (!fields) return geometry;
  if (!fields->HasKey("layers")) {
    if (pattern)
      *pattern = {Field(fields, "x"), Field(fields, "y"), Field(fields, "width"),
                  Field(fields, "height")};
    return geometry;
  }
  geometry.clip = Rect(fields->GetList("clip"));
  geometry.original = fields->GetString("source") == "original";
  if (CefRefPtr<CefListValue> layers = fields->GetList("layers")) {
    for (size_t index = 0; index < layers->GetSize(); ++index) {
      CefRefPtr<CefDictionaryValue> layer = layers->GetDictionary(index);
      if (!layer) continue;
      LayerPlacement placement;
      placement.slot = layer->GetString("slot").ToString();
      placement.frame = Id(layer, "frame");
      placement.original = Id(layer, "original");
      placement.rect = Rect(layer->GetList("rect"));
      if (!placement.slot.empty() && !placement.rect.Empty())
        geometry.layers.push_back(std::move(placement));
    }
  }
  return geometry;
}

void PlaceImageLayer(const std::shared_ptr<WindowCompositor>& compositor,
                     ImageLayerGeometry geometry) {
  compositor->core().Place(std::move(geometry), compositor->Now());
  // Applied with the next browser frame; this is for a layout change that repaints nothing.
  std::weak_ptr<WindowCompositor> weak = compositor;
  compositor->RunAfter(CompositorCore::kPlacementWaitSeconds, [weak] {
    auto strong = weak.lock();
    if (!strong || !strong->core().PlacementDue(strong->Now())) return;
    strong->core().ApplyPlacement();
    strong->SetNeedsDisplay();
  });
}

void RegisterPresentationMethods(Dispatcher& dispatcher,
                                 std::function<std::shared_ptr<WindowCompositor>()> window) {
  using Thread = Dispatcher::Thread;

  // Where the page shows the engine's image layer (presentation/image_layer.h): the canvas's
  // clip, which frames go where and whether the original shows, in CSS pixels from the top left.
  // The diagnostics page's {x, y, width, height} asks for the moving test pattern instead.
  dispatcher.Register("setImageLayer", Thread::kUi,
                      [window](const Call& call, std::shared_ptr<Reply> reply) {
                        if (auto compositor = window()) {
                          LayerRect pattern;
                          ImageLayerGeometry geometry =
                              ParseImageLayerGeometry(Fields(call), &pattern);
                          CompositorCore& core = compositor->core();
                          core.ShowTestPattern(pattern);
                          core.set_continuous(!pattern.Empty());
                          PlaceImageLayer(compositor, std::move(geometry));
                          compositor->SetNeedsDisplay();
                        }
                        reply->Resolve(nullptr);
                      });

  dispatcher.Register(
      "compositorStats", Thread::kUi, [window](const Call&, std::shared_ptr<Reply> reply) {
        CefRefPtr<CefDictionaryValue> stats = CefDictionaryValue::Create();
        if (auto compositor = window()) {
          const CompositorStats& values = compositor->core().stats();
          stats->SetDouble("frames", double(values.frames));
          stats->SetDouble("browserFrames", double(values.browser_frames));
          stats->SetDouble("copyMicroseconds", values.last_copy_us);
          stats->SetDouble("copyGpuMicroseconds", values.last_copy_gpu_us);
          stats->SetDouble("drawableWaitMicroseconds", values.last_drawable_wait_us);
          stats->SetDouble("compositeMicroseconds", values.last_composite_us);
          stats->SetBool("sharedTextures", values.shared_textures);
          stats->SetDouble("imageFrames", double(values.image_frames));
          stats->SetBool("extendedRange", values.extended_range);
          stats->SetDouble("headroom", compositor->Headroom());
        }
        reply->Resolve(Dictionary(stats));
      });

  // What the screen shows, page and image layer together, written to a temporary file whose
  // path is the answer (diagnostics and checks).
  dispatcher.Register("compositorSnapshot", Thread::kUi,
                      [window](const Call&, std::shared_ptr<Reply> reply) {
                        auto compositor = window();
                        if (!compositor) return reply->Resolve(nullptr);
                        compositor->Snapshot([reply](const std::string& path) {
                          CefRefPtr<CefValue> value = CefValue::Create();
                          if (path.empty())
                            value->SetNull();
                          else
                            value->SetString(path);
                          reply->Resolve(value);
                        });
                      });

  // The latency probe: {x, y} in CSS pixels arms it at a point of the window ({} stops it);
  // probeReport answers the changes seen there and the host's clock, in milliseconds.
  dispatcher.Register(
      "probePixel", Thread::kUi, [window](const Call& call, std::shared_ptr<Reply> reply) {
        CefRefPtr<CefDictionaryValue> fields = Fields(call);
        if (auto compositor = window()) {
          std::optional<std::pair<double, double>> point;
          if (fields && fields->HasKey("x")) point = {Field(fields, "x"), Field(fields, "y")};
          compositor->core().Probe(point);
          compositor->SetNeedsDisplay();
        }
        reply->Resolve(nullptr);
      });
  dispatcher.Register(
      "probeReport", Thread::kUi, [window](const Call&, std::shared_ptr<Reply> reply) {
        CefRefPtr<CefDictionaryValue> report = CefDictionaryValue::Create();
        CefRefPtr<CefListValue> changes = CefListValue::Create();
        if (auto compositor = window()) {
          report->SetDouble("now", compositor->Now() * 1000);
          for (const ProbeChange& change : compositor->core().probe_changes()) {
            CefRefPtr<CefDictionaryValue> entry = CefDictionaryValue::Create();
            entry->SetDouble("time", change.time_ms);
            entry->SetString("value", change.value);
            changes->SetDictionary(changes->GetSize(), entry);
          }
        }
        report->SetList("changes", changes);
        reply->Resolve(Dictionary(report));
      });
}

}  // namespace fotufilm
