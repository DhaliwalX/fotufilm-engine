#include "app/library_methods.h"

#include <filesystem>
#include <memory>
#include <set>
#include <vector>

#include "app/library_folders.h"
#include "app/scheme.h"
#include "include/base/cef_callback.h"
#include "include/cef_browser.h"
#include "include/cef_parser.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"

namespace fotufilm {
namespace {

CefRefPtr<CefDictionaryValue> Fields(const Call& call) {
  return call.params && call.params->GetType() == VTYPE_DICTIONARY
             ? call.params->GetDictionary()
             : CefDictionaryValue::Create();
}

class FolderChosen : public CefRunFileDialogCallback {
 public:
  FolderChosen(std::shared_ptr<LibraryFolders> folders, std::shared_ptr<Reply> reply)
      : folders_(std::move(folders)), reply_(std::move(reply)) {}

  void OnFileDialogDismissed(const std::vector<CefString>& paths) override {
    const std::string path = paths.empty() ? "" : paths.front().ToString();
    if (path.empty()) return reply_->Resolve(nullptr);
    if (!folders_->Grant(path)) return reply_->Reject("The folder could not be opened.");
    std::filesystem::path chosen = std::filesystem::path(path).lexically_normal();
    if (!chosen.has_filename() && chosen.has_relative_path()) chosen = chosen.parent_path();
    CefRefPtr<CefDictionaryValue> folder = CefDictionaryValue::Create();
    folder->SetString("path", chosen.string());
    folder->SetString("name", chosen.filename().string());
    CefRefPtr<CefValue> result = CefValue::Create();
    result->SetDictionary(folder);
    reply_->Resolve(result);
  }

