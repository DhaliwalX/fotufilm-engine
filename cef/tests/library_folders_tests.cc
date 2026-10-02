// The library's folder grants and listing on their own, with no CEF: what the page may read and
// what a folder lists. cef/tests/run.sh builds and runs it.
#include <atomic>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>

#include "app/library_folders.h"

using namespace fotufilm;
namespace fs = std::filesystem;

namespace {

int failures = 0;

#define CHECK(condition)                                                     \
  do {                                                                       \
    if (!(condition)) {                                                      \
      std::fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #condition); \
      ++failures;                                                            \
    }                                                                        \
  } while (0)

void Touch(const fs::path& path, size_t bytes) {
  fs::create_directories(path.parent_path());
  std::ofstream(path) << std::string(bytes, 'x');
}

}  // namespace

int main() {
  const fs::path root = fs::temp_directory_path() / "fotufilm-library-tests";
  fs::remove_all(root);
  const fs::path photos = root / "Documents";
  Touch(photos / "a.JPG", 3);
  Touch(photos / "notes.txt", 1);
  Touch(photos / ".hidden.jpg", 1);
  Touch(photos / "trip" / "b.arw", 5);
  Touch(photos / ".cache" / "c.jpg", 1);
  Touch(root / "Other" / "d.jpg", 1);
  const std::string store = (root / "folders.txt").string();

  {
    LibraryFolders folders(store);
    CHECK(!folders.Grant("relative/path"));
    CHECK(!folders.Grant((root / "missing").string()));
    CHECK(folders.Grant(photos.string() + "/"));
    CHECK(folders.Granted(photos.string()));
    // Only files inside a chosen folder are served, however the path is spelled.
    CHECK(folders.Resolve((photos / "trip" / "b.arw").string()) ==
          (photos / "trip" / "b.arw").string());
    CHECK(folders.Resolve((photos / ".." / "Other" / "d.jpg").string()).empty());
    CHECK(folders.Resolve((root / "Other" / "d.jpg").string()).empty());
    CHECK(folders.Resolve(photos.string()).empty());
    CHECK(folders.Resolve("trip/b.arw").empty());
  }
  {
    // Chosen folders outlast the launch, and a forgotten one stops being served.
    LibraryFolders folders(store);
    CHECK(folders.Granted(photos.string()));
    std::atomic<bool> cancelled{false};
    std::string json, error;
    CHECK(LibraryFolders::List(photos.string(), {"jpg", "arw"}, cancelled, json, error));
    CHECK(json.find("\"a.JPG\",3,") != std::string::npos);
    CHECK(json.find("\"trip/b.arw\",5,") != std::string::npos);
    CHECK(json.find("notes") == std::string::npos);
    CHECK(json.find("hidden") == std::string::npos);
    CHECK(json.find("c.jpg") == std::string::npos);
    cancelled = true;
    CHECK(!LibraryFolders::List(photos.string(), {"jpg"}, cancelled, json, error));
    cancelled = false;
    CHECK(!LibraryFolders::List((root / "missing").string(), {"jpg"}, cancelled, json, error));
    // A photo is renamed in its own folder, to a visible name no other file has.
    std::string renamed = folders.Rename((photos / "a.JPG").string(), "first.jpg", error);
    CHECK(renamed == (photos / "first.jpg").string());
    CHECK(fs::exists(photos / "first.jpg") && !fs::exists(photos / "a.JPG"));
    CHECK(folders.Rename((photos / "first.jpg").string(), "trip/x.jpg", error).empty());
    CHECK(folders.Rename((photos / "first.jpg").string(), ".hidden2.jpg", error).empty());
    CHECK(folders.Rename((photos / "first.jpg").string(), "notes.txt", error).empty());
    CHECK(error.find("notes.txt") != std::string::npos);
    CHECK(folders.Rename((root / "Other" / "d.jpg").string(), "e.jpg", error).empty());
    CHECK(fs::exists(root / "Other" / "d.jpg"));
    CHECK(folders.Rename((photos / "missing.jpg").string(), "e.jpg", error).empty());
    folders.Forget(photos.string());
    CHECK(folders.Resolve((photos / "first.jpg").string()).empty());
  }
  CHECK(!LibraryFolders(store).Granted(photos.string()));
  fs::remove_all(root);
  if (failures) {
    std::fprintf(stderr, "%d library folder checks failed\n", failures);
    return 1;
  }
  std::printf("library folder checks passed\n");
  return 0;
}
