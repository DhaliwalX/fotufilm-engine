// The photo library's folders, read by the host rather than the page. Chromium's folder picker
// refuses a home, Documents, Desktop or Downloads folder as a whole ("contains system files"),
// which is where photos live, so the desktop host picks, lists and serves library folders itself.
// The page reaches only folders the person chose, and only files inside them.
//
// No CEF here: the methods that expose this to the page are in library_methods.cc.
#pragma once

#include <atomic>
#include <mutex>
#include <set>
#include <string>

namespace fotufilm {

class LibraryFolders {
 public:
  // `store` keeps the chosen folders between launches, one path per line; empty keeps none.
  explicit LibraryFolders(std::string store);

  // Records a folder the person chose. False for a path that is not an absolute folder.
  bool Grant(const std::string& folder);
  void Forget(const std::string& folder);
  bool Granted(const std::string& folder) const;

  // The file a chosen folder holds at `path` (absolute), or empty for anything outside them.
  std::string Resolve(const std::string& path) const;

  // Renames the file at `path` (absolute, inside a chosen folder) to `name` in the same folder,
  // and answers its new absolute path. Empty with `error` set for a name that is not a plain,
  // visible file name, a name another file has, or a file that cannot be renamed.
  std::string Rename(const std::string& path, const std::string& name, std::string& error) const;

  // Every file under `folder` whose extension, lowercased, is in `extensions`, depth first, as a
  // JSON array of [relative path, size, modified milliseconds]. Hidden files and folders are left
  // out, as the browser's walk leaves them. False with `error` set when the folder cannot be read
  // or `cancelled` turns true.
  static bool List(const std::string& folder, const std::set<std::string>& extensions,
                   const std::atomic<bool>& cancelled, std::string& json, std::string& error);

 private:
  void Save() const;

  const std::string store_;
  mutable std::mutex mutex_;
  std::set<std::string> folders_;
};

}  // namespace fotufilm
