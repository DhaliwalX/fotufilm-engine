#import "platform/mac/main_menu.h"

namespace {

constexpr NSEventModifierFlags kCommand = NSEventModifierFlagCommand;
constexpr NSEventModifierFlags kShift = NSEventModifierFlagShift;
constexpr NSEventModifierFlags kOption = NSEventModifierFlagOption;
constexpr NSEventModifierFlags kControl = NSEventModifierFlagControl;

NSMenu* Submenu(NSMenu* bar, NSString* title) {
  NSMenuItem* holder = [bar addItemWithTitle:title action:nil keyEquivalent:@""];
  NSMenu* menu = [[NSMenu alloc] initWithTitle:title];
  holder.submenu = menu;
  return menu;
}

NSMenuItem* Add(NSMenu* menu, NSString* title, SEL action, NSString* key = @"",
                NSEventModifierFlags modifiers = kCommand) {
  NSMenuItem* item = [menu addItemWithTitle:title action:action keyEquivalent:key];
  if (key.length) item.keyEquivalentModifierMask = modifiers;
  return item;
}

// An item that runs one of the editor's commands.
NSMenuItem* Command(NSMenu* menu, NSString* title, NSString* command, NSString* key = @"",
                    NSEventModifierFlags modifiers = kCommand) {
  NSMenuItem* item = Add(menu, title, @selector(performEditorCommand:), key, modifiers);
  item.representedObject = command;
  return item;
}

NSMenuItem* HelpPage(NSMenu* menu, NSString* title, NSString* page, NSString* key = @"") {
  NSMenuItem* item = Add(menu, title, @selector(openHelpPage:), key);
  item.representedObject = page;
  return item;
}

}  // namespace

static NSString* const kRecentKey = @"RecentDocuments";
static const NSUInteger kRecentLimit = 10;

@implementation FotufilmRecentFiles

+ (NSArray<NSURL*>*)URLs {
  NSMutableArray<NSURL*>* urls = [NSMutableArray array];
  // Filtered on the way out: a file is renamed or thrown away long after it was opened.
  for (NSString* path in [NSUserDefaults.standardUserDefaults stringArrayForKey:kRecentKey])
    if ([NSFileManager.defaultManager fileExistsAtPath:path])
      [urls addObject:[NSURL fileURLWithPath:path]];
  return urls;
}

+ (void)note:(NSURL*)url {
  NSMutableArray<NSString*>* paths =
      [[NSUserDefaults.standardUserDefaults stringArrayForKey:kRecentKey] mutableCopy]
          ?: [NSMutableArray array];
  [paths removeObject:url.path];
  [paths insertObject:url.path atIndex:0];
  if (paths.count > kRecentLimit)
    [paths removeObjectsInRange:NSMakeRange(kRecentLimit, paths.count - kRecentLimit)];
  [NSUserDefaults.standardUserDefaults setObject:paths forKey:kRecentKey];
}

+ (void)clear {
  [NSUserDefaults.standardUserDefaults removeObjectForKey:kRecentKey];
}

@end

// Builds Open Recent as it is pulled down, so it never offers a file that has gone.
@interface FotufilmRecentMenu : NSObject <NSMenuDelegate>
@end

@implementation FotufilmRecentMenu

- (void)menuNeedsUpdate:(NSMenu*)menu {
  [menu removeAllItems];
  NSArray<NSURL*>* urls = [FotufilmRecentFiles URLs];
  for (NSURL* url in urls) {
    NSMenuItem* item = Add(menu, url.lastPathComponent, @selector(openRecentFile:));
    item.representedObject = url;
    item.toolTip = url.path;
    item.image = [NSWorkspace.sharedWorkspace iconForFile:url.path];
    item.image.size = NSMakeSize(16, 16);
  }
  if (!urls.count) {
    [menu addItemWithTitle:@"No Recent Files" action:nil keyEquivalent:@""].enabled = NO;
    return;
  }
  [menu addItem:[NSMenuItem separatorItem]];
  Add(menu, @"Clear Menu", @selector(clearRecentFiles:));
}

@end

