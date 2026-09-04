import CoreGraphics
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// The desktop session is one piece of code that runs on two view frameworks. This file is the whole
// of the seam: the names that differ between AppKit and UIKit, spelled once here, so that the
// editor above it is written in one vocabulary and never asks which machine it is on.
//
// Only differences of *spelling* belong here. Where the two frameworks genuinely disagree about
// behaviour — a scroll view's magnification, a menu bar, a file picker — the editor keeps a
// platform branch at the point where the disagreement matters, and says why.

#if canImport(UIKit)

typealias PlatformView = UIView
typealias PlatformViewController = UIViewController
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformEdgeInsets = UIEdgeInsets
typealias PlatformBezierPath = UIBezierPath

#elseif canImport(AppKit)

typealias PlatformView = NSView
typealias PlatformViewController = NSViewController
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformEdgeInsets = NSEdgeInsets
typealias PlatformBezierPath = NSBezierPath

#endif

// MARK: - Colours

extension PlatformColor {
    /// The colour ordinary reading matter is set in.
    static var primaryText: PlatformColor {
        #if canImport(UIKit)
        return .label
        #else
        return .labelColor
        #endif
    }

    /// A caption, a unit, a row's second line.
    static var secondaryText: PlatformColor {
        #if canImport(UIKit)
        return .secondaryLabel
        #else
        return .secondaryLabelColor
        #endif
    }

    /// What the app is currently agreeing to call its accent. On the Mac this is whatever the user
    /// chose in System Settings; on the iPad there is no such preference, so it is the tint the app
    /// sets on its own window.
    static var accent: PlatformColor {
        #if canImport(UIKit)
        return .tintColor
        #else
        return .controlAccentColor
        #endif
    }

    /// The fill behind a control that is not doing anything yet.
    static var inactiveFill: PlatformColor {
        #if canImport(UIKit)
        return UIColor.label.withAlphaComponent(0.08)
        #else
        return NSColor.labelColor.withAlphaComponent(0.08)
        #endif
    }
}

// MARK: - Fonts

enum PlatformType {
    static var bodySize: CGFloat {
        #if canImport(UIKit)
        return UIFont.systemFontSize
        #else
        return NSFont.systemFontSize
        #endif
    }

    static func system(_ size: CGFloat,
                       weight: PlatformFont.Weight = .regular) -> PlatformFont {
        .systemFont(ofSize: size, weight: weight)
    }

    /// For a number that changes while it is being read — a zoom, a temperature, a timecode — so the
    /// reading does not jitter under the pointer.
    static func steadyDigits(_ size: CGFloat,
                             weight: PlatformFont.Weight = .regular) -> PlatformFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

// MARK: - Symbols

enum Symbol {
    /// An SF Symbol at a point size, as an image the platform's image view will take.
    static func image(_ name: String, size: CGFloat = 15,
                      weight: PlatformFont.Weight = .medium,
                      description: String? = nil) -> PlatformImage? {
        #if canImport(UIKit)
        let configuration = UIImage.SymbolConfiguration(
            pointSize: size, weight: symbolWeight(weight))
        let image = UIImage(systemName: name)?
            .withConfiguration(configuration)
        image?.accessibilityLabel = description
        return image
        #else
        let configuration = NSImage.SymbolConfiguration(
            pointSize: size, weight: symbolWeight(weight))
        return NSImage(systemSymbolName: name,
                       accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        #endif
    }

    #if canImport(UIKit)
    private static func symbolWeight(
        _ weight: PlatformFont.Weight) -> UIImage.SymbolWeight {
        switch weight {
        case .bold: return .bold
        case .semibold: return .semibold
        case .medium: return .medium
        case .light: return .light
        default: return .regular
        }
    }
    #else
    private static func symbolWeight(
        _ weight: PlatformFont.Weight) -> NSFont.Weight { weight }
    #endif
}

// MARK: - Views

extension PlatformView {
    /// One name for how see-through a view is. AppKit calls it `alphaValue` and UIKit calls it
    /// `alpha`, and the editor sets it constantly.
    var opacity: CGFloat {
        get {
            #if canImport(UIKit)
            return alpha
            #else
            return alphaValue
            #endif
        }
        set {
            #if canImport(UIKit)
            alpha = newValue
            #else
            alphaValue = newValue
            #endif
        }
    }

