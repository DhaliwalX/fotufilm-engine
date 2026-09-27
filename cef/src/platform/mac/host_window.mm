#import "platform/mac/host_window.h"

#import <QuartzCore/QuartzCore.h>

#include <cstring>
#include <memory>
#include <set>
#include <vector>

#include "app/client.h"
#include "app/view_delegate.h"
#include "bridge/dispatcher.h"
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_version.h"
#import "platform/mac/compositor.h"
#import "platform/mac/main_menu.h"

@class FotufilmHostView;

namespace {

uint32_t Modifiers(NSEventModifierFlags flags) {
  uint32_t modifiers = 0;
  if (flags & NSEventModifierFlagCapsLock) modifiers |= EVENTFLAG_CAPS_LOCK_ON;
  if (flags & NSEventModifierFlagShift) modifiers |= EVENTFLAG_SHIFT_DOWN;
  if (flags & NSEventModifierFlagControl) modifiers |= EVENTFLAG_CONTROL_DOWN;
  if (flags & NSEventModifierFlagOption) modifiers |= EVENTFLAG_ALT_DOWN;
  if (flags & NSEventModifierFlagCommand) modifiers |= EVENTFLAG_COMMAND_DOWN;
  if (flags & NSEventModifierFlagNumericPad) modifiers |= EVENTFLAG_IS_KEY_PAD;
  const NSUInteger buttons = [NSEvent pressedMouseButtons];
  if (buttons & (1 << 0)) modifiers |= EVENTFLAG_LEFT_MOUSE_BUTTON;
  if (buttons & (1 << 1)) modifiers |= EVENTFLAG_RIGHT_MOUSE_BUTTON;
  if (buttons & (1 << 2)) modifiers |= EVENTFLAG_MIDDLE_MOUSE_BUTTON;
  return modifiers;
}

CefKeyEvent KeyEvent(NSEvent* event, cef_key_event_type_t type) {
  CefKeyEvent key;
  key.type = type;
  // CEF derives the Windows key code from the macOS one.
  key.native_key_code = [event keyCode];
  key.modifiers = Modifiers([event modifierFlags]);
  if ([event type] != NSEventTypeFlagsChanged) {
    NSString* characters = [event characters];
    NSString* unmodified = [event charactersIgnoringModifiers];
    if (characters.length) key.character = [characters characterAtIndex:0];
    if (unmodified.length) key.unmodified_character = [unmodified characterAtIndex:0];
  }
  return key;
}

// Characters a key types: printable ones and Return, never AppKit's private function-key range.
bool Typed(unichar character) {
  if (character >= 0xF700 && character <= 0xF8FF) return false;
  return character == '\r' || (character >= 0x20 && character != 0x7F);
}

CefRefPtr<CefValue> Dictionary(CefRefPtr<CefDictionaryValue> dictionary) {
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(dictionary);
  return value;
}

// JSON numbers arrive as integers when they are whole.
double Number(CefRefPtr<CefDictionaryValue> fields, const char* key) {
  if (!fields || !fields->HasKey(key)) return 0;
  return fields->GetType(key) == VTYPE_INT ? fields->GetInt(key)
                                           : fields->GetDouble(key);
}

}  // namespace

@interface FotufilmHostWindow () <FotufilmMenuActions>
- (void)browserClosed;
- (CGRect)windowDragRegion:(NSPoint)point;
@end

// The view the browser draws into. It owns the compositor's layer and turns AppKit input into
// CEF events.
@interface FotufilmHostView : NSView <NSMenuItemValidation>
@property(nonatomic, weak) FotufilmHostWindow* owner;
@property(nonatomic, readonly) FotufilmCompositor* compositor;
@property(nonatomic) CefRefPtr<CefBrowser> browser;
// The last key sent down, offered to the menu bar if the page leaves it unhandled.
@property(nonatomic, strong) NSEvent* lastKeyDown;
// What the page last said it would do with the files dragged over it.
@property(nonatomic) cef_drag_operations_mask_t dragOperation;
// Sizes the compositor to the view and tells the browser.
- (void)layoutMetrics;
// A moving test layer needs a frame every refresh; a still one does not.
- (void)setAnimating:(BOOL)animating;
// Composites at the next refresh.
- (void)setNeedsRender;
@end

