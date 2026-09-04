import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// Display metadata for the UI's working subset of `LensFilter.catalogue`.
struct FilterChoice: Identifiable, Hashable, StripChoice {
    let id: String
    let name: String
    /// What the filter says for itself where a list has room for it.
    var subtitle: String = ""

    /// The id that means bare glass. Not a clear filter — no filter, which is a different thing:
    /// a clear filter still costs light and still makes a ghost.
    static let noneID = "none"
    static let none = FilterChoice(id: noneID, name: "None", subtitle: "No filter")

    static func isNone(_ id: String?) -> Bool { id == nil || id == noneID }

    // MARK: The absorbing wall

    /// Colour conversion first, because that is the one a roll of tungsten film in daylight
    /// actually needs; then the gentler balancing filters, and the contrast filters that only
    /// mean anything on a monochrome stock.
    ///
    /// No neutral densities. An ND is a filter for the moment of exposure — it buys a slower
    /// shutter or a wider aperture — and that moment is already over by the time a photograph
    /// reaches the editor. Metered through the lens, which is the default, it is exactly
    /// invisible; metered as though the exposure were fixed, it only darkens, which is what the
    /// exposure control is for. The engine still carries them for the camera and for edits made
    /// while they were offered.
    static let absorbing: [FilterChoice] = [none] + [
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
    ].map { FilterChoice(id: $0.0, name: $0.1, subtitle: $0.2) }

    // MARK: The diffusion wall

    /// Family and grade together, because that is how they are sold and how they are chosen: the
    /// family decides how tight the glow is and the grade how much of it there is.
    static let diffusion: [FilterChoice] = [none] + DiffusionFilter.Family.allCases.flatMap {
        family in
        [DiffusionFilter.Grade.eighth, .quarter, .half, .one].map { grade in
            FilterChoice(id: "\(family.rawValue)-\(grade.rawValue)",
                         name: "\(family.label) \(grade.rawValue)",
                         subtitle: family.subtitle)
        }
    }

    // MARK: The lens strip

    /// Every filter the editor can fit, bare glass first, as the lens deck's strip offers them:
    /// the absorbing wall in its own order, then the diffusion wall. Each tile is the photograph
    /// with that one filter in front of the lens and nothing else.
    static let strip: [FilterChoice] =
        [none] + absorbing.filter { !isNone($0.id) } + diffusion.filter { !isNone($0.id) }

    /// The stack this tile stands for on its own: nothing for bare glass, else the one filter.
    var fittedAlone: [String] { Self.isNone(id) ? [] : [id] }

    /// The tile as the strip rule names it: nil for bare glass, else the filter's id.
    private var stripTile: String? { Self.isNone(id) ? nil : id }

    /// Whether this tile is one the edit's stack already carries: bare glass when nothing is
    /// fitted, otherwise the filter itself.
    func isFitted(in ids: [String]) -> Bool {
        LensFilterStrip.isFitted(stripTile, in: ids)
    }

    /// The stack after a tap on this tile: fitted behind the rest, taken off again, or — for
    /// bare glass — everything off.
    func toggled(_ ids: [String]) -> [String] {
        LensFilterStrip.toggled(ids, tile: stripTile)
    }

    /// A run of filter tiles is developed through everything but the stack; the stack is what
    /// the tiles are for.
    static func aside(_ grade: EditState) -> EditState {
        var slice = grade
        slice.lensFilterIDs = []
        return slice
    }

    func develop(_ grade: inout EditState) {
        grade.lensFilterIDs = fittedAlone
    }

    // MARK: Resolving a choice back to the physics

    static func lensFilter(id: String) -> LensFilter? {
        guard !isNone(id) else { return nil }
        return LensFilter.catalogued(id)
    }

    static func diffusionFilter(id: String) -> DiffusionFilter? {
        guard !isNone(id) else { return nil }
        let parts = id.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let family = DiffusionFilter.Family(rawValue: parts[0]),
              let grade = DiffusionFilter.Grade(rawValue: parts[1]) else { return nil }
        return DiffusionFilter.preset(family, grade: grade)
    }

    /// Resolves IDs into ordered absorbing filters and the first diffusion filter.
    /// Additional diffusion filters and unknown IDs are returned explicitly because they are not
    /// rendered.
    static func resolve(_ ids: [String])
        -> (absorbing: [LensFilter], diffusion: DiffusionFilter?, unusedDiffusion: [String],
            unknown: [String]) {
        var absorbing: [LensFilter] = []
        var diffusion: DiffusionFilter?
        var unused: [String] = []
        var unknown: [String] = []
        for id in ids where !isNone(id) {
            if let filter = lensFilter(id: id) {
                absorbing.append(filter)
            } else if let mist = diffusionFilter(id: id) {
                if diffusion == nil { diffusion = mist } else { unused.append(id) }
            } else {
                unknown.append(id)
            }
        }
        return (absorbing, diffusion, unused, unknown)
    }

