import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Reads a scanned negative without a film, as Normal reads one (`PlainNegativeScan`), from what
/// its frame measures and what its edit says of the scan. The browser's scan preparation takes
/// the result as it is.
public struct WebNegativePlainRequest: Decodable {
    public let negative: WebProfileRequest.Negative

    struct Result: Codable, Equatable {
        let border: [Float]
        let gains: [Float]
        let reference: Float
        /// Rows the read channels, columns the scan's densities over the clear film.
        let weights: [[Float]]
    }

    public func prepare() throws -> Data {
        let measured = try negative.measured()
        let plain = measured.edit.plain(border: measured.border, denseEnd: measured.denseEnd,
                                        source: negative.source)
        let values = { (v: SIMD3<Float>) in [v.x, v.y, v.z] }
        return try JSONEncoder().encode(Result(
            border: values(plain.border), gains: values(plain.gains), reference: plain.reference,
            weights: plain.weights.map(values)))
    }
}
