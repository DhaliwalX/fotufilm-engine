import CoreGraphics
import Foundation
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// The crop: the photograph is drawn by this view rather than by the zoomable canvas, scaled so that
/// the crop sits large and centred — and when a drag ends, the picture settles to re-centre what was
/// just chosen.
///
/// Every rectangle here has its origin at the top left, which is what `SessionView` gives on both
/// platforms.
final class CropCanvasView: DragTarget {
    private let model: DesktopEditorModel

    private enum Side { case minX, maxX, minY, maxY }

    private enum Grip: Equatable {
        case move
        case corner(minX: Bool, minY: Bool)
        case edge(Side)
    }

    // A drag changes only this view. Publishing each pointer event to EditState wakes
    // the whole editor, including thumbnail generation and persistence.
    private var draftRectangle: CGRect?
    private var draftCorners: QuadrilateralCrop?
    private var dragStartEdit: EditState?
    private var dragSourceToken: UUID?
    private weak var previewSource: PlatformImage?
    private var previewImage: PlatformImage?
    private var previewGeneration = UUID()

    private var corners: QuadrilateralCrop? { draftCorners ?? model.edit.cornerCrop }

    private var cornerGrip: Int?
    private var grip: Grip?
    private var dragActive = false
    private var startRect = CGRect.zero
    private var startLocation = CGPoint.zero
    private var focusCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    private let handleReach: CGFloat = 22
    private let minSide: CGFloat = 44
    private let stageInset: CGFloat = 24

    /// What the fitted stage keeps clear of — the same insets the ordinary canvas fits by, so
    /// entering the mode does not jump the picture.
    var insets = PlatformEdgeInsets() {
        didSet { redraw() }
    }

    private var focusTravel: (from: CGRect, to: CGRect,
                              start: CFTimeInterval, duration: CFTimeInterval)?
    private var displayLink: CADisplayLink?
    private var thirdsStrength: CGFloat = 0
    private var wantsThirds = false

    init(model: DesktopEditorModel) {
        self.model = model
        super.init(frame: .zero)
        focusCrop = unitCrop
        setAXLabel("Crop rectangle")
        onDragBegan = { [weak self] point in self?.began(at: point) }
        onDragMoved = { [weak self] point in self?.moved(to: point) }
        onDragEnded = { [weak self] _ in self?.ended() }
    }

