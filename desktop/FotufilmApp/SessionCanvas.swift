import CoreGraphics
import Foundation
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The canvas: the picture, zoomable, with the original underneath a press.
///
/// The picture is pinned to a document view that tracks the window, so it is the drawing that
/// scales and never the layout. The insets hold a fitted print clear of the panels, and they
/// animate, so opening the inspector slides the photograph out from under it.
final class SessionCanvasView: SessionView {
    private let document = PlatformView()
    private let imageView = PeekImageView(frame: .zero)
    private let peekBadge = GlassPanelView(radius: 14)

    private var edges: Edges?
    private var reportedZoom: CGFloat = 1

    /// Reports magnification as it changes, for the readout the window keeps over the canvas.
    var onZoom: ((CGFloat) -> Void)?

    /// Set while the selective panel wants a colour out of the picture; see `PeekImageView`.
    var onSample: ((CGPoint) -> Void)? {
        get { imageView.onSample }
        set { imageView.onSample = newValue }
    }

    #if canImport(UIKit)
    private let scroll = UIScrollView()
    private let zoomDelegate = ZoomDelegate()
    #else
    private let scroll = MagnifyingScrollView()
    private var boundsObserver: NSObjectProtocol?
    #endif

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)

        imageView.fitProportionally()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.onPeek = { [weak self] peeking in self?.showPeekBadge(peeking) }
        document.addSubview(imageView)

        let edges = Edges(
            leading: imageView.leadingAnchor.constraint(
                equalTo: document.leadingAnchor),
            trailing: document.trailingAnchor.constraint(
                equalTo: imageView.trailingAnchor),
            top: imageView.topAnchor.constraint(equalTo: document.topAnchor),
            bottom: document.bottomAnchor.constraint(
                equalTo: imageView.bottomAnchor))
        NSLayoutConstraint.activate([edges.leading, edges.trailing,
                                     edges.top, edges.bottom])
        self.edges = edges

        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // The badge that says the picture on screen is the undeveloped one.
        peekBadge.translatesAutoresizingMaskIntoConstraints = false
        peekBadge.opacity = 0
        // Hidden as well as transparent, so it is not read out while the developed print is what is
        // actually on screen.
        peekBadge.isHidden = true
        let caption = makeLabel("Original", size: 13, weight: .medium)
        peekBadge.content.addSubview(caption)
        addSubview(peekBadge)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(
                equalTo: peekBadge.content.leadingAnchor, constant: 14),
            caption.trailingAnchor.constraint(
                equalTo: peekBadge.content.trailingAnchor, constant: -14),
            caption.topAnchor.constraint(
                equalTo: peekBadge.content.topAnchor, constant: 9),
            caption.bottomAnchor.constraint(
                equalTo: peekBadge.content.bottomAnchor, constant: -9),
            peekBadge.leadingAnchor.constraint(equalTo: leadingAnchor,
                                               constant: 12),
            peekBadge.topAnchor.constraint(
                equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
        ])

        #if canImport(UIKit)
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 8
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.contentInsetAdjustmentBehavior = .never
        // The document is framed by hand rather than pinned: a zooming scroll view rewrites its
        // content size as it magnifies, and constraints tying that size to the frame would be
        // arguing with it every step of the way.
        document.frame = bounds
        scroll.addSubview(document)
        zoomDelegate.view = document
        zoomDelegate.onZoom = { [weak self] in self?.reportZoom() }
        scroll.delegate = zoomDelegate

        let doubleTap = UITapGestureRecognizer(target: self,
                                               action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        document.addGestureRecognizer(doubleTap)
        #else
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.usesPredominantAxisScrolling = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 8
        document.frame = scroll.contentView.bounds
        document.autoresizingMask = [.width, .height]
        scroll.documentView = document

        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportZoom() }
        }
        #endif
    }

    #if !canImport(UIKit)
    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }
    #endif

    #if canImport(UIKit)
    override func layoutContents() {
        // At rest the document is the visible frame, so a fitted print fills it. While it is
        // magnified the scroll view owns the geometry and this stays out of the way.
        guard scroll.zoomScale <= 1.0001 else { return }
        document.frame = CGRect(origin: .zero, size: scroll.bounds.size)
        scroll.contentSize = scroll.bounds.size
    }
    #endif

    /// The developed picture, and the undeveloped one a press reveals.
    func show(image: PlatformImage, original: PlatformImage?) {
        imageView.developed = image
        imageView.original = original
        if !imageView.isPeeking { imageView.setImage(image) }
    }

    /// What the fitted picture keeps clear of — the columns and the toolbar. Animated, because the
    /// panels that decided it are animating too and the photograph should travel with them.
    func setInsets(_ insets: PlatformEdgeInsets, animated: Bool) {
        guard let edges else { return }
        guard animated else {
            Motion.immediate { edges.apply(insets) }
            return
        }
        Motion.run(Motion.panel, curve: Motion.smooth) { [document] in
            edges.apply(insets, animated: true)
            document.animated.layoutNow()
        }
    }

    /// Back to a fitted print: a new photograph has arrived, and the last one's magnification is
    /// not a statement about this one.
    func resetZoom() {
        #if canImport(UIKit)
        scroll.setZoomScale(1, animated: false)
        #else
        scroll.magnification = 1
        #endif
        reportedZoom = 1
        onZoom?(1)
    }

    /// Where the magnification is, and the two ends it stops at. A pinch and a scroll wheel state
    /// these themselves; a menu command has to ask.
    var magnification: CGFloat {
        #if canImport(UIKit)
        return scroll.zoomScale
        #else
        return scroll.magnification
        #endif
    }

    private var zoomLimits: (min: CGFloat, max: CGFloat) {
        #if canImport(UIKit)
        return (scroll.minimumZoomScale, scroll.maximumZoomScale)
        #else
        return (scroll.minMagnification, scroll.maxMagnification)
        #endif
    }

    var canZoomIn: Bool { magnification < zoomLimits.max - 0.005 }
    var canZoomOut: Bool { magnification > zoomLimits.min + 0.005 }

    /// A step of the zoom, from a menu or a key.
    ///
    /// The pointer-centred zoom the wheel does has a place to zoom towards; a keystroke does not, so
    /// this magnifies about the middle of what is on screen, which is where the eye already is.
    func zoom(by factor: CGFloat) {
        let limits = zoomLimits
        let target = min(max(magnification * factor, limits.min), limits.max)
        guard abs(target - magnification) > 0.001 else { return }
        #if canImport(UIKit)
        let centre = CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY)
        let spot = document.convert(centre, from: scroll)
        let size = CGSize(width: scroll.bounds.width / target,
                          height: scroll.bounds.height / target)
        scroll.zoom(to: CGRect(x: spot.x - size.width / 2,
                               y: spot.y - size.height / 2,
                               width: size.width, height: size.height),
                    animated: true)
        #else
        let centre = CGPoint(x: scroll.contentView.bounds.midX,
                             y: scroll.contentView.bounds.midY)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = Motion.smooth.timingFunction
            scroll.animator().setMagnification(target, centeredAt: centre)
        }
        #endif
    }

    /// Whether the original is on screen in place of the print, for the keyboard's sake: the press
    /// that does this is a press, and a key is not one.
    var isPeeking: Bool { imageView.isPeeking }

    /// There is only something to peek at once the print differs from what went in.
    var canShowOriginal: Bool { imageView.original != nil }

    func setPeeking(_ peeking: Bool) { imageView.setPeeking(peeking) }

    private func reportZoom() {
        guard abs(magnification - reportedZoom) > 0.005 else { return }
        reportedZoom = magnification
        onZoom?(magnification)
    }

    private func showPeekBadge(_ peeking: Bool) {
        if peeking { peekBadge.isHidden = false }
        Motion.run(Motion.quick) { [peekBadge] in
            peekBadge.animated.opacity = peeking ? 1 : 0
        } completion: { [peekBadge] in
            if !peeking { peekBadge.isHidden = true }
        }
    }

    #if canImport(UIKit)
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard scroll.zoomScale <= 1.01 else {
            scroll.setZoomScale(1, animated: true)
            return
        }
        let target = min(4, scroll.maximumZoomScale)
        let point = gesture.location(in: document)
        let size = CGSize(width: scroll.bounds.width / target,
                          height: scroll.bounds.height / target)
        scroll.zoom(to: CGRect(x: point.x - size.width / 2,
                               y: point.y - size.height / 2,
                               width: size.width, height: size.height),
                    animated: true)
    }
    #endif

    /// The four constraints that hold the picture off the chrome.
    private final class Edges {
        let leading, trailing, top, bottom: NSLayoutConstraint

        init(leading: NSLayoutConstraint, trailing: NSLayoutConstraint,
             top: NSLayoutConstraint, bottom: NSLayoutConstraint) {
            self.leading = leading
            self.trailing = trailing
            self.top = top
            self.bottom = bottom
        }

        func apply(_ insets: PlatformEdgeInsets, animated: Bool = false) {
            let targets: [(NSLayoutConstraint, CGFloat)] = [
                (leading, insets.left), (trailing, insets.right),
                (top, insets.top), (bottom, insets.bottom),
            ]
            for (constraint, value) in targets {
                #if canImport(UIKit)
                constraint.constant = value
                #else
                if animated {
                    constraint.animator().constant = value
                } else {
                    constraint.constant = value
                }
                #endif
            }
        }
    }
}

