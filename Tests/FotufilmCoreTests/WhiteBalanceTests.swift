import XCTest
@testable import FotufilmCore

final class WhiteBalanceTests: XCTestCase {
    private func xy(_ kelvin: Float, tint: Float = 0) -> SIMD2<Float> {
        WhiteBalance.chromaticity(kelvin: kelvin, tint: tint)
    }

    func testDaylightLocusMatchesPublishedIlluminants() {
        let published: [(Float, Float, Float)] = [
            (5003, 0.3457, 0.3585),
            (5503, 0.3324, 0.3474),
            (6504, 0.3127, 0.3290),
            (7504, 0.2990, 0.3149),
        ]
        for (kelvin, x, y) in published {
            let found = xy(kelvin)
            XCTAssertEqual(found.x, x, accuracy: 0.001, "x at \(kelvin) K")
            XCTAssertEqual(found.y, y, accuracy: 0.001, "y at \(kelvin) K")
        }
    }

    func testPlanckianLocusMatchesIlluminantA() {
        let found = xy(2856)
        XCTAssertEqual(found.x, 0.4476, accuracy: 0.004)
        XCTAssertEqual(found.y, 0.4074, accuracy: 0.004)
    }

    func testLocusIsContinuousAtTheDaylightCrossover() {
        let below = xy(3999), above = xy(4001)
        XCTAssertEqual(below.x, above.x, accuracy: 0.006)
        XCTAssertEqual(below.y, above.y, accuracy: 0.006)
    }

    func testNeutralIsExactlyIdentity() {
        let gains = WhiteBalance.neutral.gains
        XCTAssertEqual(gains.r, 1)
        XCTAssertEqual(gains.g, 1)
        XCTAssertEqual(gains.b, 1)
        XCTAssertTrue(WhiteBalance.neutral.isNeutral)
    }

    func testWarmIlluminantCoolsTheRendering() {
        let tungsten = WhiteBalance(kelvin: 3200).gains
        XCTAssertLessThan(tungsten.r, 1)
        XCTAssertGreaterThan(tungsten.b, 1)
        XCTAssertEqual(tungsten.g, 1, accuracy: 1e-6)

        let shade = WhiteBalance(kelvin: 9000).gains
        XCTAssertGreaterThan(shade.r, 1)
        XCTAssertLessThan(shade.b, 1)
    }

    func testGreenIsPinnedAcrossTheWholeRange() {
        for kelvin in stride(from: Float(2000), through: 12000, by: 250) {
            for tint in [Float(-100), 0, 100] {
                let gains = WhiteBalance(kelvin: kelvin, tint: tint).gains
                XCTAssertEqual(gains.g, 1, accuracy: 1e-5, "\(kelvin) K tint \(tint)")
                XCTAssertGreaterThan(gains.r, 0)
                XCTAssertGreaterThan(gains.b, 0)
            }
        }
    }

    func testTintMovesGreenAgainstMagenta() {
        let green = WhiteBalance(kelvin: 6504, tint: 60).gains
        let magenta = WhiteBalance(kelvin: 6504, tint: -60).gains
        XCTAssertGreaterThan(green.r, 1)
        XCTAssertGreaterThan(green.b, 1)
        XCTAssertLessThan(magenta.r, 1)
        XCTAssertLessThan(magenta.b, 1)
    }

    func testTintDoesNotShiftCorrelatedColourTemperature() {
        func nearestKelvin(_ point: SIMD2<Float>) -> Float {
            let uv = WhiteBalance.uvFromXY(point)
            var best: Float = 0, bestDistance = Float.greatestFiniteMagnitude
            for kelvin in stride(from: Float(1600), through: 20000, by: 5) {
                let locus = WhiteBalance.uvFromXY(
                    WhiteBalance.chromaticity(kelvin: kelvin, tint: 0))
                let d = (locus.x - uv.x) * (locus.x - uv.x)
                      + (locus.y - uv.y) * (locus.y - uv.y)
                if d < bestDistance { bestDistance = d; best = kelvin }
            }
            return best
        }
        for kelvin in [Float(2800), 4200, 6504, 9500] {
            for tint in [Float(-80), -30, 30, 80] {
                let recovered = nearestKelvin(xy(kelvin, tint: tint))
                XCTAssertEqual(recovered, kelvin, accuracy: kelvin * 0.02,
                               "\(kelvin) K drifted to \(recovered) K at tint \(tint)")
            }
        }
    }

    func testMiredStepsAreVisuallyEven() {
        var distances: [Float] = []
        var previous = WhiteBalance.uvFromXY(xy(WhiteBalance.miredToKelvin(100)))
        for mired in stride(from: Float(120), through: 500, by: 20) {
            let point = WhiteBalance.uvFromXY(xy(WhiteBalance.miredToKelvin(mired)))
            let dx = point.x - previous.x, dy = point.y - previous.y
            distances.append((dx * dx + dy * dy).squareRoot())
            previous = point
        }
        let smallest = distances.min()!, largest = distances.max()!
        XCTAssertLessThan(largest / smallest, 2.2,
                          "mired steps vary by \(largest / smallest)x in uv")
    }
}

