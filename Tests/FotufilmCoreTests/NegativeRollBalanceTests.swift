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

    func testARollIsTheMiddleOfWhatItsFramesMeasure() throws {
        typealias Measure = ApproximateNegativeScan.RollBalance.Measure
        let pair = try XCTUnwrap(ApproximateNegativeScan.RollBalance(measures: [
            Measure(denseEnd: SIMD3(1, 1, 1)), Measure(denseEnd: SIMD3(2, 1, 3)),
        ]))
        XCTAssertEqual(pair.colour, [1.5, 2])
        XCTAssertEqual(pair.frames, 2)
        XCTAssertEqual(pair.level, 1)
        XCTAssertNil(pair.slopes)
        // Frames that cannot be read are left out; fewer than two leave no roll.
        XCTAssertNil(ApproximateNegativeScan.RollBalance(measures: [Measure(denseEnd: SIMD3(1, 1, 1))]))
        XCTAssertNil(ApproximateNegativeScan.RollBalance(measures: [
            Measure(denseEnd: SIMD3(1, 1, 1)), Measure(denseEnd: SIMD3(1, 0.01, 1)),
            Measure(denseEnd: SIMD3(.nan, 1, 1)), Measure(),
        ]))
        // One frame filled by a colour moves the middle little.
        var measures = (0..<7).map { i in
            Measure(denseEnd: SIMD3(0.9, 1, 1.2) * (1 + 0.1 * Float(i)),
                    slopes: SIMD2(0.6 + 0.01 * Float(i), 1.1))
        }
        measures[3] = Measure(denseEnd: SIMD3(2.4, 1, 0.3), slopes: SIMD2(3, 0.2))
        let roll = try XCTUnwrap(ApproximateNegativeScan.RollBalance(measures: measures))
        XCTAssertEqual(roll.colour[0], 0.9, accuracy: 1e-5)
        XCTAssertEqual(roll.colour[1], 1.2, accuracy: 1e-5)
        XCTAssertEqual(roll.frames, 7)
        XCTAssertEqual(try XCTUnwrap(roll.level), 1.2, accuracy: 0.11)
        XCTAssertEqual(try XCTUnwrap(roll.slopes)[0], 0.64, accuracy: 0.011)
        XCTAssertEqual(try XCTUnwrap(roll.slopes)[1], 1.1, accuracy: 1e-5)
        // Contrast waits for enough frames with tonal steps.
        let few = try XCTUnwrap(ApproximateNegativeScan.RollBalance(
            measures: Array(measures.prefix(ApproximateNegativeScan.RollBalance.contrastFrames - 1))))
        XCTAssertNil(few.slopes)
        XCTAssertNotNil(few.level)
    }

    func testARollKeepsItsLevelAndSlopes() throws {
        let kept = ApproximateNegativeScan.RollBalance(colour: [0.9, 1.2], frames: 8, level: 1.3,
                                                      slopes: [0.62, 1.15])
        let decoded = try JSONDecoder().decode(ApproximateNegativeScan.RollBalance.self,
                                               from: JSONEncoder().encode(kept))
        XCTAssertEqual(decoded, kept)
        // A roll kept before them reads back without them, and writes none.
        let json = String(decoding: try JSONEncoder().encode(roll), as: UTF8.self)
        XCTAssertFalse(json.contains("level"))
        XCTAssertFalse(json.contains("slopes"))
        for bad in [#"{"colour":[0.9,1.2],"frames":4,"level":0}"#,
                    #"{"colour":[0.9,1.2],"frames":4,"slopes":[0.6]}"#,
                    #"{"colour":[0.9,1.2],"frames":4,"slopes":[0.6,-1]}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(
                ApproximateNegativeScan.RollBalance.self, from: Data(bad.utf8)), bad)
        }
    }
}
