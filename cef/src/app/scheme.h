// The editor is served from fotufilm://app/, a standard secure scheme read straight from the
// bundled web build: no local server, no port, and no network stack between the UI and its files.
#pragma once

#include <functional>
#include <string>

#include "include/cef_scheme.h"

namespace fotufilm {

inline constexpr char kScheme[] = "fotufilm";
inline constexpr char kAppHost[] = "app";
inline constexpr char kAppOrigin[] = "fotufilm://app";

// Every process registers the scheme identically, before CEF starts.
void RegisterCustomSchemes(CefRawPtr<CefSchemeRegistrar> registrar);

// Browser process only, after the context is initialised.
void RegisterAppSchemeHandler(const std::string& web_root);

// Serves `fotufilm://app/<name>?<query>` from the file `resolve` names for the query, or answers
// Not found when it names none. Browser process only, before the page loads.
using AppFileResolver = std::function<std::string(const std::string& query)>;
void ServeAppFiles(const std::string& name, AppFileResolver resolve);

}  // namespace fotufilm
