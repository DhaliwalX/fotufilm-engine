import CoreGraphics
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// The session's controls. Each one is a small view that owns whichever widget the platform
// actually has, and offers the same handful of properties to the panels above it — a value, a
// closure for when it changes, and a way to be told to catch up with the model.
//
// Wrapping rather than aliasing is deliberate. `NSSlider` and `UISlider` are close enough to tempt
// a typealias and far enough apart — `doubleValue` against a `Float`, a target-action against a
// control event, a hand on the knob reported or not reported — that the panels would end up full
// of small platform branches. Here there are four.

#if canImport(UIKit)
typealias PlatformLabel = UILabel
typealias PlatformImageView = UIImageView
typealias PlatformControl = UIControl
#else
typealias PlatformLabel = NSTextField
typealias PlatformImageView = NSImageView
typealias PlatformControl = NSControl
#endif

extension PlatformLabel {
    /// One name for the words a label is showing.
    var textValue: String {
        get {
            #if canImport(UIKit)
            return text ?? ""
            #else
            return stringValue
            #endif
        }
        set {
            #if canImport(UIKit)
            text = newValue
            #else
            stringValue = newValue
            #endif
        }
    }

    #if canImport(UIKit)
    /// AppKit's name for it, so a row that sets one does not have to know which label it has.
    var alignment: NSTextAlignment {
        get { textAlignment }
        set { textAlignment = newValue }
    }
    #endif

    var attributed: NSAttributedString? {
        get {
            #if canImport(UIKit)
            return attributedText
            #else
            return attributedStringValue
            #endif
        }
        set {
            #if canImport(UIKit)
            attributedText = newValue
            #else
            attributedStringValue = newValue ?? NSAttributedString()
            #endif
        }
    }
}

