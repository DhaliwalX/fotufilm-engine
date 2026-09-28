#import <Cocoa/Cocoa.h>

#include <memory>
#include <string>

#include "app/browser_app.h"
#include "app/host_capabilities.h"
#include "app/scheme.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "bridge/dispatcher.h"
#if defined(FOTUFILM_WITH_ENGINE)
#include "engine/engine_bridge.h"
#endif
#include "include/cef_application_mac.h"
#include "include/cef_command_line.h"
#include "include/wrapper/cef_library_loader.h"
#import "platform/mac/export_files.h"
#import "platform/mac/host_window.h"
#import "platform/mac/main_menu.h"
#include "switches.h"

namespace {

std::unique_ptr<fotufilm::Dispatcher> g_dispatcher;
#if defined(FOTUFILM_WITH_ENGINE)
std::unique_ptr<fotufilm::EngineBridge> g_engine;
#endif
FotufilmHostWindow* g_window = nil;

std::string ResourcePath(NSString* name) {
  return [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:name]
      .UTF8String;
}

// Library records and settings live in IndexedDB and local storage, so the profile must persist.
std::string ProfilePath() {
  NSURL* support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                        inDomains:NSUserDomainMask]
                       .firstObject;
  NSURL* profile = [support URLByAppendingPathComponent:@"Fotufilm Desktop" isDirectory:YES];
  [NSFileManager.defaultManager createDirectoryAtURL:profile
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil];
  return profile.path.UTF8String;
}

// The plug-ins the engine installs (`capabilities.plugins`), for the Plugins menu.
NSArray<NSDictionary*>* Plugins(const std::string& capabilities) {
  NSData* json = [NSData dataWithBytes:capabilities.data() length:capabilities.size()];
  NSDictionary* fields = capabilities.empty()
                             ? nil
                             : [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
  if (![fields isKindOfClass:NSDictionary.class]) return @[];
  NSArray* plugins = fields[@"plugins"];
  return [plugins isKindOfClass:NSArray.class] ? plugins : @[];
}

// This host's capabilities (app/host_capabilities.h). With the engine it draws the photograph
// itself, beneath the page (`imageLayer`), and opens what it saved (`openExport`,
// web/src/backend/README.md).
CefRefPtr<CefDictionaryValue> HostCapabilities() {
  CefRefPtr<CefDictionaryValue> host = CefDictionaryValue::Create();
  host->SetString("platform", "macos");
#if defined(FOTUFILM_WITH_ENGINE)
  host->SetBool("imageLayer", true);
  CefRefPtr<CefDictionaryValue> open = CefDictionaryValue::Create();
  open->SetString("reveal", "Show in Finder");
  host->SetDictionary("openExport", open);
#endif
  return host;
}

// Files the system asked to open before the window existed.
NSMutableArray<NSURL*>* g_pending_urls = [NSMutableArray array];

}  // namespace

// Files and help, for the whole application: Finder opens (double-click, Open With, the Dock icon),
// File > Open and Open Recent, and the help pages. Files go to the editor by path.
@interface FotufilmAppDelegate : NSObject <NSApplicationDelegate, NSMenuItemValidation,
                                           FotufilmMenuActions>
@end

@implementation FotufilmAppDelegate

- (void)openURLs:(NSArray<NSURL*>*)urls {
  if (g_window && !g_window.closed)
    [g_window openURLs:urls];
  else
    [g_pending_urls addObjectsFromArray:urls];
}

- (void)application:(NSApplication*)application openURLs:(NSArray<NSURL*>*)urls {
  [self openURLs:urls];
}

