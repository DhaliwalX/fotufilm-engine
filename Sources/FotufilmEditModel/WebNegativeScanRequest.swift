import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Supplies shared scan calibration and a print-only profile. Image samples stay
/// in the rendering worker; this request receives only dimensions and the border.
public struct WebNegativeScanRequest: Decodable {
    public let stock: FilmStockDefinition
    public let border: [Float]
    public let width: Int
    public let height: Int

    public struct Result: Encodable {
        public let calibration: ApproximateNegativeScan
        public let profile: Data
    }

    public func prepare() throws -> Data {
        guard border.count == 3 else {
            throw WebProfileRequest.Failure(description: "Sample a clear film border before converting the negative.")
        }
        var film = try stock.validated().stock
        // Match printPositiveChecked: transport belongs to exposure/development,
        // which the scanned film has already undergone.
        film.layeredTransport = nil
        let calibration = try ApproximateNegativeScan(stock: film, border: SIMD3(border[0], border[1], border[2]))
        var options = FotufilmEngine.Options()
        options.paper = .screen
        options.stage = .print
        let profile = try WebFilmProfile.prepare(stock: film, options: options, width: width, height: height)
        return try JSONEncoder().encode(Result(calibration: calibration, profile: profile))
    }
}
