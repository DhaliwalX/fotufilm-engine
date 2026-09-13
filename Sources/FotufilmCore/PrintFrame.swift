import Foundation

/// Finishing follows the loaded film and output medium, not an unrelated decorative material.
public enum PrintFrame: String, CaseIterable, Codable, Sendable, Identifiable {
    case none, film, paper
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .none: return "None"
        case .film: return "Film Border"
        case .paper: return "Paper Border"
        }
    }
    public var detail: String {
        switch self {
        case .none: return "The photograph without a border."
        case .film: return "The selected film gauge, with its physical edges and perforations."
        case .paper: return "The selected photographic paper, in a 4 × 6 inch lustre print."
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Migrate the initial, unreleased decorative frame names into material-following modes.
        switch value {
        case "none": self = .none
        case "film", "film-35", "instant": self = .film
        case "paper", "contact", "baryta", "cotton": self = .paper
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown print frame")
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

/// Millimetre geometry before the finished photograph is fitted into the camera aperture.
/// x runs across the film, y along transport, except 135 stills which transport horizontally.
public struct FilmBorderGeometry: Equatable, Sendable {
    public enum Perforation: Sendable { case kodakStandard, bellHowell, sixteen, superEight }
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

public struct PrintFrameConfiguration: Equatable, Sendable {
    public let frame: PrintFrame
    public let geometry: FilmBorderGeometry?
    public let sheetNotches: SheetFilmNotchCode?
    /// Display-linear P3, converted into the photograph's output profile by the compositor.
    public let baseRGB: SIMD3<Float>
    public let detail: String

    public init(frame: PrintFrame, formatID: String?, stockID: String,
                paper: PrintPaper, viewingKelvin: Float? = nil,
                negativeViewing: NegativeViewing = .lightBox) {
        let definition = FilmStock.presetDefinitions[stockID]
        let nativeID = definition?.nativeFormatID
        let motionStock = nativeID.flatMap(FilmFormat.preset(id:))?.isMotionPicture == true
        let nativeInstant = nativeID.flatMap { FilmBorderGeometry.preset($0) }?.isInstant == true
        let film = formatID.flatMap { FilmBorderGeometry.preset($0, motionPictureStock: motionStock) }
        let name = formatID.flatMap(FilmFormat.preset(id:))?.name ?? "Film"
        let reflective = paper == .ektacolorEdge || paper == .enduraPremier || paper == .crystalArchive
        let filmAvailable = definition != nil && film != nil
            && ((film?.isInstant != true && !nativeInstant) || nativeID == formatID)
        self.frame = frame == .film && !filmAvailable || frame == .paper && !reflective ? .none : frame
        geometry = self.frame == .film ? film : nil
        sheetNotches = geometry?.isSheet == true ? definition?.sheetNotches : nil
        switch frame {
        case .none:
            baseRGB = .zero
            detail = frame.detail
        case .film:
            if film?.isInstant == true {
                baseRGB = SIMD3(repeating: 0.94)
            } else if paper.isNegative, let stock = definition?.stock {
                baseRGB = SpectralRuntime.negativeViewing(for: stock, look: negativeViewing).sample(.zero)
            } else {
                // A positive border reads the unexposed rebate as black; no invented orange mask
                // or manufacturer edge text is applied to a developed positive.
                baseRGB = SIMD3(repeating: 0.002)
            }
            if !filmAvailable {
                detail = "Choose a film and a matching physical film format."
            } else if film?.isSheet == true && sheetNotches == nil {
                detail = "\(name) sheet film · notch code not documented for this stock"
            } else {
                detail = "\(name) · \(definition?.name ?? "Film")"
            }
        case .paper:
            baseRGB = paper.frameBaseRGB(viewingKelvin: viewingKelvin) ?? .zero
            detail = reflective ? "\(paper.name) · lustre · 4 × 6 in"
                : "Choose Ektacolor Edge, ENDURA Premier, or Crystal Archive paper."
        }
    }
}

extension PrintPaper {
    /// An unexposed border uses the receiver's existing minimum-density records and viewing
    /// lamp. Crystal Archive shares the engine's explicitly documented RA-4 curve proxy.
    /// This is the model's paper base, not a new measured substrate-reflectance claim.
    func frameBaseRGB(viewingKelvin: Float?) -> SIMD3<Float>? {
        let density: SIMD3<Float>
        switch self {
        case .ektacolorEdge:
            density = SIMD3(Self.ra4PrintCurveRed.dMin, Self.ra4PrintCurve.dMin, Self.ra4PrintCurveBlue.dMin)
        case .enduraPremier:
            density = SIMD3(EnduraPremierPaperSpectra.redCurve.dMin,
                            EnduraPremierPaperSpectra.greenCurve.dMin, EnduraPremierPaperSpectra.blueCurve.dMin)
        case .crystalArchive: density = SIMD3(repeating: Self.ra4PrintCurve.dMin)
        default: return nil
        }
        let receiver = SpectralRuntime.PrintReceiver(dyes: analyticalDyes, flare: viewingFlare,
            viewingLight: viewingKelvin.map(SpectralRuntime.printLightSPD) ?? Illuminant.d50,
            unmix: PrintDyeUnmix(dyes: analyticalDyes))
        return receiver.rgb(density: density)
    }
}
