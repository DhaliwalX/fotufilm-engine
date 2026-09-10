import AppKit

enum MacSettingsPane: String, CaseIterable {
    case general = "General"
    case output = "Output"
    case filmModel = "Film Model"

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .output: return "square.and.arrow.up"
        case .filmModel: return "film"
        }
    }

    var snapshotName: String {
        switch self {
        case .general: return "general"
        case .output: return "output"
        case .filmModel: return "film-model"
        }
    }
}

/// AppKit provides toolbar selection, keyboard navigation, and the settings window chrome.
final class MacSettingsTabsController: NSTabViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Settings"
        tabStyle = .toolbar
        transitionOptions = []
        canPropagateSelectedChildViewControllerTitle = false
        for pane in MacSettingsPane.allCases {
            let controller = SettingsSheetController()
            controller.pane = pane
            controller.title = pane.rawValue
            let item = NSTabViewItem(viewController: controller)
            item.identifier = pane.rawValue
            item.label = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol,
                                 accessibilityDescription: pane.rawValue)
            addTabViewItem(item)
        }
    }

    required init?(coder: NSCoder) { fatalError("not in a nib") }

    override func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + super.toolbarDefaultItemIdentifiers(toolbar) + [.flexibleSpace]
    }
}

final class MacSettingsWindowController: NSWindowController {
    static let shared = MacSettingsWindowController()
    let tabs = MacSettingsTabsController()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 510),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Settings"
        window.toolbarStyle = .preference
        window.contentViewController = tabs
        window.contentMinSize = NSSize(width: 520, height: 460)
        window.setContentSize(NSSize(width: 560, height: 510))
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not in a nib") }
}
