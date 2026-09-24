import Foundation

/// Physical film/paper finishing, mounts, and the film's unexposed edge printed with the picture.
public enum PrintFrame: String, CaseIterable, Codable, Sendable, Identifiable {
    case none, film, slideMount, paper, paper5x7, paper8x10, paper5x5, carrier, emulsion, mount, darkMount,
         socialSquare, socialPortrait, socialStory
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .none: return "None"
        case .film: return "Film Border"
        case .slideMount: return "Slide Mount"
        case .paper: return "Paper Border 4 × 6"
        case .paper5x7: return "Paper Border 5 × 7"
        case .paper8x10: return "Paper Border 8 × 10"
        case .paper5x5: return "Paper Border 5 × 5"
        case .carrier: return "Carrier Border"
        case .emulsion: return "Emulsion Border"
        case .mount: return "White Mount"
        case .darkMount: return "Black Mount"
        case .socialSquare: return "Square Post"
        case .socialPortrait: return "Portrait Post"
        case .socialStory: return "Story"
        }
    }
    public var detail: String {
        switch self {
        case .none: return "The photograph without a border."
        case .film: return "The selected film gauge, with its physical edges and perforations."
        case .slideMount: return "The developed transparency in a card slide mount."
        case .paper: return "The selected photographic paper, in a 4 × 6 inch print."
        case .paper5x7: return "The selected photographic paper, in a 5 × 7 inch print."
        case .paper8x10: return "The selected photographic paper, in an 8 × 10 inch print."
        case .paper5x5: return "The selected photographic paper, in a 5 × 5 inch print."
        case .carrier: return "The film rebate printed through a filed-out negative carrier: a black line inside the paper margin."
        case .emulsion: return "The film just outside the camera gate, printed with the photograph: the stock's own unexposed tone, glow and grain, inside a paper margin."
        case .mount: return "A clean white margin around the photograph."
        case .darkMount: return "A clean black margin around the photograph."
        case .socialSquare: return "A square 1 : 1 canvas for posting, the photograph inside a white margin."
        case .socialPortrait: return "A 4 : 5 portrait canvas for posting, the photograph inside a white margin."
        case .socialStory: return "A 9 : 16 story canvas, the photograph inside a white margin."
        }
    }

    /// A display-white canvas at a fixed posting aspect, with no manufactured material behind it.
    public var isSocialCanvas: Bool {
        switch self {
        case .socialSquare, .socialPortrait, .socialStory: return true
        default: return false
        }
    }

    /// A cut sheet of the selected photographic paper, with or without a printed rebate.
    public var isPaperSheet: Bool {
        switch self {
        case .paper, .paper5x7, .paper8x10, .paper5x5, .carrier: return true
        default: return false
        }
    }

    /// A crop-following presentation mount with no manufactured material behind it.
    public var isPlainMount: Bool { self == .mount || self == .darkMount }

    /// The developed film is seen by transmission, not printed to the chosen paper.
    public var viewsTransparency: Bool { self == .film || self == .slideMount }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Migrate the initial, unreleased decorative frame names into material-following modes.
        switch value {
        case "none": self = .none
        case "film", "film-35", "instant": self = .film
        case "paper", "contact", "baryta", "cotton": self = .paper
        case "emulsion": self = .emulsion
        default:
            guard let frame = PrintFrame(rawValue: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown print frame")
            }
            self = frame
        }
    }
}

/// A cut sheet of photographic paper on an easel. Sheet sizes are lab print choices, not
/// intrinsic dimensions of the emulsion; the easel margin and the filed carrier's rebate are
/// representative darkroom conventions documented in docs/print-frame-model.md.
public struct PaperSheetGeometry: Codable, Equatable, Sendable {
    public let widthMM: Double
    public let heightMM: Double
    /// The white margin held by the easel blades on every side.
    public let marginMM: Double
    /// The printed film rebate inside the easel opening; zero for a plain print.
    public let rebateMM: Double