@implementation FotufilmHostView {
  NSTrackingArea* _tracking;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if (!(self = [super initWithFrame:frame])) return nil;
  self.wantsLayer = YES;
  self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
  CAMetalLayer* layer = (CAMetalLayer*)self.layer;
  _compositor = [[FotufilmCompositor alloc] initWithLayer:layer];
  [self registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
  return self;
}

- (CALayer*)makeBackingLayer {
  return [CAMetalLayer layer];
}

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
  return YES;
}

- (BOOL)becomeFirstResponder {
  if (_browser) _browser->GetHost()->SetFocus(true);
  return YES;
}

- (BOOL)resignFirstResponder {
  if (_browser) _browser->GetHost()->SetFocus(false);
  return YES;
}

- (void)layoutMetrics {
  const CGFloat scale = self.window ? self.window.backingScaleFactor : 2;
  [_compositor resizeToPoints:self.bounds.size scale:scale];
  if (_browser) _browser->GetHost()->WasResized();
  [self setNeedsRender];
}

- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  [self layoutMetrics];
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  if (_browser) _browser->GetHost()->NotifyScreenInfoChanged();
  [self layoutMetrics];
}

- (void)updateTrackingAreas {
  if (_tracking) [self removeTrackingArea:_tracking];
  _tracking = [[NSTrackingArea alloc]
      initWithRect:NSZeroRect
           options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                   NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:_tracking];
  [super updateTrackingAreas];
}

- (void)setNeedsRender {
  [_compositor setNeedsDisplay];
}

- (void)setAnimating:(BOOL)animating {
  _compositor.continuous = animating;
}

#pragma mark Mouse

- (CefMouseEvent)mouseEvent:(NSEvent*)event {
  const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  CefMouseEvent mouse;
  mouse.x = static_cast<int>(point.x);
  mouse.y = static_cast<int>(point.y);
  mouse.modifiers = Modifiers(event.modifierFlags);
  return mouse;
}

- (void)click:(NSEvent*)event button:(cef_mouse_button_type_t)button up:(bool)up {
  if (!_browser) return;
  _browser->GetHost()->SendMouseClickEvent([self mouseEvent:event], button, up,
                                           static_cast<int>(event.clickCount));
}

- (void)mouseDown:(NSEvent*)event {
  const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  // Empty toolbar space moves the window, as a title bar would.
  if (!CGRectIsNull([self.owner windowDragRegion:point])) {
    if (event.clickCount == 2)
      [self.window performZoom:nil];
    else
      [self.window performWindowDragWithEvent:event];
    return;
  }
  [self.window makeFirstResponder:self];
  [self click:event button:MBT_LEFT up:false];
}
- (void)mouseUp:(NSEvent*)event {
  [self click:event button:MBT_LEFT up:true];
}
- (void)rightMouseDown:(NSEvent*)event {
  [self click:event button:MBT_RIGHT up:false];
}
- (void)rightMouseUp:(NSEvent*)event {
  [self click:event button:MBT_RIGHT up:true];
}
- (void)otherMouseDown:(NSEvent*)event {
  [self click:event button:MBT_MIDDLE up:false];
}
- (void)otherMouseUp:(NSEvent*)event {
  [self click:event button:MBT_MIDDLE up:true];
}

- (void)mouseMoved:(NSEvent*)event {
  if (_browser)
    _browser->GetHost()->SendMouseMoveEvent([self mouseEvent:event], false);
}
- (void)mouseDragged:(NSEvent*)event {
  [self mouseMoved:event];
}
- (void)rightMouseDragged:(NSEvent*)event {
  [self mouseMoved:event];
}
- (void)otherMouseDragged:(NSEvent*)event {
  [self mouseMoved:event];
}
- (void)mouseExited:(NSEvent*)event {
  if (_browser)
    _browser->GetHost()->SendMouseMoveEvent([self mouseEvent:event], true);
}

