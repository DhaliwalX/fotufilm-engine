#if canImport(CoreImage)
import CoreImage
import CoreGraphics
import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Shared exposure placement for processed HDR stills in the apps and CLI.
public enum ProcessedHDRExposure {
    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!

    /// Raw keeps its scene radiometry; only processed sources declaring HDR need placement.
    public static func isEligible(isRaw: Bool, declaredHeadroom: Float?) -> Bool {
        !isRaw && declaredHeadroom != nil
    }

    /// Compare full-source renditions at a fixed size, independent of preview size or crop.
    /// Only the resulting scalar reaches the scene; SDR reference pixels never replace HDR.
    /// Reuse the caller's rendering context rather than allocating another GPU queue and cache.
    public static func referenceGain(
        expandedHDR: CIImage, sdrReference: CIImage, context: CIContext
    ) -> Float {
        let hdr = ImageResampling.downsample(expandedHDR, longEdge: 256)
        let reference = ImageResampling.downsample(sdrReference, longEdge: 256)
        let extent = hdr.extent.integral
        guard !extent.isInfinite, !extent.isEmpty,
              extent.size == reference.extent.integral.size else { return 1 }
        let width = Int(extent.width), height = Int(extent.height)
        guard let hdrPixels = ImageResampling.rasterizeLinearFloat(
                  hdr, width: width, height: height,
                  context: context, colorSpace: linearSpace),
              let referencePixels = ImageResampling.rasterizeLinearFloat(
                  reference, width: width, height: height,
                  context: context, colorSpace: linearSpace)
        else { return 1 }
        return SceneExposureCalibration.referenceGain(
            sceneLinearHDR: hdrPixels, linearSDRReference: referencePixels)
    }

    /// Apply the reference placement uniformly, preserving alpha and HDR channel ratios.
    public static func applying(_ gain: Float, to image: CIImage) -> CIImage {
        precondition(gain.isFinite && gain > 0 && gain <= 1)
        guard gain < 1 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(gain), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(gain), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(gain), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }
}
#endif
