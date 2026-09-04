// `CGRect`, `CGSize`, and `CGFloat` are provided by CoreGraphics on Apple platforms and by
// swift-corelibs-foundation elsewhere.
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// A display-density request for one settled region of an editor preview.
///
/// Coordinates are normalized in the displayed frame, with the origin at its top-left. The
/// request snaps density upward and its edges outward. A standing tile can therefore serve small
/// pan and zoom changes without ever falling below the display's requested pixel density.
public struct PreviewViewport: Equatable, Sendable {
    /// The largest whole-frame editor preview. This is a memory ceiling, not the normal target;
    /// `baseLongEdge` normally returns the canvas's native display-pixel length.
    public static let baseLongEdgeCeiling = 2560

    /// Density buckets per 1x step and pan buckets in virtual-frame pixels.
    public static let zoomStepsPerUnit: CGFloat = 4
    public static let panGridPixels = 16

    /// The viewport that was visible when this request was made.
    public let visibleUnitRect: CGRect
    /// Physical display pixels occupied by `visibleUnitRect`.
    public let targetPixelSize: CGSize
    /// The pan-bucketed frame area carried by the displayed tile, excluding its spatial apron.
    public let tileUnitRect: CGRect
    /// `tileUnitRect` widened for the film model's spatial support.
    public let renderUnitRect: CGRect
    /// Pixel dimensions of the virtual whole frame at this tile's density.
    public let virtualFrameSize: CGSize
    /// Pixel dimensions rasterized and developed, including the apron.
    public let renderPixelSize: CGSize
    /// The tile's origin in the virtual whole-frame lattice.
    public let origin: CGPoint
    /// The apron-free image to publish, in the developed region's top-origin pixel coordinates.
    public let displayCropPixelRect: CGRect

    /// Whole-frame preview resolution for a canvas measured in points.
    public static func baseLongEdge(
        canvasPoints: CGSize, displayScale: CGFloat,
        ceiling: Int = baseLongEdgeCeiling
    ) -> Int {
        guard canvasPoints.width > 0, canvasPoints.height > 0,
              displayScale > 0, ceiling > 0 else { return 1 }
        let native = Int(ceil(max(canvasPoints.width, canvasPoints.height)
                              * displayScale))
        return min(max(native, 1), ceiling)
    }

    /// Makes the bucketed viewport before a stock-specific spatial apron is known.
    public init?(
        visibleUnitRect: CGRect,
        targetPixelSize: CGSize,
        frameAspect: CGFloat,
        baseLongEdge: Int
    ) {
        self.init(visibleUnitRect: visibleUnitRect,
                  targetPixelSize: targetPixelSize,
                  frameAspect: frameAspect,
                  baseLongEdge: baseLongEdge,
                  spatialSupport: 0)
    }

    private init?(
        visibleUnitRect requested: CGRect,
        targetPixelSize requestedPixels: CGSize,
        frameAspect: CGFloat,
        baseLongEdge: Int,
        spatialSupport: Int
    ) {
        guard frameAspect > 0, baseLongEdge > 0,
              requestedPixels.width > 0, requestedPixels.height > 0 else {
            return nil
        }
        let frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        let visible = requested.standardized.intersection(frame)
        guard visible.width > 0, visible.height > 0 else { return nil }

        let baseSize = Self.framePixelSize(aspect: frameAspect,
                                           longEdge: baseLongEdge)
        let requiredWidth = requestedPixels.width / visible.width
        let requiredHeight = requestedPixels.height / visible.height
        let requiredScale = max(requiredWidth / baseSize.width,
                                requiredHeight / baseSize.height, 1)
        // CGRect arithmetic often leaves an exact bucket a few ulps above its mathematical
        // value. Do not turn that into an unnecessary quarter-step density jump.
        let bucketedScale = ceil(requiredScale * Self.zoomStepsPerUnit - 1e-7)
            / Self.zoomStepsPerUnit
        let virtualLongEdge = max(baseLongEdge,
                                  Int(ceil(CGFloat(baseLongEdge) * bucketedScale)))
        let virtual = Self.framePixelSize(aspect: frameAspect,
                                          longEdge: virtualLongEdge)

        let gridX = CGFloat(Self.panGridPixels) / virtual.width
        let gridY = CGFloat(Self.panGridPixels) / virtual.height
        let snapped = CGRect(
            x: floor(visible.minX / gridX) * gridX,
            y: floor(visible.minY / gridY) * gridY,
            width: ceil(visible.maxX / gridX) * gridX
                - floor(visible.minX / gridX) * gridX,
            height: ceil(visible.maxY / gridY) * gridY
                - floor(visible.minY / gridY) * gridY
        ).intersection(frame)

        let support = CGFloat(max(0, spatialSupport))
        let expanded = CGRect(
            x: floor(snapped.minX * virtual.width - support),
            y: floor(snapped.minY * virtual.height - support),
            width: ceil(snapped.maxX * virtual.width + support)
                - floor(snapped.minX * virtual.width - support),
            height: ceil(snapped.maxY * virtual.height + support)
                - floor(snapped.minY * virtual.height - support)
        ).intersection(CGRect(origin: .zero, size: virtual))
        guard expanded.width > 0, expanded.height > 0 else { return nil }

        let tilePixels = CGRect(
            x: (snapped.minX * virtual.width).rounded(.down),
            y: (snapped.minY * virtual.height).rounded(.down),
            width: (snapped.width * virtual.width).rounded(.up),
            height: (snapped.height * virtual.height).rounded(.up))
        let origin = expanded.origin

        self.visibleUnitRect = visible
        self.targetPixelSize = requestedPixels
        self.tileUnitRect = snapped
        self.renderUnitRect = CGRect(
            x: expanded.minX / virtual.width,
            y: expanded.minY / virtual.height,
            width: expanded.width / virtual.width,
            height: expanded.height / virtual.height)
        self.virtualFrameSize = virtual
        self.renderPixelSize = expanded.size
        self.origin = origin
        self.displayCropPixelRect = CGRect(
            x: tilePixels.minX - origin.x,
            y: tilePixels.minY - origin.y,
            width: tilePixels.width,
            height: tilePixels.height)
    }

