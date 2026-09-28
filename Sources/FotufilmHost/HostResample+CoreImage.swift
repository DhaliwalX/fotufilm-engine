#if canImport(CoreImage)
import CoreImage
import Foundation
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// The Mac app's reduction (`ImageResampling.downsample`: Lanczos, band-limited first where the
/// reduction is gentle), so a reduced photograph holds the pixels the Mac app's does.
final class CoreImageResampler: HostResampler {
    private let context = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
    ])

    func reduce(_ rgba: [Float], width: Int, height: Int,
                to targetWidth: Int, _ targetHeight: Int) -> [Float]? {
        guard targetWidth <= width, targetHeight <= height,
              max(targetWidth, targetHeight) < max(width, height) else { return nil }
        var reduced = [Float](repeating: 0, count: targetWidth * targetHeight * 4)
        rgba.withUnsafeBytes { source in
            // Read in place rather than copied: a photograph's scene is hundreds of megabytes.
            // The caches are cleared before the buffer goes, so nothing keeps a view of it.
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: source.baseAddress!),
                            count: width * height * 16, deallocator: .none)
            let image = CIImage(bitmapData: data, bytesPerRow: width * 16,
                                size: CGSize(width: width, height: height),
                                format: .RGBAf, colorSpace: nil)
            let output = ImageResampling.downsample(image,
                                                    longEdge: max(targetWidth, targetHeight))
            // Its extent rounds outward exactly as the target does; clamping only covers a
            // target a hair past it.
            let origin = output.extent.origin
            reduced.withUnsafeMutableBytes { target in
                context.render(output.clampedToExtent(), toBitmap: target.baseAddress!,
                               rowBytes: targetWidth * 16,
                               bounds: CGRect(x: origin.x, y: origin.y,
                                              width: CGFloat(targetWidth),
                                              height: CGFloat(targetHeight)),
                               format: .RGBAf, colorSpace: nil)
            }
            context.clearCaches()
        }
        // The scene was flattened over black when it was decoded; Lanczos reads transparency
        // past the edge, which would otherwise come back as coverage.
        for pixel in 0..<(targetWidth * targetHeight) { reduced[pixel * 4 + 3] = 1 }
        return reduced
    }
}
#endif
