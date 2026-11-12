import XCTest
@testable import FotufilmCore

final class NegativeScanDecoderMatrixTests: XCTestCase {
    /// A matrix like a decoder's into wide primaries: every row adds up to one.
    private let matrix: [SIMD3<Float>] = [
        SIMD3(1.18, -0.09, -0.09), SIMD3(-0.04, 1.52, -0.48), SIMD3(0.01, -0.25, 1.24),
    ]

    /// Sensor samples like a negative's: orange film from its clear base to its densest.
    private func sensor(count: Int = 400) -> [SIMD3<Float>] {
        var generator = SplitMix64(seed: 11)
        return (0..<count).map { _ in
            let depth = Float.random(in: 0...1.4, using: &generator)
            let colour = SIMD3<Float>(Float.random(in: -0.15...0.15, using: &generator),
                                      Float.random(in: -0.15...0.15, using: &generator),
                                      Float.random(in: -0.15...0.15, using: &generator))
            let density = depth * SIMD3<Float>(0.7, 1, 1.25) + colour
            return SIMD3(0.5 * pow(10, -density.x), 0.3 * pow(10, -density.y),
                         0.16 * pow(10, -density.z))
        }
    }

    private func decoded(_ sensor: [SIMD3<Float>], balance: SIMD3<Float>,
                         matrix: [SIMD3<Float>]? = nil) -> [SIMD3<Float>] {
        let matrix = matrix ?? self.matrix
        return sensor.map { sample in
            let balanced = sample * balance
            return SIMD3((matrix[0] * balanced).sum(), (matrix[1] * balanced).sum(),
                         (matrix[2] * balanced).sum())
        }
    }

    private func assertEqual(_ found: [SIMD3<Float>]?, _ expected: [SIMD3<Float>],
                             accuracy: Float, file: StaticString = #filePath, line: UInt = #line) {
        guard let found else { return XCTFail("No matrix was recovered.", file: file, line: line) }
        for row in 0..<3 {
            for column in 0..<3 {
                XCTAssertEqual(found[row][column], expected[row][column], accuracy: accuracy,
                               "row \(row) column \(column)", file: file, line: line)
            }
        }
    }

    func testTwoTintsOfOneDecodeShowItsMatrix() {
        let sensor = sensor()
        let before = decoded(sensor, balance: SIMD3(2.1, 1, 1.6))
        let after = decoded(sensor, balance: SIMD3(2.3, 0.86, 1.68))
        assertEqual(NegativeScanDecoderMatrix.recovered(before: before, after: after), matrix,
                    accuracy: 2e-3)
        // The other way round shows the same matrix.
        assertEqual(NegativeScanDecoderMatrix.recovered(before: after, after: before), matrix,
                    accuracy: 2e-3)
    }

    func testAgreeingTintsAreAveragedAndDisagreeingOnesRefused() {
        let sensor = sensor()
        let before = decoded(sensor, balance: SIMD3(2.1, 1, 1.6))
        let greener = decoded(sensor, balance: SIMD3(2.3, 0.86, 1.68))
        let pinker = decoded(sensor, balance: SIMD3(1.9, 1.14, 1.56))
        assertEqual(NegativeScanDecoderMatrix.recovered(before: before, tinted: [greener, pinker]),
                    matrix, accuracy: 2e-3)
        XCTAssertNil(NegativeScanDecoderMatrix.recovered(before: before, tinted: []))
        // A second tint that went through another matrix shows that one, and the two disagree.
        let other: [SIMD3<Float>] = [
            SIMD3(1.02, 0.05, -0.07), SIMD3(-0.07, 1.31, -0.24), SIMD3(0.11, -0.67, 1.56),
        ]
        let columns = (0..<3).map { SIMD3<Double>(Double(other[0][$0]), Double(other[1][$0]),
                                                  Double(other[2][$0])) }
        let strayed = before.map { sample -> SIMD3<Float> in
            let balanced = NegativeScanDecoderMatrix.solve(columns, SIMD3<Double>(sample))!
            let tinted = SIMD3<Float>(balanced) * SIMD3(0.9, 1.14, 0.98)
            return SIMD3((other[0] * tinted).sum(), (other[1] * tinted).sum(),
                         (other[2] * tinted).sum())
        }
        assertEqual(NegativeScanDecoderMatrix.recovered(before: before, after: strayed), other,
                    accuracy: 2e-3)
        XCTAssertNil(NegativeScanDecoderMatrix.recovered(before: before, tinted: [greener, strayed]))
    }

