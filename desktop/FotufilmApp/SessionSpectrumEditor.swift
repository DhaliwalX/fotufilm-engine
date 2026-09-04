#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Where the three layers listen, as one value the editor can return.
///
/// A colour film's peaks and bandwidths, or a panchromatic film's three weights — the same view
/// draws both, because in both cases what the author is choosing is a shape against wavelength.
struct SpectrumShape: Equatable {
    /// Nanometres, one per layer. Ignored for a panchromatic emulsion, whose bands are fixed.
    var peaks: [Float]
    /// Nanometres, one per layer: how wide a band each answers over.
    var widths: [Float]
    /// What one panchromatic emulsion makes of red, green and blue.
    var monoWeights: [Float]
    /// True for a black-and-white film: one emulsion, three fixed bands, heights to choose.
    var isMonochrome: Bool
}

/// What a spectral graph is a graph of, which decides its names and its tints: capture layers
/// answer in R/G/B, image dyes absorb in C/M/Y.
enum SpectrumFlavor {
    case sensitivity, dye
}

/// Edits spectral sensitivity or dye curves through peak, bandwidth, and control-point handles.
/// Displayed curves use `FilmSpectralProfile` sampling so they match the engine input.
final class SpectrumEditorView: DragTarget {

    /// What is being edited. Setting this redraws but does not call back.
    var shape = SpectrumShape(peaks: [650, 550, 450], widths: [58, 46, 42],
                              monoWeights: [0.32, 0.48, 0.20],
                              isMonochrome: false) {
        didSet {
            guard shape != oldValue else { return }
            redraw()
        }
    }

    /// Hand-drawn curves, one row per layer. Non-nil puts the whole view in drawn mode.
    var points: [[SpectralControlPoint]]? {
        didSet {
            guard points != oldValue else { return }
            if let points, !points.indices.contains(activeLayer) { activeLayer = 0 }
            redraw()
        }
    }

    /// Which row's handles are up in drawn mode. The other rows stay stroked, faintly, because a
    /// dye is only readable against the other two.
    var activeLayer = 0 {
        didSet {
            guard activeLayer != oldValue else { return }
            redraw()
        }
    }

    var flavor = SpectrumFlavor.sensitivity {
        didSet {
            guard flavor != oldValue else { return }
            yAxis.textValue = flavor == .dye ? "Dye share" : "Sensitivity"
            redraw()
        }
    }

    /// Called once when a handle is taken hold of, or a new one is about to be placed — while the
    /// curve about to change is still the curve to remember.
    var onEditBegan: (() -> Void)?
    /// Called on every change a drag makes, so the preview follows the pointer.
    var onEdit: ((SpectrumShape) -> Void)?
    /// The drawn-mode counterpart, handing back every row.
    var onPointsEdit: (([[SpectralControlPoint]]) -> Void)?
    /// Called once when the pointer lifts, for one undo step per drag rather than one per pixel.
    var onEditEnded: (() -> Void)?

    private let peakRange: ClosedRange<Float> = 395...715
    private let widthRange: ClosedRange<Float> = 12...110
    private let weightRange: ClosedRange<Float> = 0...1

    // MARK: - Handles

    private struct Knob {
        var layer: Int
        var kind: Kind
        enum Kind { case peak, band, weight }
    }

    private var knobs: [Knob] {
        guard !shape.isMonochrome else {
            return (0..<3).map { Knob(layer: $0, kind: .weight) }
        }
        return (0..<3).flatMap {
            [Knob(layer: $0, kind: .peak), Knob(layer: $0, kind: .band)]
        }
    }

    private var dragging: Knob?
    private var grabOffset = CGSize.zero

    private var draggingPoint: (layer: Int, index: Int)?
    private var pendingRemoval = false

    // MARK: - The drawn domain

    private let nmRange: ClosedRange<Float> = 380...780

    private let halfHeightSigmas: Float = 1.1774

    // MARK: - Readout