#if canImport(UIKit)

/// Which view magnifies, and who to tell when it has.
private final class ZoomDelegate: NSObject, UIScrollViewDelegate {
    weak var view: UIView?
    var onZoom: (() -> Void)?

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { view }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { onZoom?() }
}

#else

/// Pointer-centred zoom for a mouse.
private final class MagnifyingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let zooming = event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.option)
        guard zooming, allowsMagnification, let documentView else {
            super.scrollWheel(with: event)
            return
        }
        let step = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY * 0.01
            : event.scrollingDeltaY * 0.05
        let target = min(max(magnification * (1 + step), minMagnification),
                         maxMagnification)
        setMagnification(target,
                         centeredAt: documentView.convert(event.locationInWindow,
                                                          from: nil))
    }
}

#endif

/// The picture, and the press that swaps the undeveloped one in.
///
/// A mouse holds the button down; a finger holds still on the picture. Both are the same gesture —
/// keep pressing to see what came out of the camera — reached the way each device reaches it.
private final class PeekImageView: CrossfadingImageView {
    var developed: PlatformImage?
    var original: PlatformImage?
    var onPeek: ((Bool) -> Void)?
    /// Where the picture was clicked, in unit image coordinates with the origin at the top left.
    /// Set while the selective panel is asking for a sample; nil the rest of the time, and while
    /// it is nil a press compares with the original as it always has.
    var onSample: ((CGPoint) -> Void)?
    private(set) var isPeeking = false