    func testChannelsATintMovesAlikeShowNoMatrix() {
        let sensor = sensor()
        let before = decoded(sensor, balance: SIMD3(2.1, 1, 1.6))
        // The same picture, and one only brighter: every channel's balance changed alike.
        XCTAssertNil(NegativeScanDecoderMatrix.recovered(before: before, after: before))
        XCTAssertNil(NegativeScanDecoderMatrix.recovered(
            before: before, after: decoded(sensor, balance: SIMD3(2.1, 1, 1.6) * 1.2)))
        // Green alone changed: red and blue cannot be told apart.
        XCTAssertNil(NegativeScanDecoderMatrix.recovered(
            before: before, after: decoded(sensor, balance: SIMD3(2.1, 0.8, 1.6))))
    }

    func testAPairThatIsNotOneMatrixUnderTwoBalancesShowsNone() {
        let sensor = sensor()
        let before = decoded(sensor, balance: SIMD3(2.1, 1, 1.6))
        let after = decoded(sensor, balance: SIMD3(2.3, 0.86, 1.68))
        // Too few pixels, and pixels that are not paired.
        XCTAssertNil(NegativeScanDecoderMatrix.recovered(before: Array(before.prefix(20)),
                                                         after: Array(after.prefix(20))))
        XCTAssertNil(NegativeScanDecoderMatrix.recovered(before: before,
                                                         after: Array(after.dropLast())))
        // A tone curve between the two is no linear map.
        XCTAssertNil(NegativeScanDecoderMatrix.recovered(
            before: before, after: after.map { SIMD3(pow($0.x, 0.8), pow($0.y, 0.8), pow($0.z, 0.8)) }))
        // A map that turns the channels into one another has no real balance change.
        let turned = before.map { SIMD3($0.y, $0.z, $0.x) }
        XCTAssertNil(NegativeScanDecoderMatrix.recovered(before: before, after: turned))
        // Clipped samples are left out, which leaves too few here.
        XCTAssertNil(NegativeScanDecoderMatrix.recovered(before: before.map { $0 + 1 },
                                                         after: after.map { $0 + 1 }))
    }

    func testAWhiteAdaptedAfterTheMatrixShowsNone() {
        // The cone space's axes, each to the scale that keeps white: every row adds up to one.
        let adaptation = NegativeScanDecoderMatrix.adaptation
        for row in 0..<3 { XCTAssertEqual(adaptation[row].sum(), 1, accuracy: 1e-5) }
        XCTAssertTrue(NegativeScanDecoderMatrix.plausible(adaptation))
        XCTAssertFalse(NegativeScanDecoderMatrix.adapts(matrix))
        // A decoder that mixes the sensor's channels first and adapts the picture's white in the
        // cone space: two tints of it differ by the cones' gains, whatever its own matrix.
        let columns = (0..<3).map { SIMD3<Double>(Double(adaptation[0][$0]), Double(adaptation[1][$0]),
                                                  Double(adaptation[2][$0])) }
        let mixed = decoded(sensor(), balance: SIMD3(2.1, 1, 1.6))
        func adapted(_ gains: SIMD3<Float>) -> [SIMD3<Float>] {
            mixed.map { sample in
                let cones = SIMD3<Float>(NegativeScanDecoderMatrix.solve(columns, SIMD3<Double>(sample))!)
                    * gains
                return SIMD3((adaptation[0] * cones).sum(), (adaptation[1] * cones).sum(),
                             (adaptation[2] * cones).sum())
            }
        }
        let before = adapted(SIMD3(1, 1, 1)), after = adapted(SIMD3(1.04, 0.9, 1.07))
        XCTAssertNotNil(NegativeScanDecoderMatrix.linearMap(from: before, to: after))
        XCTAssertNil(NegativeScanDecoderMatrix.recovered(before: before, after: after))
        XCTAssertNil(NegativeScanDecoderMatrix.recovered(
            before: before, tinted: [after, adapted(SIMD3(0.96, 1.1, 0.93))]))
    }

    func testOnlyMatricesADecoderCouldUseArePlausible() {
        XCTAssertTrue(NegativeScanDecoderMatrix.plausible(matrix))
        XCTAssertFalse(NegativeScanDecoderMatrix.plausible(
            [SIMD3(0.2, 0.9, -0.1), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]))
        XCTAssertFalse(NegativeScanDecoderMatrix.plausible(
            [SIMD3(.nan, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]))
        XCTAssertFalse(NegativeScanDecoderMatrix.plausible([SIMD3(1, 0, 0), SIMD3(0, 1, 0)]))
    }
}
