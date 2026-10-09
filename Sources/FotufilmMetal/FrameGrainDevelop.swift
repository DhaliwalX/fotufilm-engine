#if canImport(Metal)
import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

extension HalideMetalFilmRenderer {
    /// Whether `developWithFrameGrain` lays this develop's grain: Film grain on a whole film,
    /// where the host can lay it.
    public static func laysFrameGrain(stock: FilmStock, options: FotufilmEngine.Options) -> Bool {
        FilmGrain.laysFrameGrain && options.stage == .full && options.grainModel == .film
            && options.grainScale > 0 && stock.grainStrength > 0
            && options.transportConstruction(for: stock) == nil
    }

    /// Develops a still whose Film grain is laid crystal by crystal over the whole frame rather
    /// than sampled from the tiles, so nothing in it repeats: the negative without grain, a
    /// band at a time; the frame's grain laid on its developed densities; then the print from
    /// them, a band at a time. Between them the two spans run every other stage once, as `full`
    /// does, and both take the whole develop's metering of the scene. Nil where the develop lays no Film grain; false where a span failed or
    /// `shouldContinue` stopped it.
    public func developWithFrameGrain(
        width: Int, height: Int, stock: FilmStock, options: FotufilmEngine.Options,
        outputTransform: inout FilmOutputTransform?, exactMath: Bool,
        shouldContinue: @escaping () -> Bool,
        readRows: (_ rows: Range<Int>, _ into: UnsafeMutableBufferPointer<Float>) -> Void,
        writeRows: (_ rows: Range<Int>, _ from: UnsafeBufferPointer<Float>) -> Void
    ) -> Bool? {
        guard Self.laysFrameGrain(stock: stock, options: options) else { return nil }
        return developInSpans(
            width: width, height: height, stock: stock, options: options,
            outputTransform: &outputTransform, exactMath: exactMath, laysGrain: true,
            shouldContinue: shouldContinue, readRows: readRows, writeRows: writeRows)
    }

    /// The negative and the print as two spans, with the frame's grain laid between them when
    /// `laysGrain`; without it, the whole develop's pixels.
    func developInSpans(
        width: Int, height: Int, stock: FilmStock, options: FotufilmEngine.Options,
        outputTransform: inout FilmOutputTransform?, exactMath: Bool, laysGrain: Bool,
        shouldContinue: @escaping () -> Bool,
        readRows: (_ rows: Range<Int>, _ into: UnsafeMutableBufferPointer<Float>) -> Void,
        writeRows: (_ rows: Range<Int>, _ from: UnsafeBufferPointer<Float>) -> Void
    ) -> Bool? {
        guard var invocation = try? FilmEngineInvocation(
                  validating: stock, options: options, width: width, height: height,
                  checkCancellation: { if !shouldContinue() { throw CancellationError() } })
        else { return nil }
        let grain = laysGrain ? invocation.filmGrainFrame : nil
        guard !laysGrain || grain != nil else { return nil }

        // The scene metered once, as the whole develop meters it, for both spans to adopt.
        invocation.featureMask |= FilmEngineFeature.floatIO
        if exactMath { invocation.featureMask |= FilmEngineFeature.exactMath }
        let unmetered = invocation
        let bandRows = max(1, min(height, (64 << 20) / (width * 16)))
        var band = [Float](repeating: 0, count: bandRows * width * 4)
        let measured = band.withUnsafeMutableBufferPointer { band in
            measureWholeFrame(
                &invocation, width: width, height: height, bandRows: bandRows,
                cancelled: { !shouldContinue() }, progress: nil,
                band: { rows in
                    readRows(rows, UnsafeMutableBufferPointer(rebasing: band[0..<(rows.count * width * 4)]))
                    return UnsafePointer(band.baseAddress!)
                })
        }
        guard measured else { return false }
        band = []
        let metering = invocation.metering(since: unmetered)

        var negative = options
        negative.stage = .negative
        negative.grainScale = 0
        var density = [Float](repeating: 0, count: width * height * 4)
        var noTransform: FilmOutputTransform?
        let developed = density.withUnsafeMutableBufferPointer { density in
            developStreaming(
                width: width, height: height, stock: stock, options: negative,
                outputTransform: &noTransform, exactMath: exactMath, metering: metering,
                shouldContinue: shouldContinue,
                readRows: readRows,
                writeRows: { rows, from in
                    (density.baseAddress! + rows.lowerBound * width * 4)
                        .update(from: from.baseAddress!, count: rows.count * width * 4)
                })
        }
        guard developed, shouldContinue() else { return false }
        if let grain {
            let laid = density.withUnsafeMutableBufferPointer {
                grain.binding.addFrameGrain(to: $0, channels: 4, width: width, height: height,
                                        pxPerMM: grain.pxPerMM, amount: grain.amount,
                                        look: grain.look, seed: grain.seed,
                                        shouldContinue: shouldContinue)
            }
            guard laid, shouldContinue() else { return false }
        }

        var print = options
        print.stage = .print
        return density.withUnsafeBufferPointer { density in
            developStreaming(
                width: width, height: height, stock: stock, options: print,
                outputTransform: &outputTransform, exactMath: exactMath, metering: metering,
                shouldContinue: shouldContinue,
                readRows: { rows, into in
                    into.baseAddress!.update(from: density.baseAddress! + rows.lowerBound * width * 4,
                                             count: rows.count * width * 4)
                },
                writeRows: writeRows)
        }
    }
}
#endif
