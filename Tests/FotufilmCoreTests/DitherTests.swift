import XCTest
@testable import FotufilmCore

final class DitherTests: XCTestCase {
    private static let positions = (0...32).map { Float($0) / 32 }

    private static let draws = 20000

    private static func quantize(_ value: Float) -> (mean: Double, variance: Double) {
        var total = 0.0, totalSquares = 0.0
        for index in 0..<draws {
            let dither = triangularDither(index: UInt32(index), channel: 0,
                                          seed: 0x46494C4D)
            let code = Double(floor(value + 0.5 + dither))
            total += code
            totalSquares += code * code
        }
        let mean = total / Double(draws)
        return (mean, totalSquares / Double(draws) - mean * mean)
    }

    func testTheMeanCodeTracksTheValueAcrossEveryStep() {
        var worst = 0.0, worstAt = Float(0)
        for position in Self.positions {
            let error = abs(Self.quantize(position).mean - Double(position))
            if error > worst { worst = error; worstAt = position }
        }
        print(String(format: "DITHER worst DC error %.4f codes at %.3f into a step",
                     worst, worstAt))
        XCTAssertLessThan(
            worst, Self.dcCeiling,
            "the delivered code is biased by \(worst) at \(worstAt) into a "
            + "step, so the tone scale bends inside every code. A triangular "
            + "dither spanning ±1 step has no such bend; a narrower one does.")
    }

    func testTheNoiseDoesNotBreatheAcrossTheStep() {
        let variances = Self.positions.map { Self.quantize($0).variance }
        let low = variances.min()!, high = variances.max()!
        print(String(format: "DITHER error variance %.4f-%.4f codes^2", low, high))
        XCTAssertGreaterThan(
            low, Self.varianceFloor,
            "at some point inside a step the dither adds no noise at all "
            + "(variance \(low)), so the quantizer's steps survive there. "
            + "That is what banding looks like.")
        XCTAssertLessThan(
            high - low, Self.varianceSwing,
            "the noise the dither adds swings by \(high - low) codes² across "
            + "one step, so it breathes at the code spacing along a gradient")
    }

    func testTheDrawIsTheOneTheHalideEngineMakes() {
        // pcg and the two-uniform sum, spelled out independently of the
        // function under test.
        func pcg(_ v: UInt32) -> UInt32 {
            let state = v &* 747796405 &+ 2891336453
            let word = ((state >> ((state >> 28) &+ 4)) ^ state) &* 277803737
            return (word >> 22) ^ word
        }
        let seed: UInt32 = 0x9E3779B9
        for index: UInt32 in [0, 1, 7, 1023, 65535] {
            for channel: UInt32 in 0..<3 {
                let h1 = pcg(index ^ pcg(channel &+ (seed &* 0x9E3779B9)))
                let h2 = pcg(h1)
                let u1: Float = Float(h1 >> 8) * (1.0 / 16777216.0)
                let u2: Float = Float(h2 >> 8) * (1.0 / 16777216.0)
                let expected: Float = u1 + u2 - 1
                XCTAssertEqual(
                    triangularDither(index: index, channel: channel, seed: seed),
                    expected, accuracy: 0,
                    "index \(index) channel \(channel)")
            }
        }
    }

    private static let dcCeiling = 0.02
    private static let varianceFloor = 0.2
    private static let varianceSwing = 0.02
}
