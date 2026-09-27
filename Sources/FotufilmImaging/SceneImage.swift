import Foundation

#if canImport(CoreImage) && canImport(ImageIO)
import CoreImage
import CoreGraphics
import ImageIO

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// A photograph as the engine takes it: associated scene-referred linear Rec.2020 RGBA, with what
/// the file says about the light it was made in and the range it records. Decoded once for the
/// command line and for native hosts alike.
public struct SceneImage {
    public var rgba: [Float]
    public var width: Int
    public var height: Int
    /// The as-shot white of a raw file, when it states one.
    public var sceneKelvin: Float?
    public var sceneChromaticity: SIMD2<Float>?
    /// The range the file declares above diffuse white; 1 for none.
    public var contentHeadroom: Float
    /// The camera profile correction applied to a raw file, if one matched.
    public var cameraProfile: CameraProfileCorrection.Resolved?

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    static func associatedOpenEXRColor(url: URL) -> CIImage? {
        guard url.pathExtension.lowercased() == "exr",
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == "com.ilm.openexr-image" else {
            return nil
        }
        let options = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: true,
        ] as CFDictionary
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, options),
              let color = AssociatedAlphaImage.colorSamples(from: decoded) else {
            return nil
        }
        return CIImage(cgImage: color)
    }

    /// Decodes any supported image as associated scene-referred linear Rec.2020 RGBA, preserving
    /// values above 1 for HDR/raw sources. Association is retained until the caller composites the
    /// scene.
    private static func orientation(of url: URL) -> CGImagePropertyOrientation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let value = properties[kCGImagePropertyOrientation as String] as? NSNumber
        else { return nil }
        return CGImagePropertyOrientation(rawValue: value.uint32Value)
    }

    public static func decode(url: URL) throws -> SceneImage {
        let path = url.path
        let isRaw = RawDecode.isRaw(url: url)
        let declaredHeadroom = isRaw ? nil : GainMapHeadroom.declared(url: url)
        let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        var image: CIImage?
        var sceneKelvin: Float?
        var sceneChromaticity: SIMD2<Float>?
        var contentHeadroom: Float = 1
        var profileCorrection: CameraProfileCorrection.Resolved?
        var associatedEXRColor: CIImage?
        if isRaw {
            guard let raw = CIRAWFilter(imageURL: url) else {
                throw Failure(description: "Could not read raw file: \(path)")
            }
            // Decode at the file's complete as-shot white once. Edits change the spectral lamp.
            let white = raw.neutralChromaticity
            let xy = SIMD2<Float>(Float(white.x), Float(white.y))
            if xy.x > 0 && xy.y > 0 && xy.x + xy.y < 1 {
                sceneChromaticity = xy
            }
            sceneKelvin = raw.neutralTemperature > 0 ? raw.neutralTemperature : nil
            RawDecode.configure(raw, recipe: RawDecode.Recipe())
            profileCorrection = CameraProfileCorrection.resolve(
                camera: RawDecode.cameraIdentity(url: url),
                sceneKelvin: sceneKelvin)
            image = raw.outputImage
        } else {
            associatedEXRColor = associatedOpenEXRColor(url: url)
            if #available(macOS 14.0, *) {
                image = CIImage(contentsOf: url, options: [.expandToHDR: true])
            }
            if image == nil {
                image = CIImage(contentsOf: url)
            }
            // The declared range, the app's rule exactly (`FilmRender`): the decoded image's own
            // statement when the platform reports one, and the file's own — a gain map's stated
            // ceiling, or the fixed one an HLG/PQ container stands for — when a declaring file
            // decodes to a neutral report. Raw never declares: its above-white light is the
            // negative's own path and is not rolled.
            if #available(macOS 15.0, *), let decoded = image {
                contentHeadroom = max(1, decoded.contentHeadroom)
            }
            if contentHeadroom <= 1, let declaredHeadroom {
                contentHeadroom = declaredHeadroom
            }
        }
        // An HLG or PQ file decodes as display light; its range is the scene's, stated by its transfer.
        let hdrTransfer = isRaw ? nil : GainMapHeadroom.transfer(url: url)
        if let hdrTransfer { contentHeadroom = hdrTransfer.sceneHeadroom }
        // Share the apps' eligibility rule and compare full-source renditions before crop or resize.
        if #available(macOS 14.0, *),
           ProcessedHDRExposure.isEligible(isRaw: isRaw, declaredHeadroom: declaredHeadroom),
           let hdr = image,
           let reference = CIImage(contentsOf: url, options: [.toneMapHDRtoSDR: true]) {
            let gain = ProcessedHDRExposure.referenceGain(
                expandedHDR: hdr, sdrReference: reference, context: context)
            image = ProcessedHDRExposure.applying(gain, to: hdr)
        }
        guard var ci = image else {
            throw Failure(description: "Could not read image: \(path)")
        }
        // Upright as the apps show it: a camera's orientation tag turns the pixels (RAW decodes
        // upright already).
        if !isRaw, let orientation = orientation(of: url), orientation != .up {
            ci = ci.oriented(orientation)
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX,
                                                      y: -ci.extent.minY))
        }
        let width = Int(ci.extent.width.rounded()), height = Int(ci.extent.height.rounded())
        guard width > 0, height > 0, ci.extent.isInfinite == false else {
            throw Failure(description: "Image has no finite extent: \(path)")
        }
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else {
            throw Failure(description: "No extended linear Rec.2020 color space available")
        }
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            context.render(ci, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: ci.extent, format: .RGBAf, colorSpace: space)
        }
        if let associatedEXRColor,
           Int(associatedEXRColor.extent.width.rounded()) == width,
           Int(associatedEXRColor.extent.height.rounded()) == height {
            var alpha = [Float](repeating: 1, count: width * height)
            for pixel in 0..<(width * height) { alpha[pixel] = rgba[pixel * 4 + 3] }
            rgba.withUnsafeMutableBytes { buffer in
                context.render(associatedEXRColor, toBitmap: buffer.baseAddress!,
                               rowBytes: width * 16, bounds: associatedEXRColor.extent,
                               format: .RGBAf, colorSpace: space)
            }
            for pixel in 0..<(width * height) { rgba[pixel * 4 + 3] = alpha[pixel] }
        }
        if hdrTransfer != nil {
            for pixel in 0..<(width * height) {
                let scene = GainMapHeadroom.Transfer.sceneLight(SIMD3(
                    rgba[pixel * 4], rgba[pixel * 4 + 1], rgba[pixel * 4 + 2]))
                rgba[pixel * 4] = scene.x
                rgba[pixel * 4 + 1] = scene.y
                rgba[pixel * 4 + 2] = scene.z
            }
        }
        if let corrected = profileCorrection {
            CameraProfileCorrection.apply(corrected.matrix, toRGBA: &rgba)
        }
        return SceneImage(rgba: rgba, width: width, height: height, sceneKelvin: sceneKelvin,
                          sceneChromaticity: sceneChromaticity, contentHeadroom: contentHeadroom,
                          cameraProfile: profileCorrection)
    }
}
#endif
