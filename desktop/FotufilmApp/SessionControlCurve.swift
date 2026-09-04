import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// A catalogued curve control in the desktop inspector.
///
/// The first use is the film base's return spectrum: seven gains in stops, drawn against the
/// visible band. It edits the same `EditState` values as the phone's curve row and uses the same
/// `SpectralCurve` interpolation as the engine.
final class ControlCurveFormRow: FormRowView {
    private let curve: EditorControlCurve
    private let read: () -> [Double]
    private let write: ([Double]) -> Void
    private let began: () -> Void
    private let ended: () -> Void

    private let reading = makeLabel("Flat", size: 11, color: .secondaryText,
                                    monospacedDigits: true)
    private let plot: ControlCurvePlotView
    private let axis: ControlCurveAxisView

    init(_ title: String, curve: EditorControlCurve,
         get: @escaping () -> [Double],
         set: @escaping ([Double]) -> Void,
         began: @escaping () -> Void,
         ended: @escaping () -> Void) {
        self.curve = curve
        read = get
        write = set
        self.began = began
        self.ended = ended
        plot = ControlCurvePlotView(curve: curve)
        axis = ControlCurveAxisView(curve: curve)
        super.init(frame: .zero)

        let name = makeLabel(title, size: 12)
        reading.alignment = .right
        name.setContentCompressionResistancePriority(.defaultLow,
                                                     for: .horizontal)
        reading.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        addSubview(name)
        addSubview(reading)
        addSubview(plot)
        addSubview(axis)
        for view in [name, reading, plot, axis] as [PlatformView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.topAnchor.constraint(equalTo: topAnchor),
            reading.trailingAnchor.constraint(equalTo: trailingAnchor),
            reading.firstBaselineAnchor.constraint(
                equalTo: name.firstBaselineAnchor),
            reading.leadingAnchor.constraint(
                greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            plot.leadingAnchor.constraint(equalTo: leadingAnchor),
            plot.trailingAnchor.constraint(equalTo: trailingAnchor),
            plot.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 7),
            plot.heightAnchor.constraint(equalToConstant: 118),
            axis.leadingAnchor.constraint(equalTo: plot.leadingAnchor),
            axis.trailingAnchor.constraint(equalTo: plot.trailingAnchor),
            axis.topAnchor.constraint(equalTo: plot.bottomAnchor, constant: 2),
            axis.heightAnchor.constraint(equalToConstant: 12),
            axis.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        plot.onBegan = { [weak self] index, value in
            guard let self else { return }
            began()
            show(index: index, value: value)
        }
        plot.onChanged = { [weak self] values, index in
            guard let self else { return }
            write(values)
            show(index: index, value: values[index])
        }
        plot.onEnded = { [weak self] in
            guard let self else { return }
            ended()
            showSummary()
        }
        plot.setHelp("Drag a wavelength handle vertically to change its return in stops.")
        refresh()
    }

    override func refresh() {
        guard !plot.isTracking else { return }
        let values = read()
        guard values.count == curve.handles.count else { return }
        plot.values = values
        showSummary()
    }

    private func show(index: Int, value: Double) {
        reading.textValue = String(format: "%.0f nm · %@",
                                   curve.handles[index],
                                   curve.unit.format(value))
        reading.textColor = .primaryText
    }

    private func showSummary() {
        let values = read()
        reading.textValue = curve.isMoved(values) ? "Drawn" : "Flat"
        reading.textColor = curve.isMoved(values) ? .primaryText : .secondaryText
    }
}

/// The spectral plot and its draggable handles.
private final class ControlCurvePlotView: SessionView {
    let curve: EditorControlCurve
    var values: [Double] {
        didSet {
            guard values != oldValue else { return }
            redraw()
        }
    }

    var onBegan: ((Int, Double) -> Void)?
    var onChanged: (([Double], Int) -> Void)?
    var onEnded: (() -> Void)?

    private(set) var isTracking = false
    private var held: Int?
    private static let grabRadius: CGFloat = 24
    private static let handleRadius: CGFloat = 5

    #if canImport(UIKit)
    private let drag = UILongPressGestureRecognizer()
    #endif

