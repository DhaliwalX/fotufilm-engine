import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Suggests which films a scanned negative could be (`NegativeFilmSuggestions`), from the preview
/// the automatic analysis reads and the film bases the browser catalogue carries.
public struct WebNegativeFilmRequest: Decodable {
    public struct Film: Codable {
        public let id: String
        public let name: String
        public let base: [Float]
    }

    public let width: Int
    public let height: Int
    /// Planar little-endian float32 linear Rec.2020, base64 in JSON.
    public let samples: Data
    public let films: [Film]
    public let limit: Int?

    struct Result: Encodable {
        struct Suggestion: Encodable {
            let films: [String]
            let likelihood: Float
        }
        let suggestions: [Suggestion]
        /// Whether the scan showed its light past the film, which the base was read against.
        let lamp: Bool
    }

    public func prepare() throws -> Data {
        guard width >= 2, height >= 2, width <= 512, height <= 512,
              let planes = WebAutomaticNegativeRequest.planes(samples, count: width * height),
              films.allSatisfy({ $0.base.count == 3 && $0.base.allSatisfy(\.isFinite) }) else {
            throw AutomaticNegativeScan.Failure.invalidImage
        }
        let preview = ImageBuffer(width: width, height: height, planes: planes)
        let catalogue = NegativeFilmSuggestions(films: films.map {
            .init(id: $0.id, name: $0.name, base: SIMD3($0.base[0], $0.base[1], $0.base[2]))
        })
        let reading = NegativeFilmSuggestions.read(preview: preview)
        let suggestions = reading.map { catalogue.suggest($0, limit: min(max(limit ?? 3, 1), 10)) } ?? []
        return try JSONEncoder().encode(Result(
            suggestions: suggestions.map { .init(films: $0.films.map(\.id), likelihood: $0.likelihood) },
            lamp: reading?.lamp != nil))
    }
}