    /// Whether an id names a scattering filter rather than an absorbing one — what a list needs
    /// to know to say which kind a row is.
    static func isDiffusion(_ id: String) -> Bool {
        !isNone(id) && diffusionFilter(id: id) != nil
    }

    // MARK: What a filter does, as a picture

    /// White light through the filter — the spectrum with its absorption cut out — as
    /// display-linear RGB across the strip. The most direct statement of what an absorbing
    /// filter is: a #25 keeps the long end, an 85B keeps everything with the blue pulled down.
    static func spectrumStrip(for id: String, samples: Int) -> [SIMD3<Float>]? {
        guard let filter = lensFilter(id: id) else { return nil }
        return filter.spectrumSwatch(samples: samples)
    }

    /// The halo one mist would put around something bright, in the units a glow needs: how far
    /// it spreads, and how much of the light goes into it.
    ///
    /// The spread is the halo's own weighted sigma, measured on a strip the size of a row rather
    /// than a frame, so a tight family stays tight and a wide one washes — Glimmerglass against
    /// Fog, in the row's own text.
    static func diffusionGlow(for id: String, stock: FilmStock?,
                              rowHeight: Float) -> (spread: Float, share: Float)? {
        guard let mist = diffusionFilter(id: id), let stock, rowHeight > 0 else { return nil }
        let halo = mist.halo(stock: stock, focalLengthMM: 50,
                             pixelPitchMM: 24 / rowHeight,
                             maximumSigmaPixels: rowHeight)
        let row = halo.weights[1]
        let total = row.reduce(0, +)
        guard total > 0 else { return nil }
        let spread = zip(row, halo.sigmasPixels).map(*).reduce(0, +) / total
        return (spread, halo.scatteredShare)
    }

    /// A few bright points as this mist leaves them.
    ///
    /// A diffusion filter has no colour to show, so a spectrum would say nothing about it. What
    /// it does have is the halo, and the way to show a halo is to put a highlight in front of it.
    /// The scattered share is spread by the filter's own three scales at their own weights, so a
    /// tight family blooms tightly and a wide one washes — the difference between Glimmerglass
    /// and Fog, drawn rather than described.
    static func bloomStrip(for id: String, stock: FilmStock?,
                           width: Int, height: Int) -> [Float]? {
        guard let mist = diffusionFilter(id: id), let stock, width > 0, height > 0 else {
            return nil
        }
        // A strip this small stands in for a frame, so the halo is measured against its own
        // short edge rather than a photograph's.
        let halo = mist.halo(stock: stock, focalLengthMM: 50,
                             pixelPitchMM: 24 / Float(height),
                             maximumSigmaPixels: Float(height))
        let spots: [(Float, Float)] = [(0.18, 0.5), (0.5, 0.34), (0.82, 0.62)]
        var image = [Float](repeating: 0.015, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var value: Float = 0
                for (sx, sy) in spots {
                    let dx = Float(x) - sx * Float(width)
                    let dy = Float(y) - sy * Float(height)
                    let r2 = dx * dx + dy * dy
                    // The unscattered core, then each scale's share of what did scatter.
                    // A wider core than a point: at this size a single-pixel highlight would be
                    // gone under the label, and what is being shown is the halo around it.
                    value += halo.directShare * exp(-r2 / 20)
                    for (weight, sigma) in zip(halo.weights[1], halo.sigmasPixels) {
                        let s = max(sigma, 0.5)
                        value += halo.scatteredShare * weight * exp(-r2 / (2 * s * s))
                    }
                }
                image[y * width + x] += value
            }
        }
        let peak = image.max() ?? 1
        return peak > 0 ? image.map { min($0 / peak, 1) } : image
    }

    /// What to call a fitted filter where there is room for one line.
    static func name(for id: String?) -> String {
        guard let id, !isNone(id) else { return none.name }
        if let offered = (absorbing + diffusion).first(where: { $0.id == id }) {
            return offered.name
        }
        // A filter no longer offered can still be fitted on an edit made while it was, and the
        // engine still develops it. It names itself from the catalogue rather than reading blank.
        return LensFilter.catalogued(id)?.name ?? ""
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
