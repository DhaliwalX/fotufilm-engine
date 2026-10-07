import XCTest
import FotufilmHalide
@testable import FotufilmCore

final class PrintFinishTests: XCTestCase {
    /// Neutral packs to zeros, which every configuration that never wrote the slots holds, and
    /// leaves a print as it is.
    func testNeutralIsZeroAndLeavesThePrint() {
        XCTAssertEqual(PrintFinish.neutral.packed, [Float](repeating: 0, count: 7))
        XCTAssertEqual(PrintFinish.neutral.packed.count,
                       Int(FOTUFILM_CONFIG_PRINT_FINISH_COUNT))
        let rgb = SIMD3<Float>(0.4, 0.2, 0.05)
        let finished = PrintFinish.neutral.apply(rgb)
        for c in 0..<3 { XCTAssertEqual(finished[c], rgb[c], accuracy: 1e-6) }
    }

    /// Highlights move the bright end and leave mid-grey; shadows move the dark end; neither
    /// shifts a hue.
    func testHighlightsAndShadowsMoveTheirOwnEnds() {
        let grey = SIMD3<Float>(repeating: 0.18), white = SIMD3<Float>(repeating: 0.9)
        let dark = SIMD3<Float>(0.03, 0.02, 0.01)
        let lowered = PrintFinish(highlights: -1)
        XCTAssertEqual(lowered.apply(grey).y, 0.18, accuracy: 1e-6)
        let whiteStops = log2(Float(0.9) / 0.18)
        let x = whiteStops / PrintFinish.highlightReach
        XCTAssertEqual(log2(lowered.apply(white).y / 0.9),
                       -PrintFinish.endStops * x * x * (3 - 2 * x), accuracy: 1e-5)
        let lifted = PrintFinish(shadows: 1).apply(dark)
        XCTAssertGreaterThan(lifted.x, dark.x)
        XCTAssertEqual(lifted.x / lifted.z, dark.x / dark.z, accuracy: 1e-4)
        XCTAssertEqual(PrintFinish(shadows: 1).apply(white).x, 0.9, accuracy: 1e-6)
    }

    /// Gains come first; saturation and vibrance turn chroma about luminance, which they keep.
    func testGainsThenChroma() {
        let rgb = SIMD3<Float>(0.3, 0.2, 0.1)
        let gained = PrintFinish(gains: SIMD3(2, 1, 0.5)).apply(rgb)
        XCTAssertEqual(gained.x, 0.6, accuracy: 1e-6)
        XCTAssertEqual(gained.z, 0.05, accuracy: 1e-6)
        let grey = PrintFinish(saturation: 0).apply(rgb)
        let luminance = (rgb * PrintFinish.luminance).sum()
        for c in 0..<3 { XCTAssertEqual(grey[c], luminance, accuracy: 1e-6) }
        let vivid = PrintFinish(vibrance: 1).apply(rgb)
        XCTAssertGreaterThan(vivid.x - vivid.z, rgb.x - rgb.z)
        XCTAssertEqual((vivid * PrintFinish.luminance).sum(), luminance, accuracy: 1e-6)
    }
}