    init(curve: EditorControlCurve) {
        self.curve = curve
        values = curve.restingValues
        super.init(frame: .zero)
        backingLayer.cornerRadius = 8
        backingLayer.cornerCurve = .continuous
        backingLayer.masksToBounds = true
        setAXLabel("Return spectrum")

        #if canImport(UIKit)
        drag.minimumPressDuration = 0
        drag.delegate = self
        drag.addTarget(self, action: #selector(dragged(_:)))
        addGestureRecognizer(drag)
        #endif
    }

    private func x(ofNM nm: Double) -> CGFloat {
        let span = curve.domain.upperBound - curve.domain.lowerBound
        guard span > 0 else { return 0 }
        return bounds.width * CGFloat((nm - curve.domain.lowerBound) / span)
    }

    private func y(ofValue value: Double) -> CGFloat {
        let span = curve.range.upperBound - curve.range.lowerBound
        guard span > 0 else { return bounds.midY }
        return bounds.height * (1 - CGFloat((value - curve.range.lowerBound) / span))
    }

    private func value(atY y: CGFloat) -> Double {
        guard bounds.height > 0 else { return curve.neutral }
        let fraction = 1 - Double(y / bounds.height)
        let span = curve.range.upperBound - curve.range.lowerBound
        return min(max(curve.range.lowerBound + fraction * span,
                       curve.range.lowerBound), curve.range.upperBound)
    }

    private func centre(ofHandle index: Int) -> CGPoint {
        guard curve.handles.indices.contains(index), values.indices.contains(index)
        else { return .zero }
        return CGPoint(x: x(ofNM: curve.handles[index]),
                       y: y(ofValue: values[index]))
    }

    private func handle(nearest point: CGPoint) -> Int? {
        guard bounds.insetBy(dx: -10, dy: -10).contains(point) else { return nil }
        let nearest = curve.handles.indices.min {
            abs(x(ofNM: curve.handles[$0]) - point.x)
                < abs(x(ofNM: curve.handles[$1]) - point.x)
        }
        guard let nearest,
              abs(x(ofNM: curve.handles[nearest]) - point.x) <= Self.grabRadius
        else { return nil }
        return nearest
    }

    private func begin(at point: CGPoint) {
        guard let index = handle(nearest: point), values.indices.contains(index)
        else { return }
        held = index
        isTracking = true
        let next = value(atY: point.y)
        onBegan?(index, next)
        change(index, to: next)
        redraw()
    }

    private func move(to point: CGPoint) {
        guard let held else { return }
        change(held, to: value(atY: point.y))
    }

    private func change(_ index: Int, to value: Double) {
        guard values.indices.contains(index), values[index] != value else { return }
        values[index] = value
        onChanged?(values, index)
    }

    private func end() {
        guard held != nil else { return }
        held = nil
        isTracking = false
        redraw()
        onEnded?()
    }

    #if canImport(UIKit)
    @objc private func dragged(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began: begin(at: point)
        case .changed: move(to: point)
        case .ended, .cancelled, .failed: end()
        default: break
        }
    }
    #else
    override func mouseDown(with event: NSEvent) {
        begin(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        move(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) { end() }
    #endif

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        guard let context = Draw.context,
              !curve.handles.isEmpty, values.count == curve.handles.count
        else { return }

        PlatformColor(white: 0.08, alpha: 1).setFill()
        context.fill(bounds)
        drawSpectrum(context)
        drawRestLine(context)
        drawCurve(context)
        drawHandles(context)
    }

    private func drawSpectrum(_ context: CGContext) {
        let steps = 40
        let span = curve.domain.upperBound - curve.domain.lowerBound
        for index in 0..<steps {
            let fraction = Double(index) / Double(steps - 1)
            let color = Self.tint(nm: curve.domain.lowerBound + fraction * span)
                .withAlphaComponent(0.25)
            context.setFillColor(color.cgColor)
            let x0 = bounds.width * CGFloat(index) / CGFloat(steps)
            let x1 = bounds.width * CGFloat(index + 1) / CGFloat(steps)
            context.fill(CGRect(x: x0, y: 0, width: x1 - x0 + 0.5,
                                height: bounds.height))
        }
    }

    private func drawRestLine(_ context: CGContext) {
        context.saveGState()
        context.setLineDash(phase: 0, lengths: [3, 3])
        context.setStrokeColor(
            PlatformColor.white.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(1)
        let y = y(ofValue: curve.neutral)
        context.move(to: CGPoint(x: 0, y: y))
        context.addLine(to: CGPoint(x: bounds.width, y: y))
        context.strokePath()
        context.restoreGState()
    }

    private func drawCurve(_ context: CGContext) {
        let floor = curve.range.lowerBound
        let points = zip(curve.handles, values).map {
            SpectralControlPoint(nm: Float($0), value: Float($1 - floor))
        }
        let row = SpectralCurve.resampled(points).map { Double($0) + floor }
        guard row.count == SpectralGrid.count else { return }

        context.beginPath()
        var began = false
        for (index, sample) in row.enumerated() {
            let nm = Double(SpectralGrid.wavelengths[index])
            guard curve.domain.contains(nm) else { continue }
            let point = CGPoint(x: x(ofNM: nm), y: y(ofValue: sample))
            if began { context.addLine(to: point) }
            else { context.move(to: point); began = true }
        }
        context.setStrokeColor(
            PlatformColor.white.withAlphaComponent(0.92).cgColor)
        context.setLineWidth(2)
        context.setLineJoin(.round)
        context.strokePath()
    }

    private func drawHandles(_ context: CGContext) {
        for index in curve.handles.indices {
            let centre = centre(ofHandle: index)
            let radius = index == held
                ? Self.handleRadius + 2 : Self.handleRadius
            let circle = CGRect(x: centre.x - radius, y: centre.y - radius,
                                width: radius * 2, height: radius * 2)
            context.setFillColor(Self.tint(nm: curve.handles[index]).cgColor)
            context.fillEllipse(in: circle)
            context.setStrokeColor(
                PlatformColor.white.withAlphaComponent(index == held ? 1 : 0.8)
                    .cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: circle)
        }
    }

    private static func tint(nm: Double) -> PlatformColor {
        var red = 0.0, green = 0.0, blue = 0.0
        switch nm {
        case ..<440: red = -(nm - 440) / 60; blue = 1
        case 440..<490: green = (nm - 440) / 50; blue = 1
        case 490..<510: green = 1; blue = -(nm - 510) / 20
        case 510..<580: red = (nm - 510) / 70; green = 1
        case 580..<645: red = 1; green = -(nm - 645) / 65
        default: red = 1
        }
        let fade: Double
        switch nm {
        case ..<420: fade = 0.3 + 0.7 * (nm - 380) / 40
        case 700...: fade = 0.3 + 0.7 * (780 - nm) / 80
        default: fade = 1
        }
        func shaped(_ component: Double) -> CGFloat {
            CGFloat(pow(max(min(component, 1), 0) * max(fade, 0.3), 0.8))
        }
        return PlatformColor(red: shaped(red), green: shaped(green),
                             blue: shaped(blue), alpha: 1)
    }
}

#if canImport(UIKit)
extension ControlCurvePlotView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        handle(nearest: touch.location(in: self)) != nil
    }
}
#endif

/// Wavelength labels under the curve.
private final class ControlCurveAxisView: SessionView {
    let curve: EditorControlCurve

    init(curve: EditorControlCurve) {
        self.curve = curve
        super.init(frame: .zero)
        setAXLabel(nil)
    }

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        let span = curve.domain.upperBound - curve.domain.lowerBound
        guard span > 0, bounds.width > 0 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: PlatformType.steadyDigits(8, weight: .medium),
            .foregroundColor: PlatformColor.secondaryText,
        ]
        var nm = (curve.domain.lowerBound / 100).rounded(.up) * 100
        while nm <= curve.domain.upperBound {
            let text = "\(Int(nm))" as NSString
            let size = text.size(withAttributes: attributes)
            let x = bounds.width * CGFloat((nm - curve.domain.lowerBound) / span)
            let left = min(max(x - size.width / 2, 0), bounds.width - size.width)
            text.draw(at: CGPoint(x: left, y: 0), withAttributes: attributes)
            nm += 100
        }
    }
}
