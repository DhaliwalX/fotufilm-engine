import XCTest
@testable import FotufilmCore

final class FilmStripMediaTests: XCTestCase {
    func testStillAndMotionGaugesOfferTheirOwnPrintVariants() {
        for stock in [TestStocks.negative, TestStocks.monochrome] {
            for gauge in [FilmFormat.still35, .mediumFormat120] {
                XCTAssertEqual(PrintPaper.stripChoices(for: stock, gauge: gauge),
                               [.photo, .photoContrast, .photoSoft, .screen])
            }
            for gauge in [FilmFormat.super35, .sixteenMM, .super8] {
                XCTAssertEqual(PrintPaper.stripChoices(for: stock, gauge: gauge),
                               [.projection, .projectionContrast, .projectionSoft,
                                .telecine, .screen])
            }
        }
    }

    func testStockNamesDoNotControlWhichPrintsAreAvailable() {
        var stock = TestStocks.negative
        let expected = PrintPaper.stripChoices(for: stock, gauge: .still35)
        for name in ["Gold 200", "Portrait", "My custom film"] {
            stock.name = name
            XCTAssertEqual(PrintPaper.stripChoices(for: stock, gauge: .still35), expected)
        }
    }

    func testNativeMediumLeadsOnlyWhenItBelongsToTheGauge() {
        var stock = TestStocks.negative
        stock.nativePrintMedium = .projectionSoft
        XCTAssertEqual(PrintPaper.stripChoices(for: stock, gauge: .super35),
                       [.projectionSoft, .projection, .projectionContrast, .telecine, .screen])
        XCTAssertEqual(PrintPaper.stripChoices(for: stock, gauge: .still35),
                       [.photo, .photoContrast, .photoSoft, .screen])
        stock.nativePrintMedium = .photoContrast
        XCTAssertEqual(PrintPaper.stripChoices(for: stock, gauge: .still35),
                       [.photoContrast, .photo, .photoSoft, .screen])
    }

    func testStripsAreUniqueAndEndOnTheDisplay() {
        for stock in [TestStocks.negative, TestStocks.monochrome, TestStocks.reversal] {
            for gauge in FilmFormat.presets.map(\.format) {
                let media = PrintPaper.stripChoices(for: stock, gauge: gauge)
                XCTAssertEqual(Set(media).count, media.count)
                XCTAssertEqual(media.last, .screen)
                XCTAssertFalse(media.contains(.labScan))
                XCTAssertFalse(media.contains(.negative))
            }
        }
    }

    func testReversalUsesItsDirectPositiveOnEveryGauge() {
        for gauge in FilmFormat.presets.map(\.format) {
            XCTAssertEqual(PrintPaper.stripChoices(for: TestStocks.reversal, gauge: gauge), [.screen])
        }
    }
}
