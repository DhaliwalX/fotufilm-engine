import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Only the neutral 64-cell regional meter enters the settings worker, not a photograph.
public struct WebAutoAdjustmentRequest: Decodable {
    public var stock: FilmStockDefinition?
    public var printCorrection: Float?
    public var regionStops: [Float]

    public struct Result: Codable {
        public var exposureEV: Float
        public var highlights: Float
        public var shadows: Float
        public var shadowLatitude: Float
        public var highlightLatitude: Float
    }

    public func prepare() throws -> Data {
        guard !regionStops.isEmpty, regionStops.count <= 4096,
              regionStops.allSatisfy({ $0.isFinite && (-256...256).contains($0) }),
              (printCorrection ?? 0).isFinite, (0...1).contains(printCorrection ?? 0),
              let scene = AutoAdjustment.SceneStops(regionStops: regionStops) else {
            throw WebProfileRequest.Failure(description: "Invalid automatic exposure measurement.")
        }
        let window: (shadows: Float, highlights: Float)
        if let stock {
            window = AutoAdjustment.latitude(stock: try stock.validated().stock,
                                               printCorrection: printCorrection ?? 0)
        } else {
            window = PlainDevelop.latitude
        }
        let solution = AutoAdjustment.solve(scene: scene, window: window)
        return try JSONEncoder().encode(Result(
            exposureEV: solution.exposureEV, highlights: solution.highlights,
            shadows: solution.shadows, shadowLatitude: window.shadows,
            highlightLatitude: window.highlights))
    }
}
