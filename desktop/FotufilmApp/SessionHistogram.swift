import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A floating, draggable RGB histogram. It reads a reduced copy of the displayed print, so showing
/// it does not ask the film pipeline for another develop.
@MainActor
final class SessionHistogramPanelView: SessionView {
    static let panelSize = CGSize(width: 180, height: 116)

    private let glass = GlassPanelView(radius: 18)
    private let plot = HistogramPlotView()
    private var lastImage: PlatformImage?
    /// The rectangle the panel may occupy, in its parent's coordinates.
    var room = CGRect.zero

    #if canImport(UIKit)
    private let pan = UIPanGestureRecognizer()
    #else
    private var lastDragLocation = CGPoint.zero
    #endif

    override init(frame: CGRect) {
        super.init(frame: CGRect(origin: .zero, size: Self.panelSize))
        addSubview(glass)
        glass.content.addSubview(plot)
        glass.translatesAutoresizingMaskIntoConstraints = false
        plot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            plot.leadingAnchor.constraint(equalTo: glass.content.leadingAnchor,
                                           constant: 10),
            plot.trailingAnchor.constraint(equalTo: glass.content.trailingAnchor,
                                            constant: -10),
            plot.topAnchor.constraint(equalTo: glass.content.topAnchor,
                                       constant: 10),
            plot.bottomAnchor.constraint(equalTo: glass.content.bottomAnchor,
                                          constant: -10),
        ])

        #if canImport(UIKit)
        pan.addTarget(self, action: #selector(dragged(_:)))
        addGestureRecognizer(pan)
        #endif
        setAXLabel("RGB histogram")
        setHelp("RGB histogram. Drag to move it over the canvas.")
    }

    func setImage(_ image: PlatformImage?) {
        guard image !== lastImage else { return }
        lastImage = image
        plot.bins = image.flatMap(Self.count) ?? []
    }

    func setCounts(_ bins: [[Int]]) {
        lastImage = nil
        plot.bins = bins
    }

    static func count(_ image: PlatformImage) -> [[Int]] {
        #if canImport(UIKit)
        guard let source = image.cgImage else { return [] }
        #else
        guard let source = image.cgImage(forProposedRect: nil, context: nil,
                                         hints: nil) else { return [] }
        #endif
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: side,
                                        height: side))
        return count(rgba: pixels)
    }

    /// Counts 64 bins per channel from an RGBA8 frame.
    nonisolated static func count(rgba pixels: [UInt8]) -> [[Int]] {
        var bins = [[Int]](repeating: [Int](repeating: 0, count: 64), count: 3)
        guard pixels.count >= 4 else { return bins }
        for index in stride(from: 0, through: pixels.count - 4, by: 4) {
            for channel in 0..<3 {
                bins[channel][Int(pixels[index + channel]) >> 2] += 1
            }
        }
        return bins
    }

    func setShown(_ shown: Bool, completion: (() -> Void)? = nil) {
        if shown { isHidden = false }
        Motion.run(Motion.quick, curve: Motion.smooth) { [weak self] in
            self?.animated.opacity = shown ? 1 : 0
        } completion: { [weak self] in
            if !shown { self?.isHidden = true }
            completion?()
        }
    }

    func keepInRoom() {
        let placed = settled(frame.origin)
        guard placed != frame.origin else { return }
        Motion.run(Motion.quick) { [weak self] in
            self?.animated.frame.origin = placed
        }
    }

    private func settled(_ proposed: CGPoint) -> CGPoint {
        guard !room.isEmpty else { return proposed }
        return CGPoint(
            x: min(max(proposed.x, room.minX),
                   max(room.minX, room.maxX - frame.width)),
            y: min(max(proposed.y, room.minY),
                   max(room.minY, room.maxY - frame.height)))
    }

    #if canImport(UIKit)
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        switch gesture.state {
        case .changed:
            let movement = gesture.translation(in: parent)
            gesture.setTranslation(.zero, in: parent)
            frame.origin = settled(CGPoint(x: frame.origin.x + movement.x,
                                           y: frame.origin.y + movement.y))
        case .ended, .cancelled, .failed:
            let velocity = gesture.velocity(in: parent)
            let carried = CGPoint(x: frame.origin.x + velocity.x * 0.08,
                                  y: frame.origin.y + velocity.y * 0.08)
            Motion.run(Motion.quick) { [weak self] in
                guard let self else { return }
                self.animated.frame.origin = self.settled(carried)
            }
        default: break
        }
    }
    #else
    override func mouseDown(with event: NSEvent) {
        lastDragLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        let current = event.locationInWindow
        let movement = CGPoint(x: current.x - lastDragLocation.x,
                               y: -(current.y - lastDragLocation.y))
        lastDragLocation = current
        frame.origin = settled(CGPoint(x: frame.origin.x + movement.x,
                                       y: frame.origin.y + movement.y))
    }
    #endif
}

/// Three filled channel curves blended additively. The 98th percentile of populated bins sets the
/// height, keeping a single clipped spike from flattening the useful part of the reading.
private final class HistogramPlotView: SessionView {
    var bins: [[Int]] = [] { didSet { redraw() } }

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        guard let context = Draw.context else { return }
        guard bins.count == 3,
              bins.allSatisfy({ $0.count == 64 }),
              bins.flatMap({ $0 }).contains(where: { $0 > 0 }) else {
            context.setStrokeColor(
                PlatformColor.white.withAlphaComponent(0.2).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: 0, y: bounds.maxY))
            context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
            context.strokePath()
            return
        }

        let populated = bins.flatMap { $0 }.filter { $0 > 0 }.sorted()
        let bulkIndex = Int(Double(populated.count - 1) * 0.98)
        let scale = CGFloat(max(populated[bulkIndex], 1))
        let colors = [
            PlatformColor(red: 1, green: 0.25, blue: 0.25, alpha: 0.75),
            PlatformColor(red: 0.3, green: 1, blue: 0.4, alpha: 0.75),
            PlatformColor(red: 0.35, green: 0.5, blue: 1, alpha: 0.75),
        ]
        context.setBlendMode(.plusLighter)
        for (channel, channelBins) in bins.enumerated() {
            context.beginPath()
            context.move(to: CGPoint(x: bounds.minX, y: bounds.maxY))
            for (index, value) in channelBins.enumerated() {
                let x = bounds.minX + bounds.width * CGFloat(index)
                    / CGFloat(channelBins.count - 1)
                let height = min(CGFloat(value) / scale, 1) * bounds.height
                context.addLine(to: CGPoint(x: x, y: bounds.maxY - height))
            }
            context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
            context.closePath()
            context.setFillColor(colors[channel].cgColor)
            context.fillPath()
        }
    }
}
