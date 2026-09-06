import XCTest
@testable import FotufilmCore

final class Gold200CurveTests: XCTestCase {
    func testResponseHasNoAbruptSlopeJumps() throws {
        let stock = try XCTUnwrap(FilmStock.named("gold200"))
        let step: Float = 0.002
        for (channel, curve) in stock.curves.enumerated() {
            var previousDensity = curve.density(logExposure: -4)
            var previousSlope: Float?
            var largestJump: Float = 0
            for index in 1...4500 {
                let density = curve.density(logExposure: -4 + Float(index) * step)
                let slope = (density - previousDensity) / step
                XCTAssertTrue(density.isFinite, "channel \(channel)")
                XCTAssertGreaterThanOrEqual(density, curve.dMin, "channel \(channel)")
                XCTAssertGreaterThanOrEqual(slope, -0.001, "channel \(channel)")
                if let previousSlope {
                    largestJump = max(largestJump, abs(slope - previousSlope))
                }
                previousDensity = density
                previousSlope = slope
            }
            // The old blue toe hit the density floor with a slope jump around 0.19.
            // Bound adjacent slope changes across the entire toe and shoulder range.
            XCTAssertLessThan(largestJump, 0.025, "channel \(channel): abrupt slope change")
        }
    }
}
