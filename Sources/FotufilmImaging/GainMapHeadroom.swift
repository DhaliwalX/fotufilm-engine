#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO

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
    /// different ceilings relative to diffuse white and must not share a fallback number.
    private static func transferFunctionHeadroom(in source: CGImageSource) -> Float? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, nil) as? [CFString: Any],
              let profile = properties[kCGImagePropertyProfileName] as? String
        else { return nil }
        let name = profile.uppercased()
        if name.contains("HLG") { return HLGSceneTransfer.headroom }
        if name.contains("PQ") || name.contains("2084") {
            return PQSceneTransfer.headroom
        }
        return nil
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
