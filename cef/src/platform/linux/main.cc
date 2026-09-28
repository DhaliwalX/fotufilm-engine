// Fotufilm Desktop on Linux: the editor in a CEF Views window (app/windowed_host.h), the engine
// beside it (libfotufilm.so, developing on CUDA or Vulkan), and one executable for every CEF
// process. Everything the app reads sits beside the executable:
//
//   fotufilm        this program          web/        the editor
//   libcef.so …     CEF and its data      resources/  the engine's films and camera profiles
//   libfotufilm.so  the engine            fotufilm.png the window icon
#include <unistd.h>

#include <cstdlib>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

#include "app/browser_app.h"
#include "app/file_panels.h"
#include "app/host_capabilities.h"
#include "app/library_methods.h"
#include "app/scheme.h"
#include "app/windowed_host.h"
#include "bridge/dispatcher.h"
#if defined(FOTUFILM_WITH_ENGINE)
#include "engine/engine_bridge.h"
#endif
#include "include/base/cef_compiler_specific.h"
#include "include/cef_command_line.h"
#include "platform/linux/system_open.h"
#include "switches.h"

namespace {

namespace fs = std::filesystem;

fs::path ExecutableDirectory() {
  std::error_code error;
  const fs::path executable = fs::read_symlink("/proc/self/exe", error);
  return error ? fs::current_path(error) : executable.parent_path();
}

// Library records and settings live in IndexedDB and local storage, so the profile must persist.
fs::path ProfilePath() {
  const char* config = std::getenv("XDG_CONFIG_HOME");
  const char* home = std::getenv("HOME");
  const fs::path root = config && *config ? fs::path(config)
                        : home            ? fs::path(home) / ".config"
                                          : fs::temp_directory_path();
  fs::path profile = root / "Fotufilm";
  std::error_code error;
  fs::create_directories(profile, error);
  return fs::weakly_canonical(profile, error);
}

// The scheme and origin of a development server URL, for the renderer's trust check.
std::string Origin(const std::string& url) {
  const size_t scheme = url.find("://");
  if (scheme == std::string::npos) return {};
  const size_t path = url.find('/', scheme + 3);
  return url.substr(0, path);
}

// This host's capabilities (app/host_capabilities.h): it reads the photo library's folders and
// opens or shows what it saved; the page draws the photograph itself.
CefRefPtr<CefDictionaryValue> HostCapabilities() {
  CefRefPtr<CefDictionaryValue> host = CefDictionaryValue::Create();
  host->SetString("platform", "linux");
  host->SetBool("libraryFolders", true);
#if defined(FOTUFILM_WITH_ENGINE)
  CefRefPtr<CefDictionaryValue> open = CefDictionaryValue::Create();
  open->SetString("reveal", "Show in Folder");
  host->SetDictionary("openExport", open);
#endif
  return host;
}

}  // namespace