// Finder › Services › Open in Fotufilm Desktop (NSServices in Info.plist), as the Mac app's
// FinderServiceProvider answers it; several files open together here.
- (void)openInFotufilm:(NSPasteboard*)pasteboard
              userData:(NSString*)userData
                 error:(NSString**)error {
  NSArray<NSURL*>* urls = [pasteboard readObjectsForClasses:@[ NSURL.class ]
                                                    options:@{
                                                      NSPasteboardURLReadingFileURLsOnlyKey : @YES,
                                                      NSPasteboardURLReadingContentsConformToTypesKey :
                                                          @[ UTTypeImage.identifier, UTTypeMovie.identifier ],
                                                    }];
  if (!urls.count) {
    if (error) *error = @"Choose a photo or video to open in Fotufilm.";
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [self openURLs:urls];
    [NSApp activateIgnoringOtherApps:YES];
  });
}

- (void)openDocument:(id)sender {
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.allowedContentTypes = @[ UTTypeImage, UTTypeMovie ];
  panel.allowsMultipleSelection = YES;
  panel.canChooseDirectories = NO;
  auto finish = ^(NSModalResponse response) {
    if (response == NSModalResponseOK) [self openURLs:panel.URLs];
  };
  if (NSWindow* window = g_window.window)
    [panel beginSheetModalForWindow:window completionHandler:finish];
  else
    finish([panel runModal]);
}

// The Mac app's File › Import Film Pack…: the chosen packs go to the editor by path, as a Finder
// double-click on one does, and the engine installs them where the Mac app keeps its packs.
- (void)importFilmPack:(id)sender {
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  if (UTType* pack = [UTType typeWithFilenameExtension:@"fotufilmpack"])
    panel.allowedContentTypes = @[ pack ];
  panel.allowsMultipleSelection = YES;
  panel.canChooseDirectories = NO;
  panel.prompt = @"Add";
  panel.message = @"Choose a Fotufilm film pack to add to your library.";
  auto finish = ^(NSModalResponse response) {
    if (response == NSModalResponseOK) [self openURLs:panel.URLs];
  };
  if (NSWindow* window = g_window.window)
    [panel beginSheetModalForWindow:window completionHandler:finish];
  else
    finish([panel runModal]);
}

- (void)openRecentFile:(id)sender {
  if (NSURL* url = [sender representedObject]) [self openURLs:@[ url ]];
}

- (void)useSamplePhoto:(id)sender {
  [g_window openSamplePhoto];
}

- (void)clearRecentFiles:(id)sender {
  [FotufilmRecentFiles clear];
}

// The same pages the native Mac app opens.
- (void)openHelpPage:(id)sender {
  NSString* page = [sender representedObject];
  [NSWorkspace.sharedWorkspace
      openURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://fotufilm.com/%@.html", page]]];
}

- (BOOL)validateMenuItem:(NSMenuItem*)item {
  const SEL action = item.action;
  // Nothing opens while the editor is exporting, as its own import buttons are greyed.
  if (action == @selector(openDocument:) || action == @selector(openRecentFile:) ||
      action == @selector(useSamplePhoto:))
    return !g_window || [g_window commandEnabled:@"open"];
  // Only an engine that installs packs offers it (the `filmPacks` capability), and never while
  // the editor exports.
  if (action == @selector(importFilmPack:))
    return g_window && [g_window commandEnabled:@"importFilmPack"];
  return YES;
}

@end

// CEF runs the message loop and needs to know when AppKit is dispatching an event.
@interface FotufilmApplication : NSApplication <CefAppProtocol>
@end

@implementation FotufilmApplication {
  BOOL _handlingSendEvent;
}

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sending;
  [super sendEvent:event];
}

// AppKit's terminate would exit under CEF's feet: close the browser and let the loop end.
- (void)terminate:(id)sender {
  if (g_window && !g_window.closed)
    [g_window requestClose];
  else
    CefQuitMessageLoop();
}

@end

