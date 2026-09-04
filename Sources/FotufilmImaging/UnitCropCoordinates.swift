// `CGRect` and `CGFloat` come from CoreGraphics on Apple platforms and from
// swift-corelibs-foundation elsewhere, so the geometry below is portable as written.
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// Converts a normalized crop between top-origin display coordinates and Core Image's
/// bottom-origin coordinates. The transform is its own inverse.
public enum UnitCropCoordinates {
    public static func verticallyFlipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY,
               width: rect.width, height: rect.height)
    }

    public static func verticallyFlipped(_ rect: CGRect?) -> CGRect? {
        rect.map(verticallyFlipped)
    }
}
