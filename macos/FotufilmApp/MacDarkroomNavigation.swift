import AppKit

/// Named process stages stay visible while their controls scroll underneath.
/// Canvas tools are opened from the toolbar and use this column for their settings.
final class MacDarkroomNavigation: SessionView {
    var onSelect: ((Int) -> Void)?

    private let stages = SessionTabStrip()
    private let heading = makeLabel("Darkroom", size: 16, weight: .semibold)
    private let toolLabel = makeLabel("Canvas tool", size: 11, color: .secondaryText)
    private let help = MacHelpButton(label: "Darkroom")
    private var panels: [InspectorPanel] = []

    var count: Int { panels.count }

    var selectedIndex = 0 {
        didSet { updateSelection() }
    }

    var isEnabled = true {
        didSet { stages.isEnabled = isEnabled }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        toolLabel.isHidden = true
        let title = makeStack(.horizontal, spacing: 8, alignment: .firstBaseline)
        title.addArrangedSubview(heading)
        title.addArrangedSubview(help)
        title.addArrangedSubview(toolLabel)
        let stack = makeStack(.vertical, spacing: 10)
        [title, stages].forEach { stack.addArrangedSubview($0) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stages.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        stages.onSelect = { [weak self] in self?.onSelect?($0) }
        help.addDescription { [weak self] in
            guard let self, panels.indices.contains(selectedIndex) else { return "" }
            return panels[selectedIndex].workflowDetail
        }
    }

    func setPanels(_ panels: [InspectorPanel]) {
        guard panels != self.panels else { return }
        self.panels = panels
        stages.setTitles(panels.prefix(4).map(\.title))
        updateSelection()
    }

    private func updateSelection() {
        guard panels.indices.contains(selectedIndex) else { return }
        stages.selectedIndex = selectedIndex < 4 ? selectedIndex : -1
        heading.textValue = selectedIndex < 4 ? "Darkroom" : panels[selectedIndex].title
        toolLabel.isHidden = selectedIndex < 4
        help.setAccessibilityLabel("Help for \(panels[selectedIndex].title)")
        help.refresh()
    }
}

private extension InspectorPanel {
    var workflowDetail: String {
        switch self {
        case .film: return "Load a stock and choose its format and character."
        case .adjustments: return "Adjust the light and filters, then refine the colour grade."
        case .development: return "Develop the film, then shape its grain and colour separation."
        case .print: return "Choose a print or scan, set its viewing light, and export."
        case .selective: return "Adjust a selected colour, area, or subject."
        case .crop: return "Frame and straighten the finished photograph."
        }
    }
}
