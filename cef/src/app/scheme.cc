#include "app/scheme.h"

#include <filesystem>
#include <string_view>

#include "include/cef_parser.h"
#include "include/cef_stream.h"
#include "include/wrapper/cef_stream_resource_handler.h"

namespace fotufilm {
namespace {

namespace fs = std::filesystem;

std::string MimeType(const fs::path& path) {
  const std::string extension = path.extension().string();
  // CEF's table misses the module and WebAssembly types the editor depends on.
  if (extension == ".js" || extension == ".mjs") return "text/javascript";
  if (extension == ".wasm") return "application/wasm";
  if (extension == ".webmanifest") return "application/manifest+json";
  if (extension == ".pack") return "application/octet-stream";
  const std::string type =
      CefGetMimeType(extension.empty() ? "" : extension.substr(1)).ToString();
  return type.empty() ? "application/octet-stream" : type;
}

class AppSchemeHandlerFactory : public CefSchemeHandlerFactory {
 public:
  explicit AppSchemeHandlerFactory(fs::path root)
      : root_(fs::weakly_canonical(std::move(root))) {}

  CefRefPtr<CefResourceHandler> Create(CefRefPtr<CefBrowser>,
                                       CefRefPtr<CefFrame>,
                                       const CefString&,
                                       CefRefPtr<CefRequest> request) override {
    CefURLParts parts;
    if (!CefParseURL(request->GetURL(), parts)) return NotFound();
    std::string path = CefURIDecode(
        CefString(&parts.path), true,
        static_cast<cef_uri_unescape_rule_t>(UU_SPACES |
                                             UU_URL_SPECIAL_CHARS_EXCEPT_PATH_SEPARATORS))
                           .ToString();
    while (!path.empty() && path.front() == '/') path.erase(0, 1);
    if (path.empty()) path = "index.html";

    fs::path file = fs::weakly_canonical(root_ / path);
    // Nothing outside the web build is reachable, whatever the path spells.
    const auto relative = file.lexically_relative(root_);
    if (relative.empty() || *relative.begin() == "..") return NotFound();
    std::error_code error;
    // The editor is one page; unknown paths without an extension load it.
    if (!fs::is_regular_file(file, error) && !file.has_extension())
      file = root_ / "index.html";
    if (!fs::is_regular_file(file, error)) return NotFound();

    CefRefPtr<CefStreamReader> stream =
        fs::file_size(file, error) == 0 ? nullptr : CefStreamReader::CreateForFile(file.string());
    if (!stream) return NotFound();
    CefResponse::HeaderMap headers;
    headers.emplace("Cache-Control", "no-cache");
    return new CefStreamResourceHandler(200, "OK", MimeType(file), headers,
                                        stream);
  }

 private:
  // CEF gives no reader for empty data, and a handler without one crashes when it is read, so
  // the refusal carries a body.
  static CefRefPtr<CefResourceHandler> NotFound() {
    static char body[] = "Not found";
    return new CefStreamResourceHandler(
        404, "Not Found", "text/plain", {},
        CefStreamReader::CreateForData(body, sizeof(body) - 1));
  }

  const fs::path root_;
  IMPLEMENT_REFCOUNTING(AppSchemeHandlerFactory);
};

}  // namespace

void RegisterCustomSchemes(CefRawPtr<CefSchemeRegistrar> registrar) {
  registrar->AddCustomScheme(
      kScheme, CEF_SCHEME_OPTION_STANDARD | CEF_SCHEME_OPTION_SECURE |
                   CEF_SCHEME_OPTION_CORS_ENABLED |
                   CEF_SCHEME_OPTION_FETCH_ENABLED);
}

void RegisterAppSchemeHandler(const std::string& web_root) {
  CefRegisterSchemeHandlerFactory(kScheme, kAppHost,
                                  new AppSchemeHandlerFactory(web_root));
}

}  // namespace fotufilm
