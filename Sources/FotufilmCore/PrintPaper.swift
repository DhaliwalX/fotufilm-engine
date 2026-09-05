import Foundation

/// The medium that turns developed film into a finished image, including the film itself.
public enum PrintPaper: String, CaseIterable, Sendable {
    case ektacolorEdge = "ektacolor-edge"
    case enduraPremier = "endura-premier"
    case crystalArchive = "crystal-archive"
    case vision2383 = "vision-2383"
    case vision2393 = "vision-2393"
    case eternaCP = "eterna-cp"
    /// The minilab scanner's finished positive: a trichromatic LED read of the
    /// negative inverted in software, the way most real colour negative is
    /// finished today.
    case labScan = "lab-scan"
    /// The video transfer: a telecine machine reads the negative through
    /// printing-density-class sensor bands (SMPTE RP 180), characterizes that
    /// receiver with TAF timing, and inverts it into a Rec.709 video signal.
    case telecine
    /// An idealized direct digital reference, with no scanner or physical print stage.
    case screen
    /// The developed negative itself, viewed by transmission rather than printed or inverted.
    case negative

    /// Default for engine and headless callers.
    public static let `default`: PrintPaper = .ektacolorEdge

    /// The default output for editor edits and the direct-positive destination for reversal film.
    /// The engine's unstated, physically matched path remains `default(for:)`.
    public static let editorDefault: PrintPaper = .screen

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .ektacolorEdge: return "Example Photo Print"
        case .enduraPremier: return "Example Photo Print 2"
        case .crystalArchive: return "Example Photo Print 3"
        case .vision2383: return "Example Projection"
        case .vision2393: return "Example Projection 2"
        case .eternaCP: return "Example Projection 3"
        case .labScan: return "Lab Scan"
        case .telecine: return "Telecine"
        case .screen: return "Digital Reference"
        case .negative: return "Negative"
        }
    }

    public var detail: String {
        switch self {
        case .ektacolorEdge, .enduraPremier, .crystalArchive,
             .vision2383, .vision2393, .eternaCP:
            return "An analytic example receiver, not a calibration of a commercial print material."
        case .labScan:
            return "A clean digital scan of the negative, with the full black point and punchy "
                + "contrast a minilab gives a file."
        case .telecine:
            return "A classic Rec.709 video transfer, with film black sitting just above video "
                + "black and a gentler run into the highlights than a lab scan."
        case .screen:
            return "A clean D65 wide-gamut display rendering with no paper, scanner, or viewing "
                + "lamp added. HDR delivery is available for reversal film."
        case .negative:
            return "The developed film itself on a light box, before printing or digital "
                + "inversion. Colour negatives keep their film base and reversed tones."
        }
    }

    public static func preset(id: String) -> PrintPaper? { PrintPaper(rawValue: id) }

    /// Whether output on this medium can hold light above display white.
    public var showsHDR: Bool { self == .screen }

    /// Whether this stock may use the medium's range above display white. Negative film keeps its
    /// full exposure latitude in the film model, but is delivered as an SDR positive.
    public func supportsHDRDelivery(for stock: FilmStock) -> Bool {
        showsHDR && stock.isReversal
    }

    /// Whether the finished output is the developed negative itself.
    public var isNegative: Bool { self == .negative }

    /// The output media a stock can reach. A reversal stock has no developed negative to expose.
    public static func choices(for stock: FilmStock) -> [PrintPaper] {
        stock.isReversal ? [.screen] : allCases
    }

    /// Reversal film is viewed directly; negative film uses the requested medium.
    public func resolved(for stock: FilmStock) -> PrintPaper {
        stock.isReversal ? .screen : self
    }

    /// Use the stock's stated medium, or the standard example photo print.
    public static func `default`(for stock: FilmStock) -> PrintPaper {
        (stock.nativePrintMedium ?? .default).resolved(for: stock)
    }

    /// Preview media for the selected gauge, with an explicitly named native medium first.
    /// Reversal film is viewed directly. Negative film offers the three analytic photo or
    /// projection variants; motion-picture gauges also offer Telecine.
    public static func stripChoices(for stock: FilmStock,
                                    gauge: FilmFormat) -> [PrintPaper] {
        guard !stock.isReversal else { return [.screen] }
        var media: [PrintPaper] = gauge.isMotionPicture
            ? [.vision2383, .vision2393, .eternaCP, .telecine]
            : [.ektacolorEdge, .enduraPremier, .crystalArchive]
        if let native = stock.nativePrintMedium,
           let index = media.firstIndex(of: native) {
            media.remove(at: index)
            media.insert(native, at: 0)
        }
        return media + [.screen]
    }

    /// Illustrative viewing glare as a fraction of the medium's reference white.
    public var viewingFlare: Float {
        switch self {
        case .vision2383, .vision2393, .eternaCP: return 1.0 / 2000.0
        case .ektacolorEdge, .enduraPremier, .crystalArchive: return 1.0 / 400.0
        case .labScan, .telecine, .screen, .negative: return 0
        }
    }

    /// Projection uses the example xenon illuminant; photo prints use D50.
    public var isProjected: Bool {
        self == .vision2383 || self == .vision2393 || self == .eternaCP
    }

    /// Whether this finished positive is a scanner's file rather than a physical
    /// sheet: the read is a flat lamp through trichromatic sensor bands, the
    /// output has no physical viewing dyes and no viewing lamp can fall on it. Both scan paths
    /// characterize their receiver bands into display colour.
    public var isScan: Bool { self == .labScan || self == .telecine }

    /// Whether a caller can replace the medium's reference viewing illuminant. Physical sheets
    /// and projected positives can be inspected under another lamp. A scan is already a digital
    /// signal, and the screen is the fixed D65 display the renderer targets, so neither takes a
    /// second viewing-light transform.
    public var acceptsViewingIlluminant: Bool {
        switch self {
        case .ektacolorEdge, .enduraPremier, .crystalArchive, .vision2383, .vision2393, .eternaCP:
            return true
        case .labScan, .telecine, .screen, .negative:
            return false
        }
    }

    /// Whether the scan's three channels leave the machine as a Rec.709 video signal rather than
    /// as an unrendered file. The engine's delivery basis is display-linear P3, which is wider, so
    /// the container is honoured by holding the timed colour inside the Rec.709 primaries (sRGB
    /// shares them) before it is carried to P3: a transfer cannot deliver a saturation the signal
    /// could not encode. Lab Scan writes a file and is limited only by its own bands.
    public var deliversRec709: Bool { self == .telecine }

    /// Illustrative output-stage blur, expressed as Gaussian sigma in millimetres on film.
    public var enlargerBlurMM: Float {
        switch self {
        case .ektacolorEdge, .enduraPremier, .crystalArchive: return 0.004
        case .vision2383, .vision2393, .eternaCP: return 0.003
        case .labScan: return 0.007
        case .telecine: return 0.0065
        case .screen, .negative: return 0
        }
    }

    /// Fraction of pre-blur detail restored by the scan model.
    public var scanSharpening: Float {
        switch self {
        case .labScan: return 0.65
        case .telecine: return 0.8
        case .ektacolorEdge, .enduraPremier, .crystalArchive, .vision2383, .vision2393, .eternaCP,
             .screen, .negative:
            return 0
        }
    }

    /// Whether printing reads each film layer independently instead of integrating enlarger light
    /// through all film dyes. This is the idealized digital-reference path, not a physical claim.
    public var readsLayersDirectly: Bool { self == .screen }

    /// Whether timing can balance the film records while forming this output. A viewed negative
    /// has no print exposure to correct, and the digital reference already reads records directly.
    public var acceptsPrintCorrection: Bool { !readsLayersDirectly && !isNegative }

    /// The density above base to anchor mid-grey on, so that the print still
    /// *reads* at `midDensity` once glare is added. Anchoring on the density
    /// itself would put mid-grey light by the whole of the flare — 0.002 on
    /// the papers, which the accuracy ratchet sees.
    public func anchorDensity(_ midDensity: Float) -> Float {
        guard viewingFlare > 0 else { return midDensity }
        let read = pow(10, -midDensity)
        return -log10(max(read * (1 + viewingFlare) - viewingFlare, 1e-6))
    }
}
