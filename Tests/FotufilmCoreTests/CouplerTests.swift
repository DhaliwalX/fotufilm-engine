import XCTest
import FotufilmHalide
@testable import FotufilmCore

final class CouplerTests: XCTestCase {
    private let couplerStocks: [FilmStock] = [
        TestStocks.negative, TestStocks.negative, TestStocks.negative, TestStocks.negative, TestStocks.negative, TestStocks.negative,
    ]

    private var options: FotufilmEngine.Options {
        var o = FotufilmEngine.Options()
        o.grainScale = 0
        o.halationScale = 0
        return o
    }

    private func uniform(_ r: Float, _ g: Float, _ b: Float, size: Int = 32) -> ImageBuffer {
        var image = ImageBuffer(width: size, height: size)
        for i in 0..<image.pixelCount {
            image.planes[0][i] = r
            image.planes[1][i] = g
            image.planes[2][i] = b
        }
        return image
    }

    private func centerDensity(_ stock: FilmStock, _ options: FotufilmEngine.Options,
                               _ image: ImageBuffer) -> (Float, Float, Float) {
        let developed = FotufilmEngine(stock: stock, options: options)
            .developNegative(linearRGB: image)
        return developed[developed.width / 2, developed.height / 2]
    }

    func testNeutralSubjectDevelopsIdenticallyWithAndWithoutCouplers() {
        var off = options
        off.couplerScale = 0
        for stock in couplerStocks {
            for level in [Float(0.02), 0.05, 0.09, 0.18, 0.4, 0.9, 2.0] {
                let image = uniform(level, level, level)
                let with = centerDensity(stock, options, image)
                let without = centerDensity(stock, off, image)
                let message = "\(stock.name) at neutral \(level)"
                XCTAssertEqual(with.0, without.0, accuracy: 1e-3, message)
                XCTAssertEqual(with.1, without.1, accuracy: 1e-3, message)
                XCTAssertEqual(with.2, without.2, accuracy: 1e-3, message)
            }
        }
    }

    func testCouplersAreTransparentToNeutralsThroughThePrint() {
        var off = options
        off.couplerScale = 0
        let sim = FotufilmEngine(stock: TestStocks.negative, options: options)
        let silent = FotufilmEngine(stock: TestStocks.negative, options: off)
        for stops in [Float(-2), -1, 0, 1, 2, 3] {
            let level = 0.18 * exp2(stops)
            let image = uniform(level, level, level)
            let with = sim.process(linearRGB: image)
            let without = silent.process(linearRGB: image)
            let a = with[with.width / 2, with.height / 2]
            let b = without[without.width / 2, without.height / 2]
            let message = "neutral at \(stops) stops"
            XCTAssertEqual(a.0, b.0, accuracy: 1e-5, message)
            XCTAssertEqual(a.1, b.1, accuracy: 1e-5, message)
            XCTAssertEqual(a.2, b.2, accuracy: 1e-5, message)
        }
    }

    func testNeutralRampKeepsItsContrastWithCouplersActive() {
        var off = options
        off.couplerScale = 0
        for stock in couplerStocks {
            let shadow = uniform(0.05, 0.05, 0.05)
            let highlight = uniform(0.72, 0.72, 0.72)
            let withSpan = centerDensity(stock, options, highlight).1
                - centerDensity(stock, options, shadow).1
            let withoutSpan = centerDensity(stock, off, highlight).1
                - centerDensity(stock, off, shadow).1
            XCTAssertEqual(withSpan, withoutSpan, accuracy: 2e-3, stock.name)
        }
    }

