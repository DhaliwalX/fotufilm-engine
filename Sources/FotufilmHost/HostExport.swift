import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Which of the source's capture records an export carries, as the Mac app offers them
/// (`ExportMetadataPolicy`).
enum HostMetadataPolicy: String, CaseIterable {
    /// Camera, exposure, lens and location.
    case preserve
    /// Camera, exposure and lens; no location.
    case preserveWithoutLocation
    /// No source metadata.
    case strip

    /// The Mac app's default.
    static let `default` = HostMetadataPolicy.preserveWithoutLocation
}

/// A developed still ready for a file: the picture every format carries and, for an HDR HEIC,
/// the same frame above display white.
struct HostStill {
    enum Pixels {
        /// Dithered 8-bit Display P3 with its sRGB transfer, RGBA.
        case display8([UInt8])
        /// 16-bit Display P3 with its sRGB transfer, RGBA.
        case display16([UInt16])
    }

    var pixels: Pixels
    var width: Int
    var height: Int
    /// 16-bit BT.2100 HLG in Rec. 2020 primaries, RGBA, when the export asked for HDR and the
    /// film delivers it.
    var hlg: [UInt16]?
    /// A print frame drawn around the picture.
    var frame: PrintFrameConfiguration?
    /// The source file's capture records, in the decoder's own form; the encoder that read them
    /// knows how to write them back.
    var capture: [String: Any]?
    var metadata: HostMetadataPolicy = .default
}

/// Writes stills to files. Each platform supplies one; the host asks `HostExport.encoder`.
protocol HostStillEncoder {
    /// The MIME types this encoder writes.
    var types: [String] { get }
    /// Whether it can write an HDR HEIC.
    var writesHDR: Bool { get }
    /// Writes the still and returns the size written, which a print frame makes larger.
    func write(_ still: HostStill, type: String, quality: Double, to url: URL) throws
        -> (width: Int, height: Int)
}

enum HostExport {
    /// The platform's encoder, or nil where this build has none.
    static let encoder: HostStillEncoder? = {
        #if canImport(ImageIO)
        return ImageIOStillEncoder()
        #else
        return nil
        #endif
    }()

    /// 16-bit Display P3 from display-linear light, through the same shoulder and transfer as the
    /// preview.
    static func display16(linear: [Float], width: Int, height: Int, knee: Float) -> [UInt16] {
        var encoded = [UInt16](repeating: 65535, count: width * height * 4)
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
        return encoded
    }

    /// BT.2100 HLG from the engine's developed linear Display P3, relight alpha included, with the
    /// conversion the Mac app writes its HDR stills through.
    static func hlg16(linear: [Float], width: Int, height: Int) -> [UInt16] {
        var encoded = [UInt16](repeating: 65535, count: width * height * 4)
        linear.withUnsafeBufferPointer { source in
            encoded.withUnsafeMutableBufferPointer { out in
                let out = out
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    var row = [Float](repeating: 0, count: width * 4)
                    row.withUnsafeMutableBufferPointer { row in
                        FilmOutputConversion.rec2020HLG.convert(
                            source, from: y * width * 4, count: width * 4, into: row)
                        for x in 0..<width {
                            for c in 0..<3 {
                                out[(y * width + x) * 4 + c] = UInt16(
                                    clamp(row[x * 4 + c] * 65535 + 0.5, 0, 65535))
                            }
                        }
                    }
                }
            }
        }
        return encoded
    }
}
