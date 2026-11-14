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

    /// A roll's neutral is the average its frames come to, not the colour of their brightest
    /// things: one frame filled by a colour moves it little, and a roll kept before it balanced
    /// on its densest ends still does.
    func testARollIsBalancedOnTheAverageItsFramesComeTo() throws {
        typealias Measure = ApproximateNegativeScan.RollBalance.Measure
        var measures = (0..<7).map { i in
            Measure(denseEnd: SIMD3(1.4, 1.5, 1.7),
                    average: SIMD3(0.52, 0.6, 0.71) + SIMD3(repeating: 0.05 * Float(i - 3)))
        }
        // A sunset: red through the roof, and a white wall lit by it as its densest end.
        measures[2] = Measure(denseEnd: SIMD3(2.4, 1.5, 0.6), average: SIMD3(1.3, 0.7, 0.3))
        let roll = try XCTUnwrap(ApproximateNegativeScan.RollBalance(measures: measures))
        let average = try XCTUnwrap(roll.average)
        XCTAssertEqual(average[1], 0.6, accuracy: 0.051)
        XCTAssertEqual(average[0] - average[1], -0.08, accuracy: 1e-5)
        XCTAssertEqual(average[2] - average[1], 0.11, accuracy: 1e-5)
        XCTAssertEqual(roll.neutral(green: 2), SIMD3(average[0], average[1], average[2]))
        // Fewer than two frames with an average keep the roll on its densest ends.
        let ends = try XCTUnwrap(ApproximateNegativeScan.RollBalance(
            measures: [measures[0], Measure(denseEnd: SIMD3(1.4, 1.5, 1.7))]))
        XCTAssertNil(ends.average)
        XCTAssertEqual(try XCTUnwrap(ends.neutral(green: 2)).y, 1.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(self.roll.neutral(green: 2)).x, 1.8, accuracy: 1e-6)
    }

    /// Exposure moves a scan's clear film up and down, not its colour. A frame that shows no
    /// unexposed film reads its clear film off its picture, off colour, and takes the roll's.
    func testAFramesClearFilmKeepsItsLevelAndTakesItsRollsColour() throws {
        typealias Measure = ApproximateNegativeScan.RollBalance.Measure
        let film = SIMD3<Float>(0.44, 0.2, 0.1)
        var measures = [Float](arrayLiteral: 0.5, 0.8, 1, 1.3, 2).map { exposure in
            Measure(denseEnd: SIMD3(1, 1, 1), clear: film * exposure)
        }
        // Read off a picture: red a sixth of a stop short.
        let off = SIMD3<Float>(0.44 * pow(10, -0.07), 0.2, 0.1) * 1.1
        measures.append(Measure(denseEnd: SIMD3(1, 1, 1), clear: off))
        let roll = try XCTUnwrap(ApproximateNegativeScan.RollBalance(measures: measures))
        let clear = try XCTUnwrap(roll.clear)
        XCTAssertEqual(clear[0], 2.2, accuracy: 1e-4)
        XCTAssertEqual(clear[1], 0.5, accuracy: 1e-4)
        let taken = roll.clearFilm(off)
        XCTAssertEqual(taken.y, off.y)
        XCTAssertEqual(taken.x / taken.y, 2.2, accuracy: 1e-4)
        XCTAssertEqual(taken.z / taken.y, 0.5, accuracy: 1e-4)
        // Another film, or another light, keeps its own; so does a roll kept without a colour.
        let other = SIMD3<Float>(0.2, 0.2, 0.2)
        XCTAssertEqual(roll.clearFilm(other), other)
        XCTAssertEqual(self.roll.clearFilm(off), off)
        // One frame's clear film says nothing of a roll's.
        XCTAssertNil(try XCTUnwrap(ApproximateNegativeScan.RollBalance(measures: [
            Measure(denseEnd: SIMD3(1, 1, 1), clear: film), Measure(denseEnd: SIMD3(1, 1, 1)),
        ])).clear)
    }

    /// Each frame's average is over the clear film it was measured against. The roll takes it
    /// over the clear film it gives the frame, so measuring a roll again changes nothing.
    func testARollTakesEachAverageOverTheClearFilmItGivesTheFrame() throws {
        typealias Measure = ApproximateNegativeScan.RollBalance.Measure
        let film = SIMD3<Float>(0.44, 0.2, 0.1)
        let off = SIMD3<Float>(0.44 * pow(10, -0.07), 0.2, 0.1)
        let average = SIMD3<Float>(0.52, 0.6, 0.71)
        // The frame read off its picture measured red 0.07 thinner than the film's would.
        var first = (0..<4).map { _ in Measure(denseEnd: SIMD3(1, 1, 1), average: average, clear: film) }
        first.append(Measure(denseEnd: SIMD3(1, 1, 1), average: average - SIMD3(0.07, 0, 0), clear: off))
        let roll = try XCTUnwrap(ApproximateNegativeScan.RollBalance(measures: first))
        // Measured again on the roll, that frame is read against the roll's colour of it.
        var again = first
        again[4] = Measure(denseEnd: SIMD3(1, 1, 1), average: average, clear: off,
                           border: roll.clearFilm(off))
        let second = try XCTUnwrap(ApproximateNegativeScan.RollBalance(measures: again))
        for c in 0..<3 {
            XCTAssertEqual(try XCTUnwrap(roll.average)[c], average[c], accuracy: 1e-5)
            XCTAssertEqual(try XCTUnwrap(second.average)[c], average[c], accuracy: 1e-5)
        }
        XCTAssertEqual(second.clear, roll.clear)
    }

    func testARollKeepsItsAverageAndClearFilm() throws {
        let kept = ApproximateNegativeScan.RollBalance(
            colour: [0.9, 1.2], frames: 8, level: 1.3, slopes: [0.62, 1.15],
            average: [0.52, 0.6, 0.71], clear: [2.2, 0.5])
        XCTAssertEqual(try JSONDecoder().decode(ApproximateNegativeScan.RollBalance.self,
                                                from: JSONEncoder().encode(kept)), kept)
        let json = String(decoding: try JSONEncoder().encode(roll), as: UTF8.self)
        XCTAssertFalse(json.contains("average"))
        XCTAssertFalse(json.contains("clear"))
        for bad in [#"{"colour":[0.9,1.2],"frames":4,"average":[0.5,0.6]}"#,
                    #"{"colour":[0.9,1.2],"frames":4,"average":[0.5,0,0.7]}"#,
                    #"{"colour":[0.9,1.2],"frames":4,"clear":[2.2]}"#,
                    #"{"colour":[0.9,1.2],"frames":4,"clear":[2.2,0]}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(
                ApproximateNegativeScan.RollBalance.self, from: Data(bad.utf8)), bad)
        }
    }
}