- (void)scrollWheel:(NSEvent*)event {
  if (!_browser) return;
  // Trackpads report pixels; wheels report lines, which Chromium scrolls 40 pixels at a time.
  const CGFloat scale = event.hasPreciseScrollingDeltas ? 1 : 40;
  _browser->GetHost()->SendMouseWheelEvent(
      [self mouseEvent:event], static_cast<int>(event.scrollingDeltaX * scale),
      static_cast<int>(event.scrollingDeltaY * scale));
}

- (void)magnifyWithEvent:(NSEvent*)event {
  if (!_browser) return;
  // Chromium hands pages a pinch as a wheel event with Control held; the editor zooms on it.
  CefMouseEvent mouse = [self mouseEvent:event];
  mouse.modifiers |= EVENTFLAG_CONTROL_DOWN;
  _browser->GetHost()->SendMouseWheelEvent(
      mouse, 0, static_cast<int>(event.magnification * 100));
}

#pragma mark Keyboard

- (void)keyDown:(NSEvent*)event {
  if (!_browser) return;
  _lastKeyDown = event;
  CefRefPtr<CefBrowserHost> host = _browser->GetHost();
  host->SendKeyEvent(KeyEvent(event, KEYEVENT_RAWKEYDOWN));
  // Shortcuts type nothing.
  if (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl))
    return;
  NSString* characters = event.characters;
  for (NSUInteger index = 0; index < characters.length; ++index) {
    const unichar character = [characters characterAtIndex:index];
    if (!Typed(character)) continue;
    CefKeyEvent typed = KeyEvent(event, KEYEVENT_CHAR);
    typed.character = typed.unmodified_character = character;
    host->SendKeyEvent(typed);
  }
}

- (void)keyUp:(NSEvent*)event {
  if (_browser) _browser->GetHost()->SendKeyEvent(KeyEvent(event, KEYEVENT_KEYUP));
}

- (void)flagsChanged:(NSEvent*)event {
  if (!_browser) return;
  // A modifier went down if its flag is now set.
  NSEventModifierFlags flag = 0;
  switch (event.keyCode) {
    case 56: case 60: flag = NSEventModifierFlagShift; break;
    case 59: case 62: flag = NSEventModifierFlagControl; break;
    case 58: case 61: flag = NSEventModifierFlagOption; break;
    case 54: case 55: flag = NSEventModifierFlagCommand; break;
    case 57: flag = NSEventModifierFlagCapsLock; break;
    default: return;
  }
  const bool down = event.modifierFlags & flag;
  _browser->GetHost()->SendKeyEvent(
      KeyEvent(event, down ? KEYEVENT_RAWKEYDOWN : KEYEVENT_KEYUP));
}

// The menu bar answers its own shortcuts before the page, so a key a menu item takes never also
// reaches the page's bindings; one whose item is disabled goes nowhere. Other Command keys reach
// the page, as in a browser tab.
- (BOOL)performKeyEquivalent:(NSEvent*)event {
  if (self.window.firstResponder != self || event.type != NSEventTypeKeyDown)
    return NO;
  if ([NSApp.mainMenu performKeyEquivalent:event] ||
      FotufilmMenuHasKeyEquivalent(NSApp.mainMenu, event))
    return YES;
  [self keyDown:event];
  return YES;
}

#pragma mark Editing (menu bar)

