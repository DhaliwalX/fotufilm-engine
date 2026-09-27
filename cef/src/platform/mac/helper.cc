// Renderer, GPU and utility processes. Each loads the framework from inside the app bundle.
#include "app/browser_app.h"
#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

#if defined(CEF_USE_SANDBOX)
#include "include/cef_sandbox_mac.h"
#endif

int main(int argc, char* argv[]) {
#if defined(CEF_USE_SANDBOX)
  CefScopedSandboxContext sandbox;
  if (!sandbox.Initialize(argc, argv)) return 1;
#endif
  CefScopedLibraryLoader library;
  if (!library.LoadInHelper()) return 1;
  CefMainArgs arguments(argc, argv);
  CefRefPtr<CefApp> app = new fotufilm::ChildApp();
  return CefExecuteProcess(arguments, app, nullptr);
}
