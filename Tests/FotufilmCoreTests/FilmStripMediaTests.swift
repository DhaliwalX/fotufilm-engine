import XCTest
@testable import FotufilmCore

/// The run of media a film strip shows for one film on its gauge: what
/// `PrintPaper.stripChoices(for:gauge:)` answers, which the editor's strip multiplies out over the
/// pack into its tile count.
final class FilmStripMediaTests: XCTestCase {

    private static var kodakCine: FilmStock {
        var cine = TestStocks.negative
        cine.nativePrintMedium = .vision2383
        return cine
    }

    private static var fujiCine: FilmStock {
        var cine = TestStocks.negative
        cine.nativePrintMedium = .eternaCP
        return cine
    }

    func testAStillNegativeGetsItsTwoPapersAndTheDisplayByDefault() {
        XCTAssertEqual(PrintPaper.stripChoices(for: TestStocks.negative, gauge: .still35),
                       [.ektacolorEdge, .crystalArchive, .screen])
        XCTAssertEqual(PrintPaper.stripChoices(for: TestStocks.negative,
                                               gauge: .mediumFormat120),
                       [.ektacolorEdge, .crystalArchive, .screen])
    }

    func testEnduraMatchedStillFilmsGetEnduraOnTheStrip() {
        let names = ["Portra 400", "Portra 160", "Ektar 100", "Gold 200", "UltraMax 400", "PRO 400H"]
        for name in names {
            var stock = TestStocks.negative
            stock.name = name
            XCTAssertEqual(PrintPaper.stripChoices(for: stock, gauge: .still35),
                           [.ektacolorEdge, .enduraPremier, .crystalArchive, .screen],
                           "\(name) on still strip")
        }
    }

    func testAKodakMotionNegativeGetsBothKodakReleasePrintsThenTelecine() {
        XCTAssertEqual(PrintPaper.stripChoices(for: Self.kodakCine, gauge: .super35),
                       [.vision2383, .vision2393, .telecine, .screen])
        var premier = Self.kodakCine
        premier.nativePrintMedium = .vision2393
        XCTAssertEqual(PrintPaper.stripChoices(for: premier, gauge: .super35),
                       [.vision2393, .vision2383, .telecine, .screen],
                       "the print the film was made for leads")
    }

    func testAFujiMotionNegativeGetsEternaCPAlone() {
        XCTAssertEqual(PrintPaper.stripChoices(for: Self.fujiCine, gauge: .super35),
                       [.eternaCP, .telecine, .screen])
    }

    func testACineStockNamingNoPrintIsStillACineStock() {
        // Double-X: a motion-picture gauge, no release print on its sheet. It is printed on
        // release stock and transferred to video, not printed on colour paper.
        for gauge in [FilmFormat.super35, .sixteenMM, .super8] {
            XCTAssertEqual(PrintPaper.stripChoices(for: TestStocks.monochrome, gauge: gauge),
                           [.vision2383, .vision2393, .telecine, .screen],
                           gauge.name)
        }
    }

    func testTelecineOnlyWhereTheGaugeIsMotionPicture() {
        for stock in [TestStocks.negative, Self.kodakCine, Self.fujiCine,
                      TestStocks.monochrome] {
            XCTAssertTrue(PrintPaper.stripChoices(for: stock, gauge: .super35)
                              .contains(.telecine), stock.name)
            XCTAssertFalse(PrintPaper.stripChoices(for: stock, gauge: .still35)
                               .contains(.telecine), stock.name)
        }
    }

    func testNoMotionPictureNegativeIsOfferedPhotoPaper() {
        for stock in [TestStocks.negative, Self.kodakCine, Self.fujiCine,
                      TestStocks.monochrome] {
            let run = PrintPaper.stripChoices(for: stock, gauge: .super35)
            XCTAssertFalse(run.contains(.ektacolorEdge), stock.name)
            XCTAssertFalse(run.contains(.enduraPremier), stock.name)
            XCTAssertFalse(run.contains(.crystalArchive), stock.name)
        }
    }

    func testTheLabScanAndTheLightBoxAreNeverOnTheStrip() {
        for stock in [TestStocks.negative, Self.kodakCine, TestStocks.monochrome,
                      TestStocks.reversal] {
            for gauge in [FilmFormat.still35, .super35] {
                let run = PrintPaper.stripChoices(for: stock, gauge: gauge)
                XCTAssertFalse(run.contains(.labScan), stock.name)
                XCTAssertFalse(run.contains(.negative), stock.name)
                XCTAssertEqual(Set(run).count, run.count, "\(stock.name): each medium once")
                XCTAssertEqual(run.last, .screen, "\(stock.name) ends on the display")
            }
        }
    }

    func testAReversalHasItsOneDirectPositiveOnAnyGauge() {
        XCTAssertEqual(PrintPaper.stripChoices(for: TestStocks.reversal, gauge: .still35),
                       [.screen])
        XCTAssertEqual(PrintPaper.stripChoices(for: TestStocks.reversal, gauge: .super35),
                       [.screen])
    }

    func testTheMotionPictureGaugesAreTheCineOnes() {
        XCTAssertEqual(FilmFormat.presets.filter { $0.format.isMotionPicture }.map(\.id),
                       ["super8", "16mm", "super35"])
    }

    func testTheStripCountIsTheSumOverTheFilms() {
        let films: [(FilmStock, FilmFormat)] = [
            (TestStocks.negative, .still35), (Self.kodakCine, .super35),
            (Self.fujiCine, .super35), (TestStocks.monochrome, .super35),
            (TestStocks.reversal, .still35),
        ]
        let count = films.reduce(0) {
            $0 + PrintPaper.stripChoices(for: $1.0, gauge: $1.1).count
        }
        XCTAssertEqual(count, 3 + 4 + 3 + 4 + 1)
    }
}