- (CefRefPtr<CefFrame>)focusedFrame {
  return _browser ? _browser->GetFocusedFrame() : nullptr;
}
// Undo and Redo edit a focused text field, and otherwise the photograph's history.
- (void)undo:(id)sender {
  if (!_owner.pageEditsText) return [_owner sendCommand:@"undo"];
  if (auto f = [self focusedFrame]) f->Undo();
}
- (void)redo:(id)sender {
  if (!_owner.pageEditsText) return [_owner sendCommand:@"redo"];
  if (auto f = [self focusedFrame]) f->Redo();
}
- (void)cut:(id)sender { if (auto f = [self focusedFrame]) f->Cut(); }
- (void)copy:(id)sender { if (auto f = [self focusedFrame]) f->Copy(); }
- (void)paste:(id)sender { if (auto f = [self focusedFrame]) f->Paste(); }
- (void)selectAll:(id)sender { if (auto f = [self focusedFrame]) f->SelectAll(); }

- (BOOL)validateMenuItem:(NSMenuItem*)item {
  const SEL action = item.action;
  const BOOL text = _owner.pageEditsText;
  if (action == @selector(undo:)) return text || [_owner commandEnabled:@"undo"];
  if (action == @selector(redo:)) return text || [_owner commandEnabled:@"redo"];
  if (action == @selector(cut:) || action == @selector(copy:) || action == @selector(paste:) ||
      action == @selector(selectAll:))
    return text;
  return YES;
}

#pragma mark Dropping files

// Files dragged in from the Finder become a CEF drag, so the page's own drop handling (the
// viewer's highlight, the import) takes them as it would in a browser.
- (CefMouseEvent)dragEvent:(id<NSDraggingInfo>)info {
  const NSPoint point = [self convertPoint:info.draggingLocation fromView:nil];
  CefMouseEvent mouse;
  mouse.x = static_cast<int>(point.x);
  mouse.y = static_cast<int>(point.y);
  mouse.modifiers = Modifiers(NSEvent.modifierFlags);
  return mouse;
}

// AppKit's and CEF's drag operation bits have the same values.
- (NSDragOperation)dragOver:(id<NSDraggingInfo>)info {
  _browser->GetHost()->DragTargetDragOver(
      [self dragEvent:info],
      static_cast<cef_drag_operations_mask_t>(info.draggingSourceOperationMask));
  return static_cast<NSDragOperation>(_dragOperation);
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
  if (!_browser) return NSDragOperationNone;
  NSArray<NSURL*>* urls =
      [info.draggingPasteboard readObjectsForClasses:@[ NSURL.class ]
                                             options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];
  if (!urls.count) return NSDragOperationNone;
  CefRefPtr<CefDragData> data = CefDragData::Create();
  for (NSURL* url in urls) data->AddFile(url.path.UTF8String, url.lastPathComponent.UTF8String);
  _dragOperation = DRAG_OPERATION_NONE;
  _browser->GetHost()->DragTargetDragEnter(
      data, [self dragEvent:info],
      static_cast<cef_drag_operations_mask_t>(info.draggingSourceOperationMask));
  return [self dragOver:info];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
  return _browser ? [self dragOver:info] : NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)info {
  if (_browser) _browser->GetHost()->DragTargetDragLeave();
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
  if (!_browser) return NO;
  const bool taken = _dragOperation != DRAG_OPERATION_NONE;
  _browser->GetHost()->DragTargetDrop([self dragEvent:info]);
  // A file the editor took is one it opened, as from File > Open.
  if (taken)
    for (NSURL* url in [info.draggingPasteboard
             readObjectsForClasses:@[ NSURL.class ]
                           options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}])
      [FotufilmRecentFiles note:url];
  return taken;
}

@end

namespace {

class MacView : public fotufilm::ViewDelegate {
 public:
  MacView(FotufilmHostView* view, FotufilmHostWindow* owner)
      : view_(view), owner_(owner) {}