    func testCouplerWarpInvertsTheNeutralInhibition() {
        let samples = FilmEngineInvocation.couplerWarpSamples
        let low = FilmEngineInvocation.couplerWarpMin
        let high = FilmEngineInvocation.couplerWarpMax
        for stock in couplerStocks {
            let table = FilmEngineInvocation.couplerWarp(
                curves: stock.curves, inhibition: stock.couplerInhibition, scale: 1,
                releaseGamma: stock.couplerReleaseGamma)
            XCTAssertEqual(table.count, 3 * samples)

            for channel in 0..<3 {
                for step in 0...48 {
                    let l = Float(-3) + Float(step) * (6.0 / 48.0)
                    var released: Float = 0
                    for donor in 0..<3 {
                        let curve = stock.curves[donor]
                        let range = curve.dMax - curve.dMin
                        let activation =
                            (curve.density(logExposure: l) - curve.dMin) / range
                        let release = FilmEngineInvocation.inhibitorRelease(
                            activation: activation,
                            gamma: stock.couplerReleaseGamma[donor])
                        released += stock.couplerInhibition[channel][donor] * release
                    }
                    let u = l - released

                    let q = min(max((u - low) * (Float(samples - 1) / (high - low)), 0),
                                Float(samples - 1))
                    let index = min(Int(q), samples - 2)
                    let frac = q - Float(index)
                    let base = channel * samples
                    let offset = table[base + index]
                        + frac * (table[base + index + 1] - table[base + index])

                    XCTAssertEqual(u + offset, l, accuracy: 5e-4,
                                   "\(stock.name) channel \(channel) at logE \(l)")
                }
            }
        }
    }

    func testNonlinearReleaseHasThresholdMidpointAndSaturation() {
        XCTAssertEqual(FilmEngineInvocation.inhibitorRelease(activation: 0, gamma: 1.8), 0)
        XCTAssertEqual(FilmEngineInvocation.inhibitorRelease(activation: 0.5, gamma: 1.8),
                       0.5, accuracy: 1e-7)
        XCTAssertEqual(FilmEngineInvocation.inhibitorRelease(activation: 1, gamma: 1.8), 1)
        XCTAssertLessThan(FilmEngineInvocation.inhibitorRelease(activation: 0.25, gamma: 1.8),
                          0.25)
        XCTAssertGreaterThan(FilmEngineInvocation.inhibitorRelease(activation: 0.75, gamma: 1.8),
                             0.75)
        XCTAssertEqual(FilmEngineInvocation.inhibitorRelease(activation: 0.25, gamma: 1),
                       0.25)
    }

    func testNonlinearReleaseChangesAChromaticSubject() {
        var linear = TestStocks.negative
        linear.couplerReleaseGamma = [1, 1, 1]
        let image = uniform(0.08, 0.55, 0.10)
        let old = centerDensity(linear, options, image)
        let nonlinear = centerDensity(TestStocks.negative, options, image)

        let largestDifference = max(abs(nonlinear.0 - old.0),
                                    abs(nonlinear.1 - old.1),
                                    abs(nonlinear.2 - old.2))
        XCTAssertGreaterThan(largestDifference, 1e-3)
    }

    /// A stock that releases no inhibitor needs no anchor, and must not be given one — an all-zero
    /// matrix has to leave log exposure untouched.
    func testStocksWithoutCouplersGetAnIdentityWarp() {
        for stock in [TestStocks.monochrome, TestStocks.reversal] {
            let table = FilmEngineInvocation.couplerWarp(
                curves: stock.curves, inhibition: stock.couplerInhibition, scale: 1)
            XCTAssertFalse(table.contains { $0 != 0 }, stock.name)
        }
    }

