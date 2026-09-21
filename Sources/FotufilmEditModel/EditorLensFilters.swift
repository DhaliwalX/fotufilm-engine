import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The filter drawer shared by the native editors and browser inspector.
public enum EditorLensFilters {
    public struct Choice: Codable, Sendable {
        public let id, name, detail, kind: String
        public let spectrum: [[Int]]?
    }

    public static let absorbing: [Choice] = [
        ("w85b", "85B", "Daylight → tungsten film"),
        ("w85", "85", "Daylight → 3400 K"),
        ("w80a", "80A", "Tungsten → daylight film"),
        ("w80b", "80B", "3400 K → daylight film"),
        ("w81a", "81A", "Warm a little"),
        ("w81ef", "81EF", "Warm a lot"),
        ("w82a", "82A", "Cool a little"),
        ("w82c", "82C", "Cool a lot"),
        ("w8", "#8 Yellow", "Monochrome contrast"),
        ("w15", "#15 Deep Yellow", "Monochrome contrast"),
        ("w21", "#21 Orange", "Monochrome contrast"),
        ("w25", "#25 Red", "Monochrome contrast"),
        ("w29", "#29 Deep Red", "Monochrome contrast"),
        ("w58", "#58 Green", "Monochrome contrast"),
    ].map { id, name, detail in
        Choice(id: id, name: name, detail: detail, kind: "absorbing",
               spectrum: LensFilter.catalogued(id)?.spectrumSwatch(samples: 26).map { pixel in
                   [pixel.x, pixel.y, pixel.z].map { Int((min(max($0, 0), 1) * 255).rounded()) }
               })
    }

    public static let diffusion: [Choice] = DiffusionFilter.Family.allCases.flatMap { family in
        [DiffusionFilter.Grade.eighth, .quarter, .half, .one].map { grade in
            Choice(id: "\(family.rawValue)-\(grade.rawValue)", name: "\(family.label) \(grade.rawValue)",
                   detail: family.subtitle, kind: "diffusion", spectrum: nil)
        }
    }

    public static func diffusionFilter(_ id: String) -> DiffusionFilter? {
        let parts = id.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, let family = DiffusionFilter.Family(rawValue: parts[0]),
              let grade = DiffusionFilter.Grade(rawValue: parts[1]) else { return nil }
        return .preset(family, grade: grade)
    }

    public static func resolve(_ ids: [String])
        -> (absorbing: [LensFilter], diffusion: DiffusionFilter?, unusedDiffusion: [String], unknown: [String]) {
        var absorbing: [LensFilter] = [], diffusion: DiffusionFilter?
        var unused: [String] = [], unknown: [String] = []
        for id in ids where id != "none" {
            if let filter = LensFilter.catalogued(id) { absorbing.append(filter) }
            else if let mist = diffusionFilter(id) {
                if diffusion == nil { diffusion = mist } else { unused.append(id) }
            } else { unknown.append(id) }
        }
        return (absorbing, diffusion, unused, unknown)
    }

    public struct DiffusionPreview: Encodable {
        public let sigmas, weights: [Float]
        public let direct, scattered: Float
    }

    public static func previews(for stock: FilmStock) -> [String: DiffusionPreview] {
        Dictionary(uniqueKeysWithValues: diffusion.compactMap { choice in
            guard let filter = diffusionFilter(choice.id) else { return nil }
            let halo = filter.halo(stock: stock, focalLengthMM: 50,
                pixelPitchMM: 24 / 26, maximumSigmaPixels: 26)
            return (choice.id, DiffusionPreview(sigmas: halo.sigmasPixels,
                weights: halo.weights[1], direct: halo.directShare, scattered: halo.scatteredShare))
        })
    }

    public static func webData() throws -> Data {
        struct Metering: Encodable { let id, name: String }
        struct Catalogue: Encodable {
            let choices: [Choice]
            let supported: [String]
            let names: [String: String]
            let meterings: [Metering]
        }
        let supported = LensFilter.catalogue.map(\.id) + DiffusionFilter.Family.allCases.flatMap { family in
            DiffusionFilter.Grade.allCases.map { "\(family.rawValue)-\($0.rawValue)" }
        }
        let names = Dictionary(uniqueKeysWithValues: LensFilter.catalogue.map { ($0.id, $0.name) }
            + DiffusionFilter.Family.allCases.flatMap { family in
                DiffusionFilter.Grade.allCases.map { ("\(family.rawValue)-\($0.rawValue)", "\(family.label) \($0.rawValue)") }
            })
        let value = Catalogue(choices: absorbing + diffusion, supported: supported, names: names,
            meterings: LensFilterCompensation.allCases.map { Metering(id: $0.rawValue, name: $0.label) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private extension DiffusionFilter.Family {
    var subtitle: String {
        switch self {
        case .proMist: return "Broad bloom, lifted blacks"
        case .blackProMist: return "Broad bloom, blacks held"
        case .glimmerglass: return "Tight sparkle"
        case .blackGlimmerglass: return "Tight sparkle, blacks held"
        case .fog: return "Widest glow"
        case .blackFog: return "Widest glow, blacks held"
        }
    }
}