  CefRect ViewRect() override {
    const NSRect bounds = view_.bounds;
    return CefRect(0, 0, static_cast<int>(bounds.size.width),
                   static_cast<int>(bounds.size.height));
  }
  float ScaleFactor() override {
    return view_.window ? static_cast<float>(view_.window.backingScaleFactor) : 2.f;
  }
  CefPoint ScreenPoint(const CefPoint& point) override {
    NSPoint window = [view_ convertPoint:NSMakePoint(point.x, point.y) toView:nil];
    const NSPoint screen = [view_.window convertPointToScreen:window];
    // CEF screen coordinates run down from the top of the main screen.
    const CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
    return CefPoint(static_cast<int>(screen.x), static_cast<int>(top - screen.y));
  }
  void AcceleratedPaint(const CefAcceleratedPaintInfo& info) override {
    [view_.compositor
        copyBrowserSurface:(IOSurfaceRef)info.shared_texture_io_surface];
    [view_ setNeedsRender];
  }
  void SoftwarePaint(const void* pixels, int width, int height) override {
    [view_.compositor uploadBrowserPixels:pixels width:width height:height];
    [view_ setNeedsRender];
  }
  void SetCursor(CefCursorHandle cursor, cef_cursor_type_t) override {
    [(__bridge NSCursor*)cursor set];
  }
  bool UnhandledKey(const CefKeyEvent& event) override {
    NSEvent* last = view_.lastKeyDown;
    if (!last || last.keyCode != event.native_key_code) return false;
    view_.lastKeyDown = nil;
    return [NSApp.mainMenu performKeyEquivalent:last];
  }
  void SetTitle(const std::string& title) override {
    view_.window.title = [NSString stringWithUTF8String:title.c_str()];
  }
  void UpdateDragOperation(cef_drag_operations_mask_t operation) override {
    view_.dragOperation = operation;
  }
  void BrowserClosed() override { [owner_ browserClosed]; }

 private:
  __weak FotufilmHostView* view_;
  __weak FotufilmHostWindow* owner_;
};

}  // namespace

@implementation FotufilmHostWindow {
  NSWindow* _window;
  FotufilmHostView* _view;
  std::unique_ptr<MacView> _delegate;
  CefRefPtr<fotufilm::Client> _client;
  fotufilm::Dispatcher* _dispatcher;
  // The page's toolbar and the controls on it, in view points, for window dragging.
  CGRect _toolbar;
  std::vector<CGRect> _controls;
  // The editor's commands that apply now and those ticked, as it last reported them.
  std::set<std::string> _enabled;
  std::set<std::string> _checked;
  NSDictionary<NSString*, NSArray<NSArray<NSString*>*>*>* _menuLists;
  // Files to open once the editor listens for them.
  NSMutableArray<NSString*>* _pendingPaths;
  BOOL _pageListening;
}

- (instancetype)initWithURL:(const std::string&)url
                 dispatcher:(fotufilm::Dispatcher*)dispatcher {
  if (!(self = [super init])) return nil;
  _dispatcher = dispatcher;
  _toolbar = CGRectNull;
  const NSRect frame = NSMakeRect(0, 0, 1440, 900);
  _window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  _window.title = @"Fotufilm";
  _window.releasedWhenClosed = NO;
  _window.delegate = self;
  _window.minSize = NSMakeSize(720, 480);
  _window.tabbingMode = NSWindowTabbingModeDisallowed;
  _window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
  _pendingPaths = [NSMutableArray array];
  _view = [[FotufilmHostView alloc] initWithFrame:frame];
  _view.owner = self;
  _window.contentView = _view;
  [_window center];

  _delegate = std::make_unique<MacView>(_view, self);
  _client = new fotufilm::Client(dispatcher, _delegate.get());
  [self registerMethods];

  CefWindowInfo info;
  info.SetAsWindowless((__bridge CefWindowHandle)_view);
  info.shared_texture_enabled = true;
  CefBrowserSettings settings;
  // Paint as often as the display refreshes; ProMotion panels reach 120 Hz.
  NSInteger fps = NSScreen.mainScreen.maximumFramesPerSecond;
  settings.windowless_frame_rate = static_cast<int>(fps > 0 ? fps : 60);
  // Transparent where the page is, so the image layer beneath shows through.
  settings.background_color = CefColorSetARGB(0, 0, 0, 0);
  CefBrowserHost::CreateBrowserSync(info, _client, url, settings, nullptr, nullptr);
  _view.browser = _client->browser();

  [_window makeKeyAndOrderFront:nil];
  [_window makeFirstResponder:_view];
  [_view layoutMetrics];
  return self;
}