    func testSwiftAndHalideAgreeOnTheConfigurationLayout() {
        XCTAssertEqual(FilmEngineInvocation.configurationCount,
                       FOTUFILM_FRAME_CONFIGURATION_COUNT)
        XCTAssertEqual(FilmEngineInvocation.couplerWarpOffset,
                       FOTUFILM_CONFIG_COUPLER_WARP)
        XCTAssertEqual(FilmEngineInvocation.couplerWarpSamples,
                       FOTUFILM_COUPLER_WARP_SAMPLES)
        XCTAssertEqual(FilmEngineInvocation.couplerWarpMin,
                       Float(FOTUFILM_COUPLER_WARP_MIN))
        XCTAssertEqual(FilmEngineInvocation.couplerWarpMax,
                       Float(FOTUFILM_COUPLER_WARP_MAX))
        XCTAssertEqual(FilmEngineInvocation.flareMeanOffset,
                       FOTUFILM_CONFIG_FLARE_MEAN)
        XCTAssertEqual(FilmEngineInvocation.sceneAdjustOffset,
                       FOTUFILM_CONFIG_HIGHLIGHTS)
        XCTAssertEqual(FilmEngineInvocation.gradeSpaceOffset,
                       FOTUFILM_CONFIG_GRADE_SPACE)
        XCTAssertEqual(FilmEngineInvocation.mottleSigmaOffset,
                       FOTUFILM_CONFIG_MOTTLE_SIGMA)
        XCTAssertEqual(FilmEngineInvocation.mottleOffset,
                       FOTUFILM_CONFIG_MOTTLE)
        XCTAssertEqual(FilmEngineInvocation.paperRedOffset,
                       FOTUFILM_CONFIG_PAPER_RED)
        XCTAssertEqual(FilmEngineInvocation.paperBlueOffset,
                       FOTUFILM_CONFIG_PAPER_BLUE)
        XCTAssertEqual(FilmEngineInvocation.paperMidpointRedOffset,
                       FOTUFILM_CONFIG_PAPER_MIDPOINT_RED)
        XCTAssertEqual(FilmEngineInvocation.paperMidpointBlueOffset,
                       FOTUFILM_CONFIG_PAPER_MIDPOINT_BLUE)
        XCTAssertEqual(FilmEngineInvocation.curveSecondaryOffset,
                       FOTUFILM_CONFIG_CURVE_SECONDARY)
        XCTAssertEqual(FilmEngineInvocation.mtfSecondarySigmaOffset,
                       FOTUFILM_CONFIG_MTF_SECONDARY_SIGMA)
        XCTAssertEqual(FilmEngineInvocation.mtfSecondaryRadiusOffset,
                       FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS)
        XCTAssertEqual(FilmEngineInvocation.mtfPrimaryShareOffset,
                       FOTUFILM_CONFIG_MTF_PRIMARY_SHARE)
        XCTAssertEqual(FilmEngineInvocation.couplerReleaseGammaOffset,
                       FOTUFILM_CONFIG_COUPLER_RELEASE_GAMMA)
        XCTAssertEqual(FilmEngineInvocation.donorReleaseGammaOffset,
                       FOTUFILM_CONFIG_DONOR_RELEASE_GAMMA)
    }

    func testMatrixIsIndexedReceiverByDonor() {
        var silent = TestStocks.negative
        silent.couplerInhibition = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
        var greenIntoRed = silent
        greenIntoRed.couplerInhibition[0][1] = 0.30

        let image = uniform(0.10, 0.55, 0.12)
        let base = centerDensity(silent, options, image)
        let inhibited = centerDensity(greenIntoRed, options, image)

        XCTAssertNotEqual(inhibited.0, base.0, accuracy: 5e-3,
                          "green donor must reach the red layer")
        XCTAssertEqual(inhibited.1, base.1, accuracy: 1e-5,
                       "nothing donates to green, so green must not move")
        XCTAssertEqual(inhibited.2, base.2, accuracy: 1e-5,
                       "nothing donates to blue, so blue must not move")
    }

    func testInhibitionFromABrighterDonorReducesReceiverDensity() {
        var silent = TestStocks.negative
        silent.couplerInhibition = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
        var greenIntoRed = silent
        greenIntoRed.couplerInhibition[0][1] = 0.30

        let image = uniform(0.10, 0.55, 0.12)
        let base = centerDensity(silent, options, image)
        let inhibited = centerDensity(greenIntoRed, options, image)
        XCTAssertLessThan(inhibited.0, base.0)
    }

    func testStrongerCouplingInhibitsFurther() {
        var silent = TestStocks.negative
        silent.couplerInhibition = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
        var weak = silent
        weak.couplerInhibition[0][1] = 0.15
        var strong = silent
        strong.couplerInhibition[0][1] = 0.30

        let image = uniform(0.10, 0.55, 0.12)
        let base = centerDensity(silent, options, image).0
        let weakDensity = centerDensity(weak, options, image).0
        let strongDensity = centerDensity(strong, options, image).0

        XCTAssertLessThan(weakDensity, base)
        XCTAssertLessThan(strongDensity, weakDensity)
    }