// Builds Edit History as it is pulled down, as the Mac app's EditHistoryMenuDelegate does: every
// step of the shown photograph, the one standing ticked (validated with the editor's commands).
@interface FotufilmEditHistoryMenu : NSObject <NSMenuDelegate>
@end

@implementation FotufilmEditHistoryMenu

- (void)menuNeedsUpdate:(NSMenu*)menu {
  [menu removeAllItems];
  id source = [NSApp targetForAction:@selector(editHistoryTitles) to:nil from:nil];
  NSArray<NSString*>* titles =
      [source conformsToProtocol:@protocol(FotufilmEditHistory)] ? [source editHistoryTitles] : @[];
  [titles enumerateObjectsUsingBlock:^(NSString* title, NSUInteger step, BOOL*) {
    Command(menu, title, [NSString stringWithFormat:@"history:%lu", (unsigned long)step]);
  }];
  if (!titles.count)
    [menu addItemWithTitle:@"No Open Edit" action:nil keyEquivalent:@""].enabled = NO;
}

@end

NSMenu* FotufilmMainMenu() {
  static FotufilmRecentMenu* recent = [FotufilmRecentMenu new];
  static FotufilmEditHistoryMenu* history = [FotufilmEditHistoryMenu new];
  NSMenu* bar = [NSMenu new];

  NSMenu* app = Submenu(bar, @"Fotufilm");
  Add(app, @"About Fotufilm", @selector(orderFrontStandardAboutPanel:));
  [app addItem:[NSMenuItem separatorItem]];
  Command(app, @"Settings…", @"settings", @",");
  [app addItem:[NSMenuItem separatorItem]];
  NSMenu* services = Submenu(app, @"Services");
  NSApp.servicesMenu = services;
  [app addItem:[NSMenuItem separatorItem]];
  Add(app, @"Hide Fotufilm", @selector(hide:), @"h");
  Add(app, @"Hide Others", @selector(hideOtherApplications:), @"h", kCommand | kOption);
  Add(app, @"Show All", @selector(unhideAllApplications:));
  [app addItem:[NSMenuItem separatorItem]];
  Add(app, @"Quit Fotufilm", @selector(terminate:), @"q");

  NSMenu* file = Submenu(bar, @"File");
  Add(file, @"Open…", @selector(openDocument:), @"o");
  Command(file, @"Import Scanned Negative…", @"importNegative");
  NSMenu* recents = Submenu(file, @"Open Recent");
  recents.delegate = recent;
  [file addItem:[NSMenuItem separatorItem]];
  Command(file, @"Export…", @"export", @"e");
  [file addItem:[NSMenuItem separatorItem]];
  Command(file, @"Close Photo", @"closePhoto", @"w", kCommand | kShift);
  Add(file, @"Close Window", @selector(performClose:), @"w");

  // Undo, Redo and the clipboard go to the host view, which gives them to a focused text field
  // or, for Undo and Redo, to the editor's history, and names them after the step they change.
  NSMenu* edit = Submenu(bar, @"Edit");
  Add(edit, @"Undo", @selector(undo:), @"z");
  Add(edit, @"Redo", @selector(redo:), @"z", kCommand | kShift);
  Submenu(edit, @"Edit History").delegate = history;
  [edit addItem:[NSMenuItem separatorItem]];
  Command(edit, @"Auto Adjust", @"autoAdjust", @"a", kCommand | kShift);
  Command(edit, @"Sample a Selection", @"sampleSelection", @"s", kCommand | kShift);
  [edit addItem:[NSMenuItem separatorItem]];
  Add(edit, @"Cut", @selector(cut:), @"x");
  Add(edit, @"Copy", @selector(copy:), @"c");
  Add(edit, @"Paste", @selector(paste:), @"v");
  Add(edit, @"Select All", @selector(selectAll:), @"a");
  [edit addItem:[NSMenuItem separatorItem]];
  Command(edit, @"Copy Photo", @"copyPhoto", @"c", kCommand | kShift);

  // The Mac app's grain model, halation and film-list items have no editor action yet.
  NSMenu* film = Submenu(bar, @"Film");
  Command(film, @"New Grain Pattern", @"newGrainPattern", @"g", kCommand | kShift);
  [film addItem:[NSMenuItem separatorItem]];
  Command(film, @"Choose Film Per Photo", @"autoFilm", @"");
  Command(film, @"Forget What I've Taught It", @"forgetFilms", @"");
  [film addItem:[NSMenuItem separatorItem]];
  Command(film, @"Reset All Edits", @"resetEdits", @"r", kCommand | kShift);

  NSMenu* view = Submenu(bar, @"View");
  // ⌘+ rather than ⌘=: the menu shows characters, as the Mac app's does.
  Command(view, @"Zoom In", @"zoomIn", @"+");
  Command(view, @"Zoom Out", @"zoomOut", @"-");
  Command(view, @"Zoom to Fit", @"zoomToFit", @"0");
  [view addItem:[NSMenuItem separatorItem]];
  Command(view, @"Show Original", @"showOriginal", @"\\");
  Command(view, @"Show Histogram", @"histogram", @"h", kCommand | kControl);
  [view addItem:[NSMenuItem separatorItem]];
  Command(view, @"Film Stocks", @"filmSidebar", @"s", kCommand | kControl);
  Command(view, @"Inspector", @"inspector", @"i", kCommand | kOption);
  // The inspector's tabs, numbered as they are stacked (MENU_PANELS in useNativeCommands.js).
  [view addItem:[NSMenuItem separatorItem]];
  NSArray<NSArray<NSString*>*>* panels = @[
    @[ @"Film", @"film" ], @[ @"Expose", @"light" ], @[ @"Develop", @"develop" ],
    @[ @"Print", @"print" ], @[ @"Selective", @"selective" ], @[ @"Crop", @"crop" ]
  ];
  [panels enumerateObjectsUsingBlock:^(NSArray<NSString*>* panel, NSUInteger index, BOOL*) {
    Command(view, panel[0], [@"panel:" stringByAppendingString:panel[1]],
            [NSString stringWithFormat:@"%lu", (unsigned long)index + 1]);
  }];
  [view addItem:[NSMenuItem separatorItem]];
  Add(view, @"Enter Full Screen", @selector(toggleFullScreen:), @"f", kCommand | kControl);

  NSMenu* window = Submenu(bar, @"Window");
  Add(window, @"Minimize", @selector(performMiniaturize:), @"m");
  Add(window, @"Zoom", @selector(performZoom:));
  [window addItem:[NSMenuItem separatorItem]];
  Add(window, @"Bring All to Front", @selector(arrangeInFront:));
  NSApp.windowsMenu = window;

  NSMenu* help = Submenu(bar, @"Help");
  HelpPage(help, @"Fotufilm Help", @"support", @"?");
  [help addItem:[NSMenuItem separatorItem]];
  HelpPage(help, @"Third-Party Notices", @"third-party");
  HelpPage(help, @"Terms of Use", @"terms");
  HelpPage(help, @"Privacy Policy", @"privacy");
  NSApp.helpMenu = help;
  return bar;
}

BOOL FotufilmMenuHasKeyEquivalent(NSMenu* menu, NSEvent* event) {
  const NSEventModifierFlags relevant = kCommand | kShift | kOption | kControl;
  const NSEventModifierFlags flags = event.modifierFlags & relevant;
  NSString* typed = event.charactersIgnoringModifiers.lowercaseString;
  for (NSMenuItem* item in menu.itemArray) {
    if (item.submenu && FotufilmMenuHasKeyEquivalent(item.submenu, event)) return YES;
    NSString* key = item.keyEquivalent;
    if (!key.length || ![key.lowercaseString isEqualToString:typed]) continue;
    NSEventModifierFlags mask = item.keyEquivalentModifierMask & relevant;
    if (![key isEqualToString:key.lowercaseString]) mask |= kShift;
    // A shifted character (⌘+, ⌘?) is typed with Shift its equivalent does not name.
    const BOOL letter = [NSCharacterSet.letterCharacterSet characterIsMember:[key characterAtIndex:0]];
    if (flags == mask || (!letter && (flags & ~kShift) == (mask & ~kShift))) return YES;
  }
  return NO;
}
