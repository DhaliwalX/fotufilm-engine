#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The six editable parameters of an H&D curve.
struct CurveShape: Equatable {
    var dMin: Float
    var gamma: Float
    var toe: Float
    var toeWidth: Float
    var shoulder: Float
    var shoulderWidth: Float

    init(dMin: Float, gamma: Float, toe: Float, toeWidth: Float,
         shoulder: Float, shoulderWidth: Float) {
        self.dMin = dMin
        self.gamma = gamma
        self.toe = toe
        self.toeWidth = toeWidth
        self.shoulder = shoulder
        self.shoulderWidth = shoulderWidth
    }

    var curve: CharacteristicCurve {
        CharacteristicCurve(dMin: dMin, gamma: gamma, toe: toe,
                            toeWidth: max(toeWidth, 0.01),
                            shoulder: max(shoulder, toe + 0.05),
                            shoulderWidth: max(shoulderWidth, 0.01))
    }

    func density(at logExposure: Float) -> Float {
        curve.density(logExposure: logExposure)
    }
}

/// Edits a characteristic curve through axis-constrained handles for its six parameters.
/// The same view supports negative and paper curves with caller-provided limits and domains.
final class CurveEditorView: DragTarget {

    /// What is being edited. Setting this redraws but does not call back.
    var shape = CurveShape(dMin: 0.2, gamma: 0.6, toe: -1.2, toeWidth: 0.24,
                           shoulder: 4.2, shoulderWidth: 1.2) {
        didSet {
            guard shape != oldValue else { return }
            settleDomain()
            redraw()
        }
    }

    /// Per-layer gamma trim and negative-mask density offsets used to draw the RGB curves.
    var layerGammaTrim: [Float] = [1, 1, 1] { didSet { redraw() } }
    var layerDMinOffset: [Float] = [0, 0, 0] { didSet { redraw() } }
    /// Whether to draw the three layer curves in addition to the master curve.
    var showsLayers = true { didSet { redraw() } }

    /// Caller-provided parameter ranges for negative and paper curves.
    struct Limits {
        var dMin: ClosedRange<Float> = 0...1.6
        var gamma: ClosedRange<Float> = 0.05...4
        var toe: ClosedRange<Float> = -4 ... -0.05
        var shoulder: ClosedRange<Float> = 0.2...6
        var width: ClosedRange<Float> = 0.02...2.5
        /// Minimum log-exposure separation between the toe and shoulder knees.
        var separation: Float = 0.2

        static let negative = Limits()
        static let paper = Limits(dMin: 0...0.6, gamma: 0.5...8,
                                  toe: -2 ... -0.05, shoulder: 0.05...2,
                                  width: 0.02...1, separation: 0.1)
    }

    var limits = Limits.negative

    /// Called before the first shape change in a drag.
    var onEditBegan: (() -> Void)?
    /// Called for each shape change during a drag.
    var onEdit: ((CurveShape) -> Void)?
    /// Called when a drag ends, allowing one undo entry per drag.
    var onEditEnded: (() -> Void)?

    // MARK: - Handles

    private enum Knob: CaseIterable {
        case base, toe, toeSoftness, slope, shoulder, shoulderSoftness

        var isSoftness: Bool { self == .toeSoftness || self == .shoulderSoftness }

        var title: String {
            switch self {
            case .base: return "Base density"
            case .toe: return "Toe"
            case .toeSoftness: return "Toe softness"
            case .slope: return "Contrast"
            case .shoulder: return "Shoulder"
            case .shoulderSoftness: return "Shoulder softness"
            }
        }
    }

    private var dragging: Knob?
    private var grabOffset = CGSize.zero

    // MARK: - The drawn domain

    private var logRange: ClosedRange<Float> = -2.5...5.5
    private var densityRange: ClosedRange<Float> = 0...3.2

    private func settleDomain() {
        guard dragging == nil else { return }
        let low = min(shape.toe - 1.2, -1.5)
        let high = max(shape.shoulder + 1.2, 1)
        logRange = low...max(high, low + 1)
        let top = max(shape.curve.dMax, 0.5) + 0.25
        densityRange = 0...top
    }

    // MARK: - Readout

    private let readout = makeLabel("", size: 11, color: .secondaryText,
                                    monospacedDigits: true)
    private let xAxis = makeLabel("Stops from mid grey", size: 10,
                                  color: .secondaryText)
    private let yAxis = makeLabel("Density", size: 10, color: .secondaryText)

    override init(frame: CGRect) {
        super.init(frame: frame)
        for label in [readout, xAxis, yAxis] {
            label.translatesAutoresizingMaskIntoConstraints = true
            addSubview(label)
        }
        setAXLabel("Characteristic curve")
        settleDomain()

        onDragBegan = { [weak self] point in self?.begin(at: point) }
        onDragMoved = { [weak self] point in self?.move(to: point) }
        onDragEnded = { [weak self] _ in self?.end() }
    }

