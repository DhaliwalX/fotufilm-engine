#if canImport(CoreGraphics)
import CoreGraphics

/// Access to associated color samples that Core Image would otherwise erase at zero alpha.
public enum AssociatedAlphaImage {
    /// Returns an image over the same provider whose alpha sample is treated as padding.
    ///
    /// This is for containers such as OpenEXR whose RGB is already associated. It lets the caller
    /// color-convert that RGB independently, then combine it with the original alpha for linear
    /// compositing. It must not be used to bypass association of straight-alpha source color.
    public static func colorSamples(from image: CGImage) -> CGImage? {
        let skippedAlpha: CGImageAlphaInfo
        switch image.alphaInfo {
        case .last, .premultipliedLast:
            skippedAlpha = .noneSkipLast
        case .first, .premultipliedFirst:
            skippedAlpha = .noneSkipFirst
        default:
            return nil
        }
        guard image.bitsPerPixel == image.bitsPerComponent * 4,
              let colorSpace = image.colorSpace,
              colorSpace.model == .rgb,
              let provider = image.dataProvider else {
            return nil
        }

        var bitmapInfo = image.bitmapInfo.rawValue
        bitmapInfo &= ~CGBitmapInfo.alphaInfoMask.rawValue
        bitmapInfo |= skippedAlpha.rawValue
        return CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: image.bitsPerComponent,
            bitsPerPixel: image.bitsPerPixel,
            bytesPerRow: image.bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: image.shouldInterpolate,
            intent: image.renderingIntent)
    }
}
#endif
