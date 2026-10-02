// The photo library's folder calls (app/library_folders.h), the same on every platform:
//
//   chooseLibraryFolder   the platform's folder panel; {path, name} of the chosen folder, or null
//   listLibraryFolder     {path, extensions}: the folder's photos as `payload`, UTF-8 JSON rows
//                         of [relative path, size, modified milliseconds]
//   forgetLibraryFolder   {path}: the page removed the folder, so its files stop being served
//   renameLibraryFile     {path, name}: renames a photo in its folder; {path, name} it now has
//   revealLibraryFiles    {paths}: shows the photos in the platform's file manager
//   trashLibraryFiles     {paths}: moves the photos to the platform's trash; {trashed: [path],
//                         failed: [{path, message}]}
//
// Every path is absolute and must lie inside a chosen folder. Revealing and trashing are the
// platform's (LibraryFileActions); a host without them leaves those two methods out.
//
// and the files themselves, at fotufilm://app/.library?path=<absolute path, URI-encoded>.
#pragma once

#include <functional>
#include <string>
#include <vector>

#include "bridge/dispatcher.h"

namespace fotufilm {

// What the platform does with library files. `trash` runs on a file thread.
struct LibraryFileActions {
  std::function<bool(const std::vector<std::string>& paths)> reveal;
  std::function<bool(const std::string& path, std::string& error)> trash;
};

// `store` is where the chosen folders are kept between launches. Before the page loads.
void RegisterLibraryMethods(Dispatcher& dispatcher, const std::string& store,
                            LibraryFileActions actions = {});

}  // namespace fotufilm
