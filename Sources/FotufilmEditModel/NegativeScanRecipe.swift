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

        /// The same area kept inside the frame and at least `minimum` on a side.
        public func clamped(minimum: Double = 0.05) -> Area {
            let w = min(max(width, minimum), 1), h = min(max(height, minimum), 1)
            return Area(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
        }
    }

    public static let exposureRange: ClosedRange<Float> = -3...3
    public static let colourRange: ClosedRange<Float> = -1...1

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
    /// Clockwise quarter turns, applied after `mirrored`.
    public var quarterTurns = 0
    /// Flipped left to right, for a scan made through the base side.
    public var mirrored = false
    /// The kept frame, in the oriented picture.
    public var crop = Area.full

    public init() {}

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
    /// turn goes with it.
    public mutating func toggleMirror() {
        let kept = unorient(crop)
        mirrored.toggle()
        if !quarterTurns.isMultiple(of: 2) { quarterTurns = Self.normalized(quarterTurns + 2) }
        crop = orient(kept)
    }
}

private extension ClosedRange where Bound == Float {
    func clamp(_ value: Float) -> Float {
        value.isFinite ? Swift.min(Swift.max(value, lowerBound), upperBound) : 0
    }
}
