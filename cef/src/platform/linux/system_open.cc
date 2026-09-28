#include "platform/linux/system_open.h"

#include <spawn.h>
#include <sys/wait.h>

#include <cctype>
#include <cstdio>
#include <filesystem>
#include <functional>
#include <string>
#include <thread>
#include <vector>

extern char** environ;

namespace fotufilm {
namespace {

// Starts `arguments`; its exit status is read on a thread so no child is left a zombie.
bool Start(std::vector<std::string> arguments, std::function<void(int status)> finished = {}) {
  std::vector<char*> argv;
  for (std::string& argument : arguments) argv.push_back(argument.data());
  argv.push_back(nullptr);
  pid_t pid = 0;
  if (posix_spawnp(&pid, argv[0], nullptr, nullptr, argv.data(), environ) != 0) return false;
  std::thread([pid, finished] {
    int status = 0;
    waitpid(pid, &status, 0);
    if (finished) finished(status);
  }).detach();
  return true;
}

std::string FileUri(const std::string& path) {
  std::string uri = "file://";
  for (const unsigned char c : path) {
    if (std::isalnum(c) || c == '/' || c == '-' || c == '_' || c == '.' || c == '~') {
      uri += static_cast<char>(c);
    } else {
      char escaped[4];
      std::snprintf(escaped, sizeof(escaped), "%%%02X", c);
      uri += escaped;
    }
  }
  return uri;
}

}  // namespace

bool OpenWithSystem(const std::string& path, bool reveal) {
  if (!reveal) return Start({"xdg-open", path});
  const std::string folder = std::filesystem::path(path).parent_path().string();
  const bool started = Start(
      {"dbus-send", "--session", "--print-reply", "--dest=org.freedesktop.FileManager1",
       "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1.ShowItems",
       "array:string:" + FileUri(path), "string:"},
      [folder](int status) {
        if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) Start({"xdg-open", folder});
      });
  return started || Start({"xdg-open", folder});
}

}  // namespace fotufilm
