#if canImport(CoreImage) && canImport(ImageIO)
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Crops a camera HEIF without flattening its HDR gain map.
public enum HDRGainMapCrop {
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(
            name: CGColorSpace.extendedLinearDisplayP3)!,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false,
    ])

    /// Returns `true` only when `data` contains a gain map and the cropped HEIF was written.
    public static func writeCroppedHEIF(
        data: Data, portraitAspect: CGFloat, to url: URL
    ) -> Bool {
        guard portraitAspect > 0,
              let primary = CIImage(data: data, options: [
                .applyOrientationProperty: true,
              ]),
              let gainMap = CIImage(data: data, options: [
                .auxiliaryHDRGainMap: true,
                .applyOrientationProperty: true,
              ]),
              primary.extent.width > 0, primary.extent.height > 0,
              gainMap.extent.width > 0, gainMap.extent.height > 0
        else { return false }

        let primaryRect = centeredCrop(
            in: primary.extent, portraitAspect: portraitAspect)
        guard primaryRect.width > 0, primaryRect.height > 0 else { return false }
        let normalized = CGRect(
            x: (primaryRect.minX - primary.extent.minX) / primary.extent.width,
            y: (primaryRect.minY - primary.extent.minY) / primary.extent.height,
            width: primaryRect.width / primary.extent.width,
            height: primaryRect.height / primary.extent.height)
        let gainRect = CGRect(
            x: gainMap.extent.minX + normalized.minX * gainMap.extent.width,
            y: gainMap.extent.minY + normalized.minY * gainMap.extent.height,
            width: normalized.width * gainMap.extent.width,
            height: normalized.height * gainMap.extent.height)
            .integral.intersection(gainMap.extent)
        guard gainRect.width > 0, gainRect.height > 0 else { return false }

        var primaryProperties = primary.properties
        primaryProperties[kCGImagePropertyOrientation as String] = 1
        primaryProperties[kCGImagePropertyPixelWidth as String] =
            Int(primaryRect.width)
        primaryProperties[kCGImagePropertyPixelHeight as String] =
            Int(primaryRect.height)
        let croppedPrimary = atOrigin(primary.cropped(to: primaryRect))
            .settingProperties(primaryProperties)
        let croppedGainMap = atOrigin(gainMap.cropped(to: gainRect))
            .settingProperties(gainMap.properties)
        let outputSpace = primary.colorSpace
            ?? CGColorSpace(name: CGColorSpace.displayP3)!
        let format: CIFormat
        if #available(iOS 17, macOS 14, *) {
            format = .RGB10
        } else {
            format = .RGBA8
        }
        return (try? context.writeHEIFRepresentation(
            of: croppedPrimary, to: url, format: format,
            colorSpace: outputSpace,
            options: [.hdrGainMapImage: croppedGainMap])) != nil
    }

    private static func centeredCrop(
        in extent: CGRect, portraitAspect: CGFloat
    ) -> CGRect {
        let wantedLongOverShort = 1 / portraitAspect
        let long = max(extent.width, extent.height)
        let short = min(extent.width, extent.height)
        var keptLong = long
        var keptShort = short
        if long / short > wantedLongOverShort {
            keptLong = short * wantedLongOverShort
        } else {
            keptShort = long / wantedLongOverShort
        }
        let width = extent.width >= extent.height ? keptLong : keptShort
        let height = extent.width >= extent.height ? keptShort : keptLong
        return CGRect(
            x: extent.midX - width / 2,
            y: extent.midY - height / 2,
            width: width, height: height).integral.intersection(extent)
    }

    private static func atOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX, y: -image.extent.minY))
    }
}
#endif
