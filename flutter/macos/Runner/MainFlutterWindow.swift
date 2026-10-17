import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // The editor's toolbar is the title bar, as in the CEF app: the traffic lights sit over its
    // leading inset and the empty toolbar drags the window.
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    self.isMovableByWindowBackground = false
    // The CEF app's least size, narrow enough for the compact layout (below 834 points).
    self.minSize = NSSize(width: 720, height: 520)
    self.setContentSize(NSSize(width: 1440, height: 900))
    self.center()
    self.setFrameAutosaveName("FotufilmEditor")

    RegisterGeneratedPlugins(registry: flutterViewController)
    WindowChannel.register(with: flutterViewController, window: self)
    PresenterChannel.register(with: flutterViewController)

    super.awakeFromNib()
  }
}

/// Lets the toolbar's empty space drag the window, as the CEF host's window chrome does.
enum WindowChannel {
  static func register(with controller: FlutterViewController, window: NSWindow) {
    let channel = FlutterMethodChannel(name: "fotufilm/window",
                                       binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "startDrag":
        if let event = NSApp.currentEvent { window.performDrag(with: event) }
        result(nil)
      case "zoom":
        window.zoom(nil)
        result(nil)
      case "setContentSize":
        // Scripted checks resize the window, as a person dragging its edge does.
        if let size = call.arguments as? [Double], size.count == 2 {
          window.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        result(nil)
      case "takeOpenedFiles":
        result(OpenedFiles.shared.take(listening: channel))
      case "reveal":
        let urls = (call.arguments as? [String] ?? []).map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        result(nil)
      case "openFile":
        if let path = call.arguments as? String {
          result(NSWorkspace.shared.open(URL(fileURLWithPath: path)))
        } else {
          result(false)
        }
      case "openURL":
        if let text = call.arguments as? String, let url = URL(string: text) {
          result(NSWorkspace.shared.open(url))
        } else {
          result(false)
        }
      case "trash":
        // The paths that went to the Trash; a file that could not stays where it was.
        var trashed: [String] = []
        for path in call.arguments as? [String] ?? [] {
          if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path),
                                                 resultingItemURL: nil)) != nil {
            trashed.append(path)
          }
        }
        result(trashed)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