    override func layoutContents() {
        let size = bounds.size
        yAxis.frame = CGRect(x: 10, y: 6, width: 120,
                             height: yAxis.compressedSize.height)
        let xSize = xAxis.compressedSize
        xAxis.frame = CGRect(x: size.width - xSize.width - 10,
                             y: size.height - xSize.height - 5,
                             width: xSize.width, height: xSize.height)
        let readoutSize = readout.compressedSize
        readout.frame = CGRect(x: 10, y: size.height - readoutSize.height - 5,
                               width: min(readoutSize.width, size.width - 24),
                               height: readoutSize.height)
    }

    // MARK: - Plot geometry

    private var plot: CGRect {
        CGRect(x: bounds.minX + 22, y: bounds.minY + 24,
               width: max(bounds.width - 34, 1),
               height: max(bounds.height - 52, 1))
    }

    private func point(log: Float, density: Float) -> CGPoint {
        let plot = plot
        let x = (log - logRange.lowerBound)
            / (logRange.upperBound - logRange.lowerBound)
        let y = (density - densityRange.lowerBound)
            / (densityRange.upperBound - densityRange.lowerBound)
        return CGPoint(x: plot.minX + CGFloat(x) * plot.width,
                       y: plot.maxY - CGFloat(y) * plot.height)
    }

    private func log(atX x: CGFloat) -> Float {
        let plot = plot
        guard plot.width > 0 else { return logRange.lowerBound }
        let fraction = Float((x - plot.minX) / plot.width)
        return logRange.lowerBound
            + fraction * (logRange.upperBound - logRange.lowerBound)
    }

    private func density(atY y: CGFloat) -> Float {
        let plot = plot
        guard plot.height > 0 else { return 0 }
        let fraction = Float((plot.maxY - y) / plot.height)
        return densityRange.lowerBound
            + fraction * (densityRange.upperBound - densityRange.lowerBound)
    }

    private func position(of knob: Knob) -> CGPoint {
        switch knob {
        case .base:
            return point(log: logRange.lowerBound + 0.25, density: shape.dMin)
        case .toe:
            return point(log: shape.toe, density: shape.density(at: shape.toe))
        case .toeSoftness:
            let x = shape.toe + shape.toeWidth * 2
            return point(log: x, density: shape.density(at: x))
        case .slope:
            let x = (shape.toe + shape.shoulder) / 2
            return point(log: x, density: shape.density(at: x))
        case .shoulder:
            return point(log: shape.shoulder,
                         density: shape.density(at: shape.shoulder))
        case .shoulderSoftness:
            let x = shape.shoulder - shape.shoulderWidth * 2
            return point(log: x, density: shape.density(at: x))
        }
    }

    // MARK: - Dragging

    private func begin(at point: CGPoint) {
        let nearest = Knob.allCases.min {
            distance(position(of: $0), point) < distance(position(of: $1), point)
        }
        guard let nearest, distance(position(of: nearest), point) <= 26 else {
            dragging = nil
            readout.textValue = ""
            return
        }
        dragging = nearest
        onEditBegan?()
        let handle = position(of: nearest)
        grabOffset = CGSize(width: handle.x - point.x, height: handle.y - point.y)
        show(nearest)
        redraw()
    }

    private func move(to point: CGPoint) {
        guard let dragging else { return }
        let at = CGPoint(x: point.x + grabOffset.width,
                         y: point.y + grabOffset.height)
        var next = shape
        switch dragging {
        case .base:
            next.dMin = clamped(density(atY: at.y), to: limits.dMin)
        case .toe:
            let ceiling = min(limits.toe.upperBound,
                              shape.shoulder - limits.separation)
            next.toe = clamped(log(atX: at.x),
                               to: limits.toe.lowerBound...max(ceiling,
                                                               limits.toe.lowerBound))
        case .toeSoftness:
            next.toeWidth = clamped((log(atX: at.x) - shape.toe) / 2,
                                    to: limits.width)
        case .slope:
            // The straight line is pinned at the toe, so raising the middle of it is exactly
            // raising the slope. Solved against where the line would be at gamma 1.
            let x = (shape.toe + shape.shoulder) / 2
            var unit = shape
            unit.gamma = 1
            let reach = unit.density(at: x) - unit.dMin
            guard reach > 0.001 else { break }
            next.gamma = clamped((density(atY: at.y) - shape.dMin) / reach,
                                 to: limits.gamma)
        case .shoulder:
            let floor = max(limits.shoulder.lowerBound,
                            shape.toe + limits.separation)
            next.shoulder = clamped(log(atX: at.x),
                                    to: floor...max(limits.shoulder.upperBound,
                                                    floor))
        case .shoulderSoftness:
            next.shoulderWidth = clamped((shape.shoulder - log(atX: at.x)) / 2,
                                         to: limits.width)
        }
        guard next != shape else { return }
        shape = next
        show(dragging)
        onEdit?(next)
    }