/// A plain text label, the size and colour the inspector sets its rows in.
func makeLabel(_ text: String, size: CGFloat = PlatformType.bodySize,
               weight: PlatformFont.Weight = .regular,
               color: PlatformColor = .primaryText,
               monospacedDigits: Bool = false) -> PlatformLabel {
    #if canImport(UIKit)
    let label = PlatformLabel()
    label.text = text
    #else
    let label = PlatformLabel(labelWithString: text)
    #endif
    label.font = monospacedDigits
        ? PlatformType.steadyDigits(size, weight: weight)
        : PlatformType.system(size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}

/// Creates a wrapping footnote label for a control group.
func makeFootnote(_ text: String) -> PlatformLabel {
    #if canImport(UIKit)
    let label = PlatformLabel()
    label.text = text
    label.numberOfLines = 0
    #else
    let label = PlatformLabel(wrappingLabelWithString: text)
    label.isSelectable = false
    #endif
    label.font = PlatformType.system(11)
    label.textColor = .secondaryText
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

/// The deck's lettering: small, tracked and upper-case, the way every label on the phone's deck is
/// set and every label on this one is.
final class CapsLabel: PlatformLabel {
    init(_ text: String, dim: Bool = false) {
        super.init(frame: .zero)
        #if !canImport(UIKit)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        #endif
        font = PlatformType.system(9, weight: .bold)
        textColor = dim
            ? PlatformColor.secondaryText.withAlphaComponent(0.7)
            : .secondaryText
        translatesAutoresizingMaskIntoConstraints = false
        caption = text
        // Setting the property is not enough here: an observer on a class's own property does not
        // run for that class's initializer, so a label built with its text would draw nothing.
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    var caption: String = "" {
        didSet { render() }
    }

    private func render() {
        attributed = NSAttributedString(
            string: caption.uppercased(),
            attributes: [
                .font: font ?? PlatformType.system(9, weight: .bold),
                .foregroundColor: textColor ?? PlatformColor.secondaryText,
                .kern: 1.0,
            ])
        setAXLabel(caption)
    }
}

/// An image view that fades rather than cuts when its picture is replaced — used everywhere a
/// developed frame lands asynchronously, which is everywhere a picture appears in this app.
class CrossfadingImageView: PlatformImageView {
    private var hasPicture = false

    func setImage(_ next: PlatformImage?, animated: Bool = true) {
        guard next !== image else { return }
        if animated, hasPicture, next != nil {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = Motion.crossfade
            transition.timingFunction = Motion.smooth.timingFunction
            backingLayer.add(transition, forKey: "contents")
        }
        image = next
        hasPicture = next != nil
    }

    /// The whole picture, as large as it will go without distorting.
    func fitProportionally() {
        #if canImport(UIKit)
        contentMode = .scaleAspectFit
        #else
        imageScaling = .scaleProportionallyUpOrDown
        imageAlignment = .alignCenter
        animates = false
        #endif
    }
}

/// A borderless glyph button — the rail's tabs, the scrubber's transport, a search field's clear.
///
/// It lights under the pointer on the Mac and under a finger on the iPad, which are the same
/// highlight reached two different ways.
final class IconButton: SessionView {
    /// Whether the button holds a lit state of its own, for a tab that is the current one.
    var isOn = false { didSet { updateHighlight() } }

    private let highlight = CALayer()
    private let glyph = PlatformImageView()
    private let perform: () -> Void
    private var hovered = false
    private let glyphSize: CGFloat
    #if !canImport(UIKit)
    private var tracking: NSTrackingArea?
    #endif

    init(symbol: String, description: String, size: CGFloat = 15,
         action: @escaping () -> Void) {
        perform = action
        glyphSize = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        glyph.image = Symbol.image(symbol, size: size,
                                   description: description)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        #if canImport(UIKit)
        glyph.contentMode = .center
        glyph.tintColor = .primaryText
        isAccessibilityElement = true
        accessibilityTraits = .button
        addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(tapped)))
        #else
        glyph.contentTintColor = .primaryText
        #endif
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        highlight.cornerRadius = 7
        highlight.cornerCurve = .continuous
        highlight.backgroundColor = PlatformColor.clear.cgColor
        backingLayer.insertSublayer(highlight, at: 0)
        setHelp(description)
    }

    override func layoutContents() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = bounds.insetBy(dx: 1, dy: 1)
        CATransaction.commit()
    }

    /// A new glyph for a button whose meaning has changed under it — play becoming pause. The
    /// description changes with it, because the two are the same statement.
    func setSymbol(_ symbol: String, description: String) {
        glyph.image = Symbol.image(symbol, size: glyphSize,
                                   description: description)
        setHelp(description)
    }

    /// Off means dimmed and deaf: an export holds the engine, and the transport under it should
    /// look as unavailable as it is.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            opacity = isEnabled ? 1 : 0.4
            #if canImport(UIKit)
            isUserInteractionEnabled = isEnabled
            #endif
        }
    }

    private func dip() {
        Motion.run(0.09) { [self] in animated.opacity = 0.55 }
    }

    private func lift() {
        Motion.run(Motion.quick) { [self] in animated.opacity = 1 }
    }

    private func updateHighlight() {
        let color: PlatformColor = isOn
            ? PlatformColor.accent.withAlphaComponent(hovered ? 0.34 : 0.24)
            : PlatformColor.primaryText.withAlphaComponent(hovered ? 0.10 : 0)
        let tint: PlatformColor = isOn ? .accent : .primaryText
        #if canImport(UIKit)
        glyph.tintColor = tint
        #else
        glyph.contentTintColor = tint
        #endif
        Motion.run(Motion.quick) { [self] in
            highlight.backgroundColor = color.cgColor
        }
    }

    #if canImport(UIKit)

    @objc private func tapped() {
        dip()
        perform()
        lift()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        hovered = true
        updateHighlight()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        hovered = false
        updateHighlight()
    }

    override func touchesCancelled(_ touches: Set<UITouch>,
                                   with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        hovered = false
        updateHighlight()
    }

    #else

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateHighlight()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateHighlight()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        dip()
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        lift()
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        perform()
    }

    #endif
}

