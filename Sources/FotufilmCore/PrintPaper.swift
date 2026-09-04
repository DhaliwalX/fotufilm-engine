import Foundation

/// The medium that turns developed film into a finished image, including the film itself.
public enum PrintPaper: String, CaseIterable, Sendable {
    /// Legacy profile identifier; source builds use an analytic example receiver.
    case ektacolorEdge = "ektacolor-edge"
    /// Legacy profile identifier; source builds use an analytic example receiver.
    case enduraPremier = "endura-premier"
    /// Legacy profile identifier; source builds use an analytic example receiver.
    case crystalArchive = "crystal-archive"
    /// Legacy profile identifier; source builds use an analytic example receiver.
    case vision2383 = "vision-2383"
    /// Legacy profile identifier; source builds use an analytic example receiver.
    case vision2393 = "vision-2393"
    /// Legacy profile identifier; source builds use an analytic example receiver.
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
    /// Kept last because `allCases` order is a persisted host ABI.
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

    /// The medium a stock actually reaches when the edit asks for this one: the request where it
    /// is available, the only entry where it is not.
    public func resolved(for stock: FilmStock) -> PrintPaper {
        let available = Self.choices(for: stock)
        return available.contains(self) ? self : available[0]
    }

    /// What this stock prints on when the caller expresses no preference: the medium the emulsion
    /// was designed for where it names one, and the measured sheet where it does not.
    ///
    /// A motion-picture camera negative is timed onto a release print stock, and its mask density
    /// and contrast assume that partner; developing one onto RA-4 paper is a choice a caller can
    /// still make, but it is not what silence should mean.
    public static func `default`(for stock: FilmStock) -> PrintPaper {
        (stock.nativePrintMedium ?? .default).resolved(for: stock)
    }

    /// Whether Endura Premier is offered on this stock's film strip of preview looks.
    /// Endura Premier is a professional portrait and commercial RA-4 paper with steeper
    /// midtone contrast and deep blacks, matched to Portra, Ektar, Gold, UltraMax, and Pro 400H.
    public static func supportsEnduraStrip(for stock: FilmStock) -> Bool {
        if stock.nativePrintMedium == .enduraPremier { return true }
        let name = stock.name.lowercased()
        return name.contains("portra")
            || name.contains("ektar")
            || name.contains("gold")
            || name.contains("ultramax")
            || name.contains("pro 400h")
            || name.contains("pro400h")
    }

    /// The media a strip of finished looks offers this stock on its own `gauge`, in the order it
    /// shows them: only the ones that make sense for the film, the one it was made for first.
    ///
    /// A still negative is printed on RA-4 paper, so it gets the measured sheets. Ektacolor Edge
    /// and Crystal Archive are offered for all still colour negatives, and Endura Premier is included
    /// for matched portrait and commercial films (Portra, Ektar, Gold, UltraMax, Pro 400H). A
    /// motion-picture negative is timed onto its maker's release print — Eterna-CP for a Fuji
    /// negative, both Kodak prints for a Kodak one or for a cine stock that names none — and is
    /// transferred to video, so it gets Telecine and never photo paper. Every film can be shown on
    /// a display, so the digital reference closes each run. The minilab scan and the light-box
    /// negative are left off: the first is a second digital reading of the same film, the second
    /// is not a finished picture. A reversal stock has its one direct positive. A strip's tile
    /// count is the sum of these over its films.
    public static func stripChoices(for stock: FilmStock,
                                    gauge: FilmFormat) -> [PrintPaper] {
        if stock.isReversal { return [.screen] }
        let native = `default`(for: stock)
        var run: [PrintPaper]
        if gauge.isMotionPicture {
            let prints: [PrintPaper] = stock.nativePrintMedium == .eternaCP
                ? [.eternaCP] : [.vision2383, .vision2393]
            // A cine stock that names no print — Double-X — defaults to the RA-4 sheet, which is
            // exactly what a motion-picture gauge must not lead with.
            let lead = native.isProjected ? [native] : []
            run = lead + prints.filter { $0 != native } + [.telecine]
        } else {
            let papers: [PrintPaper] = supportsEnduraStrip(for: stock)
                ? [.ektacolorEdge, .enduraPremier, .crystalArchive]
                : [.ektacolorEdge, .crystalArchive]
            run = [native] + papers.filter { $0 != native }
        }
        run.append(.screen)
        let reachable = choices(for: stock)
        return run.filter { reachable.contains($0) }
    }

    /// Veiling glare between the print and the eye, as a fraction of the
    /// medium's own reference white. The papers are measured at 0/45, which
    /// excludes the first-surface reflection a viewer gets back, so 1/400
    /// carries their 2.10 D to the 1.98 D a glossy print reads in a booth. A
    /// projection port is a darker surround than a room.
    public var viewingFlare: Float {
        switch self {
        case .vision2383, .vision2393, .eternaCP: return 1.0 / 2000.0
        case .ektacolorEdge, .enduraPremier, .crystalArchive: return 1.0 / 400.0
        case .labScan, .telecine, .screen, .negative: return 0
        }
    }

    /// Whether this finished positive is projected rather than held: a transparency on a screen
    /// in a dark room, not a sheet under a room's light.
    ///
    /// It decides the reference lamp the print is read by. A paper hangs under whatever light the
    /// viewer has and defaults to a D50 judging booth; a release print defaults to calibrated
    /// 5400 K xenon screen light, which is the illuminant its published dye amounts target.
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

    /// Whether the digital scan uses a fixed neutral analytical reference.
    public var isReferenceAnchored: Bool { self == .labScan }

    /// Whether the scan's three channels leave the machine as a Rec.709 video signal rather than
    /// as an unrendered file. The engine's delivery basis is display-linear P3, which is wider, so
    /// the container is honoured by holding the timed colour inside the Rec.709 primaries (sRGB
    /// shares them) before it is carried to P3: a transfer cannot deliver a saturation the signal
    /// could not encode. Lab Scan writes a file and is limited only by its own bands.
    public var deliversRec709: Bool { self == .telecine }

    /// Combined lens, focus, receiver, and scattering blur as Gaussian sigma in millimetres on film.
    /// The lab-scan value is 7 µm versus a documented 5.3–6.6 µm sample pitch. Screen output has
    /// no physical imaging stage and uses zero.
    public var enlargerBlurMM: Float {
        switch self {
        case .ektacolorEdge, .enduraPremier, .crystalArchive: return 0.004
        case .vision2383, .vision2393, .eternaCP: return 0.003
        case .labScan: return 0.007
        // The Spirit's documented geometry: a 1920-photosite detail array
        // across the full Super 35 camera aperture it projects — 24.92 mm —
        // is a 0.013 mm sample pitch on the film, and a Gaussian of half that
        // pitch carries the pixel footprint with the imaging lens on top.
        case .telecine: return 0.0065
        case .screen, .negative: return 0
        }
    }

    /// Fraction of pre-blur detail restored by the output medium, from 0 to 1. Optical papers use
    /// 0. The lab-scan value of 0.65 is an illustrative detail setting after scanner
    /// aperture blur and unsharp masking.
    public var scanSharpening: Float {
        switch self {
        case .labScan: return 0.65
        // A video chain runs aperture correction — the operator-adjustable
        // detail peaking every telecine documented, applied film-relative
        // before sizing — and no machine publishes a strength for it, so the
        // figure is a stance: harder than the minilab's unsharp mask, because
        // the electronically crisped grain is part of what a transfer looks
        // like, and short of undoing the aperture entirely.
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
