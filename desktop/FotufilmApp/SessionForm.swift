import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The inspector's rows, and the grouped boxes they sit in.
///
/// A grouped form gives a panel its shape: a titled section, rounded, with rows inside it and a
/// footnote under it. That shape is built here — a section is a rounded box, a row is a view that
/// knows how to re-read its own value, and the panel is a stack of them.

/// A row that can be asked to catch up with the model without being rebuilt.
class FormRowView: SessionView {
    /// Pulls the current value out of the model and shows it. Called on every observation tick, so
    /// it must be cheap and must not write anything back.
    func refresh() {}

    /// Whether the row takes input at all, which the whole panel drops during an export.
    var isRowEnabled = true {
        didSet { applyEnabled(isRowEnabled) }
    }

    func applyEnabled(_ enabled: Bool) {
        for view in descendants {
            (view as? PlatformControl)?.isEnabled = enabled
        }
        Motion.run(Motion.quick) { [self] in
            animated.opacity = enabled ? 1 : 0.55
        }
    }
}

/// A titled, rounded group of rows — the grouped form's section.
final class FormSectionView: SessionView {
    private let stack = makeStack(.vertical, spacing: 10)
    private let box = SessionView()
    private(set) var rows: [FormRowView] = []

    init(title: String?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let outer = makeStack(.vertical, spacing: 6)
        addSubview(outer)

        if let title {
            let heading = CapsLabel(title)
            outer.addArrangedSubview(heading)
            outer.setCustomSpacing(7, after: heading)
        }

        box.backingLayer.backgroundColor = PlatformColor.primaryText
            .withAlphaComponent(0.06).cgColor
        box.backingLayer.cornerRadius = 10
        box.backingLayer.cornerCurve = .continuous
        box.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(box)
        box.addSubview(stack)

        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            box.widthAnchor.constraint(equalTo: outer.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor,
                                           constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor,
                                            constant: -12),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor,
                                          constant: -11),
        ])
    }

    @discardableResult
    func add(_ row: FormRowView) -> FormSectionView {
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rows.append(row)
        return self
    }

    /// Throws the section's rows away and puts a new set in their place, for the one case where the
    /// rows are not known until something has been read off disk.
    func replaceRows(_ replacements: [FormRowView]) {
        for row in rows {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        rows.removeAll()
        for row in replacements { add(row) }
    }

    /// A plain view — a picker grid, a grade deck — dropped into the section as though it were a
    /// row, because to the reader it is one.
    @discardableResult
    func add(view: PlatformView) -> FormSectionView {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return self
    }
}

/// A slider with its name on the left and its reading on the right — the inspector's equivalent of
/// the phone's dial-and-ruler.
final class SliderRow: FormRowView {
    private let slider: SessionSlider
    private let readout: PlatformLabel
    private let display: (Double) -> String
    private let read: () -> Double

    init(_ title: String, range: ClosedRange<Double>,
         display: @escaping (Double) -> String,
         get: @escaping () -> Double,
         set: @escaping (Double) -> Void,
         began: @escaping () -> Void,
         ended: @escaping () -> Void) {
        self.display = display
        self.read = get
        slider = SessionSlider(range: range)
        readout = makeLabel("", size: 11, color: .secondaryText,
                            monospacedDigits: true)
        super.init(frame: .zero)

        let name = makeLabel(title, size: 12)
        name.setContentCompressionResistancePriority(.defaultLow,
                                                     for: .horizontal)
        readout.alignment = .right
        readout.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        slider.began = began
        slider.ended = ended
        slider.onChange = { [weak self] value in
            guard let self else { return }
            set(value)
            readout.textValue = display(value)
        }

        addSubview(name)
        addSubview(readout)
        addSubview(slider)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.topAnchor.constraint(equalTo: topAnchor),
            readout.trailingAnchor.constraint(equalTo: trailingAnchor),
            readout.firstBaselineAnchor.constraint(
                equalTo: name.firstBaselineAnchor),
            readout.leadingAnchor.constraint(
                greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAXLabel(title)
        refresh()
    }

    override func refresh() {
        let value = read()
        // Writing while the hand is on it would fight the drag.
        if !slider.isTracking { slider.value = value }
        readout.textValue = display(value)
    }
}

/// A labelled switch.
final class ToggleRow: FormRowView {
    private let toggle: SessionToggle
    private let read: () -> Bool