int main(int argc, char* argv[]) {
  CefScopedLibraryLoader library;
  if (!library.LoadInMain()) return 1;

  @autoreleasepool {
    [FotufilmApplication sharedApplication];
    FotufilmAppDelegate* delegate = [FotufilmAppDelegate new];
    NSApp.delegate = delegate;
    NSApp.servicesProvider = delegate;
    // The View menu carries Enter Full Screen itself; AppKit would add a second.
    [NSUserDefaults.standardUserDefaults registerDefaults:@{@"NSFullScreenMenuItemEverywhere" : @NO}];
    std::string capabilities;
#if defined(FOTUFILM_WITH_ENGINE)
    capabilities = fotufilm::EngineBridge::Capabilities();
#endif
    NSApp.mainMenu = FotufilmMainMenu(Plugins(capabilities));

    CefMainArgs arguments(argc, argv);
    CefRefPtr<CefCommandLine> command_line = CefCommandLine::CreateCommandLine();
    command_line->InitFromArgv(argc, argv);

    fotufilm::BrowserApp::Options options;
    std::string url = std::string(fotufilm::kAppOrigin) + "/";
    options.web_root = ResourcePath(@"web");
    if (command_line->HasSwitch(fotufilm::switches::kWebRoot))
      options.web_root =
          command_line->GetSwitchValue(fotufilm::switches::kWebRoot).ToString();
    if (command_line->HasSwitch(fotufilm::switches::kDiagnostics)) {
      options.web_root = ResourcePath(@"diagnostics");
      url += "diagnostics.html";
    }
    if (command_line->HasSwitch(fotufilm::switches::kDevUrl)) {
      url = command_line->GetSwitchValue(fotufilm::switches::kDevUrl).ToString();
      NSURL* dev = [NSURL URLWithString:@(url.c_str())];
      options.dev_origin = std::string(dev.scheme.UTF8String) + "://" + dev.host.UTF8String +
                           (dev.port ? ":" + std::string(dev.port.stringValue.UTF8String) : "");
    }
    options.transport_global = fotufilm::switches::kDefaultTransportGlobal;
    options.capabilities = fotufilm::WithHostCapabilities(capabilities, HostCapabilities());

    g_dispatcher = std::make_unique<fotufilm::Dispatcher>();
#if defined(FOTUFILM_WITH_ENGINE)
    g_engine = std::make_unique<fotufilm::EngineBridge>(*g_dispatcher);
    const std::string export_dir =
        command_line->GetSwitchValue(fotufilm::switches::kExportDir).ToString();
    g_engine->SetDestinationPicker([export_dir](const std::string& filename,
                                                const std::string& type,
                                                std::function<void(const std::string&)> done) {
      fotufilm::ChooseExportDestination(filename, type, export_dir, std::move(done));
    });
    fotufilm::RegisterExportFiles(*g_dispatcher);
#endif
    CefRefPtr<fotufilm::BrowserApp> app =
        new fotufilm::BrowserApp(options, [url] {
          g_window = [[FotufilmHostWindow alloc] initWithURL:url
                                                  dispatcher:g_dispatcher.get()];
#if defined(FOTUFILM_WITH_ENGINE)
          g_engine->SetPresenter(g_window.presenter);
#endif
          [g_window openURLs:g_pending_urls];
          [g_pending_urls removeAllObjects];
        });

    CefSettings settings;
    settings.windowless_rendering_enabled = true;
#if !defined(CEF_USE_SANDBOX)
    settings.no_sandbox = true;
#endif
    // CEF wants the cache inside the root as spelled after symbolic links (/tmp is /private/tmp).
    const std::string profile =
        command_line->HasSwitch(fotufilm::switches::kProfile)
            ? std::string(@(command_line->GetSwitchValue(fotufilm::switches::kProfile)
                                .ToString()
                                .c_str())
                              .stringByResolvingSymlinksInPath.UTF8String)
            : ProfilePath();
    CefString(&settings.root_cache_path) = profile;
    CefString(&settings.cache_path) = profile + "/Default";
    settings.log_severity = LOGSEVERITY_WARNING;
    if (!CefInitialize(arguments, settings, app, nullptr))
      return CefGetExitCode();

    CefRunMessageLoop();
    g_window = nil;
    g_dispatcher->Shutdown();
    CefShutdown();
#if defined(FOTUFILM_WITH_ENGINE)
    g_engine.reset();
#endif
    g_dispatcher.reset();
  }
  return 0;
}
