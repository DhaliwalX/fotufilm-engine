import Foundation

/// The physical finish and viewing glare of a reflection print sheet.
///
/// Datasheet characteristic curves are measured by 0/45° reflection densitometry against an
/// unexposed reference calibration, which excludes first-surface air–gelatin reflections and
/// normalizes paper-base whiteness when Bradford-adapted to the display. `.clean` preserves that
/// reference read bit-identically.
///
/// Choosing a physical surface (`Glossy`, `Lustre`, or `Matte`) evaluates the print on its stock's
/// spectral paper-base reflectance (`PrintStock.Spectra.baseReflectance`, carrying TiO₂/gelatin UV
/// rolloff, warm portrait vs cool optical-brightener tint, and ~90% diffuse whiteness) together
/// with diffuse first-surface viewing scatter (`surfaceReflectance`), which bounds maximum black
/// density (`D_max`) and gently lifts and desaturates deep shadows the way a held print does under
/// room light.
public enum PrintSurface: String, CaseIterable, Sendable, Codable {
    /// Reference 0/45° densitometric read with unit base white and zero viewing glare. The default.
    case clean
    /// Smooth glossy finish (`F` / `1K`) viewed off the specular angle: paper-base tint with deep
    /// blacks (`D_max ≈ 2.4`).
    case glossy
    /// Semi-matte / pearl resin-coated finish (`E` / lustre): paper-base tint with moderate diffuse
    /// surface scatter (`D_max ≈ 2.0`).
    case lustre
    /// Deep-matte finish: paper-base tint with diffuse surface scatter across the shadows
    /// (`D_max ≈ 1.65`).
    case matte

    public static let `default`: PrintSurface = .clean

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .clean: return "Clean"
        case .glossy: return "Glossy"
        case .lustre: return "Lustre"
        case .matte: return "Matte"
        }
    }

    public var detail: String {
        switch self {
        case .clean:
            return "Pure reference white with no paper-base tint or surface glare."
        case .glossy:
            return "Smooth glossy paper with natural paper-base tone and deep blacks."
        case .lustre:
            return "Semi-matte textured paper with natural paper-base tone and gently softened blacks."
        case .matte:
            return "Matte paper with natural paper-base tone and lifted, low-sheen shadows."
        }
    }

    /// Fraction of incident viewing light diffusely scattered at the air–gelatin surface toward the
    /// viewer, bounding reflection black density (`-log10(surfaceReflectance)`).
    public var surfaceReflectance: Float {
        switch self {
        case .clean: return 0
        case .glossy: return 0.004
        case .lustre: return 0.010
        case .matte: return 0.022
        }
    }

    /// Whether a physical reflection sheet is being viewed: RA-4 colour papers and positive
    /// reflection papers (`Ilfochrome`). Projected cinema release prints, scans, Digital Reference,
    /// directly viewed slides, viewed negatives, and camera-developed integral instant sheets do
    /// not take a darkroom paper finish.
    public static func applies(stock: FilmStock, paper: PrintPaper) -> Bool {
        paper.printProcess?.isReflection == true
            && !paper.viewsFilmDirectly(for: stock)
            && !stock.isReflectionPrint
            && paper.resolved(for: stock) == paper
    }

    /// `.clean` wherever the medium has no darkroom reflection sheet, keeping spectral cache keys
    /// and existing renders bit-identical.
    public func resolved(for stock: FilmStock, paper: PrintPaper) -> PrintSurface {
        Self.applies(stock: stock, paper: paper) ? self : .clean
    }

    public static func preset(id: String) -> PrintSurface? { PrintSurface(rawValue: id) }
}