    init(_ title: String, get: @escaping () -> Bool,
         set: @escaping (Bool) -> Void) {
        self.read = get
        toggle = SessionToggle(description: title)
        super.init(frame: .zero)
        toggle.onChange = set

        let name = makeLabel(title, size: 12)
        addSubview(name)
        addSubview(toggle)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.leadingAnchor.constraint(
                greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            heightAnchor.constraint(greaterThanOrEqualTo: toggle.heightAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: name.heightAnchor),
        ])
        refresh()
    }

    override func refresh() { toggle.isOn = read() }
}

/// A labelled pop-up. The options are handed over as titles paired with whatever they choose, so a
/// row can select an enum, an optional number, or a string without knowing what it is.
final class PopUpRow<Value: Equatable>: FormRowView {
    private let popUp: SessionPopUp
    private let values: [Value]
    private let read: () -> Value

    init(_ title: String?, options: [(title: String, value: Value)],
         get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        values = options.map(\.value)
        read = get
        popUp = SessionPopUp(description: title ?? "")
        super.init(frame: .zero)
        popUp.setOptions(options.map(\.title))
        popUp.onPick = { [values] index in
            guard values.indices.contains(index) else { return }
            set(values[index])
        }
        addSubview(popUp)

        if let title {
            let name = makeLabel(title, size: 12)
            addSubview(name)
            NSLayoutConstraint.activate([
                name.leadingAnchor.constraint(equalTo: leadingAnchor),
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
                popUp.leadingAnchor.constraint(
                    greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
                heightAnchor.constraint(greaterThanOrEqualTo: name.heightAnchor),
            ])
        } else {
            popUp.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            popUp.trailingAnchor.constraint(equalTo: trailingAnchor),
            popUp.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: popUp.heightAnchor),
        ])
        refresh()
    }

    override func refresh() {
        guard let index = values.firstIndex(of: read()) else { return }
        popUp.selectedIndex = index
    }
}

/// A row that is one button — a reset, a reroll.
final class ButtonRow: FormRowView {
    private let button: SessionButton
    private let enabled: () -> Bool

    /// - Parameter bordered: false for a button that is really a link — "use the last settings"
    ///   sitting above a form rather than a decision to be weighed against the ones below it.
    init(_ title: String, symbol: String? = nil, destructive: Bool = false,
         bordered: Bool = true,
         enabled: @escaping () -> Bool = { true },
         action: @escaping () -> Void) {
        self.enabled = enabled
        button = SessionButton(title: title, symbol: symbol,
                               destructive: destructive,
                               borderless: !bordered, action: action)
        super.init(frame: .zero)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        refresh()
    }

    override func refresh() {
        button.isEnabled = enabled() && isRowEnabled
    }

    override func applyEnabled(_ enabled: Bool) {
        button.isEnabled = enabled && self.enabled()
    }
}

/// A row of two or three buttons side by side — the orientation controls.
final class ButtonBarRow: FormRowView {
    private let buttons: [SessionButton]
    private let enabled: [() -> Bool]

    init(_ items: [(title: String, symbol: String?, enabled: () -> Bool,
                    action: () -> Void)]) {
        var made: [SessionButton] = []
        var gates: [() -> Bool] = []
        let stack = makeStack(.horizontal, spacing: 8)

        for item in items {
            let button = SessionButton(title: item.title, symbol: item.symbol,
                                       action: item.action)
            stack.addArrangedSubview(button)
            made.append(button)
            gates.append(item.enabled)
        }
        buttons = made
        enabled = gates
        super.init(frame: .zero)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        refresh()
    }

    override func refresh() {
        for (button, gate) in zip(buttons, enabled) {
            button.isEnabled = gate() && isRowEnabled
        }
    }

    override func applyEnabled(_ enabled: Bool) { refresh() }
}

/// A row that is only words: the explanations the inspector carries under its controls.
final class NoteRow: FormRowView {
    private let label: PlatformLabel
    private let text: () -> String