- (void)registerMethods {
  using fotufilm::Call;
  using fotufilm::Dispatcher;
  using fotufilm::Reply;
  __weak FotufilmHostWindow* weakSelf = self;

  _dispatcher->Register(
      "hostInfo", Dispatcher::Thread::kUi,
      [weakSelf](const Call&, std::shared_ptr<Reply> reply) {
        FotufilmHostWindow* strong = weakSelf;
        CefRefPtr<CefDictionaryValue> info = CefDictionaryValue::Create();
        info->SetString("platform", "macos");
        info->SetString("cef", CEF_VERSION);
        info->SetString("chromium",
                        std::to_string(CHROME_VERSION_MAJOR) + "." +
                            std::to_string(CHROME_VERSION_MINOR) + "." +
                            std::to_string(CHROME_VERSION_BUILD) + "." +
                            std::to_string(CHROME_VERSION_PATCH));
        if (strong) {
          const auto stats = strong->_view.compositor.stats;
          info->SetBool("sharedTextures", stats.sharedTextures);
          info->SetDouble("scale", strong->_window.backingScaleFactor);
          info->SetInt("refreshRate",
                       static_cast<int>(strong->_window.screen.maximumFramesPerSecond));
          info->SetString("gpu", strong->_view.compositor.device.name.UTF8String);
        }
        reply->Resolve(Dictionary(info));
      });

  // Echoes run on the engine thread, as engine work will: UI → engine → renderer.
  auto echo = [](const Call& call, std::shared_ptr<Reply> reply) {
    if (call.payload_length)
      reply->Resolve(call.params, call.payload, call.payload_length);
    else
      reply->Resolve(call.params);
  };
  _dispatcher->Register("echo", Dispatcher::Thread::kEngine, echo);
  _dispatcher->Register("echoUi", Dispatcher::Thread::kUi, echo);

  _dispatcher->Register(
      "compositorStats", Dispatcher::Thread::kUi,
      [weakSelf](const Call&, std::shared_ptr<Reply> reply) {
        FotufilmHostWindow* strong = weakSelf;
        CefRefPtr<CefDictionaryValue> stats = CefDictionaryValue::Create();
        if (strong) {
          const auto values = strong->_view.compositor.stats;
          stats->SetDouble("frames", double(values.frames));
          stats->SetDouble("browserFrames", double(values.browserFrames));
          stats->SetDouble("copyMicroseconds", values.lastCopyMicroseconds);
          stats->SetDouble("copyGpuMicroseconds", values.lastCopyGpuMicroseconds);
          stats->SetDouble("drawableWaitMicroseconds",
                           values.lastDrawableWaitMicroseconds);
          stats->SetDouble("compositeMicroseconds", values.lastCompositeMicroseconds);
          stats->SetBool("sharedTextures", values.sharedTextures);
        }
        reply->Resolve(Dictionary(stats));
      });

  // Where the engine's image goes, in CSS pixels from the top left of the page; an empty or
  // missing rectangle removes it. Without an engine the layer shows a moving test pattern.
  _dispatcher->Register(
      "setImageLayer", Dispatcher::Thread::kUi,
      [weakSelf](const Call& call, std::shared_ptr<Reply> reply) {
        FotufilmHostWindow* strong = weakSelf;
        if (!strong) return reply->Resolve(nullptr);
        CefRefPtr<CefDictionaryValue> fields =
            call.params && call.params->GetType() == VTYPE_DICTIONARY
                ? call.params->GetDictionary()
                : nullptr;
        const CGRect rect = CGRectMake(Number(fields, "x"), Number(fields, "y"),
                                       Number(fields, "width"),
                                       Number(fields, "height"));
        if (CGRectIsEmpty(rect))
          [strong->_view.compositor clearImage];
        else
          [strong->_view.compositor setImageTexture:nil rect:rect];
        [strong->_view setAnimating:!CGRectIsEmpty(rect)];
        [strong->_view setNeedsRender];
        reply->Resolve(nullptr);
      });

  // Which of the editor's commands apply and which are ticked, and whether a text field has
  // focus (web/src/editor/useNativeCommands.js). Menus read it when they validate.
  _dispatcher->Register(
      "menuState", Dispatcher::Thread::kUi,
      [weakSelf](const Call& call, std::shared_ptr<Reply> reply) {
        FotufilmHostWindow* strong = weakSelf;
        if (strong && call.params && call.params->GetType() == VTYPE_DICTIONARY) {
          auto names = [](CefRefPtr<CefDictionaryValue> flags) {
            std::set<std::string> names;
            CefDictionaryValue::KeyList keys;
            if (flags && flags->GetKeys(keys))
              for (const CefString& key : keys)
                if (flags->GetType(key) == VTYPE_BOOL && flags->GetBool(key))
                  names.insert(key.ToString());
            return names;
          };
          CefRefPtr<CefDictionaryValue> fields = call.params->GetDictionary();
          strong->_enabled = names(fields->GetDictionary("enabled"));
          strong->_checked = names(fields->GetDictionary("checked"));
          strong->_pageEditsText = fields->GetBool("textInput");
          // Submenus the editor fills: {"films": [[command, title], …]}.
          NSMutableDictionary* lists = [NSMutableDictionary dictionary];
          if (CefRefPtr<CefDictionaryValue> menus = fields->GetDictionary("menus")) {
            CefDictionaryValue::KeyList keys;
            menus->GetKeys(keys);
            for (const CefString& key : keys) {
              CefRefPtr<CefListValue> list = menus->GetList(key);
              NSMutableArray* items = [NSMutableArray array];
              for (size_t i = 0; list && i < list->GetSize(); ++i) {
                CefRefPtr<CefListValue> pair = list->GetList(i);
                if (!pair || pair->GetSize() != 2) continue;
                [items addObject:@[
                  @(pair->GetString(0).ToString().c_str()), @(pair->GetString(1).ToString().c_str())
                ]];
              }
              lists[@(key.ToString().c_str())] = items;
            }
          }
          strong->_menuLists = lists;
        }
        reply->Resolve(nullptr);
      });

  // The editor listens for commands and files; those opened before it did (a Finder double-click
  // at launch) go to it now.
  _dispatcher->Register(
      "commandsReady", Dispatcher::Thread::kUi,
      [weakSelf](const Call&, std::shared_ptr<Reply> reply) {
        if (FotufilmHostWindow* strong = weakSelf) {
          strong->_pageListening = YES;
          [strong deliverOpens];
        }
        reply->Resolve(nullptr);
      });

  // The editor reports its toolbar and the controls on it (web/src/backend/macos/window-chrome.js).
  _dispatcher->Register(
      "windowChrome", Dispatcher::Thread::kUi,
      [weakSelf](const Call& call, std::shared_ptr<Reply> reply) {
        FotufilmHostWindow* strong = weakSelf;
        if (!strong || !call.params || call.params->GetType() != VTYPE_DICTIONARY)
          return reply->Resolve(nullptr);
        auto rect = [](CefRefPtr<CefListValue> list) {
          if (!list || list->GetSize() != 4) return CGRectNull;
          auto at = [&](size_t index) {
            return list->GetType(index) == VTYPE_INT ? double(list->GetInt(index))
                                                     : list->GetDouble(index);
          };
          return CGRectMake(at(0), at(1), at(2), at(3));
        };
        CefRefPtr<CefDictionaryValue> fields = call.params->GetDictionary();
        strong->_toolbar = rect(fields->GetList("toolbar"));
        strong->_controls.clear();
        if (CefRefPtr<CefListValue> controls = fields->GetList("controls"))
          for (size_t index = 0; index < controls->GetSize(); ++index)
            strong->_controls.push_back(rect(controls->GetList(index)));
        reply->Resolve(nullptr);
      });
}

