import AppKit

/// Named process stages stay visible while their controls scroll underneath.
/// Crop and selective editing are tools available alongside the four stages.
final class MacDarkroomNavigation: SessionView {
    var onSelect: ((Int) -> Void)?

    private let stages = SessionTabStrip()
    private let tools = SessionTabStrip()
    private let heading = makeLabel("Darkroom", size: 16, weight: .semibold)
    private let step = makeLabel("", size: 11, color: .secondaryText,
                                 monospacedDigits: true)
    private let detail = makeFootnote("")
    private var panels: [InspectorPanel] = []

    var count: Int { panels.count }

    var selectedIndex = 0 {
        didSet { updateSelection() }
    }

    var isEnabled = true {
        didSet {
            stages.isEnabled = isEnabled
            tools.isEnabled = isEnabled
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let title = makeStack(.horizontal, spacing: 8, alignment: .firstBaseline)
        title.addArrangedSubview(heading)
        title.addArrangedSubview(step)
        let stack = makeStack(.vertical, spacing: 10)
        [title, stages, detail, tools].forEach { stack.addArrangedSubview($0) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stages.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Keep the header steady when switching between one- and two-line descriptions.
            detail.heightAnchor.constraint(equalToConstant: 32),
            tools.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        stages.onSelect = { [weak self] in self?.onSelect?($0) }
        tools.onSelect = { [weak self] in self?.onSelect?($0 + 4) }
    }

    func setPanels(_ panels: [InspectorPanel]) {
        guard panels != self.panels else { return }
        self.panels = panels
        stages.setTitles(panels.prefix(4).map(\.title))
        tools.setTitles(panels.dropFirst(4).map(\.title))
        tools.isHidden = panels.count <= 4
        updateSelection()
    }

    private func updateSelection() {
        guard panels.indices.contains(selectedIndex) else { return }
        stages.selectedIndex = selectedIndex < 4 ? selectedIndex : -1
        tools.selectedIndex = selectedIndex >= 4 ? selectedIndex - 4 : -1
        step.textValue = selectedIndex < 4 ? "\(selectedIndex + 1) of 4" : "Tools"
        detail.textValue = panels[selectedIndex].workflowDetail
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
