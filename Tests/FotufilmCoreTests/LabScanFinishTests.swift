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

    /// Linear Display P3 of the Oklab colour at lightness `l`, chroma `c` and hue `h` degrees.
    private func colour(l: Float, c: Float, h: Float) -> SIMD3<Float> {
        let angle = h * .pi / 180
        return ColorScience.linearSRGBToDisplayP3(
            LabScanFinish.linear(fromOklab: SIMD3(l, c * cos(angle), c * sin(angle))))
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

    func testNearNeutralShadowsTurnCyanBlueAndUpperTonesStayNeutral() {
        let shadow = LabScanFinish.oklab(ColorScience.linearDisplayP3ToSRGB(
            LabScanFinish.apply(SIMD3(repeating: 0.05))))
        let upper = LabScanFinish.oklab(ColorScience.linearDisplayP3ToSRGB(
            LabScanFinish.apply(SIMD3(repeating: 0.4))))
        XCTAssertLessThan(shadow.y, -0.005)
        XCTAssertLessThan(shadow.z, -0.005)
        XCTAssertLessThan((upper.y * upper.y + upper.z * upper.z).squareRoot(), 1e-3)
        // A deep shadow takes the cast in proportion to its lightness, so it stays near neutral.
        let deep = LabScanFinish.oklab(ColorScience.linearDisplayP3ToSRGB(
            LabScanFinish.apply(SIMD3(repeating: 0.003))))
        XCTAssertLessThan((deep.y * deep.y + deep.z * deep.z).squareRoot(), 0.006)
    }

    func testDarkColouredPatchKeepsItsOwnColour() {
        // A dark red is near-neutral in absolute chroma but not relative to its lightness. Past
        // the gradation, which darkens it, it keeps its redness.
        let red = SIMD3<Float>(0.02, 0.004, 0.003)
        let graded = LabScanFinish.oklab(
            ColorScience.linearDisplayP3ToSRGB(LabScanFinish.graded(red)))
        let after = LabScanFinish.oklab(
            ColorScience.linearDisplayP3ToSRGB(LabScanFinish.apply(red)))
        XCTAssertGreaterThan(after.y, graded.y * 0.95, "no cyan pulled into a dark red")
    }

    func testMonochromeTakesTheGradationAndStaysNeutral() {
        for level: Float in [0.02, 0.18, 0.6] {
            let finished = LabScanFinish.apply(SIMD3(repeating: level), chromatic: false)
            XCTAssertEqual(finished.x, finished.y, accuracy: 1e-6)
            XCTAssertEqual(finished.z, finished.y, accuracy: 1e-6)
        }
    }

    func testColourCorrections() {
        // Colours of the moderate chroma the corrections were measured on, light enough to take
        // none of the crossover.
        let foliage = colour(l: 0.72, c: 0.08, h: 141)
        XCTAssertGreaterThan(lch(LabScanFinish.apply(foliage)).h, lch(foliage).h + 4,
                             "foliage turns toward teal")
        XCTAssertLessThan(lch(LabScanFinish.apply(foliage)).c, lch(foliage).c * 0.93,
                          "and is muted")
        let sky = colour(l: 0.72, c: 0.08, h: 255)
        XCTAssertLessThan(lch(LabScanFinish.apply(sky)).h, lch(sky).h - 4, "blues turn toward cyan")
        let red = colour(l: 0.72, c: 0.08, h: 30)
        XCTAssertGreaterThan(lch(LabScanFinish.apply(red)).h, lch(red).h + 1,
                             "reds turn slightly toward yellow")
        XCTAssertEqual(lch(LabScanFinish.apply(red)).c, lch(red).c, accuracy: lch(red).c * 0.05,
                       "and keep their chroma")
    }

    func testSaturatedColoursKeepTheirHue() {
        let yellow = colour(l: 0.75, c: 0.21, h: 105)
        XCTAssertEqual(lch(LabScanFinish.apply(yellow)).h, lch(yellow).h, accuracy: 0.01,
                       "a saturated yellow does not turn green")
        // Moving out in chroma through the fade, a colour turns aside by at most a fifth of its
        // move, so a gradient toward a saturated colour stays smooth.
        for hue: Float in [45, 135, 240] {
            let angle = hue * .pi / 180
            var previous: (radial: Float, across: Float)?
            for step in 0...120 {
                let lab = LabScanFinish.oklab(ColorScience.linearDisplayP3ToSRGB(
                    LabScanFinish.apply(colour(l: 0.75, c: 0.02 + Float(step) * 0.002, h: hue))))
                let radial = lab.y * cos(angle) + lab.z * sin(angle)
                let across = lab.z * cos(angle) - lab.y * sin(angle)
                if let previous {
                    XCTAssertLessThanOrEqual(abs(across - previous.across),
                                             0.2 * abs(radial - previous.radial),
                                             "hue \(hue)° at chroma step \(step)")
                }
                previous = (radial, across)
            }
        }
    }

    func testHueMapStaysSmooth() {
        // A ring of mid-tone colours, one degree apart: the corrections turn and mute hues but
        // never draw neighbouring hues apart or together by more than a fifth.
        var previous: Float?
        for degree in 0...360 {
            let hue = lch(LabScanFinish.apply(colour(l: 0.5, c: 0.1, h: Float(degree)))).h
            if let previous {
                let step = (hue - previous + 540).truncatingRemainder(dividingBy: 360) - 180
                XCTAssertGreaterThan(step, 0.8, "hues drawn together at \(degree)°")
                XCTAssertLessThan(step, 1.2, "hues drawn apart at \(degree)°")
            }
            previous = hue
        }
    }

    func testStrengthRunsFromTheNeutralScanToTheFullFinish() {
        let foliage = colour(l: 0.72, c: 0.08, h: 141)
        XCTAssertEqual(LabScanFinish.apply(foliage, strength: 0), foliage)
        let half = lch(LabScanFinish.apply(foliage, strength: 0.5)).h
        XCTAssertGreaterThan(half, lch(foliage).h)
        XCTAssertLessThan(half, lch(LabScanFinish.apply(foliage)).h)
    }
}