    /// Returns the same request with a stock-specific apron, clamped at the frame edges.
    public func addingSpatialSupport(_ pixels: Int) -> PreviewViewport {
        guard pixels > 0 else { return self }
        let aspect = virtualFrameSize.width / virtualFrameSize.height
        return PreviewViewport(
            visibleUnitRect: visibleUnitRect,
            targetPixelSize: targetPixelSize,
            frameAspect: aspect,
            baseLongEdge: Int(max(virtualFrameSize.width,
                                  virtualFrameSize.height)),
            spatialSupport: pixels) ?? self
    }

    /// Fraction of the placed frame's short edge visible in this viewport.
    public var shortEdgeFraction: CGFloat {
        virtualFrameSize.width <= virtualFrameSize.height
            ? visibleUnitRect.width : visibleUnitRect.height
    }

    /// Film-frame coverage after the editor crop and this viewport are composed.
    public func frameCoverage(composedWith baseCoverage: Float) -> Float {
        baseCoverage * Float(shortEdgeFraction)
    }

    /// Pixel size representing the exact visible area at the selected density. This, together
    /// with composed frame coverage, is the density reference used to size physical film stages.
    public var densityReferencePixelSize: CGSize {
        let shortPixels = ceil(min(virtualFrameSize.width, virtualFrameSize.height)
                               * shortEdgeFraction)
        // FilmEngineInvocation derives density from the buffer's shorter side. A viewport can be
        // a different aspect from the frame, so passing its literal width and height would let the
        // canvas shape change grain scale. A square reference states only the physical short-edge
        // span represented by `frameCoverage`; the actual region dimensions still go to Halide.
        return CGSize(width: shortPixels, height: shortPixels)
    }

    /// Whether this standing tile fails to cover a newer viewport at adequate density.
    public func isStale(for newer: PreviewViewport) -> Bool {
        let epsilon: CGFloat = 1e-7
        let covers = tileUnitRect.minX <= newer.visibleUnitRect.minX + epsilon
            && tileUnitRect.minY <= newer.visibleUnitRect.minY + epsilon
            && tileUnitRect.maxX + epsilon >= newer.visibleUnitRect.maxX
            && tileUnitRect.maxY + epsilon >= newer.visibleUnitRect.maxY
        let denseEnough = virtualFrameSize.width + 0.5
                >= newer.virtualFrameSize.width
            && virtualFrameSize.height + 0.5
                >= newer.virtualFrameSize.height
        return !covers || !denseEnough
    }

    /// A half-density request for the editor's moving-control tier.
    public var halved: PreviewViewport {
        let halfLong = max(1, Int(max(virtualFrameSize.width,
                                     virtualFrameSize.height)) / 2)
        let aspect = virtualFrameSize.width / virtualFrameSize.height
        return PreviewViewport(
            visibleUnitRect: visibleUnitRect,
            targetPixelSize: CGSize(width: max(1, targetPixelSize.width / 2),
                                    height: max(1, targetPixelSize.height / 2)),
            frameAspect: aspect,
            baseLongEdge: halfLong,
            spatialSupport: 0) ?? self
    }

    private static func framePixelSize(aspect: CGFloat, longEdge: Int) -> CGSize {
        let edge = CGFloat(max(1, longEdge))
        if aspect >= 1 {
            return CGSize(width: edge, height: max(1, (edge / aspect).rounded()))
        }
        return CGSize(width: max(1, (edge * aspect).rounded()), height: edge)
    }
}
