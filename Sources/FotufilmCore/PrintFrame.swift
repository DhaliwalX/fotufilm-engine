import Foundation

/// Decorative finishing outside the photograph. These are material-inspired borders,
/// independent of the sensitometric paper selected for the image itself.
public enum PrintFrame: String, CaseIterable, Codable, Sendable, Identifiable {
    case none
    case film35 = "film-35"
    case contact
    case baryta
    case cotton
    case instant

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .none: return "None"
        case .film35: return "35 mm Film"
        case .contact: return "Contact Print"
        case .baryta: return "Baryta Paper"
        case .cotton: return "Cotton Rag"
        case .instant: return "Instant Print"
        }
    }

    public var detail: String {
        switch self {
        case .none: return "The photograph without a border."
        case .film35: return "Dark film rebate, sprocket holes, and amber edge markings."
        case .contact: return "An irregular black rebate on a warm photographic sheet."
        case .baryta: return "An ivory border with a fine, lustrous paper surface."
        case .cotton: return "Warm matte paper with visible fibres and a softly uneven edge."
        case .instant: return "A softly textured white border with a deep lower margin."
        }
    }
}
