import Foundation

/// The lamp house over the negative — the one piece of darkroom equipment that changes what a
/// print sees without changing the negative or the paper.
///
/// A developed image does not only absorb the enlarger's light; its grains scatter it. Under a
/// condenser head the beam is collimated, so light scattered out of the beam misses the lens and
/// every density on the negative reads higher than a densitometer's diffuse figure. Under a
/// diffuser head light arrives from every angle, scattered light is replaced by other scattered
/// light, and the lens sees the diffuse density itself. Callier (1909) measured the ratio of the
/// two as the coefficient `Q = D_specular / D_diffuse`, and the effect carries his name.
///
/// Because `Q` rises with the amount of scattering, it is a property of the image's *material*:
/// a silver grain is an opaque scatterer and a fine-grain silver negative reads `Q ≈ 1.3–1.5`
/// under a condenser, while a dye cloud barely scatters and a chromogenic negative reads `Q ≈
/// 1.0–1.1`. That is why the same B&W negative prints half a grade harder in a condenser
/// enlarger and why colour printing hardly notices which head is fitted. The engine's stock
/// sheets are read by diffuse densitometry, so `.diffuser` is the null: every render before this
/// choice existed is a diffuser print, bit-identically.
///
/// The coefficient is applied as a constant per material. Measured `Q` falls slowly as density
/// rises (the grains begin to hide one another), so a constant is the first-order model; the
/// print re-times through the scaled mid-grey exactly as an operator re-times after changing
/// heads, so what survives is the contrast change and not a darker frame.
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
            return "Soft, even light through a mixing box: the negative prints at its measured "
                + "density, as in a colour head or a minilab"
        case .condenser:
            return "Collimated light: silver grain scatters some of it out of the beam, so a "
                + "black-and-white negative prints harder and its grain and dust sharper"
        }
    }

    /// Callier coefficient of a silver image under collimated light. Fine-grain and medium-speed
    /// negative materials measure 1.3–1.5 at moderate densities; the middle of that band.
    public static let silverCallierCoefficient: Float = 1.4
    /// Callier coefficient of a dye image under collimated light. Dye clouds are nearly
    /// non-scattering, so a chromogenic negative reads only a few percent above diffuse.
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
