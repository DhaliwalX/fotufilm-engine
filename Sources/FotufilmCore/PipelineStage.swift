import Foundation

/// Selects a pipeline span. Negative and print spans exchange optical density through
/// `NegativeInterchange`; texture runs only the selected spatial stages.
public enum PipelineStage: String, Sendable, CaseIterable, Identifiable {
    /// Scene light to the finished output medium.
    case full
    /// Scene light in, developed negative out: the camera side, the emulsion's response, the
    /// negative's own spatial stages, and grain. No enlarger and no print medium — nothing images
    /// the negative in this mode, so the paper's optics are cleared however the frame would have
    /// been finished. The result is `NegativeInterchange`, not a picture.
    case negative
    /// `NegativeInterchange` in, finished output out: the selected medium and any optics it needs,
    /// and nothing before them. Exactly the stages `full` runs after grain.
    case print
    /// Source in, source out: the film's spatial character laid over the frame it was handed,
    /// with no characteristic curve, no dyes, and no print. See `TextureStages`.
    case texture

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .full: "Full"
        case .negative: "Negative Only"
        case .print: "Print Only"
        case .texture: "Texture Only"
        }
    }

    /// Whether this stage reads the scene rather than a developed negative.
    public var readsScene: Bool { self != .print }

    /// Whether this stage produces the finished image rather than an intermediate.
    public var writesPrint: Bool { self == .full || self == .print }

    /// Whether what this stage returns is light a host's transfer curve can encode.
    /// `negative` returns `NegativeInterchange` — optical densities — and a display curve
    /// applied to a density encodes nothing.
    public var writesEncodableLight: Bool { self != .negative }

    /// The basis the light this stage returns is in. `full` and `print` deliver the print in
    /// Display P3, where `texture` returns the caller's own frame in the engine's scene
    /// working space; a host encoding either one has to use the matrix out of the right basis.
    public var deliversInPrintBasis: Bool { writesPrint }

    /// A small stable integer for cache identities and for the flat parameter block the Resolve
    /// bridge takes. The order is an ABI: a saved project holds the number, not the name.
    public var ordinal: Int32 {
        switch self {
        case .full: 0
        case .negative: 1
        case .print: 2
        case .texture: 3
        }
    }

    public init?(ordinal: Int32) {
        guard let found = Self.allCases.first(where: { $0.ordinal == ordinal }) else { return nil }
        self = found
    }
}

/// Data exchanged between negative and print spans. RGB stores base-10 diffuse optical density for
/// the red-, green-, and blue-sensitive records; monochrome repeats one record. Transmission is
/// `10^-D`. The data has no colour space and must not be transformed, resampled, graded, or gamut
/// mapped. Both spans must use the same stock and lab settings. Alpha passes through unchanged.
public enum NegativeInterchange {
    /// The density a value must lie inside to be a developed negative at all.
    public static let range: ClosedRange<Float> = -0.5...8

    /// Whether one density is inside the interchange's stated range. Slightly negative values are
    /// legal: grain is a signed perturbation and it can carry a clear-film D-min below zero.
    public static func contains(_ density: Float) -> Bool {
        density.isFinite && range.contains(density)
    }
}

/// Spatial stages available to `PipelineStage.texture`.
/// Texture is the density difference between developments with and without selected stages,
/// applied as transmittance. Pointwise operations cancel. Uniform fields and empty selections are
/// exact no-ops.
public struct TextureStages: OptionSet, Sendable, Hashable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    /// The emulsion's own diffusion, per layer, and its luminance arm.
    public static let emulsionMTF = TextureStages(rawValue: 1 << 0)
    /// The light the base returns.
    public static let halation = TextureStages(rawValue: 1 << 1)
    /// The DIR couplers' diffusion and the adjacency effect — the spatial half of the coupler
    /// stages. Their pointwise inhibition is colour, and stays in both developments.
    public static let adjacency = TextureStages(rawValue: 1 << 2)
    /// The grain.
    public static let grain = TextureStages(rawValue: 1 << 3)
    /// The enlarger lens and the paper's scattering.
    public static let enlarger = TextureStages(rawValue: 1 << 4)

    public static let all: TextureStages = [
        .emulsionMTF, .halation, .adjacency, .grain, .enlarger,
    ]
    public static let none: TextureStages = []

    /// The selectable stages in a fixed order, each with the durable id a host persists it by.
    /// The order is a menu's; the ids are the ABI.
    public static let ordered: [(id: String, name: String, value: TextureStages)] = [
        ("emulsion-mtf", "Emulsion Diffusion", .emulsionMTF),
        ("halation", "Halation", .halation),
        ("adjacency", "Adjacency", .adjacency),
        ("grain", "Grain", .grain),
        ("enlarger", "Enlarger", .enlarger),
    ]

    /// Returns stages with nonzero stock contributions. Paper-specific enlarger blur is excluded
    /// because paper selection is independent and can reduce its contribution to zero.
    public static func offered(by stock: FilmStock) -> TextureStages {
        var result: TextureStages = []
        let primaryMTF = zip(stock.emulsionDiffusionMM,
                             stock.emulsionDiffusionPrimaryShare)
            .contains { pair in pair.0 > 0 && pair.1 > 0 }
        let secondaryMTF = zip(stock.emulsionDiffusionSecondaryMM,
                               stock.emulsionDiffusionPrimaryShare)
            .contains { pair in pair.0 > 0 && pair.1 < 1 }
        if primaryMTF || secondaryMTF { result.insert(.emulsionMTF) }
        if stock.halationStrength.contains(where: { $0 > 0 }) { result.insert(.halation) }
        // The spatial half of the coupler stages: the adjacency effect, and the couplers' own
        // diffusion. Either one alone is enough to have something to select.
        let diffusingCouplers = stock.couplerDiffusionMM > 0
            && stock.couplerInhibition.contains { $0.contains { $0 != 0 } }
        if stock.adjacencyStrength > 0 || diffusingCouplers { result.insert(.adjacency) }
        if stock.grainStrength > 0 { result.insert(.grain) }
        if !stock.isReversal { result.insert(.enlarger) }
        return result
    }
}
