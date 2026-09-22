import Foundation
import FotufilmHalide

/// Whole-frame analysis for the shared Halide negative inversion stage.
/// Adapts Lin–Tretter's robust endpoint method; it does not measure physical film base.
public struct AutomaticNegativeScan: Encodable, Sendable {
    public let parameters: [Float]
    public let weak: Bool
    public let sampleCount: Int
    public enum Failure: LocalizedError {
        case invalidImage, insufficientSamples, unavailable
        public var errorDescription: String? {
            switch self {
            case .invalidImage: return "Use a bounded linear preview to analyse the negative."
            case .insufficientSamples: return "The negative contains too few usable samples."
            case .unavailable: return "Automatic negative conversion is unavailable on this device."
            }
        }
    }

    /// Supply linear sRGB, with no inversion or automatic photographic enhancements applied.
    /// The central 80% keeps ordinary holders/borders out of the image statistics.
    public init(preview: ImageBuffer, monochrome: Bool = false) throws {
        guard preview.width >= 2, preview.height >= 2, preview.width <= 512, preview.height <= 512,
              preview.planes.count == 3, preview.planes.allSatisfy({ $0.count == preview.pixelCount }) else {
            throw Failure.invalidImage
        }
        var channels = [[Float]](repeating: [], count: 3)
        let mx = preview.width / 10, my = preview.height / 10
        for y in my..<(preview.height - my) { for x in mx..<(preview.width - mx) {
            let i = y * preview.width + x
            let pixel = preview.planes.map { $0[i] }
            // Match negative_scan_valid: out-of-sRGB channels are valid after
            // colour management. Clamp them per channel, never discard the RGB triplet.
            guard pixel.allSatisfy({ $0.isFinite && abs($0) < 1e20 }),
                  pixel.contains(where: { $0 > 0 }) else { continue }
            for c in 0..<3 { channels[c].append(max(0, pixel[c])) }
        } }
        guard channels[0].count >= 4 else { throw Failure.insufficientSamples }
        sampleCount = channels[0].count
        var low = [Float](), high = [Float]()
        for values in channels {
            let sorted = values.sorted()
            // Order statistics commute with the monotone sRGB transfer used by Halide.
            low.append(sorted[Int(Float(sorted.count - 1) * 0.05)])
            high.append(sorted[Int(Float(sorted.count - 1) * 0.95)])
        }
        weak = (monochrome ? [1] : [0, 1, 2]).contains { high[$0] - low[$0] < high[$0] * 0.02 }
        parameters = low + high + [0.6, monochrome ? 1 : 0]
    }

    /// The same constant transform used for colour-managed browser ingest.
    public static func rec2020ToSRGB(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(1.660491 * rgb.x - 0.5876411 * rgb.y - 0.0728499 * rgb.z,
              -0.1245505 * rgb.x + 1.1328999 * rgb.y - 0.0083494 * rgb.z,
              -0.0181508 * rgb.x - 0.1005789 * rgb.y + 1.1187297 * rgb.z)
    }

    /// Full-resolution processing reuses the preview's endpoints, including across tiles.
    public func convert(_ scan: ImageBuffer, useMetal: Bool = true) throws -> ImageBuffer {
        guard scan.width > 0, scan.height > 0, scan.width <= 40000, scan.height <= 40000,
              scan.pixelCount <= 150_000_000, scan.planes.count == 3,
              scan.planes.allSatisfy({ $0.count == scan.pixelCount }) else { throw Failure.invalidImage }
        var result = ImageBuffer(width: scan.width, height: scan.height)
        var backend: Int32 = useMetal ? 1 : 0
        // Bounded staging avoids duplicating several full-size float images during import.
        for top in stride(from: 0, to: scan.height, by: 512) {
            for left in stride(from: 0, to: scan.width, by: 512) {
                let width = min(512, scan.width - left), height = min(512, scan.height - top)
                let count = width * height
                var input = [Float](repeating: 0, count: count * 3)
                var output = input
                for c in 0..<3 { for row in 0..<height {
                    let from = (top + row) * scan.width + left, to = c * count + row * width
                    input.replaceSubrange(to..<(to + width), with: scan.planes[c][from..<(from + width)])
                } }
                let code = input.withUnsafeBufferPointer { src in
                    output.withUnsafeMutableBufferPointer { dst in
                        parameters.withUnsafeBufferPointer { p in
                            var code = fotufilm_negative_scan(src.baseAddress, dst.baseAddress,
                                Int32(width), Int32(height), p.baseAddress, backend)
                            if code != 0 && backend == 1 {
                                backend = 0
                                code = fotufilm_negative_scan(src.baseAddress, dst.baseAddress,
                                    Int32(width), Int32(height), p.baseAddress, backend)
                            }
                            return code
                        }
                    }
                }
                guard code == 0 else { throw Failure.unavailable }
                for c in 0..<3 { for row in 0..<height {
                    let from = c * count + row * width, to = (top + row) * scan.width + left
                    result.planes[c].replaceSubrange(to..<(to + width), with: output[from..<(from + width)])
                } }
            }
        }
        return result
    }
}