    /// The smallest the view's own constraints will let it be. AppKit spells this `fittingSize`;
    /// UIKit makes you name the fitting priorities, and compressed on both axes is what AppKit
    /// means.
    var compressedSize: CGSize {
        #if canImport(UIKit)
        return systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        #else
        return fittingSize
        #endif
    }

    /// The layer, always there. A UIKit view is layer-backed from birth; an AppKit view has to be
    /// asked, and answers with an optional even once it has been.
    var backingLayer: CALayer {
        #if canImport(UIKit)
        return layer
        #else
        wantsLayer = true
        return layer ?? CALayer()
        #endif
    }

    /// Draw again, next pass.
    func redraw() {
        #if canImport(UIKit)
        setNeedsDisplay()
        #else
        needsDisplay = true
        #endif
    }

    /// Lay out again, next pass.
    func relayout() {
        #if canImport(UIKit)
        setNeedsLayout()
        #else
        needsLayout = true
        #endif
    }

    /// Force the layout that is pending, so a movement can be animated from a known position rather
    /// than from wherever the last pass happened to leave things.
    func layoutNow() {
        #if canImport(UIKit)
        layoutIfNeeded()
        #else
        layoutSubtreeIfNeeded()
        #endif
    }

    /// What a screen reader says this is.
    func setAXLabel(_ label: String?) {
        #if canImport(UIKit)
        isAccessibilityElement = label != nil
        accessibilityLabel = label
        #else
        setAccessibilityLabel(label)
        #endif
    }

    /// What the pointer's tooltip says. The iPad has no pointer resting on anything, so this is the
    /// accessibility label there and nothing else.
    func setHelp(_ text: String) {
        #if canImport(UIKit)
        setAXLabel(text)
        #else
        toolTip = text
        setAXLabel(text)
        #endif
    }

    /// Every view in a tree, for the sweeps that have to reach controls the window did not build
    /// itself — enabling a whole panel during an export, for one.
    var descendants: [PlatformView] {
        subviews + subviews.flatMap(\.descendants)
    }

    /// Pins a view to fill another, which is most of the constraints in the session.
    func pin(_ child: PlatformView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor,
                                           constant: inset),
            child.trailingAnchor.constraint(equalTo: trailingAnchor,
                                            constant: -inset),
            child.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: bottomAnchor,
                                          constant: -inset),
        ])
    }

    /// A tick per displayed frame, for the few animations the session runs by hand because what is
    /// moving is the composition a drawing is derived from and not a property of a layer.
    ///
    /// UIKit hands one out; AppKit asks the view for it, so that it comes from the clock of the
    /// display this particular window is on.
    func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink {
        #if canImport(UIKit)
        return CADisplayLink(target: target, selector: selector)
        #else
        return displayLink(target: target, selector: selector)
        #endif
    }
}

/// The base class every view in the session is built on.
///
/// It settles the one difference that would otherwise reach into every frame calculation: AppKit
/// measures from the bottom left and UIKit from the top left. Made flipped on the Mac, a panel laid
/// out by hand has the same arithmetic on both machines, and `layoutContents` is the same hook.
class SessionView: PlatformView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        #if canImport(UIKit)
        // AppKit redraws a view when it is resized and UIKit rescales the last drawing instead.
        // Everything here that draws is drawn against its own bounds, so it wants the AppKit
        // behaviour on both.
        contentMode = .redraw
        // These translucent views do not cover every pixel. Mark them non-opaque so UIKit clears
        // the backing store before redraws.
        isOpaque = false
        #else
        wantsLayer = true
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    /// Called after every layout pass, on both platforms, with `bounds` final.
    func layoutContents() {}

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutContents()
    }
    #else
    /// Top-left origin, y downward — UIKit's convention, adopted here so the session's hand-laid
    /// frames are written once.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layoutContents()
    }
    #endif
}

/// A view whose contents are placed by hand, and which says when its size has changed.
///
/// For the case where hand-laid frames have to live inside something driven by constraints — a
/// pane of graphs inside a scroll column, say. The owner keeps the placing; this only reports.
class LayoutPane: SessionView {
    var onLayout: (() -> Void)?

    override func layoutContents() {
        onLayout?()
    }
}

/// A view controller, with the initializer both platforms want written once.
class SessionViewController: PlatformViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }
}

