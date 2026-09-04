#if canImport(CoreImage)
import CoreImage
import CoreGraphics
import Foundation

/// Resampling used on the way into the film model.
public enum ImageResampling {
    /// Reduces `image` so its long edge is `longEdge` pixels, band-limiting
    /// first. `CILanczosScaleTransform` alone is not safe here.
    public static func downsample(_ image: CIImage, longEdge: Int) -> CIImage {
        let current = max(image.extent.width, image.extent.height)
        let scale = CGFloat(longEdge) / current
        guard current > 0, scale < 1, abs(current - CGFloat(longEdge)) > 0.5 else {
            return image
        }
        var working = image
        let weight = min(max((scale - 0.5) / 0.25, 0), 1)
        let radius = 0.55 / scale * weight
        if radius > 0.05, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(working.clampedToExtent(), forKey: kCIInputImageKey)
            blur.setValue(radius, forKey: kCIInputRadiusKey)
            if let blurred = blur.outputImage {
                working = blurred.cropped(to: image.extent)
            }
        }
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return working }
        filter.setValue(working, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1, forKey: kCIInputAspectRatioKey)
        return filter.outputImage ?? working
    }

    /// Lanczos-only reference path used to measure the prefilter's effect.
    public static func lanczosOnly(_ image: CIImage, longEdge: Int) -> CIImage {
        let current = max(image.extent.width, image.extent.height)
        guard current > 0, current > CGFloat(longEdge),
              let filter = CIFilter(name: "CILanczosScaleTransform") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CGFloat(longEdge) / current, forKey: kCIInputScaleKey)
        filter.setValue(1, forKey: kCIInputAspectRatioKey)
        return filter.outputImage ?? image
    }
}
#endif

#if canImport(CoreImage)
public extension ImageResampling {
    /// Target pixels per synchronous Core Image render band.
    static let defaultPixelsPerBand: Int = {
        // Raw demosaic output depends on band boundaries because each region has a finite apron.
        // Keep 8 MP for output compatibility. `FOTUFILM_RASTER_BAND` is for controlled sweeps only.
        if let raw = ProcessInfo.processInfo.environment["FOTUFILM_RASTER_BAND"],
           let megapixels = Int(raw), megapixels > 0 {
            return megapixels * 1_000_000
        }
        return 8_000_000
    }()

    /// Rasterises a Core Image graph into an interleaved float linear buffer, a band at a time.
    static func rasterizeLinearFloat(
        _ image: CIImage, width: Int, height: Int,
        context: CIContext, colorSpace: CGColorSpace,
        pixelsPerBand: Int = defaultPixelsPerBand
    ) -> [Float]? {
        guard width > 0, height > 0 else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            rasterizeLinearFloat(image, into: base, width: width, height: height,
                                 context: context, colorSpace: colorSpace,
                                 pixelsPerBand: pixelsPerBand)
        }
        return pixels
    }

    /// The caller-owned form. Raw and 16-bit inputs keep their distinguishable scene-linear
    /// values until develop.
    static func rasterizeLinearFloat(
        _ image: CIImage, into destination: UnsafeMutableRawPointer,
        width: Int, height: Int,
        context: CIContext, colorSpace: CGColorSpace,
        pixelsPerBand: Int = defaultPixelsPerBand,
        flush: ((_ byteOffset: Int, _ byteCount: Int) -> Void)? = nil
    ) {
        guard width > 0, height > 0 else { return }
        let rowBytes = width * MemoryLayout<Float>.size * 4
        let bandRows = max(1, min(height, pixelsPerBand / width))
        var top = 0
        while top < height {
            let rows = min(bandRows, height - top)
            let bounds = CGRect(
                x: image.extent.minX,
                y: image.extent.minY + CGFloat(height - top - rows),
                width: CGFloat(width), height: CGFloat(rows))
            let byteOffset = top * rowBytes
            let byteCount = rows * rowBytes
            context.render(image, toBitmap: destination.advanced(by: byteOffset),
                           rowBytes: rowBytes, bounds: bounds,
                           format: .RGBAf, colorSpace: colorSpace)
            flush?(byteOffset, byteCount)
            top += rows
        }
    }
}
#endif
