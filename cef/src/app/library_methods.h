// The photo library's folder calls (app/library_folders.h), the same on every platform:
//
//   chooseLibraryFolder   the platform's folder panel; {path, name} of the chosen folder, or null
//   listLibraryFolder     {path, extensions}: the folder's photos as `payload`, UTF-8 JSON rows
//                         of [relative path, size, modified milliseconds]
//   forgetLibraryFolder   {path}: the page removed the folder, so its files stop being served
//
// and the files themselves, at fotufilm://app/.library?path=<absolute path, URI-encoded>.
#pragma once

#include <string>

#include "bridge/dispatcher.h"

namespace fotufilm {

// `store` is where the chosen folders are kept between launches. Before the page loads.
void RegisterLibraryMethods(Dispatcher& dispatcher, const std::string& store);

}  // namespace fotufilm
