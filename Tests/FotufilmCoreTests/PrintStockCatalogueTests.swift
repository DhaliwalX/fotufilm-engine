import XCTest
@testable import FotufilmCore

/// Checks every print stock against the rules its process implies, so a new stock is offered,
/// timed and viewed like the rest of its family without further wiring.
final class PrintStockCatalogueTests: XCTestCase {
    private static let printed = PrintPaper.allCases.filter { $0.printStock != nil }

    func testEveryStockStatesCompleteFiniteSheetData() throws {
        for paper in Self.printed {
            let stock = try XCTUnwrap(paper.printStock)
            XCTAssertFalse(stock.name.isEmpty, paper.id)
            XCTAssertFalse(stock.detail.isEmpty, paper.id)
            XCTAssertEqual(stock.curves.count, 3, paper.id)
            for curve in stock.curves {
                XCTAssertGreaterThan(curve.dMax, curve.dMin, paper.id)
            }
            let spectra = stock.spectra
            for table in [spectra.dyes, spectra.analyticalDyes, spectra.sensitivity] {
                XCTAssertEqual(table.count, 3, paper.id)
                for record in table {
                    XCTAssertEqual(record.count, SpectralGrid.count, paper.id)
                    XCTAssertTrue(record.allSatisfy { $0.isFinite && $0 >= 0 }, paper.id)
                    XCTAssertGreaterThan(record.max() ?? 0, 0, paper.id)
                }
            }
        }
    }

    func testNamesAreUnique() {
        let names = PrintPaper.allCases.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testReleaseAimsSitInsideEachRecord() throws {
        for paper in PrintPaper.media(printedBy: .releasePrintFilm) {
            let stock = try XCTUnwrap(paper.printStock)
            let aim = try XCTUnwrap(stock.releaseSetup?.ladStatusA, paper.id)
            for (record, curve) in stock.curves.enumerated() {
                XCTAssertGreaterThan(aim[record], curve.dMin, paper.id)
                XCTAssertLessThan(aim[record], curve.dMax, paper.id)
            }
        }
    }

    func testProcessDecidesWhereAStockIsOffered() {
        let negative = TestStocks.negative
        let reversal = TestStocks.reversal
        for paper in Self.printed {
            let process = paper.printProcess!
            XCTAssertEqual(PrintPaper.choices(for: reversal).contains(paper), process.printsReversal,
                           paper.id)
            XCTAssertEqual(PrintPaper.choices(for: negative).contains(paper), !process.printsReversal,
                           paper.id)
            let still = PrintPaper.stripChoices(for: negative, gauge: .still35)
            let motion = PrintPaper.stripChoices(for: negative, gauge: .super35)
            let slide = PrintPaper.stripChoices(for: reversal, gauge: .still35)
            XCTAssertEqual(still.contains(paper), process == .photoPaper, paper.id)
            XCTAssertEqual(motion.contains(paper), process == .releasePrintFilm, paper.id)
            XCTAssertEqual(slide.contains(paper), process == .positivePaper, paper.id)
        }
    }

    func testProcessDecidesHowAStockIsViewed() {
        for paper in Self.printed {
            let process = paper.printProcess!
            XCTAssertTrue(paper.acceptsViewingIlluminant, paper.id)
            XCTAssertEqual(paper.isProjected, process.isProjected, paper.id)
            XCTAssertEqual(paper.isPositivePaper, process.isPositiveWorking, paper.id)
            XCTAssertEqual(paper.enlargerBlurMM, process.enlargerBlurMM, paper.id)
            XCTAssertEqual(paper.ladStatusA != nil, process.isProjected, paper.id)
            XCTAssertEqual(paper.frameBaseRGB(viewingKelvin: nil) != nil, process.isReflection,
                           paper.id)
            let trim = SpectralRuntime.reflectionPrintDensityTrim(for: paper)
            XCTAssertEqual(trim != .zero, process.isReflection, paper.id)
        }
    }

    func testOutputsWithoutAMaterialAreNotPrintStocks() {
        for paper in [PrintPaper.labScan, .telecine, .screen, .negative] {
            XCTAssertNil(paper.printStock, paper.id)
            XCTAssertFalse(paper.acceptsViewingIlluminant, paper.id)
        }
    }
}