    init(_ text: @escaping () -> String) {
        self.text = text
        label = makeFootnote(text())
        super.init(frame: .zero)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    convenience init(_ constant: String) {
        self.init({ constant })
    }

    override func refresh() {
        let next = text()
        if label.textValue != next { label.textValue = next }
    }

    override func applyEnabled(_ enabled: Bool) {}
}

/// A name with a value beside it, where the value is not editable — the matched lens profile.
final class ValueRow: FormRowView {
    private let value: PlatformLabel
    private let read: () -> String

    init(_ title: String, value read: @escaping () -> String) {
        self.read = read
        value = makeLabel(read(), size: 12, color: .secondaryText)
        super.init(frame: .zero)

        let name = makeLabel(title, size: 12)
        value.alignment = .right
        value.lineBreakMode = .byTruncatingMiddle
        value.setContentCompressionResistancePriority(.defaultLow,
                                                      for: .horizontal)
        addSubview(name)
        addSubview(value)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.topAnchor.constraint(equalTo: topAnchor),
            name.bottomAnchor.constraint(equalTo: bottomAnchor),
            value.leadingAnchor.constraint(equalTo: name.trailingAnchor,
                                           constant: 8),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func refresh() {
        let next = read()
        if value.textValue != next { value.textValue = next }
    }

    override func applyEnabled(_ enabled: Bool) {}
}

/// A name with a field beside it — the one thing a form has to have that a slider cannot do.
final class TextFieldRow: FormRowView {
    private let field: SessionTextField
    private let read: () -> String

    init(_ title: String, placeholder: String = "",
         get: @escaping () -> String, set: @escaping (String) -> Void) {
        read = get
        field = SessionTextField(placeholder: placeholder)
        super.init(frame: .zero)
        field.text = get()
        field.onChange = set

        let name = makeLabel(title, size: 12)
        name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(name)
        addSubview(field)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: name.trailingAnchor,
                                           constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAXLabel(title)
    }

    override func refresh() {
        guard !field.isEditing else { return }
        field.text = read()
    }
}

/// Edits one to three exact values that do not have meaningful slider ranges.
final class NumberFieldRow: FormRowView {
    private let fields: [SessionTextField]
    private let read: () -> [Float]
    private let write: ([Float]) -> Void
    private let decimals: Int

    /// - Parameter captions: a word under each field, for a row whose columns are not obvious.
    init(_ title: String, captions: [String] = [], decimals: Int = 3,
         get: @escaping () -> [Float], set: @escaping ([Float]) -> Void) {
        read = get
        write = set
        self.decimals = decimals
        let count = max(get().count, 1)
        fields = (0..<count).map { _ in
            SessionTextField(numeric: true, alignment: .right)
        }
        super.init(frame: .zero)

        let name = makeLabel(title, size: 12)
        name.setContentCompressionResistancePriority(.defaultLow,
                                                     for: .horizontal)
        addSubview(name)

        let columns = makeStack(.horizontal, spacing: 6)
        columns.distribution = .fillEqually
        addSubview(columns)
        for (index, field) in fields.enumerated() {
            let column = makeStack(.vertical, spacing: 2)
            column.addArrangedSubview(field)
            if captions.indices.contains(index) {
                let caption = makeLabel(captions[index], size: 10,
                                        color: .secondaryText)
                caption.alignment = .center
                column.addArrangedSubview(caption)
            }
            columns.addArrangedSubview(column)
        }

        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.topAnchor.constraint(equalTo: topAnchor),
            columns.leadingAnchor.constraint(equalTo: leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: trailingAnchor),
            columns.topAnchor.constraint(equalTo: name.bottomAnchor,
                                         constant: 4),
            columns.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAXLabel(title)
        // Committing rather than typing: half of "-0.5" is "-", and a form that acted on it would
        // clamp the number away before the second character arrived.
        for field in fields {
            field.onCommit = { [weak self] _ in self?.commit() }
        }
        refresh()
    }

    private func commit() {
        var values = read()
        for (index, field) in fields.enumerated() where values.indices.contains(index) {
            if let parsed = Float(field.text.trimmingCharacters(in: .whitespaces)) {
                values[index] = parsed
            }
        }
        write(values)
        refresh()
    }

    override func refresh() {
        let values = read()
        for (index, field) in fields.enumerated() where !field.isEditing {
            let value = values.indices.contains(index) ? values[index] : 0
            field.text = String(format: "%.\(decimals)f", value)
        }
    }
}
