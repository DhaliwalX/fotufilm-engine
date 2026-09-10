import Foundation

/// The lamp house over the negative — the one piece of darkroom equipment that changes what a
/// print sees without changing the negative or the paper.
///
/// A developed image does not only absorb the enlarger's light; its grains scatter it. Under a
/// condenser head the beam is collimated, so light scattered out of the beam misses the lens and
/// every density on the negative reads higher than a densitometer's diffuse figure. Under a
/// diffuser head light arrives from every angle, scattered light is replaced by other scattered
/// light, and the lens sees the diffuse density itself. The ratio of the two,
/// `Q = D_specular / D_diffuse`, is the Callier coefficient, and the effect carries his name.
///
/// Because `Q` rises with the amount of scattering, it is a property of the image's *material*,
/// and of how coarse that material is. Mees (*The Theory of the Photographic Process*, 1942,
/// p. 642, reported in Evans, Hanson and Brewer, *Principles of Color Photography*, 1953, p. 188)
/// puts a silver negative between `Q ≈ 1.2` for very fine-grained emulsions and `Q ≈ 1.9` for
/// coarse-grained, high-speed ones. A dye cloud barely scatters — its refractive index is close
/// to that of the dry gelatin around it — so a chromogenic negative is not usually found above
/// `Q ≈ 1.1` (Hunt, *The Reproduction of Colour*, 6th edn, p. 306). That is why the same B&W
/// negative prints harder in a condenser enlarger and why colour printing hardly notices which
/// head is fitted. The engine's stock sheets are read by diffuse densitometry, so `.diffuser` is
/// the null: every render before this choice existed is a diffuser print, bit-identically.
///
/// The coefficient is applied as one constant per material rather than per stock, so it does not
/// follow grain size across that band; `Q` also depends on how far the emulsion was developed,
/// generally rising with gamma (Evans, Hanson and Brewer, p. 189), which this model does not
/// track either. The print re-times through the scaled mid-grey exactly as an operator re-times
/// after changing heads, so what survives is the contrast change and not a darker frame.
public enum Enlarger: String, CaseIterable, Sendable, Codable {
    /// Diffuse illumination: cold-light, mixing-box colour heads, and every minilab. Reads the
    /// diffuse density the sheets are measured in. The default.
    case diffuser
    /// A condenser head: collimated light, so the negative's scattered light is lost and its
    /// densities read at their specular (Callier) values.
    case condenser

    public static let `default`: Enlarger = .diffuser

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .diffuser: return "Diffuser"
        case .condenser: return "Condenser"
        }
    }

    public var detail: String {
        switch self {
        case .diffuser:
            return "Use soft, even light, as in a color enlarger or minilab."
        case .condenser:
            return "Use focused light for stronger contrast and more visible grain and dust in black-and-white prints."
        }
    }

    /// Callier coefficient of a silver image under collimated light. Measured `Q` runs from about
    /// 1.2 for very fine-grained emulsions to about 1.9 for coarse-grained, high-speed ones (Mees,
    /// 1942, p. 642); 1.4 sits at the fine-to-medium-grain end of that band, where the negative
    /// stocks this engine models live.
    public static let silverCallierCoefficient: Float = 1.4
    /// Callier coefficient of a dye image under collimated light. Dye clouds are nearly
    /// non-scattering, so a chromogenic negative reads only a few percent above diffuse and is not
    /// usually found above 1.1 (Hunt, *The Reproduction of Colour*, 6th edn, p. 306).
    public static let dyeCallierCoefficient: Float = 1.05

    /// Whether this head is in the path at all: only an optical enlargement of a negative onto a
    /// reflection sheet has a lamp house. A reversal is its own positive, a viewed negative is
    /// not printed, a scan's LEDs read the film directly, the screen reads the layers, a cinema
    /// release print is contact-printed with the emulsions touching, and an instant print
    /// develops in the camera.
    public static func illuminates(stock: FilmStock, paper: PrintPaper) -> Bool {
        !stock.isReversal && !stock.isReflectionPrint
            && !paper.isNegative && !paper.isScan
            && !paper.readsLayersDirectly && !paper.isProjected
    }

    /// The factor the negative's diffuse densities are multiplied by on their way to the paper.
    /// Exactly 1 wherever this head changes nothing, so the spectral tables' identity is
    /// untouched there and every existing render stays bit-identical.
    public func callierCoefficient(for stock: FilmStock, paper: PrintPaper) -> Float {
        guard self == .condenser, Self.illuminates(stock: stock, paper: paper) else { return 1 }
        return stock.isMonochrome ? Self.silverCallierCoefficient
                                  : Self.dyeCallierCoefficient
    }

    public static func preset(id: String) -> Enlarger? { Enlarger(rawValue: id) }
}
