import Foundation

/// The red, green and blue lights of the additive printer a release print is exposed on, in
/// printer points: the numbers a colour timer writes on the tape for each scene.
///
/// One point is 0.025 log exposure; Kodak's 5289 data sheet gives "a change of 0.025 in
/// density is approximately equal to one printer light in laboratory color timing", so
/// twelve points are about one stop. Each light scales its own beam of the printer before
/// the negative, never a dye record of the print: a beam that also reaches a neighbouring
/// layer carries that crosstalk with it. 25-25-25, the centre of the printer's balance
/// range, prints the negative at the stock's LAD aim (Kodak's Ti2461 times LAD control film
/// "at the center of the printer balance range, usually TAPE 25-25-25"). The 1-50 span is
/// the conventional tape scale, not a published limit.
///
/// More light makes a denser print. Raising the red light adds cyan to a print and lowering
/// it adds red; green trades magenta against green and blue trades yellow against blue.
public struct PrinterLights: Hashable, Sendable, Codable {
    public var red: Float
    public var green: Float
    public var blue: Float

    /// The lab's aim setup: every light at the centre of the scale.
    public static let balanced = PrinterLights()
    public static let range: ClosedRange<Float> = 1...50
    public static let centre: Float = 25
    /// Log exposure per printer point.
    public static let logExposurePerPoint: Float = 0.025

    public init(red: Float = 25, green: Float = 25, blue: Float = 25) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public subscript(channel: Int) -> Float {
        get { channel == 0 ? red : channel == 1 ? green : blue }
        set {
            switch channel {
            case 0: red = newValue
            case 1: green = newValue
            default: blue = newValue
            }
        }
    }

    /// Each light held on the scale; a non-finite one takes the centre.
    public var normalized: PrinterLights {
        var result = self
        for channel in 0..<3 {
            result[channel] = self[channel].isFinite
                ? min(max(self[channel], Self.range.lowerBound), Self.range.upperBound) : Self.centre
        }
        return result
    }

    /// Each beam's intensity against the aim setup.
    var beamGain: SIMD3<Float> {
        let p = normalized
        return SIMD3((0..<3).map { pow(10, (p[$0] - Self.centre) * Self.logExposurePerPoint) })
    }

    /// Whether a release printer exposes this stock on this medium: a negative printed onto
    /// cinema print film, not a slide viewed directly.
    public static func applies(stock: FilmStock, paper: PrintPaper) -> Bool {
        paper.isProjected && !paper.viewsFilmDirectly(for: stock) && !stock.isReflectionPrint
            && paper.resolved(for: stock) == paper
    }

    /// The lights the printing table is built with, or nil where they change nothing: on a
    /// medium no release printer exposes, and at the aim setup, so that setup keeps the
    /// identity every untimed release print already has.
    static func resolved(_ lights: PrinterLights?, stock: FilmStock,
                         paper: PrintPaper) -> PrinterLights? {
        guard let lights = lights?.normalized, lights != .balanced,
              applies(stock: stock, paper: paper) else { return nil }
        return lights
    }

    var spectralSignature: UInt64 {
        let p = normalized
        var h: UInt64 = 0x4C49474854530001
        for value in [p.red, p.green, p.blue] {
            h = (h ^ UInt64(value.bitPattern)) &* 0x100000001b3
        }
        return h
    }
}