/// A slider that says when a hand takes hold of it and when it lets go, so a drag collapses into
/// one undo point and renders as a draft until it settles.
final class SessionSlider: SessionView {
    var onChange: ((Double) -> Void)?
    var began: (() -> Void)?
    var ended: (() -> Void)?
    /// True while a hand is on the knob, so a refresh does not fight the drag.
    private(set) var isTracking = false

    #if canImport(UIKit)
    private let slider = UISlider()
    #else
    private let slider = NSSlider()
    #endif

    init(range: ClosedRange<Double>) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.topAnchor.constraint(equalTo: topAnchor),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        #if canImport(UIKit)
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.isContinuous = true
        slider.addTarget(self, action: #selector(moved), for: .valueChanged)
        slider.addTarget(self, action: #selector(took),
                         for: [.touchDown, .touchDownRepeat])
        slider.addTarget(self, action: #selector(letGo),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])
        #else
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(moved)
        #endif
    }

    var value: Double {
        get {
            #if canImport(UIKit)
            return Double(slider.value)
            #else
            return slider.doubleValue
            #endif
        }
        set {
            #if canImport(UIKit)
            slider.value = Float(newValue)
            #else
            slider.doubleValue = newValue
            #endif
        }
    }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set { slider.isEnabled = newValue }
    }

    /// A travel that changes under the control — a video playhead learning how long its clip is.
    var range: ClosedRange<Double> {
        get {
            #if canImport(UIKit)
            return Double(slider.minimumValue) ... Double(slider.maximumValue)
            #else
            return slider.minValue ... slider.maxValue
            #endif
        }
        set {
            #if canImport(UIKit)
            slider.minimumValue = Float(newValue.lowerBound)
            slider.maximumValue = Float(newValue.upperBound)
            #else
            slider.minValue = newValue.lowerBound
            slider.maxValue = newValue.upperBound
            #endif
        }
    }

    @objc private func took() {
        isTracking = true
        began?()
    }

    @objc private func letGo() {
        isTracking = false
        ended?()
    }

    @objc private func moved() {
        #if canImport(UIKit)
        onChange?(value)
        #else
        // AppKit gives no separate down and up around a drag on a continuous slider: the action
        // fires throughout and `NSEvent`'s pressed buttons are what says whether the hand is still
        // on it. That is enough to bracket the drag.
        let down = NSEvent.pressedMouseButtons != 0
        if down, !isTracking { took() }
        onChange?(value)
        if !down, isTracking { letGo() }
        #endif
    }
}

/// A switch.
final class SessionToggle: SessionView {
    var onChange: ((Bool) -> Void)?

    #if canImport(UIKit)
    private let toggle = UISwitch()
    #else
    private let toggle = NSSwitch()
    #endif

    init(description: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.setAXLabel(description)
        addSubview(toggle)
        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.topAnchor.constraint(equalTo: topAnchor),
            toggle.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        #if canImport(UIKit)
        toggle.addTarget(self, action: #selector(flipped), for: .valueChanged)
        #else
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(flipped)
        #endif
    }

    var isOn: Bool {
        get {
            #if canImport(UIKit)
            return toggle.isOn
            #else
            return toggle.state == .on
            #endif
        }
        set {
            #if canImport(UIKit)
            guard toggle.isOn != newValue else { return }
            toggle.setOn(newValue, animated: true)
            #else
            let wanted: NSControl.StateValue = newValue ? .on : .off
            guard toggle.state != wanted else { return }
            toggle.state = wanted
            #endif
        }
    }

    var isEnabled: Bool {
        get { toggle.isEnabled }
        set { toggle.isEnabled = newValue }
    }

    @objc private func flipped() { onChange?(isOn) }
}

/// A pop-up: a title that raises a list and reports which line was taken.
final class SessionPopUp: SessionView {
    var onPick: ((Int) -> Void)?

    private var titles: [String] = []
    private var selected = 0
    #if canImport(UIKit)
    private let button = UIButton(type: .system)
    #else
    private let button = NSPopUpButton()
    #endif

