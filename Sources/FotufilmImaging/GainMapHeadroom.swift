#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
#if canImport(CoreImage)
import CoreImage
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Reads image headroom above diffuse white from ISO 21496-1, Apple gain-map, or HDR transfer
/// metadata. ISO metadata stores log2 base and alternate headroom; Apple metadata stores a ratio.
/// HLG and PQ files without gain maps use their transfer-specific reference-white ceiling.
public enum GainMapHeadroom {
    /// ISO 21496-1 writes both headrooms as log2 of a light ratio, under this prefix.
    private static let isoPrefix = "HDRToneMap"
    /// Apple's gain map writes the ratio itself, under this one.
    private static let applePrefix = "HDRGainMap"

    /// The file's declared headroom, or nil when it declares none.
    ///
    /// Never below 1: a declaration under diffuse white is not headroom, and the callers treat
    /// 1 as "nothing to recover".
    public static func declared(in source: CGImageSource) -> Float? {
        if #available(iOS 18.0, macOS 15.0, *),
           let iso = isoGainMapHeadroom(in: source) {
            return iso
        }
        if let apple = appleGainMapHeadroom(in: source) {
            return apple
        }
        return transferFunctionHeadroom(in: source)
    }

    /// The same, for a file held in memory.
    public static func declared(data: Data) -> Float? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(declared(in:))
    }

    /// The same, for a file on disc.
    public static func declared(url: URL) -> Float? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(declared(in:))
    }

    // MARK: - The three declarations

    /// ISO 21496-1: `2 ^ (alternate - base)`, the ratio between the rendition the gain map
    /// recovers and the one the pixels already are. `BaseHeadroom` is zero on every SDR-based
    /// file, but it is subtracted rather than assumed so an HDR-based pair reads correctly too.
    @available(iOS 18.0, macOS 15.0, *)
    private static func isoGainMapHeadroom(in source: CGImageSource) -> Float? {
        guard let metadata = auxiliaryMetadata(
                in: source, type: kCGImageAuxiliaryDataTypeISOGainMap),
              let alternate = number(metadata,
                                     at: "\(isoPrefix):AlternateHeadroom")
        else { return nil }
        let base = number(metadata, at: "\(isoPrefix):BaseHeadroom") ?? 0
        return usable(exp2(alternate - base))
    }

    /// Apple's gain map states the ratio directly, already in light rather than in stops.
    private static func appleGainMapHeadroom(in source: CGImageSource) -> Float? {
        guard let metadata = auxiliaryMetadata(
                in: source, type: kCGImageAuxiliaryDataTypeHDRGainMap),
              let headroom = number(
                metadata, at: "\(applePrefix):HDRGainMapHeadroom")
        else { return nil }
        return usable(headroom)
    }

    /// A file with no gain map still declares a range through its HDR transfer. HLG and PQ have
    /// different ceilings relative to diffuse white and must not share a fallback number; both are
    /// stated in scene light, the units the film meters in.
    private static func transferFunctionHeadroom(in source: CGImageSource) -> Float? {
        transfer(in: source)?.sceneHeadroom
    }

    // MARK: - HDR transfers

    /// The HDR transfer a file's pixels are encoded with, when they are HLG or PQ rather than an
    /// SDR base with a gain map. Core Image expands either to *display* light — reference white at
    /// 1.0, HLG's system gamma applied — so these pixels need `sceneLight` before the film sees
    /// them.
    public enum Transfer: Sendable {
        case hlg, pq

        /// Headroom above diffuse white in scene light.
        public var sceneHeadroom: Float {
            switch self {
            case .hlg: return HLGSceneTransfer.headroom
            case .pq: return pow(PQSceneTransfer.headroom, 1 / HLGTransfer.systemGamma)
            }
        }

        /// One display-light Rec.2020 pixel back to the scene: the inverse of BT.2100's HLG OOTF,
        /// normalised at reference white, which is also BT.2408's PQ-to-HLG relation. A grey card
        /// at 26 cd/m² returns to 0.18, as the same card does from an SDR file.
        @inlinable
        public static func sceneLight(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
            let open = HLGTransfer.opticalToOpen(r: rgb.x, g: rgb.y, b: rgb.z)
            return SIMD3(open.r, open.g, open.b)
        }
    }

    #if canImport(CoreImage)
    /// `Transfer.sceneLight` over a whole image, for a Core Image context whose working space is
    /// linear Rec.2020 — the space its BT.2020 luminance weights belong to.
    public static func sceneLight(_ image: CIImage) -> CIImage {
        guard let kernel = sceneLightKernel else { return image }
        return kernel.apply(extent: image.extent, arguments: [image]) ?? image
    }

    /// Core Image's own kernel language, as `LensCorrectionFilter`: it compiles at run time and
    /// needs no Metal library in either app's build.
    private static let sceneLightKernel = CIColorKernel(source: """
    kernel vec4 sceneFromDisplayLight(__sample c) {
        float y = dot(c.rgb, vec3(0.2627, 0.6780, 0.0593));
        float scale = y > 1.0e-6 ? pow(y, \((1 - HLGTransfer.systemGamma) / HLGTransfer.systemGamma)) : 0.0;
        return vec4(c.rgb * scale, c.a);
    }
    """)
    #endif

    /// The transfer named by a colour profile, as ImageIO reports its name.
    public static func transfer(profileName: String?) -> Transfer? {
        guard let name = profileName?.uppercased() else { return nil }
        if name.contains("HLG") { return .hlg }
        if name.contains("PQ") || name.contains("2084") { return .pq }
        return nil
    }

    /// The HDR transfer of a file's pixels, or nil for SDR and gain-map files.
    public static func transfer(in source: CGImageSource) -> Transfer? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, nil) as? [CFString: Any] else { return nil }
        return transfer(profileName: properties[kCGImagePropertyProfileName] as? String)
    }

    /// The same, for a file on disc.
    public static func transfer(url: URL) -> Transfer? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(transfer(in:))
    }

    // MARK: - Reading the metadata

    private static func auxiliaryMetadata(
        in source: CGImageSource, type: CFString
    ) -> CGImageMetadata? {
        guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                source, 0, type) as? [CFString: Any],
              let metadata = info[kCGImageAuxiliaryDataInfoMetadata]
        else { return nil }
        guard CFGetTypeID(metadata as CFTypeRef) == CGImageMetadataGetTypeID()
        else { return nil }
        return (metadata as! CGImageMetadata)
    }

    /// One tag, by the path the metadata enumerates it under. Written values arrive as either a
    /// number or its decimal spelling depending on how the file was serialised, so both are read.
    private static func number(_ metadata: CGImageMetadata,
                               at path: String) -> Float? {
        guard let tag = CGImageMetadataCopyTagWithPath(
                metadata, nil, path as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else { return nil }
        if CFGetTypeID(value) == CFNumberGetTypeID() {
            return (value as! NSNumber).floatValue
        }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            return Float(value as! String)
        }
        return nil
    }

    /// A declaration is only usable when it is finite and above diffuse white.
    private static func usable(_ headroom: Float) -> Float? {
        guard headroom.isFinite, headroom > 1 else { return nil }
        return headroom
    }
}
#endif