// Chromium gives each process it forks from the zygote a new stack canary, so a child returning
// through a guarded main would abort (CEF's samples leave main unguarded for the same reason).
NO_STACK_PROTECTOR int main(int argc, char* argv[]) {
#if !defined(CEF_USE_SANDBOX)
  // The settings' no_sandbox turns off CEF's sandbox; Chromium's zygote checks for the switch
  // before any CEF callback could add it.
  std::vector<char*> with_switch(argv, argv + argc);
  static char no_sandbox[] = "--no-sandbox";
  with_switch.push_back(no_sandbox);
  with_switch.push_back(nullptr);
  argc = static_cast<int>(with_switch.size()) - 1;
  argv = with_switch.data();
#endif
  CefMainArgs arguments(argc, argv);
  // Renderers, the GPU process and the rest run this same program.
  CefRefPtr<fotufilm::ChildApp> child = new fotufilm::ChildApp();
  if (const int code = CefExecuteProcess(arguments, child, nullptr); code >= 0) return code;

  const fs::path directory = ExecutableDirectory();
  // The engine finds its films and camera profiles here (FilmStockPack, BundledCameraProfiles).
  const fs::path resources = directory / "resources";
  setenv("FOTUFILM_RESOURCES", resources.c_str(), 0);
  setenv("FOTUFILM_STOCKS", (resources / "Stocks").c_str(), 0);

  CefRefPtr<CefCommandLine> command_line = CefCommandLine::CreateCommandLine();
  command_line->InitFromArgv(argc, argv);

  std::string capabilities;
#if defined(FOTUFILM_WITH_ENGINE)
  capabilities = fotufilm::EngineBridge::Capabilities();
#endif
  fotufilm::BrowserApp::Options options;
  std::string url = std::string(fotufilm::kAppOrigin) + "/";
  options.web_root = (directory / "web").string();
  if (command_line->HasSwitch(fotufilm::switches::kWebRoot))
    options.web_root = command_line->GetSwitchValue(fotufilm::switches::kWebRoot).ToString();
  if (command_line->HasSwitch(fotufilm::switches::kDiagnostics)) {
    options.web_root = (directory / "diagnostics").string();
    url += "diagnostics.html";
  }
  if (command_line->HasSwitch(fotufilm::switches::kDevUrl)) {
    url = command_line->GetSwitchValue(fotufilm::switches::kDevUrl).ToString();
    options.dev_origin = Origin(url);
  }
  options.transport_global = fotufilm::switches::kDefaultTransportGlobal;
  options.capabilities = fotufilm::WithHostCapabilities(capabilities, HostCapabilities());

  std::error_code error;
  const std::string profile =
      command_line->HasSwitch(fotufilm::switches::kProfile)
          ? fs::weakly_canonical(
                command_line->GetSwitchValue(fotufilm::switches::kProfile).ToString(), error)
                .string()
          : ProfilePath().string();

  auto dispatcher = std::make_unique<fotufilm::Dispatcher>();
  fotufilm::WindowedHost::Options window;
  window.url = url;
  window.icon = (directory / "fotufilm.png").string();
  auto host = std::make_unique<fotufilm::WindowedHost>(*dispatcher, window);
  fotufilm::RegisterLibraryMethods(*dispatcher, profile + "/library-folders.txt");
#if defined(FOTUFILM_WITH_ENGINE)
  auto engine = std::make_unique<fotufilm::EngineBridge>(*dispatcher);
  const std::string export_dir =
      command_line->GetSwitchValue(fotufilm::switches::kExportDir).ToString();
  fotufilm::WindowedHost* shown = host.get();
  engine->SetDestinationPicker([shown, export_dir](const std::string& filename,
                                                   const std::string& type,
                                                   std::function<void(const std::string&)> done) {
    fotufilm::ChooseExportDestination(shown->browser(), filename, type, export_dir,
                                      std::move(done));
  });
  fotufilm::RegisterOpenExport(*dispatcher, fotufilm::OpenWithSystem);
#endif

  // Files named on the command line (a file manager's Open With) open once the editor listens.
  CefCommandLine::ArgumentList files;
  command_line->GetArguments(files);
  std::vector<std::string> paths;
  for (const CefString& file : files) {
    const fs::path path = fs::absolute(file.ToString(), error);
    if (!error && fs::is_regular_file(path, error)) paths.push_back(path.string());
  }

  CefRefPtr<fotufilm::BrowserApp> app = new fotufilm::BrowserApp(options, [&host, paths] {
    host->Show();
    host->Open(paths);
  });

  CefSettings settings;
#if !defined(CEF_USE_SANDBOX)
  settings.no_sandbox = true;
#endif
  CefString(&settings.root_cache_path) = profile;
  CefString(&settings.cache_path) = profile + "/Default";
  settings.log_severity = LOGSEVERITY_WARNING;
  if (!CefInitialize(arguments, settings, app, nullptr)) return CefGetExitCode();

  CefRunMessageLoop();
  dispatcher->Shutdown();
  host.reset();
  CefShutdown();
#if defined(FOTUFILM_WITH_ENGINE)
  engine.reset();
#endif
  dispatcher.reset();
  return 0;
}
