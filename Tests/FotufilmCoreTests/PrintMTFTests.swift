import XCTest
@testable import FotufilmCore

final class PrintMTFTests: XCTestCase {

    private func requireEngine() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
    }

    private static var stock: FilmStock {
        FilmStock.presets["example-negative-400"]!
    }

    private static let frameMM: Float = 1.2
    private static let side = 600

    private func invocation(paper: PrintPaper,
                            viewing: NegativeViewing? = nil) -> FilmEngineInvocation {
        var options = FotufilmEngine.Options()
        options.format = FilmFormat(name: "print bench", frameHeightMM: Self.frameMM)
        options.paper = paper
        options.negativeViewing = viewing
        return FilmEngineInvocation(stock: Self.stock, options: options,
                                    width: Self.side, height: Self.side)
    }

    func testEnlargerSigmaIsThePapersFigureAtTheSamplingDensity() {
        let pxPerMM = Float(Self.side) / Self.frameMM
        for paper in [PrintPaper.ektacolorEdge, .crystalArchive, .vision2383, .labScan,
                      .telecine] {
            let inv = invocation(paper: paper)
            XCTAssertNotEqual(inv.featureMask & FilmEngineFeature.printMTF, 0,
                              "\(paper.name) has an enlarger and did not switch it on")
            XCTAssertEqual(inv.configuration[FilmEngineInvocation.printMTFOffset],
                           paper.enlargerBlurMM * pxPerMM, accuracy: 1e-4,
                           paper.name)
            XCTAssertGreaterThan(
                inv.configuration[FilmEngineInvocation.printMTFOffset + 1], 0,
                "\(paper.name) asks for a zero-radius blur, which is no blur")
        }
    }

    func testPathsWithNoOpticsSwitchItOff() {
        XCTAssertEqual(invocation(paper: .screen).featureMask
                        & FilmEngineFeature.printMTF, 0)
        XCTAssertEqual(invocation(paper: .negative).featureMask
                        & FilmEngineFeature.printMTF, 0)
        XCTAssertEqual(invocation(paper: .ektacolorEdge, viewing: .lightBox).featureMask
                        & FilmEngineFeature.printMTF, 0)

        var options = FotufilmEngine.Options()
        options.format = FilmFormat(name: "print bench", frameHeightMM: Self.frameMM)
        let slide = FilmEngineInvocation(stock: TestStocks.reversal, options: options,
                                        width: Self.side, height: Self.side)
        XCTAssertEqual(slide.featureMask & FilmEngineFeature.printMTF, 0)
    }

    private func correlationAtTwoPixels(paper: PrintPaper) -> Double {
        var options = FotufilmEngine.Options()
        options.format = FilmFormat(name: "print bench", frameHeightMM: Self.frameMM)
        options.paper = paper
        options.halationScale = 0
        options.couplerScale = 0
        options.seed = 0x46494C4D
        var image = ImageBuffer(width: Self.side, height: Self.side)
        for c in 0..<3 {
            for i in 0..<image.pixelCount { image.planes[c][i] = 0.18 }
        }
        let values = FotufilmEngine(stock: Self.stock, options: options)
            .process(linearRGB: image).planes[1]
        let mean = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        var variance = 0.0, lagged = 0.0, pairs = 0.0
        for y in 0..<Self.side {
            for x in 0..<Self.side {
                let here = Double(values[y * Self.side + x]) - mean
                variance += here * here
                guard x + 2 < Self.side else { continue }
                lagged += here * (Double(values[y * Self.side + x + 2]) - mean)
                pairs += 1
            }
        }
        variance /= Double(values.count)
        lagged /= pairs
        guard variance > 0 else { return 0 }
        return lagged / variance
    }

    func testPrintedGrainIsWiderThanTheNegativesOwn() throws {
        try requireEngine()
        let screen = correlationAtTwoPixels(paper: .screen)
        let paper = correlationAtTwoPixels(paper: .ektacolorEdge)
        XCTAssertGreaterThan(paper, screen + 0.2,
                             "paper grain correlates \(paper) at two pixels and the "
                                 + "screen's \(screen); the enlarger did not spread it")
    }

    func testTheKeptShareIsThePapersOwn() {
        for paper in [PrintPaper.ektacolorEdge, .crystalArchive, .vision2383, .labScan,
                      .telecine] {
            let inv = invocation(paper: paper)
            XCTAssertEqual(inv.configuration[FilmEngineInvocation.printSharpenOffset],
                           paper.scanSharpening, accuracy: 1e-6, paper.name)
        }
        XCTAssertEqual(invocation(paper: .screen)
                        .configuration[FilmEngineInvocation.printSharpenOffset], 0)
    }

    func testScanFinishKeepsTheGrainItsApertureSpreads() throws {
        try requireEngine()
        let scan = correlationAtTwoPixels(paper: .labScan)
        let paper = correlationAtTwoPixels(paper: .ektacolorEdge)
        XCTAssertLessThan(scan, paper - 0.1,
                          "the scan finish correlates \(scan) at two pixels against the "
                              + "enlarger paper's \(paper); the minilab's sharpening is not "
                              + "reaching the print")
    }

    func testTheSpreadIsTakenOnLightRatherThanOnDensity() throws {
        try requireEngine()
        func printedMean(grain: Float) -> Double {
            var options = FotufilmEngine.Options()
            options.format = FilmFormat(name: "print bench", frameHeightMM: Self.frameMM)
            options.halationScale = 0
            options.couplerScale = 0
            options.grainScale = grain
            options.seed = 0x46494C4D
            var image = ImageBuffer(width: Self.side, height: Self.side)
            for c in 0..<3 {
                for i in 0..<image.pixelCount { image.planes[c][i] = 0.18 }
            }
            let values = FotufilmEngine(stock: Self.stock, options: options)
                .process(linearRGB: image).planes[1]
            return values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        }
        let grained = printedMean(grain: 1)
        let clean = printedMean(grain: 0)
        XCTAssertLessThan(grained, clean,
                          "a grainy negative averaged in the light domain has to print "
                              + "down; got \(grained) against \(clean), which is where "
                              + "blurring density itself would have left it")
        XCTAssertGreaterThan(clean - grained, 1e-4,
                             "and measurably down, or the blur is not being taken in the "
                                 + "light domain at all")
        XCTAssertLessThan(clean - grained, 0.05 * clean,
                          "the asymmetry is second order in the grain, not a shift")
    }
}
