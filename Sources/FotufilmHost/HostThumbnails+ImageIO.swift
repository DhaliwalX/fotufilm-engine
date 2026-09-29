#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import Foundation
import ImageIO

/// Thumbnails read by ImageIO: a camera RAW's or JPEG's embedded preview when it has one, the
/// image reduced while it is read otherwise, turned upright by the file's orientation.
struct ImageIOThumbnailer: HostThumbnailer {
    func thumbnail(_ url: URL, maxEdge: Int) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            throw HostEngine.Failure(description: "\(url.lastPathComponent) has no picture to show.")
        }
        // An embedded preview may be larger than asked: draw it at the size asked for.
        let scale = min(1, Double(maxEdge) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw HostEngine.Failure(description: "\(url.lastPathComponent) has no picture to show.")
        }
        return (pixels, width, height)
    }
}
#endif
