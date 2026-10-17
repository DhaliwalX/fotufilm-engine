import AVFoundation
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
    SoundtrackChannel.register(with: flutterViewController)

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

/// A playing movie's sound (lib/app/soundtrack.dart): the file's own audio, played by AVFoundation
/// beside the editor's clock, which starts, moves and stops it with the transport.
enum SoundtrackChannel {
  private static var player: AVPlayer?
  /// Bumped by each play and pause, so a seek that lands late does not start a stopped sound.
  private static var generation = 0

  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(name: "fotufilm/soundtrack",
                                       binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      let arguments = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "load":
        generation += 1
        player?.pause()
        player = nil
        if let path = arguments["path"] as? String, FileManager.default.isReadableFile(atPath: path) {
          let sound = AVPlayer(url: URL(fileURLWithPath: path))
          sound.automaticallyWaitsToMinimizeStalling = false
          player = sound
        }
      case "play":
        guard let sound = player else { break }
        generation += 1
        let started = generation
        let rate = Float(arguments["rate"] as? Double ?? 1)
        sound.isMuted = arguments["muted"] as? Bool ?? false
        sound.pause()
        let time = CMTime(seconds: arguments["time"] as? Double ?? 0, preferredTimescale: 48_000)
        sound.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { done in
          DispatchQueue.main.async {
            if done && started == generation { sound.rate = rate }
          }
        }
      case "pause":
        generation += 1
        player?.pause()
      case "muted":
        player?.isMuted = arguments["muted"] as? Bool ?? false
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }
  }
}
