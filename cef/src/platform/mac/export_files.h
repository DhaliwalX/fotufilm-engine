#ifndef FOTUFILM_CEF_PLATFORM_MAC_EXPORT_FILES_H_
#define FOTUFILM_CEF_PLATFORM_MAC_EXPORT_FILES_H_

#include <functional>
#include <string>

#include "bridge/dispatcher.h"

namespace fotufilm {

// Where an export goes: the save panel, opened in the folder this kind of file (photo or movie)
// was last saved to, Pictures or Movies at first. `fixed_directory` skips the panel, for scripted
// runs. An empty path is a cancel.
void ChooseExportDestination(const std::string& filename, const std::string& type,
                             const std::string& fixed_directory,
                             std::function<void(const std::string&)> done);

// Where Export All saves: a folder chosen in an open panel, starting where photographs were last
// exported. `fixed_directory` skips the panel. An empty folder is a cancel.
void ChooseExportFolder(const std::string& type, const std::string& fixed_directory,
                        std::function<void(const std::string&)> done);

// "openExport" {path, reveal}: opens a file this app saved in its default app, or shows it in
// Finder. Only files saved since launch, or put in a folder chosen for Export All, are opened.
void RegisterExportFiles(Dispatcher& dispatcher);

}  // namespace fotufilm

#endif  // FOTUFILM_CEF_PLATFORM_MAC_EXPORT_FILES_H_
