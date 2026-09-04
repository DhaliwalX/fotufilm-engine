import XCTest
@testable import FotufilmCore

final class PremultipliedAlphaTests: XCTestCase {
    func testZeroAlphaAdditiveHDRSurvivesBlackFlatten() {
        var rgba: [Float] = [413.25, 173.375, 43.875, 0]

        PremultipliedAlpha.flatten(&rgba, over: .zero)

        XCTAssertEqual(rgba, [413.25, 173.375, 43.875, 1])
    }

    func testAssociatedColorCompositesOverBackground() {
        var rgba: [Float] = [0.1, 0.2, 0.3, 0.25]

        PremultipliedAlpha.flatten(&rgba, over: SIMD3(0.8, 0.4, 0.2))

        XCTAssertEqual(rgba[0], 0.7, accuracy: 0.000_001)
        XCTAssertEqual(rgba[1], 0.5, accuracy: 0.000_001)
        XCTAssertEqual(rgba[2], 0.45, accuracy: 0.000_001)
        XCTAssertEqual(rgba[3], 1)
    }

    func testOpaqueSignedHDRColorIsUnchanged() {
        var rgba: [Float] = [-0.2, 2, 8, 1]

        PremultipliedAlpha.flatten(&rgba, over: SIMD3(1, 1, 1))

        XCTAssertEqual(rgba, [-0.2, 2, 8, 1])
    }

    func testInvalidSamplesAreRepairedBeforeFlattening() {
        var rgba: [Float] = [
            .nan, .infinity, -.infinity, .nan,
            0, 0, 0, -1,
            0.4, 0.5, 0.6, 2,
        ]

        PremultipliedAlpha.flatten(&rgba, over: SIMD3(0.1, 0.2, 0.3))

        XCTAssertEqual(rgba[0...3], [0, 0, 0, 1])
        XCTAssertEqual(rgba[4...7], [0.1, 0.2, 0.3, 1])
        XCTAssertEqual(rgba[8...11], [0.4, 0.5, 0.6, 1])
    }
}
