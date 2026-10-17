import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // Photographs opened from the Finder, Open With or the Dock icon.
  override func application(_ application: NSApplication, open urls: [URL]) {
    OpenedFiles.shared.add(urls.filter(\.isFileURL).map(\.path))
  }
}

/// Files the app was asked to open, held until the editor listens (as the CEF host holds
/// `fotufilm-native-open`), then sent as they arrive.
final class OpenedFiles {
  static let shared = OpenedFiles()
  private var pending: [String] = []
  private var channel: FlutterMethodChannel?

  init() {
    // Paths on the command line, for scripted runs: `open -a … --args <file>`.
    let arguments = ProcessInfo.processInfo.arguments.dropFirst()
    pending = arguments.filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
  }

  func add(_ paths: [String]) {
    guard !paths.isEmpty else { return }
    if let channel {
      channel.invokeMethod("open", arguments: paths)
    } else {
      pending.append(contentsOf: paths)
    }
  }

  /// The editor is listening: hand over what waited and send the rest as it comes.
  func take(listening channel: FlutterMethodChannel) -> [String] {
    self.channel = channel
    defer { pending = [] }
    return pending
  }
}
