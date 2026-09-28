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

}  // namespace

void RegisterLibraryMethods(Dispatcher& dispatcher, const std::string& store) {
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
}

}  // namespace fotufilm
