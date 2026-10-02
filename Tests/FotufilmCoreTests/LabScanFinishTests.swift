import XCTest
@testable import FotufilmCore

final class LabScanFinishTests: XCTestCase {
    private func lch(_ p3: SIMD3<Float>) -> (l: Float, c: Float, h: Float) {
        let lab = LabScanFinish.oklab(ColorScience.linearDisplayP3ToSRGB(p3))
        let hue = atan2(lab.z, lab.y) * 180 / .pi
        return (lab.x, (lab.y * lab.y + lab.z * lab.z).squareRoot(), hue < 0 ? hue + 360 : hue)
    }

    private func luminance(_ p3: SIMD3<Float>) -> Float {
        let w = ColorScience.displayP3LuminanceWeights
        return w.0 * p3.x + w.1 * p3.y + w.2 * p3.z
    }

    func testWhiteAndBlackStayPut() {
        let white = LabScanFinish.apply(.one)
        for c in 0..<3 { XCTAssertEqual(white[c], 1, accuracy: 1e-4) }
        let black = LabScanFinish.apply(SIMD3(repeating: 1e-4))
        XCTAssertLessThanOrEqual(luminance(black), 1e-4)
        XCTAssertLessThan(lch(black).c, 1e-3)
    }

    func testNeutralRampStaysMonotoneWithBrighterUpperTones() {
        var previous: Float = 0
        for step in 1...200 {
            let level = Float(step) / 200
            let finished = luminance(LabScanFinish.apply(SIMD3(repeating: level)))
            XCTAssertGreaterThan(finished, previous, "\(level)")
            previous = finished
        }
        // Upper tones open up; the deepest shadows go a little deeper.
        XCTAssertGreaterThan(luminance(LabScanFinish.apply(SIMD3(repeating: 0.5))), 0.5)
        XCTAssertLessThan(luminance(LabScanFinish.apply(SIMD3(repeating: 0.01))), 0.01)
    }

    func testShadowsAreCoolerThanHighlights() {
        let shadow = LabScanFinish.oklab(ColorScience.linearDisplayP3ToSRGB(
            LabScanFinish.apply(SIMD3(repeating: 0.05))))
        let highlight = LabScanFinish.oklab(ColorScience.linearDisplayP3ToSRGB(
            LabScanFinish.apply(SIMD3(repeating: 0.7))))
        XCTAssertLessThan(shadow.y, 0)
        XCTAssertLessThan(shadow.z, 0)
        XCTAssertGreaterThan(highlight.z, shadow.z)
    }

    func testMonochromeTakesTheGradationAndStaysNeutral() {
        for level: Float in [0.02, 0.18, 0.6] {
            let finished = LabScanFinish.apply(SIMD3(repeating: level), chromatic: false)
            XCTAssertEqual(finished.x, finished.y, accuracy: 1e-6)
            XCTAssertEqual(finished.z, finished.y, accuracy: 1e-6)
        }
    }

    func testColourCorrections() {
        let foliage = SIMD3<Float>(0.08, 0.22, 0.05)
        XCTAssertGreaterThan(lch(LabScanFinish.apply(foliage)).h, lch(foliage).h + 5,
                             "foliage turns toward teal")
        let yellow = SIMD3<Float>(0.55, 0.45, 0.08)
        XCTAssertGreaterThan(lch(LabScanFinish.apply(yellow)).c, lch(yellow).c * 1.1)
        let sky = SIMD3<Float>(0.12, 0.22, 0.5)
        XCTAssertGreaterThan(lch(LabScanFinish.apply(sky)).c, lch(sky).c * 1.1)
        let red = SIMD3<Float>(0.35, 0.03, 0.04)
        XCTAssertLessThan(lch(LabScanFinish.apply(red)).c, lch(red).c)
    }
}