    private let readout = makeLabel("", size: 11, color: .secondaryText,
                                    monospacedDigits: true)
    private let xAxis = makeLabel("Wavelength (nm)", size: 10, color: .secondaryText)
    private let yAxis = makeLabel("Sensitivity", size: 10, color: .secondaryText)
    private static let ticksNM: [Float] = [400, 500, 600, 700]
    private let ticks = ticksNM.map {
        makeLabel(String(format: "%.0f", $0), size: 9, color: .secondaryText)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for label in [readout, xAxis, yAxis] + ticks {
            label.translatesAutoresizingMaskIntoConstraints = true
            addSubview(label)
        }
        for label in ticks { label.alignment = .center }
        setAXLabel("Layer sensitivity")

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
        let plot = plot
        for (index, label) in ticks.enumerated() {
            let x = point(nm: Self.ticksNM[index], level: 0).x
            label.frame = CGRect(x: x - 16, y: plot.maxY + 2, width: 32,
                                 height: label.compressedSize.height)
        }
    }

    // MARK: - Plot geometry

    private var plot: CGRect {
        CGRect(x: bounds.minX + 22, y: bounds.minY + 24,
               width: max(bounds.width - 34, 1),
               height: max(bounds.height - 52, 1))
    }

    private func point(nm: Float, level: Float) -> CGPoint {
        let plot = plot
        let x = (nm - nmRange.lowerBound)
            / (nmRange.upperBound - nmRange.lowerBound)
        return CGPoint(x: plot.minX + CGFloat(x) * plot.width,
                       y: plot.maxY - CGFloat(level) * plot.height)
    }

    private func nm(atX x: CGFloat) -> Float {
        let plot = plot
        guard plot.width > 0 else { return nmRange.lowerBound }
        let fraction = Float((x - plot.minX) / plot.width)
        return nmRange.lowerBound
            + fraction * (nmRange.upperBound - nmRange.lowerBound)
    }

    private func level(atY y: CGFloat) -> Float {
        let plot = plot
        guard plot.height > 0 else { return 0 }
        return Float((plot.maxY - y) / plot.height)
    }

    private func value(_ values: [Float], _ index: Int,
                       or fallback: Float) -> Float {
        values.indices.contains(index) ? values[index] : fallback
    }

    private func peak(_ layer: Int) -> Float {
        value(shape.peaks, layer, or: 550)
    }

    private func width(_ layer: Int) -> Float {
        value(shape.widths, layer, or: 46)
    }

    private func weight(_ layer: Int) -> Float {
        value(shape.monoWeights, layer, or: 0.33)
    }

    private func halfHeightOffset(_ layer: Int) -> Float {
        let sigma = FilmSpectralProfile
            .colorLayerSigmas(layer: layer, widthNM: width(layer)).right
        return sigma * halfHeightSigmas
    }

    private func position(of knob: Knob) -> CGPoint {
        switch knob.kind {
        case .peak:
            return point(nm: peak(knob.layer), level: 1)
        case .band:
            return point(nm: peak(knob.layer) + halfHeightOffset(knob.layer),
                         level: 0.5)
        case .weight:
            let centres = FilmSpectralProfile.monochromeBandsNM.centres
            return point(nm: value(centres, knob.layer, or: 550),
                         level: weight(knob.layer))
        }
    }

    // MARK: - Dragging

