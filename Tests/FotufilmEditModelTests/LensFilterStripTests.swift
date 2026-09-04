import XCTest
@testable import FotufilmEditModel

final class LensFilterStripTests: XCTestCase {

    func testAFilterNotOnTheLensGoesOnBehindTheStack() {
        XCTAssertEqual(LensFilterStrip.toggled(["w85b"], tile: "w80a"), ["w85b", "w80a"])
        XCTAssertEqual(LensFilterStrip.toggled([], tile: "w85b"), ["w85b"])
    }

    func testAFilterOnTheLensComesOffAgainFromTheBack() {
        XCTAssertEqual(LensFilterStrip.toggled(["w85b", "w80a"], tile: "w85b"), ["w80a"])
        XCTAssertEqual(LensFilterStrip.toggled(["w82c", "w85b", "w82c"], tile: "w82c"),
                       ["w82c", "w85b"])
    }

    func testBareGlassTakesTheWholeStackOff() {
        XCTAssertEqual(LensFilterStrip.toggled(["w85b", "w80a"], tile: nil), [])
        XCTAssertEqual(LensFilterStrip.toggled([], tile: nil), [])
    }

    func testTheChosenTilesAreTheStackOrBareGlassWhenThereIsNone() {
        XCTAssertTrue(LensFilterStrip.isFitted(nil, in: []))
        XCTAssertFalse(LensFilterStrip.isFitted(nil, in: ["w85b"]))
        XCTAssertTrue(LensFilterStrip.isFitted("w85b", in: ["w80a", "w85b"]))
        XCTAssertFalse(LensFilterStrip.isFitted("w80a", in: ["w85b"]))
    }
}
