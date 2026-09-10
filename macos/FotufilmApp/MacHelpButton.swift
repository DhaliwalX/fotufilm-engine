import AppKit

/// Compact contextual help: a native tooltip on hover, and a popover on click or keyboard press.
final class MacHelpButton: NSButton {
    private var descriptions: [() -> String] = []
    private var popover: NSPopover?

    init(label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        title = ""
        image = NSImage(systemSymbolName: "questionmark.circle",
                        accessibilityDescription: "Help for \(label)")
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        setAccessibilityLabel("Help for \(label)")
        target = self
        action = #selector(showHelp)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func addDescription(_ read: @escaping () -> String) {
        descriptions.append(read)
        refresh()
    }

    func clearDescriptions() {
        descriptions.removeAll()
        refresh()
    }

    func refresh() {
        var seen = Set<String>()
        let text = descriptions.map { $0() }.filter {
            !$0.isEmpty && seen.insert($0).inserted
        }.joined(separator: "\n\n")
        toolTip = text
        setAccessibilityHelp(text)
    }

    @objc private func showHelp() {
        if let popover, popover.isShown { popover.close(); return }
        refresh()
        let label = NSTextField(wrappingLabelWithString: toolTip ?? "")
        label.font = .systemFont(ofSize: 12)
        label.isSelectable = true
        label.preferredMaxLayoutWidth = 260
        let height = label.cell?.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: 260, height: CGFloat.greatestFiniteMagnitude)).height ?? 40
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 284, height: height + 24))
        label.frame = NSRect(x: 12, y: 12, width: 260, height: height)
        controller.view.addSubview(label)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }
}
