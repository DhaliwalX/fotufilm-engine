#include "app/host_capabilities.h"

#include "include/cef_parser.h"

namespace fotufilm {

std::string WithHostCapabilities(const std::string& engine, CefRefPtr<CefDictionaryValue> host) {
  CefRefPtr<CefValue> parsed =
      engine.empty() ? nullptr : CefParseJSON(engine, JSON_PARSER_RFC);
  CefRefPtr<CefDictionaryValue> merged = parsed && parsed->GetType() == VTYPE_DICTIONARY
                                             ? parsed->GetDictionary()->Copy(false)
                                             : CefDictionaryValue::Create();
  CefDictionaryValue::KeyList keys;
  if (host) host->GetKeys(keys);
  for (const CefString& key : keys) merged->SetValue(key, host->GetValue(key)->Copy());
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(merged);
  return CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
}

}  // namespace fotufilm
