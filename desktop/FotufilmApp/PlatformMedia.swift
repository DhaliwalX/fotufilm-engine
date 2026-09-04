import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
typealias PlatformImage = NSImage
#endif

extension PlatformImage {
    /// A platform image over a finished render. `UIImage` takes the CGImage as it is; `NSImage` has
    /// no size of its own and has to be told the pixel dimensions, or it draws at 72 dpi.
    static func from(_ cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    /// The whole picture into a rectangle of the current context, smoothly scaled.
    ///
    /// `UIImage` draws the way the view is oriented and asks for nothing else; `NSImage` has to be
    /// told to respect the flip and to interpolate, or a scaled photograph arrives upside down and
    /// coarse.
    func draw(into rect: CGRect) {
        #if canImport(UIKit)
        draw(in: rect)
        #else
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
             respectFlipped: true,
             hints: [.interpolation: NSImageInterpolation.high.rawValue])
        #endif
    }
}