    init(description: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAXLabel(description)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        #if canImport(UIKit)
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true
        button.titleLabel?.font = PlatformType.system(12)
        button.contentHorizontalAlignment = .trailing
        #else
        button.controlSize = .small
        button.font = PlatformType.system(12)
        button.target = self
        button.action = #selector(chose)
        #endif
    }

    func setOptions(_ options: [String]) {
        titles = options
        #if canImport(UIKit)
        rebuildMenu()
        #else
        button.removeAllItems()
        for option in options { button.addItem(withTitle: option) }
        #endif
    }

    var selectedIndex: Int {
        get {
            #if canImport(UIKit)
            return selected
            #else
            return button.indexOfSelectedItem
            #endif
        }
        set {
            guard titles.indices.contains(newValue) else { return }
            guard newValue != selectedIndex else { return }
            selected = newValue
            #if canImport(UIKit)
            rebuildMenu()
            #else
            button.selectItem(at: newValue)
            #endif
        }
    }

    var isEnabled: Bool {
        get { button.isEnabled }
        set { button.isEnabled = newValue }
    }

    #if canImport(UIKit)
    private func rebuildMenu() {
        let actions = titles.enumerated().map { index, title in
            UIAction(title: title,
                     state: index == selected ? .on : .off) { [weak self] _ in
                guard let self, index != selected else { return }
                selected = index
                rebuildMenu()
                onPick?(index)
            }
        }
        button.menu = UIMenu(children: actions)
        button.setTitle(titles.indices.contains(selected) ? titles[selected] : "",
                        for: .normal)
    }
    #else
    @objc private func chose() { onPick?(button.indexOfSelectedItem) }
    #endif
}

/// A bordered button that carries its own closure, so a row does not need a target of its own.
final class SessionButton: SessionView {
    private let perform: () -> Void
    #if canImport(UIKit)
    private let button = UIButton(type: .system)
    #else
    private let button = NSButton()
    #endif

    init(title: String, symbol: String? = nil, destructive: Bool = false,
         prominent: Bool = false, borderless: Bool = false,
         action: @escaping () -> Void) {
        perform = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        #if canImport(UIKit)
        var configuration: UIButton.Configuration = borderless
            ? .plain()
            : (prominent ? .borderedProminent() : .bordered())
        configuration.title = title
        configuration.image = symbol.flatMap { Symbol.image($0, size: 12) }
        configuration.imagePadding = 5
        configuration.buttonSize = .small
        if destructive { configuration.baseForegroundColor = .systemRed }
        button.configuration = configuration
        button.addTarget(self, action: #selector(fire), for: .touchUpInside)
        #else
        button.title = title
        button.bezelStyle = borderless ? .inline : .rounded
        button.isBordered = !borderless
        button.controlSize = .small
        button.font = PlatformType.system(12)
        if prominent {
            button.keyEquivalent = "\r"
            button.bezelColor = .accent
        }
        if borderless { button.contentTintColor = .accent }
        if let symbol {
            button.image = Symbol.image(symbol, size: 12, description: title)
            button.imagePosition = .imageLeading
        }
        if destructive { button.contentTintColor = .systemRed }
        button.target = self
        button.action = #selector(fire)
        #endif
    }

    var title: String {
        get {
            #if canImport(UIKit)
            return button.configuration?.title ?? ""
            #else
            return button.title
            #endif
        }
        set {
            #if canImport(UIKit)
            button.configuration?.title = newValue
            #else
            button.title = newValue
            #endif
        }
    }

    var isEnabled: Bool {
        get { button.isEnabled }
        set { button.isEnabled = newValue }
    }

    @objc private func fire() { perform() }
}

/// A determinate bar: how far through an export the developer is.
final class SessionProgressBar: SessionView {
    #if canImport(UIKit)
    private let bar = UIProgressView(progressViewStyle: .default)
    #else
    private let bar = NSProgressIndicator()
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        #if !canImport(UIKit)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        #else
        heightAnchor.constraint(equalToConstant: 4).isActive = true
        #endif
    }