#pragma mark Editor commands

- (void)openURLs:(NSArray<NSURL*>*)urls {
  for (NSURL* url in urls) {
    if (!url.isFileURL) continue;
    [FotufilmRecentFiles note:url];
    [_pendingPaths addObject:url.path];
  }
  [self deliverOpens];
}

- (void)deliverOpens {
  CefRefPtr<CefBrowser> browser = _client->browser();
  if (!_pageListening || !_pendingPaths.count || !browser) return;
  CefRefPtr<CefListValue> paths = CefListValue::Create();
  for (NSString* path in _pendingPaths) paths->SetString(paths->GetSize(), path.UTF8String);
  [_pendingPaths removeAllObjects];
  CefRefPtr<CefDictionaryValue> detail = CefDictionaryValue::Create();
  detail->SetList("paths", paths);
  fotufilm::Dispatcher::Emit(browser->GetMainFrame(), "open", Dictionary(detail));
  [_window makeKeyAndOrderFront:nil];
}

- (void)sendCommand:(NSString*)command {
  CefRefPtr<CefBrowser> browser = _client->browser();
  if (!browser) return;
  CefRefPtr<CefDictionaryValue> detail = CefDictionaryValue::Create();
  detail->SetString("command", command.UTF8String);
  fotufilm::Dispatcher::Emit(browser->GetMainFrame(), "command", Dictionary(detail));
}