final class WhiteBalanceEngineTests: XCTestCase {
    private func requireEngine() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
    }

    private func render(_ patch: SIMD3<Float>, balance: WhiteBalance,
                        stock: FilmStock = TestStocks.negative) -> SIMD3<Float> {
        let size = 8
        var image = ImageBuffer(width: size, height: size)
        for i in 0..<(size * size) {
            image.planes[0][i] = patch.x
            image.planes[1][i] = patch.y
            image.planes[2][i] = patch.z
        }
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.whiteBalance = balance
        let out = FotufilmEngine(stock: stock, options: options).process(linearRGB: image)
        let centre = (size / 2) * size + size / 2
        return SIMD3(out.planes[0][centre], out.planes[1][centre], out.planes[2][centre])
    }

    func testNeutralBalanceChangesNothing() throws {
        try requireEngine()
        let grey = SIMD3<Float>(0.18, 0.18, 0.18)
        let plain = render(grey, balance: .neutral)
        for channel in [plain.x, plain.y, plain.z] {
            XCTAssertEqual(channel, 0.18, accuracy: 0.004)
        }
        XCTAssertEqual(FilmEngineInvocation(
            stock: TestStocks.negative, options: FotufilmEngine.Options(),
            width: 8, height: 8
        ).configuration[FilmEngineInvocation.whiteBalanceOffset], 1)
    }

    func testTungstenBalanceCoolsThePrint() throws {
        try requireEngine()
        let grey = SIMD3<Float>(0.18, 0.18, 0.18)
        let plain = render(grey, balance: .neutral)
        let tungsten = render(grey, balance: WhiteBalance(kelvin: 3200))
        XCTAssertLessThan(tungsten.x / tungsten.z, plain.x / plain.z * 0.9,
                          "3200 K should print cooler than neutral")
        let shade = render(grey, balance: WhiteBalance(kelvin: 9500))
        XCTAssertGreaterThan(shade.x / shade.z, plain.x / plain.z * 1.1,
                             "9500 K should print warmer than neutral")
    }

    func testBalanceActsThroughTheEmulsionNotOnThePrint() throws {
        try requireEngine()
        let grey = SIMD3<Float>(0.18, 0.18, 0.18)
        let balance = WhiteBalance(kelvin: 3200)
        func shift(_ stock: FilmStock) -> Float {
            let plain = render(grey, balance: .neutral, stock: stock)
            let warmed = render(grey, balance: balance, stock: stock)
            return (warmed.x / warmed.z) / (plain.x / plain.z)
        }
        let negative = shift(TestStocks.negative)
        let reversal = shift(TestStocks.reversal)
        XCTAssertNotEqual(negative, reversal, accuracy: 0.001,
                          "the same illuminant must develop differently per stock")
    }

    func testBalanceStillMovesAMonochromeStock() throws {
        try requireEngine()
        let skin = SIMD3<Float>(0.35, 0.22, 0.16)
        let plain = render(skin, balance: .neutral, stock: TestStocks.monochrome)
        let tungsten = render(skin, balance: WhiteBalance(kelvin: 3200), stock: TestStocks.monochrome)
        XCTAssertEqual(tungsten.x, tungsten.y, accuracy: 1e-6, "still neutral")
        XCTAssertGreaterThan(abs(tungsten.y - plain.y), 0.004,
                             "tungsten light changes how a colour turns grey")
    }
}

// MARK: - The chroma controls read the balanced scene

extension WhiteBalanceEngineTests {
    private func print(_ patch: SIMD3<Float>, options: FotufilmEngine.Options,
                       stock: FilmStock = TestStocks.negative) -> SIMD3<Float> {
        let size = 8
        var image = ImageBuffer(width: size, height: size)
        for i in 0..<(size * size) {
            image.planes[0][i] = patch.x
            image.planes[1][i] = patch.y
            image.planes[2][i] = patch.z
        }
        var options = options
        options.grainScale = 0
        let out = FotufilmEngine(stock: stock, options: options).process(linearRGB: image)
        let centre = (size / 2) * size + size / 2
        return SIMD3(out.planes[0][centre], out.planes[1][centre], out.planes[2][centre])
    }

    func testDesaturatingABalancedGreyCardPrintsTheSameGrey() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
        let balance = WhiteBalance(kelvin: 3200)
        let g = balance.gains
        // The card as the sensor saw it under tungsten, which the declared balance neutralises.
        let card = SIMD3<Float>(0.18 / g.r, 0.18 / g.g, 0.18 / g.b)
        var options = FotufilmEngine.Options()
        options.whiteBalance = balance
        let balanced = print(card, options: options)
        let plainGrey = print(SIMD3(repeating: 0.18), options: FotufilmEngine.Options())
        XCTAssertEqual(balanced.x / balanced.z, plainGrey.x / plainGrey.z, accuracy: 0.01,
                       "a balanced card should print as the grey card does")

        for (saturation, vibrance) in [(Float(0), Float(0)), (1, 1), (2, 0)] {
            options.saturation = saturation
            options.vibrance = vibrance
            let moved = print(card, options: options)
            XCTAssertEqual(moved.x / moved.z, balanced.x / balanced.z, accuracy: 0.01,
                           "saturation \(saturation) vibrance \(vibrance) tinted the "
                           + "balanced card: \(moved) against \(balanced)")
            XCTAssertEqual(moved.y, balanced.y, accuracy: 0.004)
        }
    }
}
