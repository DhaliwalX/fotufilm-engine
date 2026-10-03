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

    func testNearNeutralShadowsTurnCyanAndUpperTonesWarm() {
        let shadow = LabScanFinish.oklab(ColorScience.linearDisplayP3ToSRGB(
            LabScanFinish.apply(SIMD3(repeating: 0.05))))
        let upper = LabScanFinish.oklab(ColorScience.linearDisplayP3ToSRGB(
            LabScanFinish.apply(SIMD3(repeating: 0.4))))
        XCTAssertLessThan(shadow.y, -0.005)
        XCTAssertLessThan(shadow.z, 0)
        XCTAssertGreaterThan(upper.y, 0.005)
        XCTAssertGreaterThan(upper.z, 0)
        // A deep shadow takes the cast in proportion to its lightness, so it stays near neutral.
        let deep = LabScanFinish.oklab(ColorScience.linearDisplayP3ToSRGB(
            LabScanFinish.apply(SIMD3(repeating: 0.003))))
        XCTAssertLessThan((deep.y * deep.y + deep.z * deep.z).squareRoot(), 0.006)
    }

    func testDarkColouredPatchKeepsItsOwnColour() {
        // A dark red is near-neutral in absolute chroma but not relative to its lightness.
        let red = SIMD3<Float>(0.02, 0.004, 0.003)
        let before = LabScanFinish.oklab(ColorScience.linearDisplayP3ToSRGB(red))
        let after = LabScanFinish.oklab(ColorScience.linearDisplayP3ToSRGB(LabScanFinish.apply(red)))
        XCTAssertGreaterThan(after.y, before.y * 0.95, "no cyan pulled into a dark red")
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
        XCTAssertLessThan(lch(LabScanFinish.apply(yellow)).c, lch(yellow).c * 0.95)
        let sky = SIMD3<Float>(0.12, 0.22, 0.5)
        XCTAssertLessThan(lch(LabScanFinish.apply(sky)).c, lch(sky).c * 0.95)
        let red = SIMD3<Float>(0.35, 0.06, 0.04)
        XCTAssertGreaterThan(lch(LabScanFinish.apply(red)).c, lch(red).c * 1.05)
    }

    func testStrengthRunsFromTheNeutralScanToTheFullFinish() {
        let foliage = SIMD3<Float>(0.08, 0.22, 0.05)
        XCTAssertEqual(LabScanFinish.apply(foliage, strength: 0), foliage)
        let half = lch(LabScanFinish.apply(foliage, strength: 0.5)).h
        XCTAssertGreaterThan(half, lch(foliage).h)
        XCTAssertLessThan(half, lch(LabScanFinish.apply(foliage)).h)
    }

    func testDensityKeyLightensMidGreyByItsStops() throws {
        let film = try XCTUnwrap(FilmStock.named("portra400"))
        let curve = PrintPaper.labScan.printCurve(for: film)
        let mid = PrintPaper.labScan.printExposureMidpoints(for: film)[1]
        func output(_ shift: Float) -> Float {
            pow(10, -(curve.density(logExposure: mid + shift) - curve.dMin))
        }
        let shift = LabScanTiming.densityShift(stops: 1, stock: film)
        XCTAssertLessThan(shift, 0)
        XCTAssertEqual(output(shift) / output(0), 2, accuracy: 0.01)
    }
}