    func testCouplerScaleTracksTheAnchor() {
        var half = options
        half.couplerScale = 0.5
        var off = options
        off.couplerScale = 0

        let neutral = uniform(0.18, 0.18, 0.18)
        let halfNeutral = centerDensity(TestStocks.negative, half, neutral)
        let offNeutral = centerDensity(TestStocks.negative, off, neutral)
        XCTAssertEqual(halfNeutral.0, offNeutral.0, accuracy: 1e-3)
        XCTAssertEqual(halfNeutral.1, offNeutral.1, accuracy: 1e-3)
        XCTAssertEqual(halfNeutral.2, offNeutral.2, accuracy: 1e-3)

        let saturated = uniform(0.08, 0.55, 0.10)
        func separation(_ options: FotufilmEngine.Options) -> Float {
            let d = centerDensity(TestStocks.negative, options, saturated)
            return max(d.0, d.1, d.2) - min(d.0, d.1, d.2)
        }
        XCTAssertGreaterThan(separation(options), separation(half))
        XCTAssertGreaterThan(separation(half), separation(off))
    }

    func testCouplerOverdriveIsBoundedAboveTheCalibratedPosition() {
        XCTAssertEqual(FilmEngineInvocation.effectiveCouplerScale(0), 0)
        XCTAssertEqual(FilmEngineInvocation.effectiveCouplerScale(0.5), 0.5)
        XCTAssertEqual(FilmEngineInvocation.effectiveCouplerScale(1), 1)
        XCTAssertEqual(FilmEngineInvocation.effectiveCouplerScale(2), 1.5)
        XCTAssertLessThan(FilmEngineInvocation.effectiveCouplerScale(100), 2)
    }

    private var geometry: CouplerGeometry {
        CouplerGeometry(
            interlayerTransmission: CouplerGeometry.transmission(forRangeUM: 4.2),
            release: [0.985, 0.919, 0.666],
            selfRetention: 0.091)
    }

    func testEveryEntryIsNonNegativeAtAnySetting() {
        for range in [Float(0), 0.1, 1, 4.2, 20, 200] {
            for retention in [Float(0), 0.09, 1, 3] {
                let g = CouplerGeometry(
                    interlayerTransmission:
                        CouplerGeometry.transmission(forRangeUM: range),
                    release: [1.1, 0.9, 0.6],
                    selfRetention: retention)
                for row in g.matrix() {
                    for entry in row {
                        XCTAssertGreaterThanOrEqual(
                            entry, 0,
                            "range \(range), retention \(retention)")
                    }
                }
            }
        }
    }

    func testInhibitionFallsOffWithLayerSeparation() {
        let k = geometry.matrix()
        XCTAssertGreaterThan(k[0][1], k[0][2],
                             "red hears green (6 µm) over blue (11 µm)")
        XCTAssertGreaterThan(k[2][1], k[2][0],
                             "blue hears green (5 µm) over red (11 µm)")
        XCTAssertGreaterThan(k[1][0], k[1][2],
                             "green hears red (6 µm) less than... ")
        XCTAssertGreaterThan(k[1][2], min(k[0][2], k[2][0]),
                             "the far pair is the weakest exchange")
    }

    func testAsymmetryComesOnlyFromReleaseStrength() {
        let g = geometry
        let k = g.matrix()
        for i in 0..<3 {
            for j in 0..<3 where i != j {
                XCTAssertEqual(k[i][j] / k[j][i],
                               g.release[j] / g.release[i],
                               accuracy: 1e-5,
                               "K[\(i)][\(j)] vs K[\(j)][\(i)]")
            }
        }
    }

