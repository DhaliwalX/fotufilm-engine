import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Suggests which films a scanned negative could be (`NegativeFilmSuggestions`), from the preview
/// of the whole scan and the film bases the browser catalogue carries.
public struct WebNegativeFilmRequest: Decodable {
    public struct Film: Codable {
        public let id: String
        public let name: String
        public let base: [Float]
        /// Clear-film spectral transmittance on `SpectralGrid`, optional for older catalogues.
        public let spectrum: [Float]?

        public init(id: String, name: String, base: [Float], spectrum: [Float]? = nil) {
            self.id = id
            self.name = name
            self.base = base
            self.spectrum = spectrum
        }
    }

    public let width: Int
    public let height: Int
    /// Planar little-endian float32 linear Rec.2020, base64 in JSON.
    public let samples: Data
    public let films: [Film]
    public let limit: Int?
    /// What the scan's file says of its camera and decoder (`NegativeScanCapture`).
    public let source: NegativeScanCapture?
    /// As `WebProfileRequest.Negative.cameraProfile`.
    public let cameraProfile: String?

    struct Result: Encodable {
        struct Suggestion: Encodable {
            let films: [String]
            let likelihood: Float
        }
        let suggestions: [Suggestion]
        /// Whether the scan showed its light past the film, which the base was read against.
        let lamp: Bool
        /// The film's base under that light, linear Rec. 2020, where the scan showed it: the
        /// clear film the current reading is measured against until one is sampled
        /// (`ApproximateNegativeScan.estimatedFilmBase`).
        let base: [Float]?
    }

    public func prepare() throws -> Data {
        WebProfileRequest.Negative.register(cameraProfile: cameraProfile)
        guard width >= 2, height >= 2, width <= 512, height <= 512,
              let planes = Self.planes(samples, count: width * height),
              films.allSatisfy({
                  $0.base.count == 3 && $0.base.allSatisfy(\.isFinite) &&
                  ($0.spectrum == nil || ($0.spectrum?.count == SpectralGrid.count &&
                                          $0.spectrum?.allSatisfy({ $0.isFinite && $0 > 0 }) == true))
              }) else {
            throw AutomaticNegativeScan.Failure.invalidImage
        }
        let preview = ImageBuffer(width: width, height: height, planes: planes)
        let catalogue: NegativeFilmSuggestions
        if let source, films.allSatisfy({ $0.spectrum != nil }) {
            let setup = source.setup(light: .white)
            let response = setup.response()
            catalogue = NegativeFilmSuggestions(
                films: films.map {
                    .init(id: $0.id, name: $0.name,
                          base: NegativeFilmSuggestions.base(transmittance: $0.spectrum!,
                                                             response: response))
                },
                setup: setup)
        } else {
            catalogue = NegativeFilmSuggestions(films: films.map {
                .init(id: $0.id, name: $0.name, base: SIMD3($0.base[0], $0.base[1], $0.base[2]))
            })
        }
        let reading = NegativeFilmSuggestions.read(preview: preview)
        let suggestions = reading.map { catalogue.suggest($0, limit: min(max(limit ?? 3, 1), 10)) } ?? []
        return try JSONEncoder().encode(Result(
            suggestions: suggestions.map { .init(films: $0.films.map(\.id), likelihood: $0.likelihood) },
            lamp: reading?.lamp != nil,
            base: reading.flatMap { $0.lamp == nil ? nil : [$0.border.x, $0.border.y, $0.border.z] }))
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
