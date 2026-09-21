import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Statistical analysis runs once in the shared native/WASI model, never per viewport tile.
public struct WebAutomaticNegativeRequest: Decodable {
    public let width: Int
    public let height: Int
    public let planes: [[Float]]
    public let monochrome: Bool
    public let rec2020: Bool

    public func prepare() throws -> Data {
        guard width >= 2, height >= 2, width <= 512, height <= 512,
              planes.count == 3, planes.allSatisfy({ $0.count == width * height }) else {
            throw AutomaticNegativeScan.Failure.invalidImage
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
}