    public static func preset(for frame: PrintFrame) -> Self? {
        switch frame {
        case .paper: return Self(widthMM: 152.4, heightMM: 101.6, marginMM: 3, rebateMM: 0)
        case .paper5x7: return Self(widthMM: 177.8, heightMM: 127, marginMM: 3, rebateMM: 0)
        case .paper8x10: return Self(widthMM: 254, heightMM: 203.2, marginMM: 3, rebateMM: 0)
        case .paper5x5: return Self(widthMM: 127, heightMM: 127, marginMM: 3, rebateMM: 0)
        case .carrier: return Self(widthMM: 254, heightMM: 203.2, marginMM: 12.7, rebateMM: 2.5)
        default: return nil
        }
    }
}

/// A fixed-aspect canvas for a social post. The aspects are the platforms' own; the margin is a
/// presentation choice. The photograph is fitted inside without cropping, so a landscape picture
/// on a story canvas stands between white bands, as posts do.
public struct SocialCanvasGeometry: Codable, Equatable, Sendable {
    public let aspectWidth: Double
    public let aspectHeight: Double
    /// The white margin on every side, as a fraction of the canvas's short side.
    public let margin: Double

    public static func preset(for frame: PrintFrame) -> Self? {
        switch frame {
        case .socialSquare: return Self(aspectWidth: 1, aspectHeight: 1, margin: 0.05)
        case .socialPortrait: return Self(aspectWidth: 4, aspectHeight: 5, margin: 0.05)
        case .socialStory: return Self(aspectWidth: 9, aspectHeight: 16, margin: 0.05)
        default: return nil
        }
    }
}

/// A card mount for a developed transparency. The outer size is the universal 2 × 2 inch
/// projector format; the aperture is the typical mounted image area for the gauge.
public struct SlideMountGeometry: Codable, Equatable, Sendable {
    public let mountMM: Double
    public let apertureWidth: Double
    public let apertureHeight: Double
    public let cornerRadiusMM: Double

    public static func preset(_ formatID: String) -> Self? {
        switch formatID {
        case "35mm":
            return Self(mountMM: 50.8, apertureWidth: 34.5, apertureHeight: 23, cornerRadiusMM: 1)
        case "120":
            return Self(mountMM: 70, apertureWidth: 56, apertureHeight: 56, cornerRadiusMM: 1)
        default: return nil
        }
    }
}

/// A manufacturer's sheet-film identification pattern, read left to right with the emulsion
/// facing the viewer and the sheet upright. Locations are fractions of the code's span.
/// The source diagrams identify the pattern; they do not specify cutting tolerances.
public struct SheetFilmNotchCode: Codable, Equatable, Sendable {
    public struct Notch: Codable, Equatable, Sendable {
        public var position: Double
        public var width: Double
        public var depth: Double
        public init(position: Double, width: Double, depth: Double) {
            self.position = position; self.width = width; self.depth = depth
        }
    }
    public var source: String
    public var notches: [Notch]
    public init(source: String, notches: [Notch]) {
        self.source = source; self.notches = notches
    }
}

/// A representative cut from documented edge printing, viewed from the base side.
/// Coordinates are millimetres: x along transport, y across the film, origin lower left.
/// The boxes specify approximate inscription proportions, not measured printer tolerances.
/// Unknown batch/roll numbers and machine-readable codes must not be fabricated.
public struct FilmEdgePrinting: Codable, Equatable, Sendable {
    public struct Mark: Codable, Equatable, Sendable {
        public var text: String
        public var xMM: Double
        public var yMM: Double
        public var widthMM: Double
        public var heightMM: Double
    }
    public var formatID: String
    public var sources: [String]
    public var marks: [Mark]
}

