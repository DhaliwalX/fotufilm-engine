import XCTest
@testable import FotufilmCore

final class HDRDeliveryPolicyTests: XCTestCase {
    func testDigitalReferenceAllowsHDRForReversalFilm() {
        XCTAssertTrue(PrintPaper.screen.supportsHDRDelivery(for: TestStocks.reversal))
    }

    func testDigitalReferenceDisablesHDRForColourAndMonochromeNegatives() {
        XCTAssertFalse(PrintPaper.screen.supportsHDRDelivery(for: TestStocks.negative))
        XCTAssertFalse(PrintPaper.screen.supportsHDRDelivery(for: TestStocks.monochrome))
    }

    func testPhysicalMediumDisablesHDREvenForReversalFilm() {
        XCTAssertFalse(PrintPaper.ektacolorEdge.supportsHDRDelivery(
            for: TestStocks.reversal))
    }
}
