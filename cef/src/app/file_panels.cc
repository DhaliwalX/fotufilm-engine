#include "app/file_panels.h"

#include <cstdlib>
#include <filesystem>
#include <memory>
#include <mutex>
#include <set>

namespace fotufilm {
namespace {

namespace fs = std::filesystem;

// The raw formats the editor opens (web/src/media-types.js), which no MIME type names.
constexpr const char* kRawExtensions[] = {
    ".dng", ".cr2", ".cr3", ".crw", ".nef", ".nrw", ".arw", ".srf", ".sr2", ".raf",
    ".orf", ".ori", ".rw2", ".raw", ".rwl", ".pef", ".ptx", ".srw", ".3fr", ".fff",
    ".iiq", ".kdc", ".dcr", ".mrw", ".mos", ".erf", ".mef", ".mdc", ".x3f"};

std::vector<CefString> Filters(const std::string& kind) {
  std::vector<CefString> filters;
  if (kind == "filmPack") return {".fotufilmpack"};
  if (kind != "video") {
    filters.push_back("image/*");
    filters.push_back(".exr");
    for (const char* extension : kRawExtensions) filters.push_back(extension);
  }
  if (kind != "image") filters.push_back("video/*");
  return filters;
}

class Chosen : public CefRunFileDialogCallback {
 public:
  explicit Chosen(std::function<void(std::vector<std::string>)> done) : done_(std::move(done)) {}
  void OnFileDialogDismissed(const std::vector<CefString>& paths) override {
    std::vector<std::string> chosen;
    for (const CefString& path : paths) chosen.push_back(path.ToString());
    done_(std::move(chosen));
  }

 private:
  std::function<void(std::vector<std::string>)> done_;
  IMPLEMENT_REFCOUNTING(Chosen);
};

fs::path Home() {
  const char* home = std::getenv("HOME");
  if (!home) home = std::getenv("USERPROFILE");
  std::error_code error;
  return home ? fs::path(home) : fs::current_path(error);
}

// The folders photographs and movies were last exported to this run.
struct LastFolders {
  std::mutex mutex;
  fs::path folders[2];
};

LastFolders& Last() {
  static LastFolders last;
  return last;
}

// The folder this kind of export was last saved to; Pictures or Videos before that.
fs::path StartingFolder(bool movie) {
  LastFolders& last = Last();
  std::lock_guard<std::mutex> lock(last.mutex);
  std::error_code error;
  if (!last.folders[movie].empty() && fs::is_directory(last.folders[movie], error))
    return last.folders[movie];
  const fs::path standard = Home() / (movie ? "Videos" : "Pictures");
  return fs::is_directory(standard, error) ? standard : Home();
}

void Remember(bool movie, const fs::path& folder) {
  LastFolders& last = Last();
  std::lock_guard<std::mutex> lock(last.mutex);
  last.folders[movie] = folder;
}

std::mutex& SavedMutex() {
  static std::mutex mutex;
  return mutex;
}

std::set<std::string>& Saved() {
  static std::set<std::string> saved;
  return saved;
}

}  // namespace

void ChooseFilesToOpen(CefRefPtr<CefBrowser> browser, const std::string& kind,
                       std::function<void(std::vector<std::string>)> done) {
  if (!browser) return done({});
  const char* title = kind == "filmPack" ? "Add Film Pack" : "Open";
  browser->GetHost()->RunFileDialog(FILE_DIALOG_OPEN_MULTIPLE, title, "", Filters(kind),
                                    new Chosen(std::move(done)));
}

void ChooseExportDestination(CefRefPtr<CefBrowser> browser, const std::string& filename,
                             const std::string& type, const std::string& fixed_directory,
                             std::function<void(const std::string&)> done) {
  auto chosen = [done](const std::string& path) {
    if (!path.empty()) {
      std::lock_guard<std::mutex> lock(SavedMutex());
      Saved().insert(fs::path(path).lexically_normal().string());
    }
    done(path);
  };
  if (!fixed_directory.empty())
    return chosen((fs::path(fixed_directory) / filename).string());
  if (!browser) return done("");
  const bool movie = type.rfind("video/", 0) == 0;
  std::vector<CefString> filters;
  if (!type.empty()) filters.push_back(type);
  browser->GetHost()->RunFileDialog(
      FILE_DIALOG_SAVE, "Export", (StartingFolder(movie) / filename).string(), filters,
      new Chosen([chosen, movie](std::vector<std::string> paths) {
        const std::string path = paths.empty() ? "" : paths.front();
        if (!path.empty()) Remember(movie, fs::path(path).parent_path());
        chosen(path);
      }));
}

void RegisterOpenExport(Dispatcher& dispatcher,
                        std::function<bool(const std::string& path, bool reveal)> open) {
  dispatcher.Register(
      "openExport", Dispatcher::Thread::kUi,
      [open](const Call& call, std::shared_ptr<Reply> reply) {
        CefRefPtr<CefDictionaryValue> fields =
            call.params && call.params->GetType() == VTYPE_DICTIONARY
                ? call.params->GetDictionary()
                : CefDictionaryValue::Create();
        const std::string path =
            fs::path(fields->GetString("path").ToString()).lexically_normal().string();
        {
          std::lock_guard<std::mutex> lock(SavedMutex());
          if (!Saved().count(path))
            return reply->Reject("Only a file this app saved can be opened.");
        }
        std::error_code error;
        if (!fs::exists(path, error))
          return reply->Reject("The file is no longer where it was saved.");
        if (!open(path, fields->GetBool("reveal")))
          return reply->Reject("The file could not be opened.");
        reply->Resolve(nullptr);
      });
}

}  // namespace fotufilm