/// Millimetre geometry before the finished photograph is fitted into the camera aperture.
/// x runs across the film, y along transport, except 135 stills which transport horizontally.
public struct FilmBorderGeometry: Codable, Equatable, Sendable {
    public struct PerforationDimensions: Codable, Equatable, Sendable {
        public let width: Double
        public let height: Double
        public let radius: Double
        public let edge: Double
    }
    public enum Perforation: String, Codable, Sendable {
        case kodakStandard, bellHowell, sixteen, superEight
        public var dimensions: PerforationDimensions {
            switch self {
            case .kodakStandard: return .init(width: 2.794, height: 1.981, radius: 0.51, edge: 2.01)
            case .bellHowell: return .init(width: 2.794, height: 1.854, radius: 0, edge: 2.01)
            case .sixteen: return .init(width: 1.829, height: 1.270, radius: 0.25, edge: 0.914)
            case .superEight: return .init(width: 0.914, height: 1.143, radius: 0.13, edge: 0.51)
            }
        }
    }
    public let widthMM: Double
    public let heightMM: Double
    public let apertureX: Double
    public let apertureY: Double
    public let apertureWidth: Double
    public let apertureHeight: Double
    public let perforation: Perforation?
    public let pitchMM: Double
    public let rows: Int
    public let horizontalTransport: Bool
    public let isInstant: Bool
    public let isSheet: Bool

    /// Camera apertures and pitch are physical format data; a nonmatching crop is fitted inside
    /// that aperture without stretching it. See docs/print-frame-model.md for sources/conventions.
    public static func preset(_ id: String, motionPictureStock: Bool = false) -> Self? {
        switch id {
        case "35mm":
            let pitch = motionPictureStock ? 4.74 : 4.75
            return Self(widthMM: pitch * 8, heightMM: 35,
                        apertureX: (pitch * 8 - 36) / 2, apertureY: 5.5,
                        apertureWidth: 36, apertureHeight: 24,
                        perforation: motionPictureStock ? .bellHowell : .kodakStandard,
                        pitchMM: pitch, rows: 2, horizontalTransport: true, isInstant: false, isSheet: false)
        case "super35":
            return Self(widthMM: 35, heightMM: 18.96, apertureX: 5.04, apertureY: 0.145,
                        apertureWidth: 24.92, apertureHeight: 18.67, perforation: .bellHowell,
                        pitchMM: 4.74, rows: 2, horizontalTransport: false, isInstant: false, isSheet: false)
        case "16mm": // The app's 16 mm choice is a single-perforation Super 16 camera gate.
            return Self(widthMM: 16, heightMM: 7.605, apertureX: 2.85, apertureY: 0.0925,
                        apertureWidth: 12.35, apertureHeight: 7.42, perforation: .sixteen,
                        pitchMM: 7.605, rows: 1, horizontalTransport: false, isInstant: false, isSheet: false)
        case "super8":
            return Self(widthMM: 7.976, heightMM: 4.234, apertureX: 1.59, apertureY: 0.112,
                        apertureWidth: 5.79, apertureHeight: 4.01, perforation: .superEight,
                        pitchMM: 4.234, rows: 1, horizontalTransport: false, isInstant: false, isSheet: false)
        case "120":
            return Self(widthMM: 61, heightMM: 60, apertureX: 2.5, apertureY: 2,
                        apertureWidth: 56, apertureHeight: 56, perforation: nil,
                        pitchMM: 0, rows: 0, horizontalTransport: false, isInstant: false, isSheet: false)
        case "4x5":
            return Self(widthMM: 100, heightMM: 125, apertureX: 2.5, apertureY: 2.5,
                        apertureWidth: 95, apertureHeight: 120, perforation: nil,
                        pitchMM: 0, rows: 0, horizontalTransport: false, isInstant: false, isSheet: true)
        case "instaxmini":
            return Self(widthMM: 54, heightMM: 86, apertureX: 4, apertureY: 20,
                        apertureWidth: 46, apertureHeight: 62, perforation: nil,
                        pitchMM: 0, rows: 0, horizontalTransport: false, isInstant: true, isSheet: false)
        case "instaxsquare":
            return Self(widthMM: 72, heightMM: 86, apertureX: 5, apertureY: 19,
                        apertureWidth: 62, apertureHeight: 62, perforation: nil,
                        pitchMM: 0, rows: 0, horizontalTransport: false, isInstant: true, isSheet: false)
        case "instaxwide":
            return Self(widthMM: 108, heightMM: 86, apertureX: 4.5, apertureY: 19.5,
                        apertureWidth: 99, apertureHeight: 62, perforation: nil,
                        pitchMM: 0, rows: 0, horizontalTransport: false, isInstant: true, isSheet: false)
        default: return nil
        }
    }
}

