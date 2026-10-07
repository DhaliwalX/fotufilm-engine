import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// How a scanned negative prints: which films can read it, the apps' scan editor recipes, and a
/// scan read as a film in the editor through the edit's own print stage and light controls.
public enum NegativeScanPrint {
    public enum Failure: LocalizedError, Equatable {
        case noFilm, reversalFilm
        public var errorDescription: String? {
            switch self {
            case .noFilm: return "This film is not installed."
            case .reversalFilm: return "Slide film has no negative to convert. Choose a negative film."
            }
        }
    }

    /// Whether a scan can be read as `stock`: slides and papers have no negative to read.
    public static func reads(_ stock: FilmStock) -> Bool {
        !stock.isReversal && !stock.isReflectionPrint
    }

    /// The installed films a scan can be read as, in the catalogue's order.
    public static var filmIDs: [String] {
        FilmStock.presetIDs.filter { FilmStock.presets[$0].map(reads) ?? false }
    }

    public static func film(_ id: String) throws -> FilmStock {
        guard let stock = FilmStock.presets[id] else { throw Failure.noFilm }
        return try film(stock)
    }

    /// `stock`, when a scan can be read as it.
    public static func film(_ stock: FilmStock) throws -> FilmStock {
        guard reads(stock) else { throw Failure.reversalFilm }
        return stock
    }

    // MARK: - Scan editor

    /// Whether a recipe's positive carries colour: an automatic reading not in black and white, or
    /// a reading on a colour negative.
    public static func carriesColour(_ recipe: NegativeScanRecipe,
                                     film: (String) throws -> FilmStock = film) -> Bool {
        recipe.conversion == .automatic ? !recipe.monochrome
            : (try? film(recipe.stockID))?.isMonochrome != true
    }

    /// Whether the recipe reads its scan samples as linear Rec. 2020 — a film reading, which
    /// wants every dense dye positive — or as linear sRGB, where the automatic stage is defined.
    public static func readsWideGamut(_ recipe: NegativeScanRecipe) -> Bool {
        recipe.conversion == .film
    }

    // MARK: - Automatic

    /// Converts rows of linear sRGB scan RGBA, in place, into the automatic reading's positive:
    /// display-linear Display P3 with the recipe's gains and tone.
    public static func printAutomatic(_ rgba: UnsafeMutableBufferPointer<Float>, width: Int,
                                      rows: Int, plan: AutomaticNegativeScan,
                                      recipe: NegativeScanRecipe) throws {
        let count = width * rows
        guard count > 0, rgba.count >= count * 4 else { return }
        var scan = ImageBuffer(width: width, height: rows)
        for i in 0..<count { for c in 0..<3 { scan.planes[c][i] = rgba[i * 4 + c] } }
        let positive = try plan.convert(scan)
        let gains = recipe.displayGains(printingOn: nil)
        let tone = recipe.tone
        for i in 0..<count {
            // The automatic stage delivers display sRGB primaries; the print is Display P3.
            let rgb = ColorScience.linearSRGBToDisplayP3(tone.apply(SIMD3(
                positive.planes[0][i], positive.planes[1][i], positive.planes[2][i]) * gains))
            rgba[i * 4] = rgb.x
            rgba[i * 4 + 1] = rgb.y
            rgba[i * 4 + 2] = rgb.z
            rgba[i * 4 + 3] = 1
        }
    }

    // MARK: - Film

    /// What the print stage is handed for a film reading, and what finishes its rows.
    public struct Film {
        public let stock: FilmStock
        /// The border calibration that turns scan samples into the film's record densities.
        public let calibration: ApproximateNegativeScan
        /// Engine options for the print stage on the recipe's receiver.
        public let options: FotufilmEngine.Options
        /// Linear gains and tone the receiver does not carry itself.
        public let gains: SIMD3<Float>
        public let tone: NegativeScanTone

        /// Whether the print stage's rows are the print as they are.
        public var isNeutral: Bool { gains == SIMD3(repeating: 1) && tone.isNeutral }

        /// Finishes display-linear RGBA rows from the print stage, in place.
        public func grade(_ rgba: inout [Float]) {
            guard !isNeutral else { return }
            for i in stride(from: 0, to: rgba.count - 3, by: 4) {
                rgba[i] *= gains.x
                rgba[i + 1] *= gains.y
                rgba[i + 2] *= gains.z
            }
            tone.apply(rgba: &rgba)
        }
    }

