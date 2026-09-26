#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// How a scanned negative becomes a positive. The scan stays the original; this recipe is
/// everything an edit of it keeps, so a conversion can be reopened and changed.
public struct NegativeScanRecipe: Codable, Equatable, Sendable {
    public enum Conversion: String, Codable, CaseIterable, Sendable {
        /// Whole-frame endpoints, no film model (`AutomaticNegativeScan`).
        case automatic
        /// The scan's densities on a chosen film, printed through the engine's print stage.
        case film
    }

    /// A rectangle in unit coordinates, origin top left.
    public struct Area: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public static let full = Area(x: 0, y: 0, width: 1, height: 1)

        public init(_ rect: CGRect) {
            self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        }

        /// The area as a crop canvas holds it: nil for the whole frame.
        public var unitRect: CGRect? {
            self == .full ? nil : CGRect(x: x, y: y, width: width, height: height)
        }

        /// The same area kept inside the frame and at least `minimum` on a side.
        public func clamped(minimum: Double = 0.05) -> Area {
            let w = min(max(width, minimum), 1), h = min(max(height, minimum), 1)
            return Area(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
        }
    }

    public static let exposureRange: ClosedRange<Float> = -3...3
    public static let colourRange: ClosedRange<Float> = -1...1
    /// Contrast, highlights and shadows share one signed scale.
    public static let toneRange: ClosedRange<Float> = -1...1
    public static let straightenRange: ClosedRange<Double> = -15...15

    public var conversion: Conversion = .automatic
    /// Automatic conversion reads a black-and-white negative from one channel.
    public var monochrome = false
    /// The film a `.film` conversion reads the scan as. Reversal films have no negative to read.
    public var stockID = "gold200"
    /// Clear film sampled from the scan, as linear scan RGB.
    public var border: [Float]?
    /// Where `border` was sampled, in the scan's own unrotated frame.
    public var borderArea: Area?
    /// The receiver a `.film` conversion prints on.
    public var paperID = PrintPaper.screen.rawValue
    /// Stops. Printer exposure on an enlarged paper, screen exposure on Digital Reference and a
    /// display gain everywhere else.
    public var exposure: Float = 0
    /// Enlarger filtration on paper, a display balance elsewhere. Positive is warmer.
    public var warmth: Float = 0
    /// Positive is more magenta.
    public var tint: Float = 0
    /// The positive's tone after conversion: contrast about mid-grey, then the bright and the dark
    /// ends on their own (`NegativeScanTone`). A black-and-white positive shows contrast as a paper
    /// grade.
    public var contrast: Float = 0
    public var highlights: Float = 0
    public var shadows: Float = 0
    /// A photograph of the bare light source the scan was made on, dividing out its unevenness.
    public var lightFrameID: String?
    /// What an app keeps with a frame's edit that the engine carries, saves and undoes without
    /// reading, by the app's own key. Each frame keeps its own.
    public var attachments: [String: Data] = [:]
    /// Clockwise quarter turns, applied after `mirrored`.
    public var quarterTurns = 0
    /// Flipped left to right, for a scan made through the base side.
    public var mirrored = false
    /// Degrees, counter-clockwise, after the turns and the flip; the frame is enlarged to stay
    /// filled.
    public var straighten = 0.0
    /// The kept frame, in the oriented and straightened picture.
    public var crop = Area.full

    public init() {}

