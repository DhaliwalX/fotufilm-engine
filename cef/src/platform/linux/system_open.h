// Hands a file to the desktop: opens it in its default application, or shows it in the file
// manager (the FileManager1 interface most file managers answer, else its folder).
#pragma once

#include <string>

namespace fotufilm {

// False when no opener could be started.
bool OpenWithSystem(const std::string& path, bool reveal);

}  // namespace fotufilm
