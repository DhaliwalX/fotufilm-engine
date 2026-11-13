import XCTest
import FotufilmCore
@testable import FotufilmEditModel

/// A scanned negative's light controls land on what makes its print.
final class NegativeScanPrintTests: XCTestCase {
    private func edit(_ paper: PrintPaper, ev: Float = 0, kelvin: Float = WhiteBalance.neutralKelvin)
        -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.paper = paper
        options.exposureEV = ev
        options.whiteBalance.kelvin = kelvin
        options.highlights = -0.4
        options.shadows = 0.3
        options.saturation = 1.2
        options.vibrance = 0.1
        return options
    }

    func testAnEnlargerTakesExposureAndWarmthAsItsOwnLightAndFiltration() throws {
        let stock = try NegativeScanPrint.film("gold200")
        let timed = NegativeScanPrint.printing(edit(.crystalArchive), stock: stock, highlightStops: 1)
        let brighter = NegativeScanPrint.printing(edit(.crystalArchive, ev: 1), stock: stock,
                                                  highlightStops: 1)
        let warmer = NegativeScanPrint.printing(edit(.crystalArchive, kelvin: 4500), stock: stock,
                                                highlightStops: 1)
        let enduraTimed = NegativeScanPrint.printing(edit(.enduraPremier), stock: stock, highlightStops: 1)
        let enduraBrighter = NegativeScanPrint.printing(edit(.enduraPremier, ev: 1), stock: stock,
                                                        highlightStops: 1)
        let printer = try XCTUnwrap(timed.printer)
        let brighterPrinter = try XCTUnwrap(brighter.printer)
        // A brighter print takes less light on negative paper, calibrated to each paper's own curve.
        XCTAssertLessThan(brighterPrinter.exposureEV, printer.exposureEV - 0.25)
        XCTAssertGreaterThan(brighterPrinter.exposureEV, printer.exposureEV - 0.5)
        let crystalStep = brighterPrinter.exposureEV - printer.exposureEV
        let enduraStep = try (XCTUnwrap(enduraBrighter.printer).exposureEV
            - XCTUnwrap(enduraTimed.printer).exposureEV)
        XCTAssertNotEqual(crystalStep, enduraStep, accuracy: 1e-3,
                          "each paper solves exposure against its own contrast curve")
        // A warmer print takes yellow filtration away.
        XCTAssertLessThan(try XCTUnwrap(warmer.printer).yellow, printer.yellow - 0.02)
        for options in [timed, brighter, warmer] {
            XCTAssertEqual(options.printFinish.gains, .one)
            XCTAssertEqual(options.printFinish.highlights, -0.4)
            XCTAssertEqual(options.printFinish.shadows, 0.3)
            XCTAssertEqual(options.printFinish.saturation, 1.2)
            XCTAssertEqual(options.printFinish.vibrance, 0.1)
            // The scene they would otherwise shape is not in the print span.
            XCTAssertEqual(options.exposureEV, 0)
            XCTAssertEqual(options.highlights, 0)
            XCTAssertEqual(options.saturation, 1)
            XCTAssertTrue(options.whiteBalance.isNeutral)
        }
    }

    func testDigitalReferenceLabScanAndReleasePrintsRouteColourPreCurve() throws {
        let stock = try NegativeScanPrint.film("gold200")
        for paper in [PrintPaper.screen, .labScan] {
            let options = NegativeScanPrint.printing(edit(paper, ev: 0.5, kelvin: 4500),
                                                     stock: stock, highlightStops: 1)
            XCTAssertEqual(options.screenExposureEV, 0.5)
            // Warming before the positive curve removes cyan (adds red) and adds yellow (reduces blue),
            // leaving post-curve gains untouched so highlights roll off smoothly and shadows stay untinted.
            XCTAssertLessThan(options.screenCMY.x, -0.05, paper.rawValue)
            XCTAssertGreaterThan(options.screenCMY.z, 0.05, paper.rawValue)
            XCTAssertEqual(options.printFinish.gains, .one, paper.rawValue)
        }
        let cinema = try NegativeScanPrint.film("vision250d")
        let release = NegativeScanPrint.printing(edit(.vision2383, ev: 1, kelvin: 4500),
                                                 stock: cinema, highlightStops: 1)
        // Brightening a release print lowers printer lights; warming lowers red more than blue.
        XCTAssertLessThan(release.printerLights.green, PrinterLights.centre - 2)
        XCTAssertLessThan(release.printerLights.red, release.printerLights.blue - 2)
        XCTAssertEqual(release.printFinish.gains, .one)

        let telecine = NegativeScanPrint.printing(edit(.telecine, ev: 1), stock: stock,
                                                  highlightStops: 1)
        XCTAssertEqual(telecine.printFinish.gains, SIMD3(repeating: 2))
    }

    func testABlackAndWhitePrintTakesNoColour() throws {
        let stock = try NegativeScanPrint.film(XCTUnwrap(NegativeScanPrint.filmIDs.first {
            FilmStock.presets[$0]?.isMonochrome == true
        }))
        let options = NegativeScanPrint.printing(edit(.screen, kelvin: 3000), stock: stock,
                                                 highlightStops: 1)
        XCTAssertEqual(options.screenCMY, .zero)
        XCTAssertEqual(options.printFinish.gains, .one)
    }
}