- (BOOL)commandEnabled:(NSString*)command {
  return _enabled.count(command.UTF8String) > 0;
}

- (NSArray<NSArray<NSString*>*>*)editorMenuItems:(NSString*)menu {
  return _menuLists[menu] ?: @[];
}

- (void)performEditorCommand:(id)sender {
  id command = [sender representedObject];
  if ([command isKindOfClass:NSString.class]) [self sendCommand:command];
}

- (BOOL)validateMenuItem:(NSMenuItem*)item {
  if (item.action != @selector(performEditorCommand:)) return YES;
  NSString* command = item.representedObject;
  item.state = _checked.count(command.UTF8String) ? NSControlStateValueOn : NSControlStateValueOff;
  return [self commandEnabled:command];
}

- (CGRect)windowDragRegion:(NSPoint)point {
  if (CGRectIsNull(_toolbar) || !CGRectContainsPoint(_toolbar, point))
    return CGRectNull;
  for (const CGRect& control : _controls)
    if (CGRectContainsPoint(control, point)) return CGRectNull;
  return _toolbar;
}

- (void)requestClose {
  if (_closed) return;
  if (CefRefPtr<CefBrowser> browser = _client->browser())
    browser->GetHost()->CloseBrowser(false);
  else
    [self browserClosed];
}

- (void)browserClosed {
  _closed = YES;
  _client->DetachView();
  _view.browser = nullptr;
  [_view setAnimating:NO];
  [_view.compositor invalidate];
  [_window close];
  CefQuitMessageLoop();
}

- (BOOL)windowShouldClose:(NSWindow*)sender {
  if (_closed) return YES;
  [self requestClose];
  return NO;
}

- (void)windowDidBecomeKey:(NSNotification*)notification {
  if (CefRefPtr<CefBrowser> browser = _client->browser())
    browser->GetHost()->SetFocus(_window.firstResponder == _view);
}

- (void)windowDidResignKey:(NSNotification*)notification {
  if (CefRefPtr<CefBrowser> browser = _client->browser())
    browser->GetHost()->SetFocus(false);
}

@end