    /// Any field a saved recipe does not carry keeps its default, so a recipe written before a
    /// control existed opens with that control at rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        conversion = try read(.conversion, d.conversion)
        monochrome = try read(.monochrome, d.monochrome)
        stockID = try read(.stockID, d.stockID)
        border = try c.decodeIfPresent([Float].self, forKey: .border)
        borderArea = try c.decodeIfPresent(Area.self, forKey: .borderArea)
        paperID = try read(.paperID, d.paperID)
        exposure = try read(.exposure, d.exposure)
        warmth = try read(.warmth, d.warmth)
        tint = try read(.tint, d.tint)
        contrast = try read(.contrast, d.contrast)
        highlights = try read(.highlights, d.highlights)
        shadows = try read(.shadows, d.shadows)
        lightFrameID = try c.decodeIfPresent(String.self, forKey: .lightFrameID)
        attachments = try read(.attachments, d.attachments)
        quarterTurns = try read(.quarterTurns, d.quarterTurns)
        mirrored = try read(.mirrored, d.mirrored)
        straighten = try read(.straighten, d.straighten)
        crop = try read(.crop, d.crop)
    }

    /// The receivers a scan prints on: the display conversion, the RA-4 papers and the lab scanner.
    public static func papers(for stock: FilmStock) -> [PrintPaper] {
        let offered: [PrintPaper] = [.screen, .crystalArchive, .enduraPremier, .ektacolorEdge, .labScan]
        let available = PrintPaper.choices(for: stock)
        return offered.filter(available.contains)
    }

    public func paper(for stock: FilmStock) -> PrintPaper {
        let papers = Self.papers(for: stock)
        return PrintPaper.preset(id: paperID).flatMap { papers.contains($0) ? $0 : nil }
            ?? papers.first ?? .screen
    }

    /// Engine options for printing this scan's densities on `stock`. `highlightStops` is where
    /// the frame's highlights sit over the film's mid-grey
    /// (`ApproximateNegativeScan.Balance.highlightStops`): Digital Reference levels to it, and an
    /// enlarged paper is timed by it, as a lab printer times each negative.
    public func printOptions(for stock: FilmStock,
                             highlightStops: Float? = nil) -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.stage = .print
        options.sceneHighlightStops = highlightStops
        let paper = paper(for: stock)
        options.paper = paper
        let exposure = Self.exposureRange.clamp(exposure)
        if Enlarger.illuminates(stock: stock, paper: paper) {
            // A yellow filter takes blue out of the lamp and the print gets less yellow dye,
            // so warming the print takes filtration away. Magenta works the same way on green.
            let reference = PrinterProfile.simulatedTungsten
            options.printer = PrinterProfile(
                exposureEV: exposure + Self.printerTiming(for: stock, highlightStops: highlightStops),
                magenta: reference.magenta - Self.filtrationPerStep * Self.colourRange.clamp(tint),
                yellow: reference.yellow - Self.filtrationPerStep * Self.colourRange.clamp(warmth)
            ).normalized
        } else if paper == .screen {
            options.screenExposureEV = exposure
        }
        return options
    }

    /// Diffuse white over mid-grey, in stops: 90% reflectance against 18%.
    static let diffuseWhiteStops: Float = log2(0.9 / 0.18)

    /// Printer stops that print the frame's highlights where a diffuse white on a normally
    /// exposed negative would print. A thinner negative takes less light, a denser one more.
    static func printerTiming(for stock: FilmStock, highlightStops: Float?) -> Float {
        guard let highlightStops, highlightStops.isFinite else { return 0 }
        let green = stock.curves[1]
        let frame = green.density(logExposure: highlightStops * log10(2))
        let white = green.density(logExposure: diffuseWhiteStops * log10(2))
        return min(max((frame - white) / log10(2), -3), 3)
    }

    /// Filtration density a full step of warmth or tint moves on the enlarger.
    static let filtrationPerStep: Float = 0.3

    /// Linear RGB gains applied after conversion: whatever the receiver does not carry itself.
    /// `stock` is the film of a `.film` conversion, `nil` for an automatic one.
    public func displayGains(printingOn stock: FilmStock?) -> SIMD3<Float> {
        var exposureStops = Self.exposureRange.clamp(exposure)
        var colour = true
        if let stock {
            let paper = paper(for: stock)
            if Enlarger.illuminates(stock: stock, paper: paper) { return SIMD3(repeating: 1) }
            if paper == .screen { exposureStops = 0 }
            colour = !stock.isMonochrome
        } else {
            colour = !monochrome
        }
        var gains = SIMD3<Float>(repeating: pow(2, exposureStops))
        guard colour else { return gains }
        let warm = Self.colourRange.clamp(warmth) * Self.balanceStopsPerStep
        let magenta = Self.colourRange.clamp(tint) * Self.balanceStopsPerStep
        gains *= SIMD3(pow(2, warm / 2 + magenta / 3), pow(2, -2 * magenta / 3),
                       pow(2, -warm / 2 + magenta / 3))
        return gains
    }

    /// Stops of red-against-blue (or green-against-magenta) a full step of balance moves.
    static let balanceStopsPerStep: Float = 0.6

    /// The tone after conversion.
    public var tone: NegativeScanTone {
        NegativeScanTone(contrast: Self.toneRange.clamp(contrast),
                         highlights: Self.toneRange.clamp(highlights),
                         shadows: Self.toneRange.clamp(shadows))
    }

    // MARK: - Paper grade

    /// The grades of a multigrade paper, softest first. Grade 2 is the paper's normal contrast.
    public static let grades: ClosedRange<Double> = 0...5

    /// The contrast a paper grade prints at: each grade a third of the scale, grade 2 at none.
    public static func contrast(forGrade grade: Double) -> Float {
        Float((min(max(grade, grades.lowerBound), grades.upperBound) - 2) / 3)
    }

    public static func grade(forContrast contrast: Float) -> Double {
        min(max(Double(contrast) * 3 + 2, grades.lowerBound), grades.upperBound)
    }

    // MARK: - A roll

    /// Takes another frame's conversion — how it is read, printed and toned, and the light and
    /// base it was measured against — and keeps this frame's own framing and attachments. Frames
    /// of one roll share all of that and none of their framing.
    public mutating func adoptConversion(of other: NegativeScanRecipe) {
        let own = (quarterTurns, mirrored, straighten, crop, attachments)
        self = other
        (quarterTurns, mirrored, straighten, crop, attachments) = own
    }

    // MARK: - Orientation

    /// The oriented picture's size for a scan of `size`.
    public func orientedSize(of size: CGSize) -> CGSize {
        quarterTurns.isMultiple(of: 2) ? size : CGSize(width: size.height, height: size.width)
    }

    /// Maps a unit point in the scan's own frame into the oriented picture.
    public func orient(_ point: CGPoint) -> CGPoint {
        var p = CGPoint(x: mirrored ? 1 - point.x : point.x, y: point.y)
        for _ in 0..<Self.normalized(quarterTurns) { p = CGPoint(x: 1 - p.y, y: p.x) }
        return p
    }

    /// Maps a unit point in the oriented picture back into the scan's own frame.
    public func unorient(_ point: CGPoint) -> CGPoint {
        var p = point
        for _ in 0..<Self.normalized(quarterTurns) { p = CGPoint(x: p.y, y: 1 - p.x) }
        return CGPoint(x: mirrored ? 1 - p.x : p.x, y: p.y)
    }

    public func orient(_ area: Area) -> Area { Self.bounds(of: area) { orient($0) } }
    public func unorient(_ area: Area) -> Area { Self.bounds(of: area) { unorient($0) } }

    static func normalized(_ turns: Int) -> Int { ((turns % 4) + 4) % 4 }

    private static func bounds(of area: Area, _ map: (CGPoint) -> CGPoint) -> Area {
        let corners = [CGPoint(x: area.x, y: area.y),
                       CGPoint(x: area.x + area.width, y: area.y + area.height)].map(map)
        let x0 = min(corners[0].x, corners[1].x), y0 = min(corners[0].y, corners[1].y)
        return Area(x: x0, y: y0, width: abs(corners[1].x - corners[0].x),
                    height: abs(corners[1].y - corners[0].y))
    }

    /// Turns the picture a quarter clockwise, keeping the same part of the scan in the crop.
    public mutating func rotateClockwise() {
        let kept = unorient(crop)
        quarterTurns = Self.normalized(quarterTurns + 1)
        crop = orient(kept)
    }

    /// Flips the picture left to right as it is shown, keeping the same part of the scan in the
    /// crop. On a turned picture the scan's own left-right flip reads upside down, so a half
    /// turn goes with it; a flipped tilt leans the other way.
    public mutating func toggleMirror() {
        let kept = unorient(crop)
        mirrored.toggle()
        if !quarterTurns.isMultiple(of: 2) { quarterTurns = Self.normalized(quarterTurns + 2) }
        crop = orient(kept)
        straighten = -straighten
    }

    // MARK: - Straightening

    /// How much a picture of `size` is enlarged when turned by `degrees`, so that the turned
    /// picture still fills its own frame.
    public static func straightenScale(size: CGSize, degrees: Double) -> Double {
        guard size.width > 0, size.height > 0 else { return 1 }
        let angle = abs(degrees) * .pi / 180
        let (c, s) = (cos(angle), sin(angle))
        let w = Double(size.width), h = Double(size.height)
        return max(c + s * h / w, c + s * w / h)
    }

    /// Maps a unit point of the picture as shown — cropped unless `cropped` is false — back
    /// into the scan's own frame, for a scan of `size`.
    public func scanPoint(ofShown point: CGPoint, cropped: Bool = true, scanSize size: CGSize) -> CGPoint {
        let crop = cropped ? self.crop.clamped() : .full
        let uncropped = CGPoint(x: crop.x + Double(point.x) * crop.width,
                                y: crop.y + Double(point.y) * crop.height)
        return unorient(unstraighten(uncropped, orientedSize: orientedSize(of: size)))
    }

    /// Maps a unit point of the straightened picture back into the oriented picture of `size`,
    /// both from the top left.
    public func unstraighten(_ point: CGPoint, orientedSize size: CGSize) -> CGPoint {
        guard straighten != 0, size.width > 0, size.height > 0 else { return point }
        let scale = Self.straightenScale(size: size, degrees: straighten)
        let angle = straighten * .pi / 180
        let (c, s) = (cos(angle), sin(angle))
        let w = Double(size.width), h = Double(size.height)
        // Pixels from the centre, y down. The picture turns counter-clockwise as seen, so a point
        // of it is found clockwise of where it shows.
        let x = (Double(point.x) - 0.5) * w / scale, y = (Double(point.y) - 0.5) * h / scale
        return CGPoint(x: (c * x - s * y) / w + 0.5, y: (s * x + c * y) / h + 0.5)
    }
}

private extension ClosedRange where Bound == Float {
    func clamp(_ value: Float) -> Float {
        value.isFinite ? Swift.min(Swift.max(value, lowerBound), upperBound) : 0
    }
}
