import XCTest
@testable import FotufilmCore

final class PlainDevelopTests: XCTestCase {
    // MARK: - Fixtures

    private func flat(_ rgb: (Float, Float, Float), width: Int,
                      height: Int) -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = rgb.0
            pixels[i * 4 + 1] = rgb.1
            pixels[i * 4 + 2] = rgb.2
            pixels[i * 4 + 3] = 1
        }
        return pixels
    }

    private func develop(_ pixels: inout [Float], width: Int, height: Int,
                         options: FotufilmEngine.Options) {
        var plain = PlainDevelop(options: options)
        if plain.needsToneBase {
            var measurement = plain.toneBaseMeasurement(frameWidth: width,
                                                        frameHeight: height)
            pixels.withUnsafeMutableBufferPointer { buffer in
                measurement.add(linearRGBA: buffer.baseAddress!,
                                rows: 0..<height)
            }
            plain.setToneBase(measurement)
        }
        pixels.withUnsafeMutableBufferPointer { buffer in
            plain.apply(linearRGBA: buffer, rows: 0..<height, width: width)
        }
    }

    private func pixel(_ pixels: [Float], _ x: Int, _ y: Int,
                       width: Int) -> SIMD3<Float> {
        let i = (y * width + x) * 4
        return SIMD3(pixels[i], pixels[i + 1], pixels[i + 2])
    }

    // MARK: - The passthrough itself

    func testUntouchedControlsLeaveTheSceneExactlyAsTheyFoundIt() {
        let source: [Float] = [0.02, 0.18, 0.5, 1, 1.0, 2.5, 0.004, 1]
        var pixels = source
        develop(&pixels, width: 2, height: 1, options: FotufilmEngine.Options())
        for pixel in 0..<2 {
            let scene = SIMD3<Float>(source[pixel * 4], source[pixel * 4 + 1],
                                     source[pixel * 4 + 2])
            let delivered = ColorScience.linearRec2020ToDisplayP3(scene)
            for c in 0..<3 {
                XCTAssertEqual(pixels[pixel * 4 + c], delivered[c], accuracy: 1e-6,
                               "pixel \(pixel) channel \(c) moved with every control at rest")
            }
            XCTAssertEqual(pixels[pixel * 4 + 3], source[pixel * 4 + 3],
                           accuracy: 1e-6, "alpha is transport")
        }
        // And the neutral components really are untouched, not merely close: grey is grey in
        // both bases.
        let grey: [Float] = [0.18, 0.18, 0.18, 1]
        var greyPixels = grey
        develop(&greyPixels, width: 1, height: 1, options: FotufilmEngine.Options())
        for i in 0..<3 {
            XCTAssertEqual(greyPixels[i], 0.18, accuracy: 2e-7,
                           "a neutral must survive the delivery basis exactly")
        }
    }

    func testExposureScalesTheSceneByTwoToTheEV() {
        for ev: Float in [-2, -0.5, 1, 3] {
            var options = FotufilmEngine.Options()
            options.exposureEV = ev
            var pixels = flat((0.1, 0.18, 0.4), width: 4, height: 4)
            develop(&pixels, width: 4, height: 4, options: options)
            let out = pixel(pixels, 2, 2, width: 4)
            let gain = exp2(ev)
            // Exposure scales in the working space; the print delivers the scaled scene in P3.
            let expected = ColorScience.linearRec2020ToDisplayP3(
                SIMD3<Float>(0.1, 0.18, 0.4) * gain)
            XCTAssertEqual(out.x, expected.x, accuracy: 1e-5)
            XCTAssertEqual(out.y, expected.y, accuracy: 1e-5)
            XCTAssertEqual(out.z, expected.z, accuracy: 1e-5)
        }
    }

    func testWhiteBalanceAppliesTheSameGainsTheEngineIsGiven() {
        var options = FotufilmEngine.Options()
        options.whiteBalance = WhiteBalance(kelvin: 3200, tint: 0)
        let gains = options.whiteBalance.gains
        XCTAssertNotEqual(gains.r, gains.b, accuracy: 0,
                          "a 3200K correction should not be neutral")

        var pixels = flat((0.2, 0.2, 0.2), width: 4, height: 4)
        develop(&pixels, width: 4, height: 4, options: options)
        let out = pixel(pixels, 1, 1, width: 4)
        // The gains are diagonal in the working basis — that is the contract with the engine —
        // and the balanced scene is then delivered in P3.
        let expected = ColorScience.linearRec2020ToDisplayP3(
            SIMD3<Float>(0.2 * gains.r, 0.2 * gains.g, 0.2 * gains.b))
        XCTAssertEqual(out.x, expected.x, accuracy: 1e-5)
        XCTAssertEqual(out.y, expected.y, accuracy: 1e-5)
        XCTAssertEqual(out.z, expected.z, accuracy: 1e-5)
    }

    func testSaturationOfZeroLeavesTheLuminanceAlone() {
        var options = FotufilmEngine.Options()
        options.saturation = 0
        var pixels = flat((0.5, 0.2, 0.1), width: 4, height: 4)
        develop(&pixels, width: 4, height: 4, options: options)
        let out = pixel(pixels, 1, 1, width: 4)
        let luma = ColorScience.luminanceWeights
        let expected = luma.0 * 0.5 + luma.1 * 0.2 + luma.2 * 0.1
        XCTAssertEqual(out.x, expected, accuracy: 1e-5)
        XCTAssertEqual(out.y, expected, accuracy: 1e-5)
        XCTAssertEqual(out.z, expected, accuracy: 1e-5)
    }

    func testVibranceReachesTheDullPixelFurtherThanTheColourfulOne() {
        var options = FotufilmEngine.Options()
        options.vibrance = 1
        // One near-neutral pixel and one saturated one, side by side.
        var pixels: [Float] = [0.30, 0.28, 0.26, 1, 0.60, 0.10, 0.05, 1]
        let before = pixels
        develop(&pixels, width: 2, height: 1, options: options)
        func spread(_ p: [Float], _ i: Int) -> Float {
            let base = i * 4
            let peak = max(p[base], max(p[base + 1], p[base + 2]))
            let low = min(p[base], min(p[base + 1], p[base + 2]))
            return (peak - low) / max(peak, 1e-6)
        }
        let dullGain = spread(pixels, 0) / spread(before, 0)
        let vividGain = spread(pixels, 1) / spread(before, 1)
        XCTAssertGreaterThan(dullGain, vividGain,
                             "vibrance should weight toward the dull pixel")
        XCTAssertGreaterThan(dullGain, 1)
    }

    func testGradeIsAppliedToTheExposedValue() {
        var grade = ColorGrade.neutral
        grade.highlights.level = 0.8
        grade.midtones.level = -0.4
        XCTAssertFalse(grade.isNeutral)

        var options = FotufilmEngine.Options()
        options.exposureEV = 1
        options.grade = grade

        var pixels = flat((0.12, 0.2, 0.33), width: 4, height: 4)
        develop(&pixels, width: 4, height: 4, options: options)
        // The grade belongs to the print, so it reads the delivered P3 value — conversion
        // first, grade second, mirroring the film path's order.
        let expected = grade.apply(
            ColorScience.linearRec2020ToDisplayP3(SIMD3(0.12, 0.2, 0.33) * 2))
        let out = pixel(pixels, 1, 1, width: 4)
        XCTAssertEqual(out.x, expected.x, accuracy: 1e-5)
        XCTAssertEqual(out.y, expected.y, accuracy: 1e-5)
        XCTAssertEqual(out.z, expected.z, accuracy: 1e-5)
    }

    func testAlphaSurvivesUntouched() {
        var options = FotufilmEngine.Options()
        options.exposureEV = 2
        options.saturation = 0.5
        options.highlights = -1
        var pixels: [Float] = [0.4, 0.5, 0.6, 0.37]
        develop(&pixels, width: 1, height: 1, options: options)
        XCTAssertEqual(pixels[3], 0.37, accuracy: 1e-6)
    }

    // MARK: - The local tone masks

    func testTheGridIsOnlySolvedWhenTheToneControlsAskForIt() {
        var options = FotufilmEngine.Options()
        options.localTone = true
        XCTAssertFalse(PlainDevelop(options: options).needsToneBase,
                       "a frame with the tone controls at rest needs no prepass")
        options.highlights = -0.5
        XCTAssertTrue(PlainDevelop(options: options).needsToneBase)
        options.localTone = false
        XCTAssertFalse(PlainDevelop(options: options).needsToneBase,
                       "keyed per pixel, there is no region to solve")
    }

    func testHighlightRecoveryPullsTheBrightRegionDownAndLeavesTheDarkOne() {
        let side = 256
        var pixels = flat((0.05, 0.05, 0.05), width: side, height: side)
        for y in 0..<side {
            for x in (side / 2)..<side {
                let i = (y * side + x) * 4
                pixels[i] = 1.2; pixels[i + 1] = 1.2; pixels[i + 2] = 1.2
            }
        }
        var options = FotufilmEngine.Options()
        options.localTone = true
        options.highlights = -1
        develop(&pixels, width: side, height: side, options: options)

        let bright = pixel(pixels, side - 16, side / 2, width: side).x
        let dark = pixel(pixels, 16, side / 2, width: side).x
        XCTAssertLessThan(bright, 1.2 * 0.9,
                          "the bright region should come down")
        XCTAssertEqual(dark, 0.05, accuracy: 1e-4,
                       "the dark region is not what was recovered")
    }

    func testASpeckIsKeyedToItsRegionRatherThanToItself() {
        let side = 256
        func frame() -> [Float] {
            var pixels = flat((1.2, 1.2, 1.2), width: side, height: side)
            for y in (side / 2 - 4)..<(side / 2 + 4) {
                for x in (side / 2 - 4)..<(side / 2 + 4) {
                    let i = (y * side + x) * 4
                    pixels[i] = 0.05; pixels[i + 1] = 0.05; pixels[i + 2] = 0.05
                }
            }
            return pixels
        }

        var options = FotufilmEngine.Options()
        options.highlights = -1

        options.localTone = false
        var perPixel = frame()
        develop(&perPixel, width: side, height: side, options: options)

        options.localTone = true
        var regional = frame()
        develop(&regional, width: side, height: side, options: options)

        let speckPerPixel = pixel(perPixel, side / 2, side / 2, width: side).x
        let speckRegional = pixel(regional, side / 2, side / 2, width: side).x
        XCTAssertEqual(speckPerPixel, 0.05, accuracy: 1e-4,
                       "keyed to itself, a dark speck is not a highlight")
        XCTAssertLessThan(speckRegional, speckPerPixel * 0.9,
                          "keyed to its region, it comes down with the field")

        // And the field itself lands in the same place either way.
        let fieldPerPixel = pixel(perPixel, 16, 16, width: side).x
        let fieldRegional = pixel(regional, 16, 16, width: side).x
        XCTAssertEqual(fieldRegional, fieldPerPixel,
                       accuracy: fieldPerPixel * 0.05)
    }

    func testShadowLiftRaisesTheDarkRegionOnly() {
        let side = 256
        var pixels = flat((1.0, 1.0, 1.0), width: side, height: side)
        for y in 0..<(side / 2) {
            for x in 0..<side {
                let i = (y * side + x) * 4
                pixels[i] = 0.004; pixels[i + 1] = 0.004; pixels[i + 2] = 0.004
            }
        }
        var options = FotufilmEngine.Options()
        options.localTone = true
        options.shadows = 1
        develop(&pixels, width: side, height: side, options: options)

        XCTAssertGreaterThan(pixel(pixels, side / 2, 16, width: side).x,
                             0.004 * 1.5, "the dark half should lift")
        XCTAssertEqual(pixel(pixels, side / 2, side - 16, width: side).x, 1.0,
                       accuracy: 1e-3, "the bright half is not a shadow")
    }

    // MARK: - Latitude

    func testHighlightLatitudeIsWhereThePrintClipsAtWhite() {
        let stops = PlainDevelop.latitude.highlights
        XCTAssertEqual(0.18 * exp2(stops), 1, accuracy: 1e-6)
        XCTAssertEqual(stops, 2.4739, accuracy: 0.001)

        // A stop above it is already off the top of the scale, not compressed onto it.
        XCTAssertEqual(ColorScience.linearToSrgb(0.18 * exp2(stops + 1)), 1,
                       accuracy: 1e-6)
    }

    func testShadowLatitudeIsTheEncodingFloorRatherThanAToe() {
        let stops = PlainDevelop.latitude.shadows
        XCTAssertEqual(ColorScience.srgbToLinear(0.5 / 255), 0.18 * exp2(stops),
                       accuracy: 1e-7)
        XCTAssertLessThan(stops, -9)

        // A scene sitting entirely inside the frame's range asks for no lift.
        let scene = AutoAdjustment.SceneStops(median: -0.7, bright: 1.5,
                                              dark: -5)
        let solution = AutoAdjustment.solve(scene: scene,
                                            window: PlainDevelop.latitude)
        XCTAssertEqual(solution.shadows, 0, accuracy: 1e-6)
    }
}

