import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreImage)
import CoreImage
#endif

/// Clockwise corners in normalized, top-origin image coordinates. Kept independent of
/// display resolution so preview, export, and saved edits use the same selection.
public struct QuadrilateralCrop: Codable, Equatable, Sendable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
        topLeft = CGPoint(x: rect.minX, y: rect.minY)
        topRight = CGPoint(x: rect.maxX, y: rect.minY)
        bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
    }

    public var points: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// Crossed, concave, collapsed and out-of-frame selections cannot define a crop.
    public var isValid: Bool {
        let p = points
        guard p.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
            (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
        return (0..<4).allSatisfy { i in
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) > 0.0001
        }
    }

    public func movingCorner(_ index: Int, to point: CGPoint) -> Self {
        var next = self
        let point = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        switch index {
        case 0: next.topLeft = point
        case 1: next.topRight = point
        case 2: next.bottomRight = point
        case 3: next.bottomLeft = point
        default: return self
        }
        return next.isValid ? next : self
    }

    #if canImport(CoreImage)
    public func applying(to image: CIImage) -> CIImage {
        guard isValid, let filter = CIFilter(name: "CIPerspectiveCorrection") else { return image }
        let e = image.extent
        filter.setValue(image, forKey: kCIInputImageKey)
        for (key, point) in zip(["inputTopLeft", "inputTopRight", "inputBottomRight", "inputBottomLeft"], points) {
            filter.setValue(CIVector(x: e.minX + point.x * e.width,
                                    y: e.maxY - point.y * e.height), forKey: key)
        }
        guard let output = filter.outputImage, !output.extent.isEmpty,
              !output.extent.isInfinite else { return image }
        return output.transformed(by: CGAffineTransform(translationX: -output.extent.minX,
                                                        y: -output.extent.minY))
    }
    #endif
}