    private func begin(at point: CGPoint) {
        if points != nil { return beginDrawn(at: point) }
        let all = knobs
        let nearest = all.min {
            distance(position(of: $0), point) < distance(position(of: $1), point)
        }
        guard let nearest, distance(position(of: nearest), point) <= 26 else {
            dragging = nil
            readout.textValue = ""
            relayout()
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
        if points != nil { return moveDrawn(to: point) }
        guard let dragging else { return }
        let at = CGPoint(x: point.x + grabOffset.width,
                         y: point.y + grabOffset.height)
        var next = shape
        while next.peaks.count < 3 { next.peaks.append(550) }
        while next.widths.count < 3 { next.widths.append(46) }
        while next.monoWeights.count < 3 { next.monoWeights.append(0.33) }

        switch dragging.kind {
        case .peak:
            // The band handle is drawn relative to the peak, so moving the peak carries it along
            // rather than stretching the lobe — one gesture, one number.
            next.peaks[dragging.layer] = clamped(nm(atX: at.x), to: peakRange)
        case .band:
            let sigmas = FilmSpectralProfile.colorLayerSigmas(layer: dragging.layer,
                                                              widthNM: 1)
            let perNM = max(sigmas.right * halfHeightSigmas, 0.01)
            let reach = nm(atX: at.x) - peak(dragging.layer)
            next.widths[dragging.layer] = clamped(reach / perNM, to: widthRange)
        case .weight:
            next.monoWeights[dragging.layer] = clamped(level(atY: at.y),
                                                       to: weightRange)
        }
        guard next != shape else { return }
        shape = next
        show(dragging)
        onEdit?(next)
    }

    private func end() {
        if points != nil { return endDrawn() }
        guard dragging != nil else { return }
        dragging = nil
        redraw()
        onEditEnded?()
    }

    // MARK: - Drawn mode

    private var drawnNames: [String] {
        if (points?.count ?? 3) == 1 { return ["Emulsion"] }
        return flavor == .dye ? ["Cyan", "Magenta", "Yellow"] : Self.layerNames
    }

    private var drawnTints: [PlatformColor] {
        if (points?.count ?? 3) == 1 { return [.primaryText] }
        return flavor == .dye ? Self.dyeTints : Self.tints
    }

    private static let dyeTints: [PlatformColor] = [
        PlatformColor(red: 0.0, green: 0.62, blue: 0.75, alpha: 1),
        PlatformColor(red: 0.82, green: 0.18, blue: 0.55, alpha: 1),
        PlatformColor(red: 0.78, green: 0.62, blue: 0.05, alpha: 1),
    ]

    private func chipRect(_ layer: Int, rows: Int) -> CGRect {
        let size = CGSize(width: 24, height: 15)
        let x = plot.maxX - CGFloat(rows - layer) * (size.width + 6) + 6
        return CGRect(x: x, y: 4, width: size.width, height: size.height)
    }

    private func beginDrawn(at location: CGPoint) {
        guard var rows = points, !rows.isEmpty else { return }

        if rows.count > 1 {
            for layer in rows.indices
            where chipRect(layer, rows: rows.count)
                .insetBy(dx: -6, dy: -6).contains(location) {
                activeLayer = layer
                readout.textValue = "\(drawnNames[layer]) curve"
                relayout()
                return
            }
        }

        func nearest(in layer: Int) -> (index: Int, distance: CGFloat)? {
            rows[layer].indices
                .map { ($0, distance(handlePosition(rows[layer][$0]), location)) }
                .min { $0.1 < $1.1 }
        }

        // The active row's handles have the first claim; a handle on another row close under the
        // pointer takes the pointer to its row, which is how the rows are reached without chips.
        if let hit = nearest(in: activeLayer), hit.distance <= 20 {
            grab(layer: activeLayer, index: hit.index, at: location, rows: rows)
            return
        }
        for layer in rows.indices where layer != activeLayer {
            if let hit = nearest(in: layer), hit.distance <= 12 {
                activeLayer = layer
                grab(layer: layer, index: hit.index, at: location, rows: rows)
                return
            }
        }

        // Empty plot: a press is a new handle, already in hand.
        guard plot.insetBy(dx: -8, dy: -8).contains(location) else {
            draggingPoint = nil
            readout.textValue = ""
            relayout()
            return
        }
        onEditBegan?()
        let added = SpectralControlPoint(
            nm: clamped(nm(atX: location.x), to: nmRange),
            value: clamped(level(atY: location.y), to: 0...1))
        let index = rows[activeLayer].firstIndex { $0.nm > added.nm }
            ?? rows[activeLayer].count
        rows[activeLayer].insert(added, at: index)
        points = rows
        grabOffset = .zero
        draggingPoint = (activeLayer, index)
        pendingRemoval = false
        showDrawn(added)
        onPointsEdit?(rows)
    }

    private func grab(layer: Int, index: Int, at location: CGPoint,
                      rows: [[SpectralControlPoint]]) {
        onEditBegan?()
        let handle = handlePosition(rows[layer][index])
        grabOffset = CGSize(width: handle.x - location.x,
                            height: handle.y - location.y)
        draggingPoint = (layer, index)
        pendingRemoval = false
        showDrawn(rows[layer][index])
        redraw()
    }

    private func moveDrawn(to location: CGPoint) {
        guard let dragging = draggingPoint, var rows = points,
              rows.indices.contains(dragging.layer),
              rows[dragging.layer].indices.contains(dragging.index) else { return }
        let at = CGPoint(x: location.x + grabOffset.width,
                         y: location.y + grabOffset.height)
        var row = rows[dragging.layer]

        // A handle stays between its neighbours: the curve is a function of wavelength, and two
        // handles crossing would fold it back on itself.
        let lower = dragging.index > 0
            ? row[dragging.index - 1].nm + 2 : nmRange.lowerBound
        let upper = dragging.index < row.count - 1
            ? row[dragging.index + 1].nm - 2 : nmRange.upperBound
        row[dragging.index].nm = clamped(nm(atX: at.x),
                                         to: min(lower, upper)...max(lower, upper))
        row[dragging.index].value = clamped(level(atY: at.y), to: 0...1)
        pendingRemoval = row.count > 2 && location.y > plot.maxY + 24

        guard row != rows[dragging.layer] || pendingRemoval else { return }
        rows[dragging.layer] = row
        points = rows
        if pendingRemoval {
            readout.textValue = "Release to remove"
            relayout()
        } else {
            showDrawn(row[dragging.index])
        }
        redraw()
        onPointsEdit?(rows)
    }

    private func endDrawn() {
        guard let dragging = draggingPoint else { return }
        if pendingRemoval, var rows = points,
           rows.indices.contains(dragging.layer),
           rows[dragging.layer].count > 2 {
            rows[dragging.layer].remove(at: dragging.index)
            points = rows
            onPointsEdit?(rows)
        }
        pendingRemoval = false
        draggingPoint = nil
        readout.textValue = ""
        relayout()
        redraw()
        onEditEnded?()
    }

    private func handlePosition(_ point: SpectralControlPoint) -> CGPoint {
        self.point(nm: point.nm, level: point.value)
    }

    private func showDrawn(_ point: SpectralControlPoint) {
        readout.textValue = String(format: "%@  %.0f nm · %.2f",
                                   drawnNames[min(activeLayer, drawnNames.count - 1)],
                                   point.nm, point.value)
        relayout()
    }

    private static let layerNames = ["Red", "Green", "Blue"]

    private func show(_ knob: Knob) {
        let name = Self.layerNames[min(knob.layer, 2)]
        let text: String
        switch knob.kind {
        case .peak:
            text = String(format: "%@ peak  %.0f nm", name, peak(knob.layer))
        case .band:
            text = String(format: "%@ bandwidth  %.0f nm", name, width(knob.layer))
        case .weight:
            text = String(format: "%@ response  %.2f", name, weight(knob.layer))
        }
        readout.textValue = text
        relayout()
    }

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

        drawSpectrum(in: plot)
        drawGrid(in: plot)
        if points != nil {
            drawDrawnCurves()
            drawChips()
        } else {
            if shape.isMonochrome { drawBands() } else { drawLobes() }
            drawHandles()
        }
    }

