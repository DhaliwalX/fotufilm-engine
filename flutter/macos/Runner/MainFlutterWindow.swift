import AVFoundation
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // The editor's toolbar is the title bar: the traffic lights sit over its leading inset and
    // the empty toolbar drags the window.
    // The title still names the window in the Window menu, Mission Control and the Dock: the
    // open photograph's name, or the app's (setTitle).
    self.title = "Fotufilm"
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    self.isMovableByWindowBackground = false
    // The least size, narrow enough for the compact layout (below 834 points).
    self.minSize = NSSize(width: 720, height: 520)
    self.tabbingMode = .disallowed
    self.collectionBehavior.insert(.fullScreenPrimary)
    self.setContentSize(NSSize(width: 1440, height: 900))
    self.center()
    // The previous desktop app's window name, so the window opens where it was before the update.
    self.setFrameAutosaveName("FotufilmDesktopWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)
    WindowChannel.register(with: flutterViewController, window: self)
    MainMenu.register(with: flutterViewController)
    PresenterChannel.register(with: flutterViewController)
    SoundtrackChannel.register(with: flutterViewController)

    super.awakeFromNib()
  }
}

/// Lets the toolbar's empty space drag the window.
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
      case "setTitle":
        window.title = call.arguments as? String ?? "Fotufilm"
        result(nil)
      case "setContentSize":
        // Scripted checks resize the window, as a person dragging its edge does.
        if let size = call.arguments as? [Double], size.count == 2 {
          window.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        result(nil)
      case "takeOpenedFiles":
        result(OpenedFiles.shared.take(listening: channel))
      case "samplePhoto":
        // File › Use Sample Photo: the generated chart (tools/build-desktop-engine.sh).
        result(Bundle.main.path(forResource: "sample", ofType: "png"))
      case "noteRecent":
        RecentFiles.note(call.arguments as? [String] ?? [])
        result(nil)
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

/// File › Open Recent's files: the newest first, ten at most, those gone filtered out as
/// they are read.
enum RecentFiles {
  private static let key = "RecentDocuments"
  private static let limit = 10

  static var paths: [String] {
    (UserDefaults.standard.stringArray(forKey: key) ?? [])
      .filter { FileManager.default.fileExists(atPath: $0) }
  }

  static func note(_ opened: [String]) {
    var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
    // A film pack is installed rather than opened, so it is no recent document.
    for path in opened where URL(fileURLWithPath: path).pathExtension.lowercased() != "fotufilmpack" {
      paths.removeAll { $0 == path }
      paths.insert(path, at: 0)
    }
    UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: key)
  }
}

/// An item that runs one of the editor's commands, named and ticked as the editor last said.
final class CommandMenuItem: NSMenuItem {
  var command = ""
  var baseTitle = ""
}

