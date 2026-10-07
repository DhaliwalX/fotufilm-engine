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
        let printer = try XCTUnwrap(timed.printer)
        // A brighter print takes less light on negative paper, a third of a stop per stop.
        XCTAssertEqual(try XCTUnwrap(brighter.printer).exposureEV, printer.exposureEV - 1.0 / 3,
                       accuracy: 1e-5)
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

    func testAScanTakesExposureAndFinishesColourAfterThePrint() throws {
        let stock = try NegativeScanPrint.film("gold200")
        for paper in [PrintPaper.screen, .labScan] {
            let options = NegativeScanPrint.printing(edit(paper, ev: 0.5, kelvin: 4500),
                                                     stock: stock, highlightStops: 1)
            XCTAssertEqual(options.screenExposureEV, 0.5)
            XCTAssertGreaterThan(options.printFinish.gains.x, 1)
            XCTAssertEqual(options.printFinish.gains.y, 1)
            XCTAssertLessThan(options.printFinish.gains.z, 1)
        }
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
        XCTAssertEqual(options.printFinish.gains, .one)
    }
}
