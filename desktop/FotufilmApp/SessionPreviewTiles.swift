import CoreGraphics
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A cancellable wait. The preview columns develop the whole pack over the open photograph, which
/// is worth doing once the sliders have stopped moving and not before, so every request goes
/// through one of these.
@MainActor
final class Debounce {
    private var task: Task<Void, Never>?

    func run(milliseconds: Int, _ body: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled else { return }
            body()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

/// The open picture developed on one film or at one gauge: a rounded thumbnail that fades in when
/// its render lands, with a ring around the one that is chosen.
final class ThumbnailView: SessionView {
    private let imageView = CrossfadingImageView()
    private let lock = PlatformImageView()
    private let ring = CALayer()
    private var selected = false

    init(radius: CGFloat = 6) {
        super.init(frame: .zero)
        backingLayer.cornerRadius = radius
        backingLayer.cornerCurve = .continuous
        backingLayer.masksToBounds = true
        backingLayer.backgroundColor = PlatformColor.primaryText
            .withAlphaComponent(0.09).cgColor

        imageView.fitProportionally()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        lock.image = Symbol.image("lock.fill", size: 10,
                                  description: "Requires Fotufilm Pro")
        lock.translatesAutoresizingMaskIntoConstraints = false
        lock.isHidden = true
        #if canImport(UIKit)
        lock.tintColor = .white
        #else
        lock.contentTintColor = .white
        #endif
        addSubview(lock)

        ring.cornerRadius = radius
        ring.cornerCurve = .continuous
        ring.borderColor = PlatformColor.accent.cgColor
        ring.borderWidth = 0
        backingLayer.addSublayer(ring)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            lock.trailingAnchor.constraint(equalTo: trailingAnchor,
                                           constant: -5),
            lock.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    override func layoutContents() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        CATransaction.commit()
    }

    var image: PlatformImage? {
        get { imageView.image }
        set { imageView.setImage(newValue) }
    }

    func setLocked(_ locked: Bool) { lock.isHidden = !locked }

    /// The chosen one. The border grows rather than appearing, which is what makes clicking down a
    /// list of films feel like one movement instead of six.
    func setSelected(_ isSelected: Bool, animated: Bool = true) {
        guard isSelected != selected else { return }
        selected = isSelected
        let width: CGFloat = isSelected ? 2.5 : 0
        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.borderWidth = width
            CATransaction.commit()
            return
        }
        Motion.run(Motion.quick, curve: Motion.spring) { [ring] in
            ring.borderWidth = width
        }
    }
}

/// Fixed-size tiles wrapped across the available width, laid out by hand because the width they
/// wrap at is the panel's and changes with the window.
final class FlowGridView: SessionView {
    private let tileSize: CGSize
    private let spacing: CGFloat
    private var height: CGFloat = 0

    init(tileSize: CGSize, spacing: CGFloat) {
        self.tileSize = tileSize
        self.spacing = spacing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: PlatformView.noIntrinsicMetric, height: height)
    }

    override func layoutContents() {
        let usable = max(bounds.width, tileSize.width)
        let columns = max(1, Int((usable + spacing)
                                / (tileSize.width + spacing)))
        var x: CGFloat = 0
        var y: CGFloat = 0
        for (index, tile) in subviews.enumerated() {
            let column = index % columns
            if column == 0, index > 0 {
                x = 0
                y += tileSize.height + spacing
            }
            tile.frame = CGRect(x: x, y: y,
                                width: tileSize.width, height: tileSize.height)
            x += tileSize.width + spacing
        }
        let rows = Int(ceil(Double(subviews.count) / Double(columns)))
        let wanted = rows > 0
            ? CGFloat(rows) * tileSize.height + CGFloat(rows - 1) * spacing
            : 0
        if abs(wanted - height) > 0.5 {
            height = wanted
            invalidateIntrinsicContentSize()
        }
    }
}

/// A tile that is a button: a thumbnail with its name under it.
final class PreviewTileButton: SessionView {
    let thumbnail = ThumbnailView(radius: 8)
    private let caption: PlatformLabel
    private let perform: () -> Void
    private var raised = false
    #if !canImport(UIKit)
    private var tracking: NSTrackingArea?
    #endif

    init(title: String, help: String, action: @escaping () -> Void) {
        perform = action
        caption = makeLabel(title, size: 10, color: .secondaryText)
        super.init(frame: .zero)

        caption.alignment = .center
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbnail)
        addSubview(caption)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnail.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumbnail.topAnchor.constraint(equalTo: topAnchor),
            thumbnail.heightAnchor.constraint(equalTo: thumbnail.widthAnchor),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.topAnchor.constraint(equalTo: thumbnail.bottomAnchor,
                                         constant: 4),
        ])
        setHelp(help)
        #if canImport(UIKit)
        accessibilityTraits = .button
        addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(tapped)))
        #else
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        #endif
    }

    func setSelected(_ selected: Bool) {
        thumbnail.setSelected(selected)
        caption.textColor = selected ? .primaryText : .secondaryText
        #if canImport(UIKit)
        accessibilityTraits = selected ? [.button, .selected] : .button
        #else
        setAccessibilitySelected(selected)
        #endif
    }

    func setLocked(_ locked: Bool) { thumbnail.setLocked(locked) }

    private func lift(to scale: CGFloat, damping: CGFloat, stiffness: CGFloat) {
        let layer = thumbnail.backingLayer
        Motion.spring(layer, key: "transform.scale",
                      from: layer.value(forKeyPath: "transform.scale") ?? 1,
                      to: scale, damping: damping, stiffness: stiffness)
    }

    private func settle() {
        lift(to: raised ? 1.05 : 1, damping: 13, stiffness: 300)
    }

    #if canImport(UIKit)

    @objc private func tapped() { perform() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        lift(to: 0.94, damping: 18, stiffness: 400)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        settle()
    }

    override func touchesCancelled(_ touches: Set<UITouch>,
                                   with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        settle()
    }

    override func accessibilityActivate() -> Bool {
        perform()
        return true
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
        raised = true
        settle()
    }

    override func mouseExited(with event: NSEvent) {
        raised = false
        settle()
    }

    override func mouseDown(with event: NSEvent) {
        lift(to: 0.94, damping: 18, stiffness: 400)
    }

    override func mouseUp(with event: NSEvent) {
        settle()
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside { perform() }
    }

    override func accessibilityPerformPress() -> Bool {
        perform()
        return true
    }

    #endif
}
