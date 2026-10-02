#include "app/library_folders.h"

#include <sys/stat.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <filesystem>
#include <fstream>

namespace fotufilm {
namespace {

namespace fs = std::filesystem;

std::string Utf8(const fs::path& path) {
  const auto text = path.generic_u8string();
  return std::string(text.begin(), text.end());
}

// A folder as it is kept and compared: absolute, normalised, without a trailing separator.
std::string Normal(const std::string& folder) {
  fs::path path = fs::path(folder).lexically_normal();
  if (!path.is_absolute()) return {};
  std::string text = Utf8(path);
  while (text.size() > 1 && text.back() == '/') text.pop_back();
  return text;
}

bool Inside(const fs::path& file, const std::string& folder) {
  const fs::path relative = file.lexically_relative(fs::path(folder));
  return !relative.empty() && *relative.begin() != ".." && relative != ".";
}

void AppendJsonString(std::string& json, const std::string& text) {
  json += '"';
  for (const unsigned char c : text) {
    if (c == '"' || c == '\\') {
      json += '\\';
      json += static_cast<char>(c);
    } else if (c < 0x20) {
      char escaped[8];
      std::snprintf(escaped, sizeof(escaped), "\\u%04x", c);
      json += escaped;
    } else {
      json += static_cast<char>(c);
    }
  }
  json += '"';
}

// Size and modification time as the browser's File reports them, in bytes and milliseconds.
bool Stat(const fs::path& file, long long& size, long long& modified) {
#if defined(_WIN32)
  struct _stat64 info;
  if (_wstat64(file.c_str(), &info) != 0) return false;
  modified = static_cast<long long>(info.st_mtime) * 1000;
#else
  struct stat info;
  if (stat(file.c_str(), &info) != 0) return false;
#if defined(__APPLE__)
  const timespec time = info.st_mtimespec;
#else
  const timespec time = info.st_mtim;
#endif
  modified = static_cast<long long>(time.tv_sec) * 1000 + time.tv_nsec / 1000000;
#endif
  size = static_cast<long long>(info.st_size);
  return true;
}

}  // namespace

LibraryFolders::LibraryFolders(std::string store) : store_(std::move(store)) {
  if (store_.empty()) return;
  std::ifstream in(store_);
  for (std::string line; std::getline(in, line);)
    if (const std::string folder = Normal(line); !folder.empty()) folders_.insert(folder);
}

bool LibraryFolders::Grant(const std::string& folder) {
  const std::string normal = Normal(folder);
  std::error_code error;
  if (normal.empty() || normal.find('\n') != std::string::npos ||
      !fs::is_directory(fs::path(normal), error))
    return false;
  std::lock_guard<std::mutex> lock(mutex_);
  if (folders_.insert(normal).second) Save();
  return true;
}

void LibraryFolders::Forget(const std::string& folder) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (folders_.erase(Normal(folder))) Save();
}

bool LibraryFolders::Granted(const std::string& folder) const {
  std::lock_guard<std::mutex> lock(mutex_);
  return folders_.count(Normal(folder)) != 0;
}

std::string LibraryFolders::Resolve(const std::string& path) const {
  const fs::path file = fs::path(path).lexically_normal();
  if (!file.is_absolute()) return {};
  std::lock_guard<std::mutex> lock(mutex_);
  for (const std::string& folder : folders_)
    if (Inside(file, folder)) return file.string();
  return {};
}

std::string LibraryFolders::Rename(const std::string& path, const std::string& name,
                                   std::string& error) const {
  const std::string from = Resolve(path);
  std::error_code status;
  if (from.empty() || !fs::is_regular_file(fs::path(from), status)) {
    error = "The photo is no longer in its folder.";
    return {};
  }
  // One visible name in the photo's own folder: no separators, and no hidden or relative names,
  // which the library would not list.
  if (name.empty() || name.front() == '.' || name.size() > 255 ||
      name.find_first_of(std::string("/\\:\0\n", 5)) != std::string::npos) {
    error = "Use a name without “/” or “:” that does not start with a dot.";
    return {};
  }
  const fs::path to = fs::path(from).parent_path() / name;
  // A change of case only is the same file on a case-insensitive volume.
  if (fs::exists(to, status) && !fs::equivalent(fs::path(from), to, status)) {
    error = "Another file is already named “" + name + "”.";
    return {};
  }
  fs::rename(fs::path(from), to, status);
  if (status) {
    error = status.message();
    return {};
  }
  return Utf8(to);
}

bool LibraryFolders::List(const std::string& folder, const std::set<std::string>& extensions,
                          const std::atomic<bool>& cancelled, std::string& json,
                          std::string& error) {
  const fs::path root(Normal(folder));
  std::error_code status;
  fs::recursive_directory_iterator walk(
      root, fs::directory_options::skip_permission_denied, status);
  if (status) {
    error = status.message();
    return false;
  }
  json = "[";
  bool first = true;
  for (auto end = fs::recursive_directory_iterator(); walk != end; walk.increment(status)) {
    if (status) {
      // An entry that vanished or cannot be read is left out, as the browser's walk leaves it.
      status.clear();
      continue;
    }
    if (cancelled.load()) {
      error = "Cancelled.";
      return false;
    }
    const fs::path& path = walk->path();
    const std::string name = Utf8(path.filename());
    if (name.empty() || name.front() == '.') {
      if (walk->is_directory(status)) walk.disable_recursion_pending();
      continue;
    }
    if (!walk->is_regular_file(status)) continue;
    std::string extension = Utf8(path.extension());
    if (extension.size() < 2) continue;
    extension.erase(0, 1);
    std::transform(extension.begin(), extension.end(), extension.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    if (!extensions.count(extension)) continue;
    long long size = 0, modified = 0;
    if (!Stat(path, size, modified)) continue;
    if (!first) json += ',';
    first = false;
    json += '[';
    AppendJsonString(json, Utf8(path.lexically_relative(root)));
    json += ',' + std::to_string(size) + ',' + std::to_string(modified) + ']';
  }
  json += ']';
  return true;
}

void LibraryFolders::Save() const {
  if (store_.empty()) return;
  const std::string temporary = store_ + ".tmp";
  {
    std::ofstream out(temporary, std::ios::trunc);
    for (const std::string& folder : folders_) out << folder << '\n';
    if (!out) return;
  }
  std::error_code error;
  fs::rename(temporary, store_, error);
}

}  // namespace fotufilm
