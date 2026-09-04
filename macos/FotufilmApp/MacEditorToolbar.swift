import AppKit

/// The window's title bar: the two panel switches at the ends, and between them the things a
/// photograph is done to — opened, zoomed, undone, reset, exported. The zoom controls and their
/// readout share the middle of the bar.
///
/// The picture runs behind it, so the bar carries only glyphs and one line of readout; anything
/// wordier belongs in a panel.
extension DesktopEditorViewController: NSToolbarDelegate {
    enum ToolbarID {
        static let stocks = NSToolbarItem.Identifier("stocks")
        static let open = NSToolbarItem.Identifier("open")
        static let zoomOut = NSToolbarItem.Identifier("zoomOut")
        static let zoomIn = NSToolbarItem.Identifier("zoomIn")
        static let zoomToFit = NSToolbarItem.Identifier("zoomToFit")
        static let undo = NSToolbarItem.Identifier("undo")
        static let redo = NSToolbarItem.Identifier("redo")
        static let reset = NSToolbarItem.Identifier("reset")
        static let readout = NSToolbarItem.Identifier("readout")
        static let histogram = NSToolbarItem.Identifier("histogram")
        static let export = NSToolbarItem.Identifier("export")
        static let inspector = NSToolbarItem.Identifier("inspector")
    }

    func installToolbar(in window: NSWindow) {
        let toolbar = NSToolbar(identifier: "FotufilmEditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    public func toolbarDefaultItemIdentifiers(
        _ toolbar: NSToolbar
    ) -> [NSToolbarItem.Identifier] {
        [ToolbarID.stocks, .sidebarTrackingSeparator, ToolbarID.open,
         .flexibleSpace,
         ToolbarID.zoomOut, ToolbarID.readout, ToolbarID.zoomIn,
         ToolbarID.zoomToFit, .flexibleSpace,
         ToolbarID.histogram, ToolbarID.undo, ToolbarID.redo,
         ToolbarID.reset, ToolbarID.export,
         ToolbarID.inspector]
    }

    public func toolbarAllowedItemIdentifiers(
        _ toolbar: NSToolbar
    ) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case ToolbarID.stocks:
            return button(identifier, symbol: "sidebar.leading", title: "Film",
                          action: #selector(toggleStockSidebar(_:)))
        case ToolbarID.open:
            return openItem(identifier)
        case ToolbarID.undo:
            return button(identifier, symbol: "arrow.uturn.backward",
                          title: "Undo", action: #selector(performUndo(_:)))
        case ToolbarID.redo:
            return button(identifier, symbol: "arrow.uturn.forward",
                          title: "Redo", action: #selector(performRedo(_:)))
        case ToolbarID.histogram:
            return button(identifier, symbol: "waveform", title: "Histogram",
                          action: #selector(toggleHistogram(_:)))
        case ToolbarID.reset:
            return button(identifier, symbol: "arrow.counterclockwise",
                          title: "Reset", action: #selector(resetAllEdits(_:)))
        case ToolbarID.export:
            return button(identifier, symbol: "square.and.arrow.up",
                          title: "Export", action: #selector(exportDocument(_:)))
        case ToolbarID.inspector:
            return button(identifier, symbol: "sidebar.trailing",
                          title: "Adjustments",
                          action: #selector(toggleInspectorPanel(_:)))
        case ToolbarID.readout:
            return readoutItem(identifier)
        case ToolbarID.zoomOut:
            return button(identifier, symbol: "minus.magnifyingglass",
                          title: "Zoom Out", action: #selector(zoomOut(_:)))
        case ToolbarID.zoomIn:
            return button(identifier, symbol: "plus.magnifyingglass",
                          title: "Zoom In", action: #selector(zoomIn(_:)))
        case ToolbarID.zoomToFit:
            return button(identifier, symbol: "arrow.down.right.and.arrow.up.left",
                          title: "Zoom to Fit", action: #selector(zoomToFit(_:)))
        default:
            return nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, symbol: String,
                        title: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = title
        item.paletteLabel = title
        item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol,
                             accessibilityDescription: title)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    private func openItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Open"
        item.paletteLabel = "Open"
        item.toolTip = "Open a photo or video"
        // The one primary-coloured control in the bar: opening is where every session starts.
        // The accent is baked into the symbol, because a toolbar redraws any template image in
        // the label colour and would wash the tint back out.
        let symbol = NSImage(systemSymbolName: "plus",
                             accessibilityDescription: "Open")?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [PlatformColor.accent]))
        symbol?.isTemplate = false
        item.image = symbol
        item.target = self
        item.action = #selector(openDocument(_:))
        item.isBordered = true
        return item
    }

    private func readoutItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Preview"
        let stack = NSStackView(views: [zoomLabel, pixelLabel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .firstBaseline
        // The pixel count arrives with the photograph, long after the toolbar has measured this
        // item and drawn its background around it. So both halves are given the width of their
        // longest reading now, while the item is empty and the measurement is being taken.
        zoomLabel.alignment = .right
        pixelLabel.alignment = .left
        NSLayoutConstraint.activate([
            zoomLabel.widthAnchor.constraint(equalToConstant: 32),
            pixelLabel.widthAnchor.constraint(equalToConstant: 56),
        ])
        item.view = stack
        item.visibilityPriority = .low
        return item
    }

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(toggleHistogram(_:)):
            item.image = NSImage(
                systemSymbolName: isHistogramShown ? "waveform.circle.fill" : "waveform",
                accessibilityDescription: isHistogramShown
                    ? "Hide Histogram" : "Show Histogram")
            item.toolTip = isHistogramShown ? "Hide Histogram" : "Show Histogram"
            return model.isOpen
        case #selector(performUndo(_:)): return model.canUndo && !model.isExporting
        case #selector(performRedo(_:)): return model.canRedo && !model.isExporting
        case #selector(zoomIn(_:)): return canvasCanZoomIn
        case #selector(zoomOut(_:)): return canvasCanZoomOut
        case #selector(zoomToFit(_:)): return canvasCanZoomOut
        case #selector(resetAllEdits(_:)): return model.canReset && !model.isExporting
        case #selector(exportDocument(_:)): return model.canExport
        default: return true
        }
    }
}