    private func unitPoint(of point: CGPoint) -> CGPoint? {
        guard let size = (developed ?? original)?.size,
              size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let frame = CGRect(x: (bounds.width - drawn.width) / 2,
                           y: (bounds.height - drawn.height) / 2,
                           width: drawn.width, height: drawn.height)
        guard frame.contains(point) else { return nil }
        let x = (point.x - frame.minX) / frame.width
        let t = (point.y - frame.minY) / frame.height
        #if canImport(UIKit)
        let y = t
        #else
        // `SessionView` flips the session's own views, but this one descends from `NSImageView`
        // and is not one of them: its y still grows upward, so the top of the picture is 1.
        let y = 1 - t
        #endif
        return CGPoint(x: x, y: y)
    }

    #if canImport(UIKit)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        let press = UILongPressGestureRecognizer(target: self,
                                                 action: #selector(pressed))
        press.minimumPressDuration = 0.22
        addGestureRecognizer(press)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        if let onSample {
            guard gesture.state == .began,
                  let unit = unitPoint(of: gesture.location(in: self))
            else { return }
            onSample(unit)
            return
        }
        switch gesture.state {
        case .began: beginPeek()
        case .ended, .cancelled, .failed: endPeek()
        default: break
        }
    }

    #else

    /// The picture never sizes anything: it is edge-pinned to the document, which tracks the
    /// window, and the drawing scales to fit.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking the picture is how the keyboard is asked back after a visit to the film search
        // field. It is handed to the workspace rather than taken by this view: the canvas is swapped
        // out whenever the crop tab or a clip takes its place, and a first responder that can be
        // removed from the window is a keyboard that stops working when it is.
        if let window, let home = window.initialFirstResponder {
            window.makeFirstResponder(home)
        }
        if let onSample {
            if let unit = unitPoint(of: convert(event.locationInWindow,
                                                from: nil)) {
                onSample(unit)
            }
            return
        }
        if event.clickCount == 2 {
            toggleZoom(at: event)
            return
        }
        beginPeek()
    }

    override func mouseUp(with event: NSEvent) { endPeek() }

    private func toggleZoom(at event: NSEvent) {
        guard let scroll = enclosingScrollView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let target = scroll.magnification > 1.01
            ? 1 : min(4, scroll.maxMagnification)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = Motion.smooth.timingFunction
            scroll.animator().setMagnification(target, centeredAt: point)
        }
    }

    #endif

    /// The same swap, held open rather than held down: a menu item and a key can ask for the
    /// original, and neither of them is a press that can be released.
    func setPeeking(_ peeking: Bool) {
        if peeking { beginPeek() } else { endPeek() }
    }

    private func beginPeek() {
        guard let original else { return }
        isPeeking = true
        setImage(original)
        onPeek?(true)
    }

    private func endPeek() {
        guard isPeeking else { return }
        isPeeking = false
        setImage(developed)
        onPeek?(false)
    }
}