/// Core Animation takes its values boxed, and the two frameworks box a point under different names.
enum Box {
    static func point(_ point: CGPoint) -> NSValue {
        #if canImport(UIKit)
        return NSValue(cgPoint: point)
        #else
        return NSValue(point: point)
        #endif
    }
}

// MARK: - Drawing

extension PlatformBezierPath {
    /// `NSBezierPath` and `UIBezierPath` disagree about the names of the two most common moves.
    func line(from start: CGPoint, to end: CGPoint) {
        move(to: start)
        #if canImport(UIKit)
        addLine(to: end)
        #else
        line(to: end)
        #endif
    }

    static func rounded(_ rect: CGRect, radius: CGFloat) -> PlatformBezierPath {
        #if canImport(UIKit)
        return UIBezierPath(roundedRect: rect, cornerRadius: radius)
        #else
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        #endif
    }
}

enum Draw {
    /// The context a `draw(_:)` override is drawing into.
    static var context: CGContext? {
        #if canImport(UIKit)
        return UIGraphicsGetCurrentContext()
        #else
        return NSGraphicsContext.current?.cgContext
        #endif
    }

    /// Runs `body` with the graphics state saved and restored, so a clip or a transform set inside
    /// it cannot leak into the rest of the drawing.
    static func inState(_ body: () -> Void) {
        guard let context else { return body() }
        context.saveGState()
        body()
        context.restoreGState()
    }

    /// A linear gradient across a rectangle.
    ///
    /// `NSGradient` has no counterpart in UIKit, so both platforms are served by the Core Graphics
    /// one underneath. The ends are given as points in the view's own coordinates rather than as an
    /// angle, which is also the only way to say "top" and "bottom" and mean it on a flipped view.
    static func gradient(in rect: CGRect, colors: [PlatformColor],
                         locations: [CGFloat]? = nil,
                         from start: CGPoint, to end: CGPoint) {
        guard let context, !colors.isEmpty else { return }
        let space = CGColorSpaceCreateDeviceRGB()
        let components = colors.map {
            $0.cgColor.converted(to: space, intent: .defaultIntent,
                                 options: nil) ?? $0.cgColor
        }
        guard let gradient = CGGradient(colorsSpace: space,
                                        colors: components as CFArray,
                                        locations: locations) else { return }
        inState {
            context.clip(to: rect)
            context.drawLinearGradient(gradient, start: start, end: end,
                                       options: [.drawsBeforeStartLocation,
                                                 .drawsAfterEndLocation])
        }
    }

    /// Draws `body` with a shadow under it.
    static func shadowed(color: PlatformColor, blur: CGFloat,
                         offset: CGSize, _ body: () -> Void) {
        guard let context else { return body() }
        inState {
            context.setShadow(offset: offset, blur: blur, color: color.cgColor)
            body()
        }
    }
}

// MARK: - Gestures

/// A drag, reported the same way on a mouse and on a finger.
///
/// This is the one interaction the two frameworks do not merely spell differently: AppKit hands a
/// view a stream of `mouseDown`/`mouseDragged`/`mouseUp` overrides, and UIKit hands it a recognizer.
/// Both are funnelled into `began`/`moved`/`ended` with a point in the view's own coordinates, which
/// is all any of the session's canvases and pads ever wanted.
class DragTarget: SessionView {
    /// Where the drag is, in this view's coordinates, and whether it is over.
    var onDragBegan: ((CGPoint) -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if canImport(UIKit)
        let pan = UIPanGestureRecognizer(target: self,
                                         action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        // A tap is a drag that never moved: the pads place their knob on a press, and a finger that
        // lands and lifts without travelling would otherwise say nothing at all.
        let tap = UITapGestureRecognizer(target: self,
                                         action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        #endif
    }

    #if canImport(UIKit)
    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let point = pan.location(in: self)
        switch pan.state {
        case .began: onDragBegan?(point)
        case .changed: onDragMoved?(point)
        case .ended, .cancelled, .failed: onDragEnded?(point)
        default: break
        }
    }

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        onDragBegan?(point)
        onDragEnded?(point)
    }
    #else
    override func mouseDown(with event: NSEvent) {
        onDragBegan?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        onDragMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?(convert(event.locationInWindow, from: nil))
    }
    #endif
}
