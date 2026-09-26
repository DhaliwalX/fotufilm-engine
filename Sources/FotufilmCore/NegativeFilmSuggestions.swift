import Foundation

/// Which installed films a scanned negative could be, from the colour of its clear film base.
///
/// Each film's base is predicted from its spectral model as a colorimetric scan white-balanced on
/// its light source would record it: linear Rec.2020 densities of the base against the bare lamp.
/// A scan's border is compared with those predictions. Without a light frame only the base's
/// colour is known, not how dense it is overall, so films whose bases differ only in density —
/// most black-and-white films — cannot be told apart and are suggested together.
///
/// These are suggestions, not an identification: batches, fog, processing and the scanner's own
/// channel response move a real base by a few hundredths of a density, which is as far apart as
/// many films of one family sit.
public struct NegativeFilmSuggestions: Sendable {
    public struct Film: Sendable, Equatable {
        public let id: String
        public let name: String
        /// Base density in each linear Rec.2020 channel, against the lamp.
        public let base: SIMD3<Float>
    }

    /// Films whose predicted bases a scan cannot tell apart, with how likely they are together.
    public struct Suggestion: Sendable, Equatable {
        public let films: [Film]
        /// Share of the likelihood across every suggestion, 0…1.
        public let likelihood: Float
    }

    public let films: [Film]

    /// Density spread of a real base's colour about its prediction: model error, batch and the
    /// scanner's channel response together.
    static let colourSpread: Float = 0.04
    /// The same for the overall density, which also carries the light frame's exposure match.
    static let densitySpread: Float = 0.08
    /// Films closer than this in every channel are one suggestion.
    static let indistinguishable: Float = 0.01

    public init(films: [Film]) {
        self.films = films
    }

    /// The films a scan can be read as: every installed negative.
    public init(stocks: [String: FilmStock]) {
        films = stocks.filter { !$0.value.isReversal && !$0.value.isReflectionPrint }
            .sorted { $0.key < $1.key }
            .map { Film(id: $0.key, name: $0.value.name, base: Self.base(of: $0.value)) }
    }

    /// The film base's densities as a lamp-balanced colorimetric scan records them.
    public static func base(of stock: FilmStock) -> SIMD3<Float> {
        let clear = ColorScience.linearDisplayP3ToRec2020(
            SpectralRuntime.transmissionRGB(density: stock.curves.map(\.dMin), stock: stock))
        return SIMD3(density(clear.x), density(clear.y), density(clear.z))
    }

    /// What a scan shows of its film base, and of the bare light when the frame includes it.
    public struct Reading: Sendable, Equatable {
        /// Clear film, linear Rec.2020.
        public var border: SIMD3<Float>
        /// The bare light source, linear Rec.2020: shown past the film's edge, or a separate light
        /// frame.
        public var lamp: SIMD3<Float>?
        /// Whether `lamp` fixes the base's overall density as well as its colour. A light frame
        /// captured like the scan does; a lamp seen in a rendered picture has been through its
        /// tone curve, which stretches density, so only its colour counts.
        public var measuresDensity: Bool

        public init(border: SIMD3<Float>, lamp: SIMD3<Float>? = nil, measuresDensity: Bool = false) {
            self.border = border
            self.lamp = lamp
            self.measuresDensity = lamp != nil && measuresDensity
        }
    }

    /// Reads a preview of a scan, linear Rec.2020. Clear film and the bare light are plateaus: many
    /// pixels at one density, where a picture's own tones and the blurred edges between them are
    /// spread thin. The thinnest plateau is the border, unless it is a neutral light with an orange
    /// plateau under it: then it is the lamp showing past the film, which the base's colour is
    /// read against. Only a neutral light is trusted, because an orange base is itself a bright
    /// plateau with the picture's plateaus under it. A black-and-white base is as neutral as the
    /// lamp, so there the thinnest plateau stays the border. A scan white-balanced on the film
    /// border shows no orange at all and reads as black-and-white film.
    public static func read(preview: ImageBuffer) -> Reading? {
        var levels: [Float] = [], colours: [SIMD3<Float>] = []
        for i in 0..<preview.pixelCount {
            let p = SIMD3(preview.planes[0][i], preview.planes[1][i], preview.planes[2][i])
            guard p.x > 0, p.y > 0, p.z > 0, p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
            levels.append(mean(SIMD3(density(p.x), density(p.y), density(p.z))))
            colours.append(p)
        }
        let plateaus = plateauLevels(levels)
        guard let thinnest = plateaus.first else { return nil }
        let at = { (level: Float) -> SIMD3<Float> in
            median(zip(levels, colours).filter { abs($0.0 - level) <= plateauWidth }.map(\.1))
        }
        let first = at(thinnest)
        if let next = plateaus.first(where: { $0 >= thinnest + lampGap }) {
            let base = at(next), lampColour = colour(first), baseColour = colour(base)
            let neutralLamp = max(abs(lampColour.x), abs(lampColour.y), abs(lampColour.z)) < neutral
            let orangeBase = baseColour.z - baseColour.x > maskContrast
            if neutralLamp, orangeBase, (0..<3).allSatisfy({ base[$0] < first[$0] }) {
                return Reading(border: base, lamp: first)
            }
        }
        return Reading(border: first)
    }