    var fraction: Double = 0 {
        didSet {
            #if canImport(UIKit)
            bar.progress = Float(fraction)
            #else
            bar.doubleValue = fraction
            #endif
        }
    }
}

/// The search field over the film list.
final class SessionSearchField: SessionView {
    var onChange: ((String) -> Void)?

    #if canImport(UIKit)
    private let field = UISearchTextField()
    #else
    private let field = NSSearchField()
    #endif

    init(placeholder: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        #if canImport(UIKit)
        field.placeholder = placeholder
        field.addTarget(self, action: #selector(edited), for: .editingChanged)
        #else
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.target = self
        field.action = #selector(edited)
        #endif
    }

    var text: String {
        #if canImport(UIKit)
        return field.text ?? ""
        #else
        return field.stringValue
        #endif
    }

    @objc private func edited() { onChange?(text) }
}

/// A line of typed text: a film's name, a number an author would rather state than hunt for with a
/// slider.
///
/// The change is reported as it is typed and again when the field is left, because the two are
/// different events to whoever is listening — a name wants the first, a number that has to be
/// parsed and clamped wants the second, and a field that only did one of them would be wrong for
/// half its uses.
final class SessionTextField: SessionView {
    var onChange: ((String) -> Void)?
    var onCommit: ((String) -> Void)?

    #if canImport(UIKit)
    private let field = UITextField()
    #else
    private let field = NSTextField()
    #endif

    /// - Parameter numeric: puts the number pad up on the iPad and holds the field to the width a
    ///   number needs, so a row of three does not eat the form.
    init(placeholder: String = "", numeric: Bool = false,
         alignment: NSTextAlignment = .natural) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = numeric ? PlatformType.steadyDigits(12)
            : PlatformType.system(12)
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        #if canImport(UIKit)
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.textAlignment = alignment
        field.autocorrectionType = .no
        field.autocapitalizationType = numeric ? .none : .words
        field.returnKeyType = .done
        if numeric { field.keyboardType = .numbersAndPunctuation }
        field.addTarget(self, action: #selector(edited), for: .editingChanged)
        field.addTarget(self, action: #selector(committed),
                        for: [.editingDidEnd, .editingDidEndOnExit])
        #else
        field.placeholderString = placeholder
        field.alignment = alignment
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.target = self
        field.action = #selector(committed)
        #endif
    }

    var text: String {
        get {
            #if canImport(UIKit)
            return field.text ?? ""
            #else
            return field.stringValue
            #endif
        }
        set {
            guard text != newValue else { return }
            #if canImport(UIKit)
            field.text = newValue
            #else
            field.stringValue = newValue
            #endif
        }
    }

    /// True while the caret is in it, so a form refreshing itself cannot rewrite what is being
    /// typed out from under the typist.
    var isEditing: Bool {
        #if canImport(UIKit)
        return field.isFirstResponder
        #else
        return field.currentEditor() != nil
        #endif
    }

    @objc private func edited() { onChange?(text) }

    @objc private func committed() { onCommit?(text) }
}

#if !canImport(UIKit)
extension SessionTextField: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) { onChange?(text) }

    func controlTextDidEndEditing(_ notification: Notification) {
        onCommit?(text)
    }
}
#endif

/// The spinner shown while a frame is developing.
final class SessionSpinner: SessionView {
    #if canImport(UIKit)
    private let spinner = UIActivityIndicatorView(style: .medium)
    #else
    private let spinner = NSProgressIndicator()
    #endif

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalTo: spinner.widthAnchor),
            heightAnchor.constraint(equalTo: spinner.heightAnchor),
        ])
        #if !canImport(UIKit)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        #endif
        isSpinning = false
    }

    var isSpinning = false {
        didSet {
            isHidden = !isSpinning
            #if canImport(UIKit)
            if isSpinning { spinner.startAnimating() }
            else { spinner.stopAnimating() }
            #else
            if isSpinning { spinner.startAnimation(nil) }
            else { spinner.stopAnimation(nil) }
            #endif
        }
    }
}