public struct PrintFrameConfiguration: Codable, Equatable, Sendable {
    public let frame: PrintFrame
    public let geometry: FilmBorderGeometry?
    public let sheet: PaperSheetGeometry?
    public let slideMount: SlideMountGeometry?
    public let canvas: SocialCanvasGeometry?
    public let sheetNotches: SheetFilmNotchCode?
    public let edgePrinting: FilmEdgePrinting?
    /// The edge exposure viewed through the same stock and lamp as its rebate.
    public let edgeRGB: SIMD3<Float>
    /// Display-linear P3, converted into the photograph's output profile by the compositor.
    public let baseRGB: SIMD3<Float>
    /// The clear film rebate printed to the paper's maximum density through a filed carrier.
    public let rebateRGB: SIMD3<Float>
    public let detail: String
    /// Positive polyester media are smooth; the existing RC papers use a lustre approximation.
    public let hasLustre: Bool

    public init(frame: PrintFrame, formatID: String?, stockID: String,
                paper: PrintPaper, viewingKelvin: Float? = nil,
                negativeViewing: NegativeViewing = .lightBox) {
        self.init(frame: frame, formatID: formatID, definition: FilmStock.presetDefinitions[stockID],
                  paper: paper, viewingKelvin: viewingKelvin, negativeViewing: negativeViewing)
    }

