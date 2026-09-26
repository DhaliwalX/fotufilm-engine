import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Statistical analysis runs once in the shared native/WASI model, never per viewport tile.
public struct WebAutomaticNegativeRequest: Decodable {
    public let width: Int
    public let height: Int
    public let planes: [[Float]]?
    /// Planar little-endian float32, base64 in JSON; bounds checked before unpacking.
    public let samples: Data?
    public let monochrome: Bool
    public let rec2020: Bool

    public func prepare() throws -> Data {
        guard width >= 2, height >= 2, width <= 512, height <= 512 else {
            throw AutomaticNegativeScan.Failure.invalidImage
        }
        let planes: [[Float]]
        if let samples {
            guard self.planes == nil,
                  let unpacked = Self.planes(samples, count: width * height) else {
                throw AutomaticNegativeScan.Failure.invalidImage
            }
            planes = unpacked
        } else {
            guard let supplied = self.planes, supplied.count == 3,
                  supplied.allSatisfy({ $0.count == width * height }) else {
                throw AutomaticNegativeScan.Failure.invalidImage
            }
            planes = supplied
        }
        var preview = ImageBuffer(width: width, height: height, planes: planes)
        if rec2020 {
            for i in 0..<preview.pixelCount {
                let rgb = AutomaticNegativeScan.rec2020ToSRGB(SIMD3(planes[0][i], planes[1][i], planes[2][i]))
                for c in 0..<3 { preview.planes[c][i] = rgb[c] }
            }
        }
        return try JSONEncoder().encode(AutomaticNegativeScan(preview: preview, monochrome: monochrome))
    }

    /// Three planes of `count` little-endian float32 samples, or nil when the size disagrees.
    static func planes(_ samples: Data, count: Int) -> [[Float]]? {
        guard samples.count == count * 3 * 4 else { return nil }
        return samples.withUnsafeBytes { bytes in
            (0..<3).map { channel in
                (0..<count).map { index in
                    let bits = bytes.loadUnaligned(fromByteOffset: (channel * count + index) * 4, as: UInt32.self)
                    return Float(bitPattern: UInt32(littleEndian: bits))
                }
            }
        }
    }
}