/// The menu bar, built from the items the editor sends (lib/app/commands.dart `mainMenu`). The
/// editor reports which commands apply, which are ticked and what the changing ones are called
/// (`setState`); items validate against it as they are shown or their key is pressed, and the
/// chosen command goes back to the editor. Choose Film, Presets, Edit History and Open Recent are
/// filled as they are pulled down.
final class MainMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
  static let shared = MainMenu()

  private var channel: FlutterMethodChannel?
  private var enabled = Set<String>()
  private var checked = Set<String>()
  private var titles: [String: String] = [:]
  private var toolTips: [String: String] = [:]
  /// The lists the editor fills: [command, title] pairs.
  private var lists: [String: [[String]]] = [:]
  /// The submenus filled as they open: the list, what stands in for an empty one, fixed items.
  private var filled: [ObjectIdentifier: (list: String, empty: String, fixed: [[String: Any]])] = [:]
  private var recentMenu: NSMenu?
  /// View › Enter Full Screen, which AppKit may add a second of.
  private var fullScreenItem: NSMenuItem?

  static func register(with controller: FlutterViewController) {
    // View › Enter Full Screen is the menu's own; AppKit adds no second one.
    UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
    let channel = FlutterMethodChannel(name: "fotufilm/menu",
                                       binaryMessenger: controller.engine.binaryMessenger)
    shared.channel = channel
    channel.setMethodCallHandler { call, result in
      let json = (call.arguments as? String).flatMap { $0.data(using: .utf8) }
        .flatMap { try? JSONSerialization.jsonObject(with: $0) }
      switch call.method {
      case "setMenus":
        if let menus = json as? [[String: Any]] { shared.build(menus) }
        result(nil)
      case "setState":
        if let state = json as? [String: Any] { shared.update(state) }
        result(nil)
      case "describe":
        // The menu bar as AppKit shows it, validated, for scripted checks.
        result(NSApp.mainMenu.map { shared.describe($0, indent: "") } ?? "")
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func update(_ state: [String: Any]) {
    enabled = Set(state["enabled"] as? [String] ?? [])
    checked = Set(state["checked"] as? [String] ?? [])
    titles = state["titles"] as? [String: String] ?? [:]
    toolTips = state["toolTips"] as? [String: String] ?? [:]
    var lists = (state["menus"] as? [String: [[String]]]) ?? [:]
    let history = state["history"] as? [String] ?? []
    lists["history"] = history.enumerated().map { ["history:\($0.offset)", $0.element] }
    self.lists = lists
  }

  private func build(_ menus: [[String: Any]]) {
    filled.removeAll()
    let bar = NSMenu()
    for menu in menus { bar.addItem(item(menu)) }
    NSApp.mainMenu = bar
  }

  private func item(_ node: [String: Any]) -> NSMenuItem {
    if node["separator"] != nil { return .separator() }
    let title = node["title"] as? String ?? ""
    if let command = node["command"] as? String { return commandItem(command, title, node) }
    if let role = node["native"] as? String { return nativeItem(role, title, node) }
    let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: title)
    holder.submenu = submenu
    let fixed = node["items"] as? [[String: Any]] ?? []
    if let list = node["list"] as? String {
      filled[ObjectIdentifier(submenu)] = (list, node["empty"] as? String ?? "", fixed)
      submenu.delegate = self
    } else {
      for child in fixed { submenu.addItem(item(child)) }
    }
    // The menu holding Enter Full Screen drops the one AppKit adds beside it as it opens.
    if fixed.contains(where: { $0["native"] as? String == "fullScreen" }) { submenu.delegate = self }
    switch node["role"] as? String {
    case "window": NSApp.windowsMenu = submenu
    case "help": NSApp.helpMenu = submenu
    default: break
    }
    return holder
  }

  private func commandItem(_ command: String, _ title: String,
                           _ node: [String: Any] = [:]) -> NSMenuItem {
    let item = CommandMenuItem(title: title, action: #selector(performCommand(_:)), keyEquivalent: "")
    item.target = self
    item.command = command
    item.baseTitle = title
    setKey(item, node)
    return item
  }

  /// The system's own items.
  private func nativeItem(_ role: String, _ title: String, _ node: [String: Any]) -> NSMenuItem {
    let actions: [String: Selector] = [
      "about": #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      "hide": #selector(NSApplication.hide(_:)),
      "hideOthers": #selector(NSApplication.hideOtherApplications(_:)),
      "showAll": #selector(NSApplication.unhideAllApplications(_:)),
      "quit": #selector(NSApplication.terminate(_:)),
      "closeWindow": #selector(NSWindow.performClose(_:)),
      "minimize": #selector(NSWindow.performMiniaturize(_:)),
      "zoom": #selector(NSWindow.performZoom(_:)),
      "bringAllToFront": #selector(NSApplication.arrangeInFront(_:)),
      "fullScreen": #selector(NSWindow.toggleFullScreen(_:)),
    ]
    let item = NSMenuItem(title: title, action: actions[role], keyEquivalent: "")
    switch role {
    case "services":
      let services = NSMenu(title: title)
      item.submenu = services
      NSApp.servicesMenu = services
    case "openRecent":
      let recent = NSMenu(title: title)
      recent.delegate = self
      item.submenu = recent
      recentMenu = recent
    case "fullScreen":
      fullScreenItem = item
    case "help":
      item.action = #selector(openHelpPage(_:))
      item.target = self
      item.representedObject = node["page"]
    default:
      break
    }
    setKey(item, node)
    return item
  }

  private func setKey(_ item: NSMenuItem, _ node: [String: Any]) {
    guard let key = node["key"] as? String else { return }
    item.keyEquivalent = key
    var mask: NSEvent.ModifierFlags = []
    for modifier in node["modifiers"] as? [String] ?? [] {
      switch modifier {
      case "command": mask.insert(.command)
      case "shift": mask.insert(.shift)
      case "option": mask.insert(.option)
      case "control": mask.insert(.control)
      default: break
      }
    }
    item.keyEquivalentModifierMask = mask
  }

  // ── Filled as they open ──────────────────────────────────────────────────────────────────

  func menuNeedsUpdate(_ menu: NSMenu) {
    if menu === recentMenu { return fillRecent(menu) }
    if let ours = fullScreenItem, menu === ours.menu {
      for item in menu.items
      where item !== ours && item.action == #selector(NSWindow.toggleFullScreen(_:)) {
        menu.removeItem(item)
      }
      return
    }
    guard let source = filled[ObjectIdentifier(menu)] else { return }
    menu.removeAllItems()
    let items = lists[source.list] ?? []
    for pair in items where pair.count == 2 { menu.addItem(commandItem(pair[0], pair[1])) }
    if items.isEmpty {
      menu.addItem(withTitle: source.empty, action: nil, keyEquivalent: "").isEnabled = false
    }
    if !source.fixed.isEmpty { menu.addItem(.separator()) }
    for child in source.fixed { menu.addItem(item(child)) }
  }

  /// Open Recent, built as it is pulled down so it never offers a file that has gone.
  private func fillRecent(_ menu: NSMenu) {
    menu.removeAllItems()
    let paths = RecentFiles.paths
    for path in paths {
      let item = menu.addItem(withTitle: URL(fileURLWithPath: path).lastPathComponent,
                              action: #selector(openRecent(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = path
      item.toolTip = path
      let icon = NSWorkspace.shared.icon(forFile: path)
      icon.size = NSSize(width: 16, height: 16)
      item.image = icon
    }
    if paths.isEmpty {
      menu.addItem(withTitle: "No Recent Files", action: nil, keyEquivalent: "").isEnabled = false
      return
    }
    menu.addItem(.separator())
    menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
      .target = self
  }

  /// Each item: ✓ when ticked, its title, key equivalent, and whether it is enabled.
  fileprivate func describe(_ menu: NSMenu, indent: String) -> String {
    menu.delegate?.menuNeedsUpdate?(menu)
    menu.update()
    var lines: [String] = []
    for item in menu.items {
      if item.isSeparatorItem { lines.append(indent + "---"); continue }
      var keys = ""
      if !item.keyEquivalent.isEmpty {
        let mask = item.keyEquivalentModifierMask
        keys = " " + (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "")
          + (mask.contains(.shift) ? "⇧" : "") + (mask.contains(.command) ? "⌘" : "")
          + item.keyEquivalent.uppercased()
      }
      lines.append(indent + (item.state == .on ? "✓ " : "") + "\"\(item.title)\"" + keys
        + (item.hasSubmenu ? " ▸" : item.isEnabled ? " on" : " off")
        + (item.keyEquivalentModifierMask.contains(.function) ? " (fn)" : ""))
      if let submenu = item.submenu, submenu !== NSApp.servicesMenu {
        lines.append(describe(submenu, indent: indent + "  "))
      }
    }
    return lines.filter { !$0.isEmpty }.joined(separator: "\n")
  }

  // ── Actions ──────────────────────────────────────────────────────────────────────────────

  @objc func performCommand(_ sender: NSMenuItem) {
    guard let item = sender as? CommandMenuItem else { return }
    channel?.invokeMethod("command", arguments: item.command)
  }

  @objc func openRecent(_ sender: NSMenuItem) {
    if let path = sender.representedObject as? String { OpenedFiles.shared.add([path]) }
  }

  @objc func clearRecent(_ sender: NSMenuItem) {
    RecentFiles.clear()
  }

  /// The same pages the native Mac app opens.
  @objc func openHelpPage(_ sender: NSMenuItem) {
    guard let page = sender.representedObject as? String,
          let url = URL(string: "https://fotufilm.com/\(page).html") else { return }
    NSWorkspace.shared.open(url)
  }

  /// Ticked, named and greyed as the editor last said (host_window.mm `validateMenuItem`).
  /// Nothing opens while the editor exports.
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(openRecent(_:)) { return enabled.contains("open") }
    guard let item = item as? CommandMenuItem else { return true }
    item.state = checked.contains(item.command) ? .on : .off
    item.title = titles[item.command] ?? item.baseTitle
    item.toolTip = toolTips[item.command]
    return enabled.contains(item.command)
  }
}