// MARK: - The chroma controls read the balanced scene

extension PlainDevelopTests {
    /// A grey card as the sensor saw it under the declared illuminant: exactly what the gains undo.
    private func greyCard(under balance: WhiteBalance) -> SIMD3<Float> {
        let g = balance.gains
        return SIMD3(0.2 / g.r, 0.2 / g.g, 0.2 / g.b)
    }

    private func developed(_ scene: SIMD3<Float>,
                           options: FotufilmEngine.Options) -> SIMD3<Float> {
        var pixels: [Float] = [scene.x, scene.y, scene.z, 1]
        develop(&pixels, width: 1, height: 1, options: options)
        return ColorScience.linearDisplayP3ToRec2020(
            SIMD3(pixels[0], pixels[1], pixels[2]))
    }

    func testSaturationAndVibranceReadTheBalancedSceneNotTheRecordedLight() {
        let balance = WhiteBalance(kelvin: 3200)
        let card = greyCard(under: balance)
        var options = FotufilmEngine.Options()
        options.whiteBalance = balance
        let plain = developed(card, options: options)
        XCTAssertEqual(plain.x, 0.2, accuracy: 1e-5)
        XCTAssertEqual(plain.z, 0.2, accuracy: 1e-5, "the balanced card is grey")

        // The card carries no chroma once balanced, so no chroma control can find any to move.
        for (saturation, vibrance) in [(Float(0), Float(0)), (1, 1), (2, 0), (0.5, -1)] {
            options.saturation = saturation
            options.vibrance = vibrance
            let out = developed(card, options: options)
            for channel in 0..<3 {
                XCTAssertEqual(out[channel], 0.2, accuracy: 1e-5,
                               "saturation \(saturation) vibrance \(vibrance) tinted "
                               + "a balanced grey card: \(out)")
            }
        }
    }

