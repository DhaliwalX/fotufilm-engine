#if canImport(Metal)
import XCTest
@testable import FotufilmCore
@testable import FotufilmMetal

final class FrameGrainDevelopTests: XCTestCase {
    private let width = 192
    private let height = 128

    private func scene() -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let ramp = Float(x) / Float(width - 1), fall = Float(y) / Float(height - 1)
                let specular = (x - 30) * (x - 30) + (y - 30) * (y - 30) < 25 ? Float(20) : Float(1)
                pixels[index] = (0.02 + 0.8 * ramp) * specular
                pixels[index + 1] = (0.02 + 0.6 * (1 - ramp) * (0.5 + fall)) * specular
                pixels[index + 2] = (0.02 + 0.4 * fall) * specular
                pixels[index + 3] = 1
            }
        }
        return pixels
    }

    private func develop(_ gpu: HalideMetalFilmRenderer, _ input: [Float], stock: FilmStock,
                         options: FotufilmEngine.Options) -> [Float]? {
        var output = [Float](repeating: 0, count: input.count)
        let ok = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                gpu.developStreaming(
                    width: width, height: height, stock: stock, options: options, exactMath: true,
                    readRows: { rows, into in
                        into.baseAddress!.update(from: source.baseAddress! + rows.lowerBound * self.width * 4,
                                                 count: rows.count * self.width * 4)
                    },
                    writeRows: { rows, from in
                        (target.baseAddress! + rows.lowerBound * self.width * 4)
                            .update(from: from.baseAddress!, count: rows.count * self.width * 4)
                    })
            }
        }
        return ok ? output : nil
    }

    private func split(_ gpu: HalideMetalFilmRenderer, _ input: [Float], stock: FilmStock,
                       options: FotufilmEngine.Options, laysGrain: Bool = true) -> [Float]? {
        var output = [Float](repeating: 0, count: input.count)
        var none: FilmOutputTransform?
        let ok = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                gpu.developInSpans(
                    width: width, height: height, stock: stock, options: options,
                    outputTransform: &none, exactMath: true, laysGrain: laysGrain,
                    shouldContinue: { true },
                    readRows: { rows, into in
                        into.baseAddress!.update(from: source.baseAddress! + rows.lowerBound * self.width * 4,
                                                 count: rows.count * self.width * 4)
                    },
                    writeRows: { rows, from in
                        (target.baseAddress! + rows.lowerBound * self.width * 4)
                            .update(from: from.baseAddress!, count: rows.count * self.width * 4)
                    })
            }
        }
        return ok == true ? output : nil
    }

    private var cases: [(String, PrintPaper?)] {
        [("portra400", .screen), ("portra400", .labScan), ("portra400", .ektacolorEdge),
         ("trix400", .screen), ("provia100f", nil)]
    }

    /// With no grain to lay, the split develop is the full one: the negative and the print
    /// between them run every stage once, metering and timing included.
    func testSplitDevelopIsTheFullDevelopWithoutGrain() throws {
        guard let gpu = HalideMetalFilmRenderer.shared, FilmGrain.laysFrameGrain else {
            throw XCTSkip("Halide Metal unavailable")
        }
        let input = scene()
        for (id, paper) in cases {
            let stock = try XCTUnwrap(FilmStock.named(id))
            var options = FotufilmEngine.Options()
            options.grainModel = .film
            options.paper = paper
            options.seed = 0x5EED
            options.grainScale = 0
            let full = try XCTUnwrap(develop(gpu, input, stock: stock, options: options), id)
            let printed = try XCTUnwrap(split(gpu, input, stock: stock, options: options,
                                              laysGrain: false), id)
            var worst: Float = 0
            for i in 0..<full.count where i % 4 != 3 {
                worst = max(worst, abs(printed[i] - full[i]) / max(abs(full[i]), 0.01))
            }
            XCTAssertLessThan(worst, 1e-3, "\(id) on \(paper?.rawValue ?? "its own medium")")
        }
    }

    /// With grain, the split develop prints the frame's own film: as bright as the tiled develop
    /// on average, as grainy, and different pixel by pixel. A crop of the frame 9 µm a pixel, as a
    /// whole frame's pixels are: much coarser and a pixel spans most of a tile, which no longer
    /// reads as grainy as film does.
    func testSplitDevelopPrintsFrameGrain() throws {
        guard let gpu = HalideMetalFilmRenderer.shared, FilmGrain.laysFrameGrain else {
            throw XCTSkip("Halide Metal unavailable")
        }
        let input = scene()
        for (id, paper) in cases {
            let stock = try XCTUnwrap(FilmStock.named(id))
            var options = FotufilmEngine.Options()
            options.grainModel = .film
            options.paper = paper
            options.seed = 0x5EED
            options.frameCoverage = 0.05
            let tiled = try XCTUnwrap(develop(gpu, input, stock: stock, options: options), id)
            let laid = try XCTUnwrap(split(gpu, input, stock: stock, options: options), id)
            var flat = options
            flat.grainScale = 0
            let clean = try XCTUnwrap(develop(gpu, input, stock: stock, options: flat), id)
            var tiledMean = 0.0, laidMean = 0.0, tiledPower = 0.0, laidPower = 0.0, differs = 0
            for i in 0..<clean.count where i % 4 == 1 {
                tiledMean += Double(tiled[i] - clean[i])
                laidMean += Double(laid[i] - clean[i])
                tiledPower += Double((tiled[i] - clean[i]) * (tiled[i] - clean[i]))
                laidPower += Double((laid[i] - clean[i]) * (laid[i] - clean[i]))
                if abs(laid[i] - tiled[i]) > 1e-4 { differs += 1 }
            }
            let count = Double(width * height)
            let scale = (tiledPower / count).squareRoot()
            XCTAssertGreaterThan(differs, width * height / 2, "\(id): the grain did not move")
            XCTAssertEqual((laidPower / tiledPower).squareRoot(), 1, accuracy: 0.15, id)
            XCTAssertEqual((laidMean - tiledMean) / count, 0, accuracy: 0.1 * scale, id)
        }
    }
}
#endif