    private func end() {
        guard dragging != nil else { return }
        dragging = nil
        settleDomain()
        redraw()
        onEditEnded?()
    }

    private func show(_ knob: Knob) {
        let value: String
        switch knob {
        case .base: value = String(format: "%.2f D", shape.dMin)
        case .toe: value = String(format: "%+.2f stops", shape.toe / logPerStop)
        case .toeSoftness:
            value = String(format: "%.2f stops", shape.toeWidth / logPerStop)
        case .slope: value = String(format: "gamma %.2f", shape.gamma)
        case .shoulder:
            value = String(format: "%+.2f stops", shape.shoulder / logPerStop)
        case .shoulderSoftness:
            value = String(format: "%.2f stops", shape.shoulderWidth / logPerStop)
        }
        readout.textValue = "\(knob.title)  \(value)"
        relayout()
    }

    private let logPerStop: Float = 0.30103

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    private func clamped(_ value: Float, to range: ClosedRange<Float>) -> Float {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        let plot = plot
        guard plot.width > 8, plot.height > 8 else { return }

        PlatformBezierPath.rounded(bounds, radius: 12).setFillAndFill(
            PlatformColor.inactiveFill)

        drawGrid(in: plot)
        if showsLayers {
            let tints: [PlatformColor] = [.systemRed, .systemGreen, .systemBlue]
            for layer in 0..<3 {
                var curve = shape
                curve.gamma *= layerGammaTrim.indices.contains(layer)
                    ? layerGammaTrim[layer] : 1
                curve.dMin += layerDMinOffset.indices.contains(layer)
                    ? layerDMinOffset[layer] : 0
                stroke(curve, colour: tints[layer].withAlphaComponent(0.55),
                       width: 1.5)
            }
        }
        stroke(shape, colour: .primaryText, width: showsLayers ? 1 : 2)
        drawHandles()
    }

    private func drawGrid(in plot: CGRect) {
        let path = PlatformBezierPath()
        // Every two stops, and the mid-grey line called out separately below.
        var stop = Float((logRange.lowerBound / logPerStop / 2).rounded(.up)) * 2
        while stop * logPerStop <= logRange.upperBound {
            let x = point(log: stop * logPerStop, density: 0).x
            path.line(from: CGPoint(x: x, y: plot.minY),
                      to: CGPoint(x: x, y: plot.maxY))
            stop += 2
        }
        var density: Float = 0.5
        while density < densityRange.upperBound {
            let y = point(log: 0, density: density).y
            path.line(from: CGPoint(x: plot.minX, y: y),
                      to: CGPoint(x: plot.maxX, y: y))
            density += 0.5
        }
        path.lineWidth = 0.5
        PlatformColor.secondaryText.withAlphaComponent(0.18).setStroke()
        path.stroke()

        // Mid grey: the exposure every other number on this plot is stated against.
        let mid = PlatformBezierPath()
        let x = point(log: 0, density: 0).x
        mid.line(from: CGPoint(x: x, y: plot.minY), to: CGPoint(x: x, y: plot.maxY))
        mid.lineWidth = 1
        PlatformColor.secondaryText.withAlphaComponent(0.45).setStroke()
        mid.stroke()
    }

    private func stroke(_ curve: CurveShape, colour: PlatformColor,
                        width: CGFloat) {
        let plot = plot
        let path = PlatformBezierPath()
        let steps = max(Int(plot.width), 32)
        for step in 0...steps {
            let log = logRange.lowerBound
                + Float(step) / Float(steps)
                * (logRange.upperBound - logRange.lowerBound)
            let at = point(log: log, density: curve.density(at: log))
            if step == 0 { path.move(to: at) } else { path.addLineOrLine(to: at) }
        }
        path.lineWidth = width
        colour.setStroke()
        path.stroke()
    }

    private func drawHandles() {
        for knob in Knob.allCases {
            let at = position(of: knob)
            let radius: CGFloat = knob.isSoftness ? 4 : 5.5
            let box = CGRect(x: at.x - radius, y: at.y - radius,
                             width: radius * 2, height: radius * 2)
            let path = PlatformBezierPath.rounded(box, radius: radius)
            if knob.isSoftness && dragging != knob {
                PlatformColor.accent.withAlphaComponent(0.9).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            } else {
                (dragging == knob ? PlatformColor.accent
                    : PlatformColor.accent.withAlphaComponent(0.85)).setFill()
                path.fill()
                PlatformColor.white.withAlphaComponent(0.9).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }
}

private extension PlatformBezierPath {
    /// `addLine(to:)` on one framework, `line(to:)` on the other.
    func addLineOrLine(to point: CGPoint) {
        #if canImport(UIKit)
        addLine(to: point)
        #else
        line(to: point)
        #endif
    }

    func setFillAndFill(_ colour: PlatformColor) {
        colour.setFill()
        fill()
    }
}