    /// Explicit stock metadata also supports isolated runtimes without a process-wide pack registry.
    public init(frame: PrintFrame, formatID: String?, definition: FilmStockDefinition?,
                paper: PrintPaper, viewingKelvin: Float? = nil,
                negativeViewing: NegativeViewing = .lightBox) {
        let nativeID = definition?.nativeFormatID
        let motionStock = nativeID.flatMap(FilmFormat.preset(id:))?.isMotionPicture == true
        let nativeInstant = nativeID.flatMap { FilmBorderGeometry.preset($0) }?.isInstant == true
        let film = formatID.flatMap { FilmBorderGeometry.preset($0, motionPictureStock: motionStock) }
        let name = formatID.flatMap(FilmFormat.preset(id:))?.name ?? "Film"
        let reflective = paper.acceptsViewingIlluminant && !paper.isProjected
        hasLustre = !paper.isPositivePaper
        let filmAvailable = definition != nil && film != nil
            && ((film?.isInstant != true && !nativeInstant) || nativeID == formatID)
        let mount = formatID.flatMap(SlideMountGeometry.preset)
        let slideAvailable = definition?.stock.isReversal == true && mount != nil && !nativeInstant
        // A filed carrier prints the clear rebate of a negative; on positive paper the dark
        // rebate of a transparency prints the same as the unexposed margin and shows nothing.
        let carrierAvailable = reflective && !paper.isPositivePaper
            && definition?.stock.isReversal == false && !nativeInstant
        // The unexposed edge is developed from the stock over the gauge's gate-to-edge margins;
        // integral instant film has a mask there instead of emulsion.
        let edgeAvailable = definition != nil && !nativeInstant
            && formatID.flatMap { UnexposedEdge.Geometry.preset($0, motionPictureStock: motionStock) } != nil
        let available: Bool
        switch frame {
        case .none, .mount, .darkMount, .socialSquare, .socialPortrait, .socialStory: available = true
        case .emulsion: available = edgeAvailable
        case .film: available = filmAvailable
        case .slideMount: available = slideAvailable
        case .carrier: available = carrierAvailable
        case .paper, .paper5x7, .paper8x10, .paper5x5: available = reflective
        }
        self.frame = available ? frame : .none
        geometry = self.frame == .film ? film : nil
        sheet = PaperSheetGeometry.preset(for: self.frame)
        slideMount = self.frame == .slideMount ? mount : nil
        canvas = SocialCanvasGeometry.preset(for: self.frame)
        sheetNotches = geometry?.isSheet == true ? definition?.sheetNotches : nil
        edgePrinting = self.frame == .film
            ? definition?.edgePrinting?.first { $0.formatID == formatID } : nil
        if self.frame == .film, let stock = definition?.stock, film?.isInstant == false {
            let light = viewingKelvin.map(SpectralRuntime.printLightSPD)
            let basis = stock.isReversal ? SpectralRuntime.neutralDensityBasis(for: stock) : nil
            let clear = SpectralRuntime.transmissionRGB(
                density: basis?(stock.curves.map(\.dMin)) ?? stock.curves.map(\.dMin),
                stock: stock, illuminant: light)
            // A representative developed edge exposure, not a measured manufacturer's
            // edge-printer calibration. Reversal clears exposed letters; negatives darken.
            let density = stock.curves.map { curve in
                curve.dMin + (curve.dMax - curve.dMin) * (stock.isReversal ? 0.08 : 0.72)
            }
            let exposed = SpectralRuntime.transmissionRGB(density: basis?(density) ?? density,
                                                          stock: stock, illuminant: light)
            if stock.isReversal {
                edgeRGB = exposed
            } else if paper.isNegative && negativeViewing == .scanner {
                edgeRGB = exposed / SIMD3(max(clear.x, 1e-6), max(clear.y, 1e-6), max(clear.z, 1e-6))
            } else {
                edgeRGB = exposed * (SpectralRuntime.lightBoxBaseLevel / max(clear.x, clear.y, clear.z, 1e-6))
            }
        } else {
            edgeRGB = .zero
        }
        rebateRGB = self.frame == .carrier ? paper.frameDenseRGB(viewingKelvin: viewingKelvin) ?? .zero : .zero
        switch frame {
        case .none:
            baseRGB = .zero
            detail = frame.detail
        case .film:
            if film?.isInstant == true {
                // The integral film's attached white mask is separate from its image dyes.
                baseRGB = SIMD3(repeating: 0.94)
            } else if let stock = definition?.stock {
                let light = viewingKelvin.map(SpectralRuntime.printLightSPD)
                if stock.isReversal {
                    // An unexposed reversal rebate develops to maximum density, including each
                    // stock's residual dye colour. It is not a universal display black.
                    baseRGB = SpectralRuntime.transmissionRGB(
                        density: stock.curves.map(\.dMax), stock: stock, illuminant: light)
                } else {
                    // The physical negative's clear rebate carries its own base-plus-fog and
                    // orange mask. A common light-box gain keeps that tint; per-channel gains
                    // would erase it. Scanner-normalized negative viewing remains explicit.
                    let base = SpectralRuntime.transmissionRGB(
                        density: stock.curves.map(\.dMin), stock: stock, illuminant: light)
                    baseRGB = paper.isNegative && negativeViewing == .scanner
                        ? SIMD3(repeating: 1)
                        : base * (SpectralRuntime.lightBoxBaseLevel / max(base.x, base.y, base.z, 1e-6))
                }
            } else {
                baseRGB = .zero
            }
            if !filmAvailable {
                detail = "Choose a film and a matching physical film format."
            } else if film?.isSheet == true && sheetNotches == nil {
                detail = "\(name) sheet film · notch code not documented for this stock"
            } else {
                detail = "\(name) · \(definition?.name ?? "Film")"
            }
        case .slideMount:
            // The rebate seen through the aperture around a nonmatching crop is the
            // transparency's own maximum density, as in Film Border. The card is drawn on top.
            if slideAvailable, let stock = definition?.stock {
                baseRGB = SpectralRuntime.transmissionRGB(
                    density: stock.curves.map(\.dMax), stock: stock,
                    illuminant: viewingKelvin.map(SpectralRuntime.printLightSPD))
                let size = mount.map { $0.mountMM == 50.8 ? "2 × 2 in" : "70 × 70 mm" } ?? ""
                detail = "\(size) mount · \(definition?.name ?? "Film")"
            } else {
                baseRGB = .zero
                detail = "Choose a slide film in 35mm or 120."
            }
        case .paper, .paper5x7, .paper8x10, .paper5x5:
            baseRGB = paper.frameBaseRGB(viewingKelvin: viewingKelvin) ?? .zero
            let size = sheet.map { "\(Int(($0.widthMM / 25.4).rounded())) × \(Int(($0.heightMM / 25.4).rounded())) in" } ?? ""
            detail = reflective ? "\(paper.name) · \(hasLustre ? "lustre" : "high gloss") · \(size)"
                : "Choose a reflection paper such as Ektacolor Edge or Ilfochrome."
        case .carrier:
            baseRGB = paper.frameBaseRGB(viewingKelvin: viewingKelvin) ?? .zero
            detail = carrierAvailable
                ? "\(paper.name) · filed carrier · 8 × 10 in"
                : "Choose a negative film and a reflection paper such as Ektacolor Edge."
        case .emulsion:
            // The band itself is developed by the host; the margin around it is the paper's white.
            baseRGB = paper.frameBaseRGB(viewingKelvin: viewingKelvin) ?? SIMD3(repeating: 0.91)
            detail = edgeAvailable
                ? "\(name) · \(definition?.name ?? "Film") · unexposed edge"
                : "Choose a film and a roll or sheet film format."
        case .mount:
            // Reflection outputs retain their modelled paper white. Other outputs use a
            // neutral presentation mount; this style does not identify a manufactured stock.
            baseRGB = paper.frameBaseRGB(viewingKelvin: viewingKelvin) ?? SIMD3(repeating: 0.91)
            detail = frame.detail
        case .darkMount:
            // A neutral presentation board, not the paper's own maximum density.
            baseRGB = SIMD3(repeating: 0.02)
            detail = frame.detail
        case .socialSquare, .socialPortrait, .socialStory:
            // Display white, so the post's margin merges with the feed it is shown in.
            baseRGB = SIMD3(repeating: 1)
            detail = frame.detail
        }
    }
}

