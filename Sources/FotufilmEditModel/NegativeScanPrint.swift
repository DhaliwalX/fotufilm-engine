import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// How a scanned negative read as a film prints through the edit's own print stage: which films
/// can read it, its reading, and the edit's light controls on the print.
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