    func testVibranceWeighsColourfulnessAfterTheBalance() {
        // Under a warm declaration every recorded pixel is orange, so a colourfulness read
        // before the balance would call this near-neutral pixel vivid and leave it alone.
        let balance = WhiteBalance(kelvin: 3200)
        let g = balance.gains
        let dull = SIMD3<Float>(0.30 / g.r, 0.28 / g.g, 0.26 / g.b)
        var options = FotufilmEngine.Options()
        options.whiteBalance = balance
        let before = developed(dull, options: options)
        options.vibrance = 1
        let after = developed(dull, options: options)
        func spread(_ p: SIMD3<Float>) -> Float {
            let peak = max(p.x, max(p.y, p.z))
            return (peak - min(p.x, min(p.y, p.z))) / max(peak, 1e-6)
        }
        // The same pixel under a neutral declaration is the reference: the balance must not
        // change how much vibrance reaches it.
        var neutral = FotufilmEngine.Options()
        let reference = developed(SIMD3(0.30, 0.28, 0.26), options: neutral)
        neutral.vibrance = 1
        let referenceVivid = developed(SIMD3(0.30, 0.28, 0.26), options: neutral)
        XCTAssertGreaterThan(spread(after), spread(before))
        XCTAssertEqual(spread(after) / spread(before),
                       spread(referenceVivid) / spread(reference), accuracy: 1e-3,
                       "vibrance reached the pixel differently under a declared illuminant")
    }
}