 private:
  const std::shared_ptr<LibraryFolders> folders_;
  const std::shared_ptr<Reply> reply_;
  IMPLEMENT_REFCOUNTING(FolderChosen);
};

// On a file thread: a large folder takes seconds to walk, which neither painting nor renders
// should wait for.
void List(std::string folder, std::set<std::string> extensions,
          std::shared_ptr<std::atomic<bool>> cancelled, std::shared_ptr<Reply> reply) {
  std::string json, error;
  if (!LibraryFolders::List(folder, extensions, *cancelled, json, error))
    return reply->Reject(error, *cancelled ? "AbortError" : "NotReadableError");
  CefRefPtr<CefValue> result = CefValue::Create();
  result->SetDictionary(CefDictionaryValue::Create());
  reply->Resolve(result, json.data(), json.size());
}

// The absolute paths a call names, each inside a chosen folder; empty when any is not.
std::vector<std::string> ChosenPaths(const LibraryFolders& folders, const Call& call) {
  std::vector<std::string> paths;
  CefRefPtr<CefListValue> list = Fields(call)->GetList("paths");
  if (!list) return {};
  for (size_t index = 0; index < list->GetSize(); ++index) {
    std::string path = folders.Resolve(list->GetString(index).ToString());
    if (path.empty()) return {};
    paths.push_back(std::move(path));
  }
  return paths;
}

void Rename(std::shared_ptr<LibraryFolders> folders, std::string path, std::string name,
            std::shared_ptr<Reply> reply) {
  std::string error;
  const std::string renamed = folders->Rename(path, name, error);
  if (renamed.empty()) return reply->Reject(error);
  CefRefPtr<CefDictionaryValue> answer = CefDictionaryValue::Create();
  answer->SetString("path", renamed);
  answer->SetString("name", name);
  CefRefPtr<CefValue> result = CefValue::Create();
  result->SetDictionary(answer);
  reply->Resolve(result);
}

void Trash(std::vector<std::string> paths,
           std::function<bool(const std::string&, std::string&)> trash,
           std::shared_ptr<Reply> reply) {
  CefRefPtr<CefListValue> trashed = CefListValue::Create(), failed = CefListValue::Create();
  for (const std::string& path : paths) {
    std::string error;
    if (trash(path, error)) {
      trashed->SetString(trashed->GetSize(), path);
      continue;
    }
    CefRefPtr<CefDictionaryValue> failure = CefDictionaryValue::Create();
    failure->SetString("path", path);
    failure->SetString("message", error.empty() ? "It could not be moved to the Trash." : error);
    failed->SetDictionary(failed->GetSize(), failure);
  }
  CefRefPtr<CefDictionaryValue> answer = CefDictionaryValue::Create();
  answer->SetList("trashed", trashed);
  answer->SetList("failed", failed);
  CefRefPtr<CefValue> result = CefValue::Create();
  result->SetDictionary(answer);
  reply->Resolve(result);
}

}  // namespace

void RegisterLibraryMethods(Dispatcher& dispatcher, const std::string& store,
                            LibraryFileActions actions) {
  using Thread = Dispatcher::Thread;
  auto folders = std::make_shared<LibraryFolders>(store);

  ServeAppFiles(".library", [folders](const std::string& query) {
    constexpr char kKey[] = "path=";
    if (query.rfind(kKey, 0) != 0) return std::string();
    const std::string path =
        CefURIDecode(query.substr(sizeof(kKey) - 1), true,
                     static_cast<cef_uri_unescape_rule_t>(
                         UU_SPACES | UU_PATH_SEPARATORS |
                         UU_URL_SPECIAL_CHARS_EXCEPT_PATH_SEPARATORS))
            .ToString();
    return folders->Resolve(path);
  });

  dispatcher.Register(
      "chooseLibraryFolder", Thread::kUi, [folders](const Call&, std::shared_ptr<Reply> reply) {
        CefRefPtr<CefFrame> frame = reply->frame();
        CefRefPtr<CefBrowser> browser = frame ? frame->GetBrowser() : nullptr;
        if (!browser) return reply->Reject("There is no window to choose a folder in.");
        browser->GetHost()->RunFileDialog(FILE_DIALOG_OPEN_FOLDER, "Add Folder", "", {},
                                          new FolderChosen(folders, reply));
      });

  dispatcher.Register(
      "listLibraryFolder", Thread::kUi,
      [folders](const Call& call, std::shared_ptr<Reply> reply) {
        CefRefPtr<CefDictionaryValue> fields = Fields(call);
        const std::string folder = fields->GetString("path").ToString();
        if (!folders->Granted(folder))
          return reply->Reject("Add this folder again to read it.", "NotAllowedError");
        std::set<std::string> extensions;
        if (CefRefPtr<CefListValue> list = fields->GetList("extensions"))
          for (size_t index = 0; index < list->GetSize(); ++index)
            extensions.insert(list->GetString(index).ToString());
        CefPostTask(TID_FILE_USER_BLOCKING,
                    base::BindOnce(&List, folder, std::move(extensions), call.cancelled, reply));
      });

  dispatcher.Register("forgetLibraryFolder", Thread::kUi,
                      [folders](const Call& call, std::shared_ptr<Reply> reply) {
                        folders->Forget(Fields(call)->GetString("path").ToString());
                        reply->Resolve(nullptr);
                      });

  dispatcher.Register(
      "renameLibraryFile", Thread::kUi, [folders](const Call& call, std::shared_ptr<Reply> reply) {
        CefRefPtr<CefDictionaryValue> fields = Fields(call);
        CefPostTask(TID_FILE_USER_BLOCKING,
                    base::BindOnce(&Rename, folders, fields->GetString("path").ToString(),
                                   fields->GetString("name").ToString(), reply));
      });

  if (actions.reveal)
    dispatcher.Register("revealLibraryFiles", Thread::kUi,
                        [folders, reveal = actions.reveal](const Call& call,
                                                           std::shared_ptr<Reply> reply) {
                          const std::vector<std::string> paths = ChosenPaths(*folders, call);
                          if (paths.empty() || !reveal(paths))
                            return reply->Reject("The photos could not be shown.");
                          reply->Resolve(nullptr);
                        });

  if (actions.trash)
    dispatcher.Register(
        "trashLibraryFiles", Thread::kUi,
        [folders, trash = actions.trash](const Call& call, std::shared_ptr<Reply> reply) {
          std::vector<std::string> paths = ChosenPaths(*folders, call);
          if (paths.empty()) return reply->Reject("Only photos in the library can be trashed.");
          CefPostTask(TID_FILE_USER_BLOCKING, base::BindOnce(&Trash, std::move(paths), trash,
                                                             reply));
        });
}

}  // namespace fotufilm
