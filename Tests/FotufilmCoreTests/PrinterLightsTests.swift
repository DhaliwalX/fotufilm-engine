import XCTest
@testable import FotufilmCore

final class PrinterLightsTests: XCTestCase {
    private let prints: [PrintPaper] = PrintPaper.media(printedBy: .releasePrintFilm)

    /// The energy each print record receives at the negative's mid-grey, in log exposure
    /// against the aim setup's reference.
    private func midShift(_ lights: PrinterLights, stock: FilmStock,
                          paper: PrintPaper) -> SIMD3<Float> {
        let density = stock.curves.map { $0.density(logExposure: 0) }
        let illumination = SpectralRuntime.printingIllumination(stock: stock, paper: paper,
            density: density, dyes: stock.spectralProfile.imageDyeDensity, lights: lights)
        let energy = SpectralRuntime.paperExposure(density: density, stock: stock,
            lamp: illumination.lamp, paperSensitivity: paper.sensitivity)
        return SIMD3((0..<3).map {
            log10(energy[$0] / illumination.referenceEnergy[$0]) })
    }

    func testAimSetupKeepsEveryUntimedPrint() throws {
        let stock = try XCTUnwrap(FilmStock.named("vision250d"))
        for paper in prints {
            XCTAssertNil(PrinterLights.resolved(.balanced, stock: stock, paper: paper))
            XCTAssertEqual(
                SpectralRuntime.cacheIdentifier(for: stock, paper: paper, printerLights: .balanced),
                SpectralRuntime.cacheIdentifier(for: stock, paper: paper))
            let shift = midShift(.balanced, stock: stock, paper: paper)
            for channel in 0..<3 { XCTAssertEqual(shift[channel], 0, accuracy: 1e-5) }
        }
    }

    func testLightsReachOnlyANegativePrintedOntoCinemaPrintFilm() throws {
        let negative = try XCTUnwrap(FilmStock.named("vision250d"))
        let slide = try XCTUnwrap(FilmStock.named("provia100f"))
        let timed = PrinterLights(red: 31, green: 25, blue: 25)
        XCTAssertNotNil(PrinterLights.resolved(timed, stock: negative, paper: .vision2383))
        XCTAssertNil(PrinterLights.resolved(timed, stock: slide, paper: .vision2383))
        for paper in [PrintPaper.ektacolorEdge, .screen, .labScan] {
            XCTAssertNil(PrinterLights.resolved(timed, stock: negative, paper: paper))
            XCTAssertEqual(
                SpectralRuntime.cacheIdentifier(for: negative, paper: paper, printerLights: timed),
                SpectralRuntime.cacheIdentifier(for: negative, paper: paper), "\(paper)")
        }
        XCTAssertNotEqual(
            SpectralRuntime.cacheIdentifier(for: negative, paper: .vision2383, printerLights: timed),
            SpectralRuntime.cacheIdentifier(for: negative, paper: .vision2383))
    }

    func testEachPointIsAFortiethOfALogExposureOnItsOwnBeam() throws {
        for id in ["vision250d", "vision500t", "gold200"] {
            let stock = try XCTUnwrap(FilmStock.named(id))
            for paper in prints {
                for channel in 0..<3 {
                    var lights = PrinterLights.balanced
                    lights[channel] += 8
                    let shift = midShift(lights, stock: stock, paper: paper)
                    // A beam reaches mostly its own layer, which takes nearly the whole 0.2 log
                    // exposure; a layer that also takes light from a neighbouring beam takes
                    // less (2383's blue layer sees some of the green beam, and CP30's, whose
                    // measured sensitivity reaches furthest into the green, sees the most), and
                    // that crosstalk moves its neighbour with the light.
                    XCTAssertEqual(shift[channel], 0.2, accuracy: 0.03, "\(id) \(paper) \(channel)")
                    XCTAssertLessThanOrEqual(shift[channel], 0.2 + 1e-5)
                    for other in 0..<3 where other != channel {
                        XCTAssertGreaterThanOrEqual(shift[other], -1e-6, "\(id) \(paper)")
                        XCTAssertLessThan(shift[other], 0.05, "\(id) \(paper) \(channel)->\(other)")
                    }
                }
                // All three lights together are a plain density change.
                let all = midShift(PrinterLights(red: 37, green: 37, blue: 37),
                                   stock: stock, paper: paper)
                for channel in 0..<3 { XCTAssertEqual(all[channel], 0.3, accuracy: 1e-4) }
            }
        }
    }

    func testMoreRedLightPrintsCyan() throws {
        var stock = try XCTUnwrap(FilmStock.named("vision250d"))
        stock.flare = 0
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.halationScale = 0
        options.couplerScale = 0
        options.localTone = false
        options.paper = .vision2383
        var scene = ImageBuffer(width: 8, height: 8)
        for channel in 0..<3 { scene.planes[channel] = [Float](repeating: 0.18, count: 64) }
        func printed(_ lights: PrinterLights) -> SIMD3<Float> {
            options.printerLights = lights
            let out = FotufilmEngine(stock: stock, options: options).process(linearRGB: scene)
            return SIMD3(out.planes[0][27], out.planes[1][27], out.planes[2][27])
        }
        let aim = printed(.balanced)
        let red = printed(PrinterLights(red: 37, green: 25, blue: 25))
        XCTAssertLessThan(red.x / aim.x, 0.8, "more red light adds cyan")
        XCTAssertLessThan(abs(red.y / aim.y - 1), abs(red.x / aim.x - 1))
        let denser = printed(PrinterLights(red: 37, green: 37, blue: 37))
        for channel in 0..<3 { XCTAssertLessThan(denser[channel], aim[channel]) }
        let lighter = printed(PrinterLights(red: 13, green: 13, blue: 13))
        for channel in 0..<3 { XCTAssertGreaterThan(lighter[channel], aim[channel]) }
    }

    func testLightsHoldTheirScale() {
        let wild = PrinterLights(red: 80, green: -3, blue: .nan).normalized
        XCTAssertEqual(wild, PrinterLights(red: 50, green: 1, blue: 25))
    }
}
