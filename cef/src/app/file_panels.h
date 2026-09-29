// The open and save panels of a windowed host, through CEF's own file dialogs: GTK or the desktop
// portal on Linux, the common dialogs on Windows. And the exports this run saved, which
// "openExport" may open or show (web/src/backend/README.md).
#pragma once

#include <functional>
#include <string>
#include <vector>

#include "bridge/dispatcher.h"
#include "include/cef_browser.h"

namespace fotufilm {

// Files to open: "image", "video", "filmPack" or "all" (photographs and movies). `done` gets the
// chosen paths, none when the panel was dismissed.
void ChooseFilesToOpen(CefRefPtr<CefBrowser> browser, const std::string& kind,
                       std::function<void(std::vector<std::string>)> done);

// Where to save an export: the suggested name and MIME type in, a path out (empty: cancelled).
// A `fixed_directory` saves there without asking, as tests do. The folder last saved to is
// offered next time, per kind (photographs, movies).
void ChooseExportDestination(CefRefPtr<CefBrowser> browser, const std::string& filename,
                             const std::string& type, const std::string& fixed_directory,
                             std::function<void(const std::string&)> done);

// Where Export All saves: a folder, starting where photographs were last exported. A
// `fixed_directory` is used without asking. Empty: cancelled.
void ChooseExportFolder(CefRefPtr<CefBrowser> browser, const std::string& type,
                        const std::string& fixed_directory,
                        std::function<void(const std::string&)> done);

// "openExport" {path, reveal}: opens a file this run saved, or one in a folder chosen for Export
// All, or shows it in its folder, with
// `open` (the platform's opener). Other paths are refused.
void RegisterOpenExport(Dispatcher& dispatcher,
                        std::function<bool(const std::string& path, bool reveal)> open);

}  // namespace fotufilm
