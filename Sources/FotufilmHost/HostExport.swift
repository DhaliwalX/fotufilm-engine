import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

/// Encodes a developed frame into the file the editor asked for. Eight-bit formats carry the
/// dithered Display P3 picture; TIFF is 16-bit Display P3 from display-linear light, encoded with
/// the same shoulder and transfer as the preview.
enum HostExport {
    static func write(_ pixels: [UInt8], width: Int, height: Int, deep: Bool, knee: Float,
                      type: String, quality: Double, to url: URL) throws {
        #if canImport(ImageIO)
        let identifiers: [String: UTType] = [
            "image/png": .png, "image/jpeg": .jpeg, "image/tiff": .tiff, "image/heic": .heic,
        ]
        guard let uti = identifiers[type] else {
            throw HostEngine.Failure(description: "This host cannot write \(type).")
        }
        let image = try cgImage(pixels, width: width, height: height, deep: deep, knee: knee)
        guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, uti.identifier as CFString, 1, nil) else {
            throw HostEngine.Failure(description: "The image could not be encoded.")
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw HostEngine.Failure(description: "The image could not be written to \(url.path).")
        }
        #else
        throw HostEngine.Failure(description: "This build has no image encoder.")
        #endif
    }

    #if canImport(ImageIO)
    /// The developed frame as a Display P3 image: 8-bit pixels as they are, 16-bit from linear light.
    static func cgImage(_ pixels: [UInt8], width: Int, height: Int, deep: Bool,
                        knee: Float) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let data: Data, bits: Int
        if deep {
            var encoded = [UInt16](repeating: 65535, count: width * height * 4)
            pixels.withUnsafeBytes { raw in
                let linear = raw.bindMemory(to: Float.self)
                encoded.withUnsafeMutableBufferPointer { out in
                    let out = out
                    DispatchQueue.concurrentPerform(iterations: height) { y in
                        for i in (y * width)..<((y + 1) * width) {
                            for c in 0..<3 {
                                let v = ColorScience.linearToSrgb(
                                    ColorScience.displayShoulder(linear[i * 4 + c], knee: knee))
                                out[i * 4 + c] = UInt16(clamp(v * 65535 + 0.5, 0, 65535))
                            }
                        }
                    }
                }
            }
            data = encoded.withUnsafeBytes { Data($0) }
            bits = 16
        } else {
            data = Data(pixels)
            bits = 8
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 4,
                bytesPerRow: width * bits / 2, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                    | (bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            throw HostEngine.Failure(description: "The image could not be encoded.")
        }
        return image
    }
    #endif
}
