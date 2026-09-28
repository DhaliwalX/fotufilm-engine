#if canImport(ImageIO)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Stills through ImageIO, as the Mac app writes them: Display P3 files carrying the source's
/// capture records by the chosen policy, and HDR HEIC as a gain map over the SDR picture where
/// the system writes one, otherwise a single HLG layer.
struct ImageIOStillEncoder: HostStillEncoder {
    private static let identifiers: [String: UTType] = [
        "image/png": .png, "image/jpeg": .jpeg, "image/tiff": .tiff, "image/heic": .heic,
    ]
    private static let context = CIContext(options: [.cacheIntermediates: false])

    var types: [String] { Array(Self.identifiers.keys) }
    var writesHDR: Bool { true }

    func write(_ still: HostStill, type: String, quality: Double, to url: URL) throws
        -> (width: Int, height: Int) {
        guard let uti = Self.identifiers[type] else {
            throw HostEngine.Failure(description: "This host cannot write \(type).")
        }
        let image = try Self.picture(still)
        let properties = Self.properties(still)
        if let hlg = still.hlg, uti == .heic {
            try writeHDR(image, hlg: hlg, still: still, properties: properties, to: url)
            return (image.width, image.height)
        }
        guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, uti.identifier as CFString, 1, nil) else {
            throw HostEngine.Failure(description: "The image could not be encoded.")
        }
        var options = properties
        options[kCGImageDestinationLossyCompressionQuality as String] = quality
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw HostEngine.Failure(description: "The image could not be written to \(url.path).")
        }
        return (image.width, image.height)
    }

    /// A picture encoded in memory, for a clipboard.
    func data(_ image: CGImage, type: UTType, properties: [String: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw HostEngine.Failure(description: "The picture could not be encoded.")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw HostEngine.Failure(description: "The picture could not be encoded.")
        }
        return data as Data
    }

    /// The SDR picture, framed when the still has a print frame.
    static func picture(_ still: HostStill) throws -> CGImage {
        let developed: CGImage?
        switch still.pixels {
        case .display8(let pixels):
            developed = image(Data(pixels), width: still.width, height: still.height, bits: 8,
                              space: CGColorSpace(name: CGColorSpace.displayP3)!)
        case .display16(let pixels):
            developed = image(pixels.withUnsafeBytes { Data($0) }, width: still.width,
                              height: still.height, bits: 16,
                              space: CGColorSpace(name: CGColorSpace.displayP3)!)
        }
        guard let developed else {
            throw HostEngine.Failure(description: "The image could not be encoded.")
        }
        guard let frame = still.frame else { return developed }
        guard let framed = PrintFrameRenderer.render(developed, configuration: frame) else {
            throw HostEngine.Failure(description: "The print frame could not be drawn.")
        }
        return framed
    }

    private static func image(_ data: Data, width: Int, height: Int, bits: Int,
                              space: CGColorSpace) -> CGImage? {
        CGDataProvider(data: data as CFData).flatMap { provider in
            CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 4,
                    bytesPerRow: width * bits / 2, space: space,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                        | (bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)),
                    provider: provider, decode: nil, shouldInterpolate: false,
                    intent: .defaultIntent)
        }
    }

    /// The capture records the policy keeps (`Rendered.metadata(applying:)`).
    static func properties(_ still: HostStill) -> [String: Any] {
        guard var carried = still.capture, still.metadata != .strip else { return [:] }
        if still.metadata == .preserveWithoutLocation {
            carried[kCGImagePropertyGPSDictionary as String] = nil
        }
        return carried
    }

    private func writeHDR(_ sdr: CGImage, hlg: [UInt16], still: HostStill,
                          properties: [String: Any], to url: URL) throws {
        guard let space = CGColorSpace(name: CGColorSpace.itur_2100_HLG),
              let hdrImage = Self.image(hlg.withUnsafeBytes { Data($0) }, width: still.width,
                                        height: still.height, bits: 16, space: space) else {
            throw HostEngine.Failure(description: "The HDR picture could not be encoded.")
        }
        func annotated(_ image: CIImage) -> CIImage {
            properties.isEmpty ? image
                : image.settingProperties(image.properties.merging(properties) { _, kept in kept })
        }
        try? FileManager.default.removeItem(at: url)
        let hdr = CIImage(cgImage: hdrImage)
        if #available(macOS 15, iOS 18, *) {
            try Self.context.writeHEIFRepresentation(
                of: annotated(CIImage(cgImage: sdr)), to: url, format: .RGB10,
                colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                options: [.hdrImage: hdr, .hdrGainMapAsRGB: true])
        } else {
            try Self.context.writeHEIF10Representation(of: annotated(hdr), to: url,
                                                       colorSpace: space, options: [:])
        }
    }
}

enum HostCaptureMetadata {
    /// The records an export can carry from the source file, as the Mac app keeps them: EXIF,
    /// its auxiliary lens records, TIFF and GPS, without the orientation or pixel size, which
    /// describe the source rather than the print.
    static func read(_ url: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return nil }
        var kept: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary] {
            guard var dictionary = properties[key as String] as? [String: Any] else { continue }
            if key == kCGImagePropertyTIFFDictionary {
                dictionary[kCGImagePropertyTIFFOrientation as String] = nil
            }
            if key == kCGImagePropertyExifDictionary {
                dictionary[kCGImagePropertyExifPixelXDimension as String] = nil
                dictionary[kCGImagePropertyExifPixelYDimension as String] = nil
            }
            kept[key as String] = dictionary
        }
        return kept.isEmpty ? nil : kept
    }
}
#endif
