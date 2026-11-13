import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Reads a scanned negative without a film, as Normal reads one (`PlainNegativeScan`), from what
/// its frame measures and what its edit says of the scan. The browser's scan preparation takes
/// the result as it is.
public struct WebNegativePlainRequest: Decodable {
    public let negative: WebProfileRequest.Negative

    /// The plain reading as the scan preparation's kernel takes it (`PlainNegativeScan`).
    struct Result: Codable, Equatable {
        /// Clear film net of the scan's stray light.
        let border: [Float]
        let gains: [Float]
        let reference: Float
        /// Rows the read channels, columns the scan's densities over the clear film.
        let weights: [[Float]]
        /// The scan's stray light, the toe's light and each channel's light scale
        /// (`NegativeScanPreparation.packedLight`).
        let flare: [Float]
        let toe: Float
        let scale: [Float]

        init(_ plain: PlainNegativeScan) {
            let values = { (v: SIMD3<Float>) in [v.x, v.y, v.z] }
            border = values(plain.border - plain.flare)
            gains = values(plain.gains)
            reference = plain.reference
            weights = plain.weights.map(values)
            flare = values(plain.flare)
            toe = plain.toeLight
            scale = values(plain.lightScales)
        }
    }

    public func prepare() throws -> Data {
        let measured = try negative.measured()
        let plain = measured.edit.plain(
            border: measured.border, denseEnd: measured.denseEnd, slopes: measured.slopes,
            source: negative.source, flare: measured.flare)
        return try JSONEncoder().encode(Result(plain))
    }
}
