import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.servicesProvider = self
    super.applicationWillFinishLaunching(notification)
  }

  // Photographs and film packs opened from the Finder, Open With or the Dock icon.
  override func application(_ application: NSApplication, open urls: [URL]) {
    OpenedFiles.shared.add(urls.filter(\.isFileURL).map(\.path))
  }

  /// Finder › Services › Open in Fotufilm (NSServices in Info.plist): several files open together.
  @objc func openInFotufilm(_ pasteboard: NSPasteboard, userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString?>) {
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
      .urlReadingFileURLsOnly: true,
      .urlReadingContentsConformToTypes: [UTType.image.identifier, UTType.movie.identifier],
    ]) as? [URL] ?? []
    if urls.isEmpty {
      error.pointee = "Choose a photo or video to open in Fotufilm."
      return
    }
    DispatchQueue.main.async {
      OpenedFiles.shared.add(urls.map(\.path))
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}

/// Files the app was asked to open, held until the editor listens, then sent as they arrive.
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
    // Film packs are installed rather than opened, so they are not recent files.
    RecentFiles.note(paths.filter { !$0.lowercased().hasSuffix(".fotufilmpack") })
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