    #if canImport(UIKit)
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopDisplayLink() }
    }
    #else
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopDisplayLink() }
    }
    #endif

    /// The crop changed under the view — an aspect chosen in the inspector, an undo — so the stage
    /// re-frames what is now selected.
    func cropChangedExternally() {
        guard !dragActive else { return }
        travel(to: unitCrop)
        redraw()
    }

    func imageChanged() {
        setAXLabel(model.edit.cornerCrop == nil ? "Crop rectangle" : "Four-corner crop")
        preparePreview()
        redraw()
    }

    /// Rasterize a bounded display copy once per print, off the UI thread. Drag frames
    /// reuse it instead of repeatedly scaling a full-resolution scan. Export keeps the original.
    private func preparePreview() {
        guard previewSource !== model.processed else { return }
        previewSource = model.processed
        previewImage = nil
        let generation = UUID()
        previewGeneration = generation
        guard let source = model.processed else { return }
        #if canImport(UIKit)
        let cg = source.cgImage
        #else
        let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
        guard let cg, max(cg.width, cg.height) > 2048 else {
            previewImage = source
            return
        }
        Task { [weak self] in
            let reduced = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let scale = 2048 / Double(max(cg.width, cg.height))
                let width = max(1, Int(Double(cg.width) * scale))
                let height = max(1, Int(Double(cg.height) * scale))
                guard let context = CGContext(data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.displayP3)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.interpolationQuality = .high
                context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                return context.makeImage()
            }.value
            guard let self, self.previewGeneration == generation, let reduced else { return }
            self.previewImage = PlatformImage.from(reduced)
            self.redraw()
        }
    }

    // MARK: - Geometry

    private var stageRect: CGRect {
        CGRect(x: insets.left + stageInset,
               y: insets.top + stageInset,
               width: bounds.width - insets.left - insets.right - stageInset * 2,
               height: bounds.height - insets.top - insets.bottom - stageInset * 2)
    }

    private struct Presentation {
        let imageRect: CGRect
        private let unitScale: CGSize

        init(imageSize: CGSize, stage: CGRect, focus: CGRect) {
            let width = max(focus.width, 0.01) * max(imageSize.width, 1)
            let height = max(focus.height, 0.01) * max(imageSize.height, 1)
            let scale = min(stage.width / width, stage.height / height)
            imageRect = CGRect(
                x: stage.midX - focus.midX * imageSize.width * scale,
                y: stage.midY - focus.midY * imageSize.height * scale,
                width: imageSize.width * scale,
                height: imageSize.height * scale)
            unitScale = CGSize(width: imageSize.width * scale,
                               height: imageSize.height * scale)
        }

        func display(_ unit: CGRect) -> CGRect {
            CGRect(x: imageRect.minX + unit.minX * unitScale.width,
                   y: imageRect.minY + unit.minY * unitScale.height,
                   width: unit.width * unitScale.width,
                   height: unit.height * unitScale.height)
        }

        func unit(_ display: CGRect) -> CGRect {
            CGRect(x: (display.minX - imageRect.minX) / unitScale.width,
                   y: (display.minY - imageRect.minY) / unitScale.height,
                   width: display.width / unitScale.width,
                   height: display.height / unitScale.height)
        }
    }

    private var unitCrop: CGRect {
        draftRectangle ?? UnitCropCoordinates.verticallyFlipped(
            model.edit.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private var presentation: Presentation? {
        guard let image = model.processed else { return nil }
        let stage = stageRect
        guard stage.width > 1, stage.height > 1 else { return nil }
        return Presentation(imageSize: image.size, stage: stage, focus: corners == nil ? focusCrop : CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func write(_ rect: CGRect, presentation: Presentation) {
        draftRectangle = presentation.unit(rect)
    }

    private var lockedRatio: CGFloat? {
        guard let image = model.processed else { return nil }
        return model.cropAspect.ratio(for: image.size)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: CGRect) {
        guard let image = model.processed, let presentation,
              let context = Draw.context else { return }
        let rect = presentation.display(unitCrop)

        (previewImage ?? image).draw(into: presentation.imageRect)
        if let corners {
            let points = corners.points.map { point in
                CGPoint(x: presentation.imageRect.minX + point.x * presentation.imageRect.width,
                        y: presentation.imageRect.minY + point.y * presentation.imageRect.height)
            }
            context.addRect(bounds)
            context.addLines(between: points)
            context.closePath()
            context.setFillColor(PlatformColor.black.withAlphaComponent(0.45).cgColor)
            context.fillPath(using: .evenOdd)
            context.addLines(between: points)
            context.closePath()
            context.setStrokeColor(PlatformColor.white.cgColor)
            context.setLineWidth(2)
            context.strokePath()
            for point in points {
                let handle = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
                context.setFillColor(PlatformColor.white.cgColor)
                context.fillEllipse(in: handle)
                context.setStrokeColor(PlatformColor.black.cgColor)
                context.strokeEllipse(in: handle)
            }
            return
        }

        // Everything outside the chosen rectangle, held back.
        context.setFillColor(PlatformColor.black.withAlphaComponent(0.45).cgColor)
        context.addRect(bounds)
        context.addRect(rect)
        context.fillPath(using: .evenOdd)

        if thirdsStrength > 0.001 {
            context.setStrokeColor(
                PlatformColor.white.withAlphaComponent(0.4 * thirdsStrength).cgColor)
            context.setLineWidth(0.5)
            for third in [1.0 / 3.0, 2.0 / 3.0] {
                let x = rect.minX + rect.width * third
                context.move(to: CGPoint(x: x, y: rect.minY))
                context.addLine(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * third
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.strokePath()
        }

        // The frame and its brackets are drawn over a photograph of unknown brightness, so they
        // carry a shadow of their own rather than trusting white to be legible.
        Draw.shadowed(color: PlatformColor.black.withAlphaComponent(0.4),
                      blur: 1, offset: .zero) {
            context.setStrokeColor(PlatformColor.white.cgColor)
            context.setLineWidth(1.5)
            context.stroke(rect)

            context.setLineWidth(3)
            context.setLineCap(.round)
            let arm: CGFloat = 18
            func bracket(_ x: CGFloat, _ y: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
                context.move(to: CGPoint(x: x + dx * arm, y: y))
                context.addLine(to: CGPoint(x: x, y: y))
                context.addLine(to: CGPoint(x: x, y: y + dy * arm))
            }
            bracket(rect.minX, rect.minY, 1, 1)
            bracket(rect.maxX, rect.minY, -1, 1)
            bracket(rect.minX, rect.maxY, 1, -1)
            bracket(rect.maxX, rect.maxY, -1, -1)
            let tick: CGFloat = 14
            context.move(to: CGPoint(x: rect.midX - tick, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.midX + tick, y: rect.minY))
            context.move(to: CGPoint(x: rect.midX - tick, y: rect.maxY))
            context.addLine(to: CGPoint(x: rect.midX + tick, y: rect.maxY))
            context.move(to: CGPoint(x: rect.minX, y: rect.midY - tick))
            context.addLine(to: CGPoint(x: rect.minX, y: rect.midY + tick))
            context.move(to: CGPoint(x: rect.maxX, y: rect.midY - tick))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY + tick))
            context.strokePath()
        }
    }

    // MARK: - Dragging

    private func began(at location: CGPoint) {
        guard let presentation else { return }
        focusTravel = nil
        if let corners {
            cornerGrip = corners.points.indices.min { a, b in
                distance(corners.points[a], to: location, frame: presentation.imageRect)
                    < distance(corners.points[b], to: location, frame: presentation.imageRect)
            }
            if let index = cornerGrip,
               distance(corners.points[index], to: location, frame: presentation.imageRect) <= handleReach {
                draftCorners = corners
                dragActive = true
                dragStartEdit = model.edit
                dragSourceToken = model.canvasResetToken
            } else { cornerGrip = nil }
            return
        }
        let rect = presentation.display(unitCrop)
        dragActive = true
        startLocation = location
        startRect = rect
        grip = hitTest(location, rect: rect)
        if grip != nil {
            draftRectangle = unitCrop
            dragStartEdit = model.edit
            dragSourceToken = model.canvasResetToken
            setThirds(visible: true)
        }
    }

    private func distance(_ unit: CGPoint, to location: CGPoint, frame: CGRect) -> CGFloat {
        hypot(frame.minX + unit.x * frame.width - location.x,
              frame.minY + unit.y * frame.height - location.y)
    }

    private func moved(to location: CGPoint) {
        if let index = cornerGrip, let corners = draftCorners, let presentation {
            let frame = presentation.imageRect
            draftCorners = corners.movingCorner(index, to: CGPoint(
                x: (location.x - frame.minX) / frame.width,
                y: (location.y - frame.minY) / frame.height))
            redraw()
            return
        }
        guard dragActive, let grip, let presentation else { return }
        apply(grip,
              translation: CGSize(width: location.x - startLocation.x,
                                  height: location.y - startLocation.y),
              presentation: presentation)
        redraw()
    }

    private func ended() {
        let rectangle = draftRectangle, quadrilateral = draftCorners
        let initial = dragStartEdit, token = dragSourceToken
        draftRectangle = nil
        draftCorners = nil
        dragStartEdit = nil
        dragSourceToken = nil
        cornerGrip = nil
        grip = nil
        dragActive = false

        // An undo or another photograph arriving during a drag supersedes the local draft.
        if token == model.canvasResetToken, let initial, model.edit == initial {
            var next = initial
            if let quadrilateral {
                next.cornerCrop = quadrilateral
            } else if let rectangle {
                next.crop = rectangle.width > 0.999 && rectangle.height > 0.999
                    ? nil : UnitCropCoordinates.verticallyFlipped(rectangle)
            }
            if next != initial {
                model.beginContinuousEdit()
                model.edit = next
                model.endContinuousEdit()
            }
        }
        setThirds(visible: false)
        if corners == nil { travel(to: unitCrop) }
        redraw()
    }

    #if !canImport(UIKit)
    /// The pointer says what a press would do before it is pressed. A finger has nothing to say in
    /// advance, so this is the Mac's alone.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let presentation else { return }
        let rect = presentation.display(unitCrop)
        addCursorRect(rect.insetBy(dx: handleReach, dy: handleReach),
                      cursor: .openHand)
        let horizontal = NSCursor.resizeLeftRight
        let vertical = NSCursor.resizeUpDown
        addCursorRect(CGRect(x: rect.minX - handleReach, y: rect.minY,
                             width: handleReach * 2, height: rect.height),
                      cursor: horizontal)
        addCursorRect(CGRect(x: rect.maxX - handleReach, y: rect.minY,
                             width: handleReach * 2, height: rect.height),
                      cursor: horizontal)
        addCursorRect(CGRect(x: rect.minX, y: rect.minY - handleReach,
                             width: rect.width, height: handleReach * 2),
                      cursor: vertical)
        addCursorRect(CGRect(x: rect.minX, y: rect.maxY - handleReach,
                             width: rect.width, height: handleReach * 2),
                      cursor: vertical)
    }
    #endif

    private func hitTest(_ point: CGPoint, rect: CGRect) -> Grip? {
        func near(_ x: CGFloat, _ y: CGFloat) -> Bool {
            abs(point.x - x) <= handleReach && abs(point.y - y) <= handleReach
        }
        if near(rect.minX, rect.minY) { return .corner(minX: true, minY: true) }
        if near(rect.maxX, rect.minY) { return .corner(minX: false, minY: true) }
        if near(rect.minX, rect.maxY) { return .corner(minX: true, minY: false) }
        if near(rect.maxX, rect.maxY) { return .corner(minX: false, minY: false) }
        let inX = rect.minX - handleReach ... rect.maxX + handleReach
        let inY = rect.minY - handleReach ... rect.maxY + handleReach
        if abs(point.x - rect.minX) <= handleReach, inY.contains(point.y) {
            return .edge(.minX)
        }
        if abs(point.x - rect.maxX) <= handleReach, inY.contains(point.y) {
            return .edge(.maxX)
        }
        if abs(point.y - rect.minY) <= handleReach, inX.contains(point.x) {
            return .edge(.minY)
        }
        if abs(point.y - rect.maxY) <= handleReach, inX.contains(point.x) {
            return .edge(.maxY)
        }
        return rect.contains(point) ? .move : nil
    }

    private func apply(_ grip: Grip, translation: CGSize,
                       presentation: Presentation) {
        let frame = presentation.imageRect
        let dx = translation.width
        let dy = translation.height
        var rect = startRect

        switch grip {
        case .move:
            rect.origin.x += dx
            rect.origin.y += dy
            rect.origin.x = min(max(rect.origin.x, frame.minX),
                                frame.maxX - rect.width)
            rect.origin.y = min(max(rect.origin.y, frame.minY),
                                frame.maxY - rect.height)

        case .corner(let minX, let minY):
            let anchorX = minX ? startRect.maxX : startRect.minX
            let anchorY = minY ? startRect.maxY : startRect.minY
            let cornerX = (minX ? startRect.minX : startRect.maxX) + dx
            let cornerY = (minY ? startRect.minY : startRect.maxY) + dy
            var width = max(minSide, minX ? anchorX - cornerX : cornerX - anchorX)
            var height = max(minSide, minY ? anchorY - cornerY : cornerY - anchorY)
            let roomX = minX ? anchorX - frame.minX : frame.maxX - anchorX
            let roomY = minY ? anchorY - frame.minY : frame.maxY - anchorY
            width = min(width, roomX)
            height = min(height, roomY)
            if let ratio = lockedRatio {
                if width / ratio >= height { height = width / ratio }
                else { width = height * ratio }
                if width > roomX { width = roomX; height = width / ratio }
                if height > roomY { height = roomY; width = height * ratio }
            }
            rect = CGRect(x: minX ? anchorX - width : anchorX,
                          y: minY ? anchorY - height : anchorY,
                          width: width, height: height)

        case .edge(let edge):
            switch edge {
            case .minX:
                let newX = min(max(startRect.minX + dx, frame.minX),
                               startRect.maxX - minSide)
                rect = CGRect(x: newX, y: rect.minY,
                              width: startRect.maxX - newX, height: rect.height)
            case .maxX:
                let newMax = min(max(startRect.maxX + dx,
                                     startRect.minX + minSide), frame.maxX)
                rect.size.width = newMax - rect.minX
            case .minY:
                let newY = min(max(startRect.minY + dy, frame.minY),
                               startRect.maxY - minSide)
                rect = CGRect(x: rect.minX, y: newY,
                              width: rect.width, height: startRect.maxY - newY)
            case .maxY:
                let newMax = min(max(startRect.maxY + dy,
                                     startRect.minY + minSide), frame.maxY)
                rect.size.height = newMax - rect.minY
            }
            if let ratio = lockedRatio {
                let horizontal = edge == .minX || edge == .maxX
                if horizontal {
                    var height = rect.width / ratio
                    var y = startRect.midY - height / 2
                    if height > frame.height {
                        height = frame.height
                        rect.size.width = height * ratio
                        if edge == .minX {
                            rect.origin.x = startRect.maxX - rect.width
                        }
                    }
                    y = min(max(y, frame.minY), frame.maxY - height)
                    rect.origin.y = y
                    rect.size.height = height
                } else {
                    var width = rect.height * ratio
                    var x = startRect.midX - width / 2
                    if width > frame.width {
                        width = frame.width
                        rect.size.height = width / ratio
                        if edge == .minY {
                            rect.origin.y = startRect.maxY - rect.height
                        }
                    }
                    x = min(max(x, frame.minX), frame.maxX - width)
                    rect.origin.x = x
                    rect.size.width = width
                }
            }
        }

        write(rect, presentation: presentation)
    }

    // MARK: - The settle

    private func travel(to target: CGRect) {
        guard target != focusCrop else { return }
        focusTravel = (from: focusCrop, to: target,
                       start: CACurrentMediaTime(), duration: Motion.settle)
        startDisplayLink()
    }

    private func setThirds(visible: Bool) {
        wantsThirds = visible
        startDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = makeDisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step() {
        var busy = false

        if let travel = focusTravel {
            let elapsed = CACurrentMediaTime() - travel.start
            let fraction = min(max(elapsed / travel.duration, 0), 1)
            // The same ease-out the panels use, so the picture settles like everything else.
            let eased = 1 - pow(1 - fraction, 3)
            focusCrop = CGRect(
                x: travel.from.minX + (travel.to.minX - travel.from.minX) * eased,
                y: travel.from.minY + (travel.to.minY - travel.from.minY) * eased,
                width: travel.from.width
                    + (travel.to.width - travel.from.width) * eased,
                height: travel.from.height
                    + (travel.to.height - travel.from.height) * eased)
            if fraction >= 1 {
                focusCrop = travel.to
                focusTravel = nil
            } else {
                busy = true
            }
        }

        let wanted: CGFloat = wantsThirds ? 1 : 0
        if abs(thirdsStrength - wanted) > 0.01 {
            thirdsStrength += (wanted - thirdsStrength) * 0.25
            busy = true
        } else {
            thirdsStrength = wanted
        }

        redraw()
        if !busy { stopDisplayLink() }
    }
}
