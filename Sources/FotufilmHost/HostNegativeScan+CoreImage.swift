#if canImport(CoreImage) && canImport(ImageIO)
import CoreImage
import Foundation
import UniformTypeIdentifiers
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Scans read through `NegativeScanImport`, the apps' own importer: a camera RAW with every
/// rendering choice off, anything else through its colour profile, or as linear samples where it
/// has none: an untagged scan is the scanner's raw output.
struct CoreImageScanDecoder: HostScanDecoder {
    func decodeScan(_ url: URL) throws -> HostImage {
        let data = try Data(contentsOf: url)
        let hint = UTType(filenameExtension: url.pathExtension)?.identifier
        let image = try NegativeScanImport.decode(data: data, identifierHint: hint,
                                                  linearSamples: !Self.statesEncoding(data))
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, height > 0, width <= 40000, height <= 40000,
              width * height <= 150_000_000 else { throw NegativeScanImport.Failure.unreadable }
        // A film reading wants every dense dye positive: the scan is held in the wide film space.
        var rgba = [Float](repeating: 1, count: width * height * 4)
        CIContext(options: [.workingColorSpace: NegativeScanImport.linearSpace,
                            .cacheIntermediates: false])
            .render(image, toBitmap: &rgba, rowBytes: width * 16,
                    bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
                    colorSpace: NegativeScanImport.filmSpace)
        return HostImage(rgba: rgba, width: width, height: height, contentHeadroom: 1)
    }

    /// Whether a file says how its samples encode light: an embedded profile, or a PNG's colour
    /// chunks, as `Sources/CFotufilmCodecs` reads them. ImageIO gives every other file sRGB.
    static func statesEncoding(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return true }
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        return properties[kCGImagePropertyProfileName] != nil
            || [kCGImagePropertyPNGsRGBIntent, kCGImagePropertyPNGGamma,
                kCGImagePropertyPNGChromaticities].contains { png[$0] != nil }
    }

    func measureLight(_ url: URL) throws -> NegativeLightFrame {
        let data = try Data(contentsOf: url)
        let hint = UTType(filenameExtension: url.pathExtension)?.identifier
        return try NegativeLightFrame(photo: NegativeScanImport.decode(data: data,
                                                                       identifierHint: hint))
    }
}
#endif
