#ifndef FOTUFILM_CEF_PLATFORM_MAC_LIBRARY_FILES_H_
#define FOTUFILM_CEF_PLATFORM_MAC_LIBRARY_FILES_H_

#include "app/library_methods.h"

namespace fotufilm {

// Finder's part in the photo library: showing photos selected in a Finder window, and moving
// them to the Trash, where they can be put back.
LibraryFileActions MacLibraryFileActions();

}  // namespace fotufilm

#endif  // FOTUFILM_CEF_PLATFORM_MAC_LIBRARY_FILES_H_