    func testZeroRangeIsolatesTheLayers() {
        let k = geometry.matrix(gapReachScales: [0, 0])
        for i in 0..<3 {
            for j in 0..<3 where i != j {
                XCTAssertEqual(k[i][j], 0, accuracy: 1e-9)
            }
            XCTAssertGreaterThan(k[i][i], 0)
        }
    }

    func testTheTwoScalesMoveDisjointHalvesOfTheMatrix() {
        let base = geometry.matrix()
        let wider = geometry.matrix(gapReachScales: [2, 2])
        let louder = geometry.matrix(selfScale: 2)

        for i in 0..<3 {
            XCTAssertEqual(wider[i][i], base[i][i], accuracy: 1e-6,
                           "range must not touch the diagonal")
            XCTAssertEqual(louder[i][i], base[i][i] * 2, accuracy: 1e-6)
            for j in 0..<3 where i != j {
                XCTAssertGreaterThan(wider[i][j], base[i][j],
                                     "a longer reach crosses more")
                XCTAssertEqual(louder[i][j], base[i][j], accuracy: 1e-6,
                               "self-scale must not touch the crossing")
            }
        }
    }

    func testFitRecoversAGeometryItGenerated() {
        let original = geometry
        let fitted = CouplerGeometry.fit(to: original.matrix())
        for gap in original.interlayerTransmission.indices {
            XCTAssertEqual(fitted.interlayerTransmission[gap],
                           original.interlayerTransmission[gap],
                           accuracy: 5e-3, "gap \(gap)")
        }
        XCTAssertEqual(fitted.selfRetention, original.selfRetention,
                       accuracy: 5e-3)
        for layer in 0..<3 {
            XCTAssertEqual(fitted.release[layer], original.release[layer],
                           accuracy: 5e-3)
        }
        XCTAssertLessThan(fitted.residual(against: original.matrix()), 1e-4)
    }

    func testShippedPacksAgreeWithTheirOwnGeometry() throws {
        let definitions = FilmStock.allPresetIDs
            .compactMap { FilmStock.presetDefinitions[$0] }
            .filter { $0.couplerGeometry != nil }
        try XCTSkipIf(definitions.isEmpty, "no pack installed carries geometry")

        for definition in definitions {
            let derived = definition.couplerGeometry!.matrix()
            for i in 0..<3 {
                for j in 0..<3 {
                    XCTAssertEqual(definition.couplerInhibition[i][j], derived[i][j],
                                   accuracy: 1e-4,
                                   "\(definition.id) K[\(i)][\(j)]")
                }
            }
        }
    }

    func testInterImageSolveRecoversKnownRelease() throws {
        let g = geometry
        let k = g.matrix()
        let slopes: [Float] = [0.42, 0.45, 0.40]

        let ratios: [Float] = (0..<3).map { c in
            let own = 1 - k[c][c] * slopes[c]
            let all = 1 - (0..<3).reduce(Float(0)) { $0 + k[c][$1] * slopes[$1] }
            return own / all
        }
        XCTAssertTrue(ratios.allSatisfy { $0 > 1 },
                      "a separation exposure develops the harder contrast")

        let solved = try XCTUnwrap(CouplerGeometry.releaseSolvedFromInterImage(
            ratios, activationSlopes: slopes,
            interlayerTransmission: g.interlayerTransmission,
            selfRetention: g.selfRetention))
        for layer in 0..<3 {
            XCTAssertEqual(solved[layer], g.release[layer], accuracy: 1e-3)
        }
    }

    func testInterImageSolveRejectsUnphysicalRatios() {
        let transmission = CouplerGeometry.transmission(forRangeUM: 4.2)
        XCTAssertNil(CouplerGeometry.releaseSolvedFromInterImage(
            [1.0, 1.1, 1.1], activationSlopes: [0.42, 0.45, 0.40],
            interlayerTransmission: transmission))
        XCTAssertNil(CouplerGeometry.releaseSolvedFromInterImage(
            [0.9, 1.1, 1.1], activationSlopes: [0.42, 0.45, 0.40],
            interlayerTransmission: transmission))
    }