    /// The film reading of `recipe` against `border`, the clear film as linear Rec. 2020 scan
    /// RGB, with `balance` measured from the framed picture
    /// (`ApproximateNegativeScan.balance`).
    public static func film(_ recipe: NegativeScanRecipe, stock: FilmStock, border: [Float],
                            balance: ApproximateNegativeScan.Balance) throws -> Film {
        let calibration = try ApproximateNegativeScan(
            stock: stock, border: SIMD3(border[0], border[1], border[2]), gains: balance.gains)
        return Film(stock: stock, calibration: calibration,
                    options: recipe.printOptions(for: stock, highlightStops: balance.highlightStops),
                    gains: recipe.displayGains(printingOn: stock), tone: recipe.tone)
    }

    // MARK: - Editor reading

    /// A scan read as a film in the editor: what turns each framed scan sample into the film's
    /// record densities, and where the frame's highlights sit. Everything after that is the
    /// edit's own print.
    public struct Reading {
        /// The border calibration that turns scan samples into the film's record densities.
        public let calibration: ApproximateNegativeScan
        /// The frame's highlights in stops over the film's mid-grey
        /// (`ApproximateNegativeScan.Balance.highlightStops`).
        public let highlightStops: Float?

        /// Reads a scan as `stock` against `border`, with its frame's `balance`.
        public init(stock: FilmStock, border: SIMD3<Float>,
                    balance: ApproximateNegativeScan.Balance) throws {
            calibration = try ApproximateNegativeScan(stock: stock, border: border,
                                                      gains: balance.gains)
            highlightStops = balance.highlightStops
        }

        /// The edit's options printing this reading (`NegativeScanPrint.printing`), the kernels
        /// reading the scan they are handed (`FotufilmEngine.Options.scanReading`).
        public func printing(_ edit: FotufilmEngine.Options,
                             stock: FilmStock) -> FotufilmEngine.Options {
            var options = NegativeScanPrint.printing(edit, stock: stock, highlightStops: highlightStops)
            options.scanReading = calibration
            return options
        }
    }

    /// An edit's options printing a scan read as `stock`: the print span alone, metered on the
    /// frame's highlights. An enlarged paper is timed to the negative's density, as a lab times
    /// each frame, and the lamp's own exposure moves the print from there.
    ///
    /// The camera already exposed the film, so the edit's light controls act on the print
    /// instead. Exposure and warmth reach what makes the print where it can carry them: an
    /// enlarger's exposure and filtration, scaled by the paper's contrast so a stop moves the
    /// picture about a stop, or a scan's exposure. What it cannot carry, and highlights,
    /// shadows, saturation and vibrance, finish the printed picture (`PrintFinish`).
    public static func printing(_ edit: FotufilmEngine.Options, stock: FilmStock,
                                highlightStops: Float?) -> FotufilmEngine.Options {
        var options = edit
        options.stage = .print
        options.sceneHighlightStops = highlightStops
        // The picture's colour the warmth and tint ask for, green held: the light they name over
        // D65, as Normal applies it. A black-and-white print takes none.
        let correction = edit.whiteBalance.gains
        let balance = stock.isMonochrome ? SIMD3<Float>.one
            : SIMD3(1 / correction.r, 1, 1 / correction.b)
        var finish = PrintFinish(highlights: edit.highlights, shadows: edit.shadows,
                                 saturation: edit.saturation, vibrance: edit.vibrance)
        let paper = options.paper(for: stock)
        if Enlarger.illuminates(stock: stock, paper: paper) {
            var printer = options.printer ?? .simulatedTungsten
            printer.exposureEV += NegativeScanRecipe.printerTiming(
                for: stock, highlightStops: highlightStops) - edit.exposureEV / paperContrast
            // A yellow filter takes blue out of the lamp and the print gets less yellow dye, so
            // warming the print takes filtration away. Magenta works the same way on green.
            let stops = SIMD3(log2(balance.x), log2(balance.y), log2(balance.z))
            let perStop = log10(Float(2)) / paperContrast
            printer.yellow -= (stops.x - stops.z) * perStop
            printer.magenta -= ((stops.x + stops.z) / 2 - stops.y) * perStop
            options.printer = printer.normalized
        } else if paper == .screen || paper == .labScan {
            options.screenExposureEV += edit.exposureEV
            finish.gains = balance
        } else {
            finish.gains = balance * exp2(edit.exposureEV)
        }
        options.printFinish = finish
        // Every light control is on the print now; the scene they would shape is not in this span.
        options.exposureEV = 0
        options.whiteBalance = .neutral
        options.highlights = 0
        options.shadows = 0
        options.saturation = 1
        options.vibrance = 0
        return options
    }

    /// A colour paper's contrast at mid-grey: picture stops per stop of printing light, about
    /// three on the enlarger's papers (2.7 on Crystal Archive to 3.5 on Endura Premier).
    static let paperContrast: Float = 3
}
