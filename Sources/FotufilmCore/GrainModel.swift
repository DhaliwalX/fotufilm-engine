import Foundation

/// Which model develops grain.
public enum GrainModel: String, Sendable, CaseIterable, Codable, Identifiable {
    /// A unit-variance field blurred to the clump's correlation length: Poisson counts for dye
    /// clouds and a continuous normal field for silver, whose clump size is a correlation length
    /// rather than one countable particle. Granularity is calibrated and cost is flat, but the
    /// texture is tied to the output lattice.
    case clumpField = "clump"
    /// The film's own crystals laid where they sit on the emulsion (`FilmGrain`): hashed in film
    /// millimetres so every resolution samples the same film, dye clouds sized by their dye over
    /// the coupler capacity that caps them, silver grains opaque, and each pixel the average of
    /// the light through it. Rendered once per stock onto tiles the kernel samples (grain mode 1);
    /// builds without those tiles — WebGPU — lay `clumpField`.
    case film = "film"
    /// The crystals that form the image, rendered as what they form: Poisson counts of
    /// developed crystals per size bin at the mean the developed density gives each, laid as
    /// dye clouds — or silver grains — at each bin's own radius, drawn from each sublayer's
    /// coupler pool, with the population read off the record's characteristic curve
    /// (`CrystalGrainModel`). Available only in the reference schedule, whose crystal variant
    /// family carries it; realtime schedules use `clumpField`.
    case crystals = "crystals"

    public var id: String { rawValue }

    /// User-facing display title.
    public var title: String {
        switch self {
        case .clumpField: return "Standard"
        case .film: return "Film"
        case .crystals: return "Organic Crystals"
        }
    }

    /// User-facing detail explanation.
    public var detail: String {
        switch self {
        case .clumpField: return "Fast calibrated RMS grain"
        case .film: return "Crystals on the film itself, averaged as light"
        case .crystals: return "Physical dye clouds and paper crystals"
        }
    }

    /// Resolves an identifier or alias (e.g. "standard", "clump", "film", "organic", "crystals").
    public static func named(_ name: String) -> GrainModel? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "clump", "clumpfield", "clump-field", "standard", "fast":
            return .clumpField
        case "film", "real", "real-film", "film-grain":
            return .film
        case "crystals", "crystal", "organic", "organic-crystals", "physical":
            return .crystals
        default:
            return nil
        }
    }
}