    func testReachScaleMatchesTheDecayFormItReplaced() {
        let depths = CouplerGeometry.colorNegativeDepthUM
        let release: [Float] = [0.985, 0.919, 0.666]
        let range: Float = 4.2

        for scale in [Float(0.25), 0.5, 1, 2, 3] {
            let produced = CouplerGeometry(
                interlayerTransmission: CouplerGeometry.transmission(forRangeUM: range),
                release: release, selfRetention: 0.091
            ).matrix(gapReachScales: [scale, scale])

            for i in 0..<3 {
                for j in 0..<3 where i != j {
                    let decayed = release[j]
                        * exp(-abs(depths[i] - depths[j]) / (range * scale))
                    XCTAssertEqual(produced[i][j], decayed, accuracy: 1e-6,
                                   "scale \(scale), K[\(i)][\(j)]")
                }
            }
        }
    }

    func testTransposedTransmissionIsNotTheSameGeometry() {
        let forward = CouplerGeometry(interlayerTransmission: [0.2577, 0.3231],
                                      release: [0.985, 0.919, 0.666])
        let reversed = CouplerGeometry(interlayerTransmission: [0.3231, 0.2577],
                                       release: [0.985, 0.919, 0.666])
        let a = forward.matrix(), b = reversed.matrix()

        XCTAssertEqual(a[0][2], b[0][2], accuracy: 1e-6,
                       "red and blue are separated by both interlayers either way")
        XCTAssertNotEqual(a[0][1], b[0][1], accuracy: 1e-3,
                          "the red-green crossing must notice which barrier it crossed")
        XCTAssertNotEqual(a[2][1], b[2][1], accuracy: 1e-3,
                          "and so must the blue-green one")
    }

    func testSealingOneGapAlsoStopsWhatSpansIt() {
        let k = geometry.matrix(gapReachScales: [0, 1])

        XCTAssertEqual(k[0][1], 0, accuracy: 1e-9, "red-green crosses the sealed gap")
        XCTAssertEqual(k[0][2], 0, accuracy: 1e-9, "red-blue spans it too")
        XCTAssertGreaterThan(k[2][1], 0, "green-blue is on the far side and survives")
    }

    private var geometricStock: FilmStock {
        var stock = TestStocks.negative
        stock.couplerGeometry = geometry
        return stock
    }

    func testRangeScaleReachesTheRenderWithoutMovingNeutral() {
        var sealed = options
        sealed.couplerRangeScale = 0
        var wide = options
        wide.couplerRangeScale = 2

        let neutral = uniform(0.18, 0.18, 0.18)
        let sealedNeutral = centerDensity(geometricStock, sealed, neutral)
        let wideNeutral = centerDensity(geometricStock, wide, neutral)
        XCTAssertEqual(sealedNeutral.0, wideNeutral.0, accuracy: 2e-3)
        XCTAssertEqual(sealedNeutral.1, wideNeutral.1, accuracy: 2e-3)
        XCTAssertEqual(sealedNeutral.2, wideNeutral.2, accuracy: 2e-3)

        let saturated = uniform(0.08, 0.55, 0.10)
        func separation(_ o: FotufilmEngine.Options) -> Float {
            let d = centerDensity(geometricStock, o, saturated)
            return max(d.0, d.1, d.2) - min(d.0, d.1, d.2)
        }
        XCTAssertGreaterThan(separation(wide), separation(sealed))
    }

    func testStatedMatricesIgnoreTheGeometryScales() {
        XCTAssertNil(TestStocks.negative.couplerGeometry)
        var moved = options
        moved.couplerRangeScale = 0
        moved.couplerSelfScale = 3

        let image = uniform(0.08, 0.55, 0.10)
        let base = centerDensity(TestStocks.negative, options, image)
        let scaled = centerDensity(TestStocks.negative, moved, image)
        XCTAssertEqual(base.0, scaled.0, accuracy: 1e-6)
        XCTAssertEqual(base.1, scaled.1, accuracy: 1e-6)
        XCTAssertEqual(base.2, scaled.2, accuracy: 1e-6)
    }
}
