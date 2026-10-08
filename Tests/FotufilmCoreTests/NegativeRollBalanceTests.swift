import XCTest
@testable import FotufilmCore

/// A frame read on its roll's colour (`ApproximateNegativeScan.RollBalance`), as the editor keeps it.
final class NegativeRollBalanceTests: XCTestCase {
    private let roll = ApproximateNegativeScan.RollBalance(colour: [0.9, 1.2], frames: 4)

    func testAFrameOnItsRollKeepsItsGreenAndTakesTheRollsColour() throws {
        let rolled = try XCTUnwrap(ApproximateNegativeScan.denseEnd(SIMD3(1.5, 1, 0.6), roll: roll))
        XCTAssertEqual(rolled.x, 0.9, accuracy: 1e-6)
        XCTAssertEqual(rolled.y, 1, accuracy: 1e-6)
        XCTAssertEqual(rolled.z, 1.2, accuracy: 1e-6)
        // Without a roll, or a frame too thin or unreadable, the frame reads as it is.
        XCTAssertEqual(ApproximateNegativeScan.denseEnd(SIMD3(1.5, 1, 0.6), roll: nil), SIMD3(1.5, 1, 0.6))
        XCTAssertEqual(ApproximateNegativeScan.denseEnd(SIMD3(1, 0.01, 1), roll: roll), SIMD3(1, 0.01, 1))
        XCTAssertNil(ApproximateNegativeScan.denseEnd(nil, roll: roll))
    }

    func testARollTimesEachFrameOnItsOwnHighlightsAndBalancesItsColour() throws {
        let stock = try XCTUnwrap(FilmStock.presets["gold200"])
        let own = ApproximateNegativeScan.balance(stock: stock, denseEnd: SIMD3(1.5, 1, 0.6))
        let rolled = ApproximateNegativeScan.balance(
            stock: stock, denseEnd: try XCTUnwrap(ApproximateNegativeScan.denseEnd(SIMD3(1.5, 1, 0.6), roll: roll)))
        // The print is timed on the frame's own green either way.
        XCTAssertEqual(try XCTUnwrap(rolled.highlightStops), try XCTUnwrap(own.highlightStops), accuracy: 1e-6)
        XCTAssertEqual(rolled.gains.y, 1)
        XCTAssertNotEqual(rolled.gains.x, own.gains.x, accuracy: 1e-3)
        // A roll of the frame's own colour is the frame's own balance.
        let same = ApproximateNegativeScan.RollBalance(colour: [1.5, 0.6], frames: 2)
        let unchanged = ApproximateNegativeScan.balance(
            stock: stock, denseEnd: try XCTUnwrap(ApproximateNegativeScan.denseEnd(SIMD3(1.5, 1, 0.6), roll: same)))
        XCTAssertEqual(unchanged, own)
    }

    func testARollIsReadBackOnlyWhenItCanBeUsed() throws {
        let decode = { (json: String) in
            try JSONDecoder().decode(ApproximateNegativeScan.RollBalance.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"colour":[0.9,1.2],"frames":4}"#), roll)
        for bad in [#"{"colour":[0.9],"frames":4}"#, #"{"colour":[0.9,0],"frames":4}"#,
                    #"{"colour":[0.9,-1],"frames":4}"#, #"{"colour":[0.9,1.2],"frames":1}"#] {
            XCTAssertThrowsError(try decode(bad), bad)
        }
    }
}