extension PrintPaper {
    /// An unexposed border is clear paper for negative paper and maximum density for positive
    /// paper, under the viewing lamp. Crystal Archive shares the engine's explicitly documented
    /// RA-4 curve proxy.
    func frameBaseRGB(viewingKelvin: Float?) -> SIMD3<Float>? {
        frameRGB(viewingKelvin: viewingKelvin, dense: false)
    }

    /// A fully exposed negative-paper border, as the clear rebate of a negative prints through
    /// a filed carrier. Positive paper has no dark rebate exposure to print.
    func frameDenseRGB(viewingKelvin: Float?) -> SIMD3<Float>? {
        isPositivePaper ? nil : frameRGB(viewingKelvin: viewingKelvin, dense: true)
    }

    /// Density above the paper base, which is what the receiver reads and what the photograph's
    /// own tones are made of: clear paper is the print's white in the frame and in the picture.
    private func frameRGB(viewingKelvin: Float?, dense: Bool) -> SIMD3<Float>? {
        let density: SIMD3<Float>
        func pick(_ curve: CharacteristicCurve) -> Float { dense ? curve.dMax - curve.dMin : 0 }
        func maximum(_ curve: CharacteristicCurve) -> Float { curve.dMax - curve.dMin }
        switch self {
        case .ektacolorEdge:
            density = SIMD3(pick(Self.ra4PrintCurveRed), pick(Self.ra4PrintCurve), pick(Self.ra4PrintCurveBlue))
        case .enduraPremier:
            density = SIMD3(pick(EnduraPremierPaperSpectra.redCurve),
                            pick(EnduraPremierPaperSpectra.greenCurve), pick(EnduraPremierPaperSpectra.blueCurve))
        case .crystalArchive: density = SIMD3(repeating: pick(Self.ra4PrintCurve))
        case .ilfochromeCPS1K: density = SIMD3(repeating: maximum(Self.ilfochromeNormalCurve))
        case .ilfochromeCLM1K: density = SIMD3(repeating: maximum(Self.ilfochromeMediumCurve))
        default: return nil
        }
        let receiver = SpectralRuntime.PrintReceiver(dyes: analyticalDyes, flare: viewingFlare,
            viewingLight: viewingKelvin.map(SpectralRuntime.printLightSPD) ?? Illuminant.d50,
            unmix: PrintDyeUnmix(dyes: analyticalDyes))
        return receiver.rgb(density: density)
    }
}
