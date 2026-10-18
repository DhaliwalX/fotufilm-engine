// Fotufilm on Linux: the Flutter editor (lib/) in a GTK window, and the engine beside it. Everything
// the app reads sits in its bundle:
//
//   fotufilm          this program        lib/        libfotufilm.so, Flutter and the plug-ins
//   data/             Flutter's assets    resources/  the engine's films and camera profiles
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>

#include <string>

#include "my_application.h"

int main(int argc, char** argv) {
  // The engine finds its films and camera profiles here (FilmStockPack, BundledCameraProfiles).
  char executable[PATH_MAX];
  const ssize_t length = readlink("/proc/self/exe", executable, sizeof(executable) - 1);
  if (length > 0) {
    executable[length] = '\0';
    std::string directory(executable);
    directory.resize(directory.rfind('/'));
    const std::string resources = directory + "/resources";
    setenv("FOTUFILM_RESOURCES", resources.c_str(), 0);
    setenv("FOTUFILM_STOCKS", (resources + "/Stocks").c_str(), 0);
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