    /// Mean densities of the preview's plateaus, thinnest first: local peaks of a density
    /// histogram holding at least `plateauShare` of the pixels.
    static func plateauLevels(_ levels: [Float]) -> [Float] {
        guard let lowest = levels.min(), levels.count >= 16 else { return [] }
        let bins = 160
        var counts = [Float](repeating: 0, count: bins)
        for level in levels {
            let bin = Int((level - lowest) / plateauBin)
            if bin < bins { counts[bin] += 1 }
        }
        let smoothed = counts.indices.map { i in
            (counts[max(i - 1, 0)] + 2 * counts[i] + counts[min(i + 1, bins - 1)]) / 4
        }
        let least = Float(levels.count) * plateauShare
        return smoothed.indices.filter { i in
            smoothed[i] >= least && smoothed[i] >= smoothed[max(i - 1, 0)]
                && smoothed[i] > smoothed[min(i + 1, bins - 1)]
        }.map { lowest + (Float($0) + 0.5) * plateauBin }
    }

    static func median(_ values: [SIMD3<Float>]) -> SIMD3<Float> {
        var result = SIMD3<Float>()
        for c in 0..<3 {
            let sorted = values.map { $0[c] }.sorted()
            result[c] = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        return result
    }

    /// Histogram bin, and the half-width a plateau's pixels are gathered over, in density.
    static let plateauBin: Float = 0.02
    static let plateauWidth: Float = 0.03
    /// Share of the pixels a plateau holds at least.
    static let plateauShare: Float = 0.01
    /// How much denser than the lamp the film base must be, in density.
    static let lampGap: Float = 0.1
    /// Largest channel departure from grey a light source may show, in density.
    static let neutral: Float = 0.06
    /// Blue-over-red density an orange mask shows at least.
    static let maskContrast: Float = 0.2

    /// A reading's densities about their mean: the base's colour without its overall density.
    static func colour(_ transmission: SIMD3<Float>) -> SIMD3<Float> {
        let d = SIMD3(density(transmission.x), density(transmission.y), density(transmission.z))
        return d - mean(d)
    }

    /// Ranks the films against a reading of a scan.
    public func suggest(_ reading: Reading, limit: Int = 5) -> [Suggestion] {
        let light = reading.lamp ?? SIMD3(repeating: 1)
        let border = reading.border
        let observed = SIMD3(Self.density(border.x / light.x), Self.density(border.y / light.y),
                             Self.density(border.z / light.z))
        guard observed.x.isFinite, observed.y.isFinite, observed.z.isFinite else { return [] }
        let absolute = reading.measuresDensity
        let scored = films.map { film -> (film: Film, energy: Float) in
            (film, Self.energy(observed, film.base, absolute: absolute))
        }
        var groups: [(films: [Film], energy: Float)] = []
        for entry in scored.sorted(by: { $0.energy < $1.energy }) {
            if let index = groups.firstIndex(where: {
                Self.alike($0.films[0].base, entry.film.base, absolute: absolute)
            }) {
                groups[index].films.append(entry.film)
            } else {
                groups.append(([entry.film], entry.energy))
            }
        }
        let best = groups.first?.energy ?? 0
        let weights = groups.map { exp(-($0.energy - best)) }
        let total = weights.reduce(0, +)
        return zip(groups, weights).prefix(limit).map {
            Suggestion(films: $0.0.films, likelihood: $0.1 / total)
        }
    }

    /// A camera records a base's colour more saturated than colorimetry predicts, by a factor that
    /// depends on its colour matrix and white balance: about 1.25 over the scans measured, rarely
    /// outside 0.85–1.4. Each scan is fitted its own factor under that prior.
    static let saturation: (typical: Float, spread: Float) = (1.25, 0.2)

    /// Half the squared, spread-scaled distance: the base's colour at the best-fitting saturation
    /// always, its overall density only when a lamp fixes it.
    static func energy(_ observed: SIMD3<Float>, _ base: SIMD3<Float>, absolute: Bool) -> Float {
        let o = observed - mean(observed), b = base - mean(base)
        var colour = Float.greatestFiniteMagnitude
        for step in 0...56 {
            let scale = 0.6 + Float(step) * 0.025
            let miss = o - scale * b
            let prior = log(scale / saturation.typical) / saturation.spread
            colour = min(colour, (miss * miss).sum() / (colourSpread * colourSpread) + prior * prior)
        }
        guard absolute else { return colour / 2 }
        let level = mean(observed) - mean(base)
        return (colour + level * level / (densitySpread * densitySpread)) / 2
    }

    static func alike(_ a: SIMD3<Float>, _ b: SIMD3<Float>, absolute: Bool) -> Bool {
        let d = absolute ? a - b : (a - mean(a)) - (b - mean(b))
        return max(abs(d.x), abs(d.y), abs(d.z)) < indistinguishable
    }

    static func mean(_ v: SIMD3<Float>) -> Float { v.sum() / 3 }
    static func density(_ transmission: Float) -> Float { -log10(max(transmission, 1e-6)) }
}
