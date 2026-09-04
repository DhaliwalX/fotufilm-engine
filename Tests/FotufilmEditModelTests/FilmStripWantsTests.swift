import XCTest
@testable import FotufilmEditModel

final class FilmStripWantsTests: XCTestCase {

    func testTheVisibleRunComesFirstAndThenFiveMoreAlternatingOutward() {
        XCTAssertEqual(FilmStripWants.indices(visible: 10..<14, of: 235),
                       [10, 11, 12, 13, 14, 9, 15, 8, 16])
    }

    func testNeverMoreThanTheVisibleRunPlusTheAllowance() {
        for beyond in 0...7 {
            let run = FilmStripWants.indices(visible: 20..<26, of: 235, beyond: beyond)
            XCTAssertEqual(run.count, 6 + beyond, "beyond \(beyond)")
            XCTAssertEqual(Set(run).count, run.count, "no tile is asked for twice")
        }
    }

    func testAtTheStartOfTheRunEverythingExtraComesAfter() {
        XCTAssertEqual(FilmStripWants.indices(visible: 0..<4, of: 235),
                       [0, 1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testAtTheEndOfTheRunEverythingExtraComesBefore() {
        XCTAssertEqual(FilmStripWants.indices(visible: 231..<235, of: 235),
                       [231, 232, 233, 234, 230, 229, 228, 227, 226])
    }

    func testAShortRunIsNeverOverrun() {
        XCTAssertEqual(FilmStripWants.indices(visible: 0..<3, of: 3), [0, 1, 2])
        XCTAssertEqual(FilmStripWants.indices(visible: 1..<2, of: 4), [1, 2, 0, 3])
        XCTAssertEqual(FilmStripWants.indices(visible: 0..<0, of: 0), [])
    }

    func testAVisibleRangePastTheEndIsClamped() {
        XCTAssertEqual(FilmStripWants.indices(visible: 230..<300, of: 235),
                       [230, 231, 232, 233, 234, 229, 228, 227, 226, 225])
        XCTAssertEqual(FilmStripWants.indices(visible: -5..<2, of: 235, beyond: 2),
                       [0, 1, 2, 3])
    }
}
