// What the editor may offer (`window.fotufilmNativeTransport.capabilities`): the engine's
// platform services (fotufilm_capabilities) with the host's own merged over them.
#pragma once

#include <string>

#include "include/cef_values.h"

namespace fotufilm {

// The engine's capabilities JSON with `host`'s fields set over it. Every host states its
// `platform` ("macos", "linux", "windows"), which the editor uses for its window chrome.
std::string WithHostCapabilities(const std::string& engine, CefRefPtr<CefDictionaryValue> host);

}  // namespace fotufilm