    private func drawDrawnCurves() {
        guard let rows = points else { return }
        let plot = plot
        let tints = drawnTints

        func stroke(_ row: [SpectralControlPoint], tint: PlatformColor,
                    active: Bool) {
            let values = SpectralCurve.resampled(row)
            let path = PlatformBezierPath()
            let fill = PlatformBezierPath()
            for (index, nm) in SpectralGrid.wavelengths.enumerated() {
                let at = point(nm: nm, level: min(values[index], 1))
                if index == 0 {
                    path.move(to: at)
                    fill.move(to: CGPoint(x: at.x, y: plot.maxY))
                    fill.addLineOrLine(to: at)
                } else {
                    path.addLineOrLine(to: at)
                    fill.addLineOrLine(to: at)
                }
            }
            if active {
                fill.addLineOrLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                fill.close()
                tint.withAlphaComponent(0.14).setFill()
                fill.fill()
            }
            path.lineWidth = active ? 2 : 1.25
            tint.withAlphaComponent(active ? 0.95 : 0.4).setStroke()
            path.stroke()
        }

        for (layer, row) in rows.enumerated() where layer != activeLayer {
            stroke(row, tint: tints[min(layer, tints.count - 1)], active: false)
        }
        guard rows.indices.contains(activeLayer) else { return }
        let tint = tints[min(activeLayer, tints.count - 1)]
        stroke(rows[activeLayer], tint: tint, active: true)

        for (index, handle) in rows[activeLayer].enumerated() {
            let at = handlePosition(handle)
            let held = draggingPoint.map {
                $0.layer == activeLayer && $0.index == index
            } ?? false
            let radius: CGFloat = held ? 6 : 4.5
            let box = CGRect(x: at.x - radius, y: at.y - radius,
                             width: radius * 2, height: radius * 2)
            let path = PlatformBezierPath.rounded(box, radius: radius)
            let fading = held && pendingRemoval
            (fading ? PlatformColor.secondaryText
                    : (held ? PlatformColor.accent : tint)).setFill()
            path.fill()
            PlatformColor.white.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawChips() {
        guard let rows = points, rows.count > 1 else { return }
        let tints = drawnTints
        for layer in rows.indices {
            let box = chipRect(layer, rows: rows.count)
            let path = PlatformBezierPath.rounded(box, radius: 4)
            tints[min(layer, tints.count - 1)]
                .withAlphaComponent(layer == activeLayer ? 0.9 : 0.3).setFill()
            path.fill()
            if layer == activeLayer {
                PlatformColor.primaryText.withAlphaComponent(0.6).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    private func drawSpectrum(in plot: CGRect) {
        let height: CGFloat = 6
        let strip = CGRect(x: plot.minX, y: plot.maxY - height,
                           width: plot.width, height: height)
        let steps = max(Int(strip.width / 2), 24)
        for step in 0..<steps {
            let fraction = Float(step) / Float(steps)
            let nm = nmRange.lowerBound
                + fraction * (nmRange.upperBound - nmRange.lowerBound)
            let slice = CGRect(x: strip.minX + CGFloat(step) * strip.width
                                / CGFloat(steps),
                               y: strip.minY,
                               width: strip.width / CGFloat(steps) + 1,
                               height: strip.height)
            PlatformBezierPath(rect: slice).setFillAndFill(
                Self.visibleColour(nm: nm).withAlphaComponent(0.5))
        }
    }

    private static func visibleColour(nm: Float) -> PlatformColor {
        var r: Float = 0, g: Float = 0, b: Float = 0
        switch nm {
        case ..<440: (r, g, b) = ((440 - nm) / 60, 0, 1)
        case ..<490: (r, g, b) = (0, (nm - 440) / 50, 1)
        case ..<510: (r, g, b) = (0, 1, (510 - nm) / 20)
        case ..<580: (r, g, b) = ((nm - 510) / 70, 1, 0)
        case ..<645: (r, g, b) = (1, (645 - nm) / 65, 0)
        default: (r, g, b) = (1, 0, 0)
        }
        // The eye gives out at both ends, and a strip that stays saturated there implies a
        // sensitivity the plot is not claiming.
        let fade: Float
        switch nm {
        case ..<420: fade = max(0.3 + 0.7 * (nm - 380) / 40, 0)
        case 680...: fade = max(0.25 + 0.75 * (780 - nm) / 100, 0)
        default: fade = 1
        }
        return PlatformColor(red: CGFloat(min(max(r, 0), 1) * fade),
                             green: CGFloat(min(max(g, 0), 1) * fade),
                             blue: CGFloat(min(max(b, 0), 1) * fade),
                             alpha: 1)
    }

    private func drawGrid(in plot: CGRect) {
        let path = PlatformBezierPath()
        for nm in stride(from: Float(400), through: 700, by: 50) {
            let x = point(nm: nm, level: 0).x
            path.line(from: CGPoint(x: x, y: plot.minY),
                      to: CGPoint(x: x, y: plot.maxY))
        }
        for level in stride(from: Float(0.25), through: 1, by: 0.25) {
            let y = point(nm: nmRange.lowerBound, level: level).y
            path.line(from: CGPoint(x: plot.minX, y: y),
                      to: CGPoint(x: plot.maxX, y: y))
        }
        path.lineWidth = 0.5
        PlatformColor.secondaryText.withAlphaComponent(0.18).setStroke()
        path.stroke()
    }

    private static let tints: [PlatformColor] = [.systemRed, .systemGreen,
                                                 .systemBlue]

    private func drawLobes() {
        let plot = plot
        let steps = max(Int(plot.width), 48)
        for layer in 0..<3 {
            let path = PlatformBezierPath()
            let fill = PlatformBezierPath()
            for step in 0...steps {
                let nm = nmRange.lowerBound + Float(step) / Float(steps)
                    * (nmRange.upperBound - nmRange.lowerBound)
                let level = FilmSpectralProfile.colorLayerSensitivity(
                    layer: layer, peakNM: peak(layer), widthNM: width(layer),
                    atNM: nm)
                let at = point(nm: nm, level: level)
                if step == 0 {
                    path.move(to: at)
                    fill.move(to: CGPoint(x: at.x, y: plot.maxY))
                    fill.addLineOrLine(to: at)
                } else {
                    path.addLineOrLine(to: at)
                    fill.addLineOrLine(to: at)
                }
            }
            fill.addLineOrLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
            fill.close()
            Self.tints[layer].withAlphaComponent(0.16).setFill()
            fill.fill()
            path.lineWidth = 1.75
            Self.tints[layer].withAlphaComponent(0.95).setStroke()
            path.stroke()
        }
    }

    private func drawBands() {
        let plot = plot
        let centres = FilmSpectralProfile.monochromeBandsNM.centres
        let widths = FilmSpectralProfile.monochromeBandsNM.widths
        let steps = max(Int(plot.width), 48)

        func band(_ index: Int, at nm: Float) -> Float {
            let sigma = max(value(widths, index, or: 60), 1)
            let x = (nm - value(centres, index, or: 550)) / sigma
            return exp(-0.5 * x * x)
        }

        for layer in 0..<3 {
            let path = PlatformBezierPath()
            for step in 0...steps {
                let nm = nmRange.lowerBound + Float(step) / Float(steps)
                    * (nmRange.upperBound - nmRange.lowerBound)
                let at = point(nm: nm, level: band(layer, at: nm) * weight(layer))
                if step == 0 { path.move(to: at) } else { path.addLineOrLine(to: at) }
            }
            path.lineWidth = 1
            Self.tints[layer].withAlphaComponent(0.5).setStroke()
            path.stroke()
        }

        let total = PlatformBezierPath()
        for step in 0...steps {
            let nm = nmRange.lowerBound + Float(step) / Float(steps)
                * (nmRange.upperBound - nmRange.lowerBound)
            let sum = (0..<3).reduce(Float(0)) {
                $0 + band($1, at: nm) * weight($1)
            }
            let at = point(nm: nm, level: min(sum, 1))
            if step == 0 { total.move(to: at) } else { total.addLineOrLine(to: at) }
        }
        total.lineWidth = 2
        PlatformColor.primaryText.setStroke()
        total.stroke()
    }

    private func drawHandles() {
        for knob in knobs {
            let at = position(of: knob)
            let held = dragging.map { $0.layer == knob.layer && $0.kind == knob.kind }
                ?? false
            let hollow = knob.kind == .band && !held
            let radius: CGFloat = hollow ? 4 : 5.5
            let box = CGRect(x: at.x - radius, y: at.y - radius,
                             width: radius * 2, height: radius * 2)
            let path = PlatformBezierPath.rounded(box, radius: radius)
            if hollow {
                Self.tints[knob.layer].setStroke()
                path.lineWidth = 1.5
                path.stroke()
            } else {
                (held ? PlatformColor.accent : Self.tints[knob.layer]).setFill()
                path.fill()
                PlatformColor.white.withAlphaComponent(0.9).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }
}

private extension PlatformBezierPath {
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
