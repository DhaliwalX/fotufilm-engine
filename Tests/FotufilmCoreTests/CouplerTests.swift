import XCTest
import FotufilmHalide
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

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
        XCTAssertFalse(definitions.isEmpty, "no bundled stock carries a coupler geometry")

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

    // MARK: - Stage 1A v4 Forward-Compensated QDI & Multi-Donor Chemistry Tests

    private func forwardQDIStock(donorCount: Int = 0, donorSecondary: Bool = false) -> FilmStock {
        var stock = TestStocks.negative
        stock.useForwardCouplerModel = true
        stock.couplerReleaseGamma = [1, 1, 1]
        stock.couplerReleaseKappa = [0.22, 0.26, 0.30]
        stock.couplerGeometry = CouplerGeometry(
            interlayerTransmission: CouplerGeometry.transmission(forRangeUM: 4.5),
            release: [0.85, 0.78, 0.62],
            selfRetention: 0.10,
            receiverSusceptibility: [1.0, 1.15, 0.90])
        stock.couplerInhibition = stock.couplerGeometry!.matrix()
        stock.couplerDiffusionMM = 0.012
        let baseSens = stock.spectralProfile.layerSensitivity
        var curve = stock.curves[1]
        if donorSecondary {
            curve.secondary = CharacteristicCurveComponent(
                gamma: 0.22, toe: 0.20, toeWidth: 0.30, shoulder: 1.40, shoulderWidth: 0.50)
        }
        let allDonors: [DonorCaptureLayer] = [
            DonorCaptureLayer(
                name: "CL cyan->red",
                sensitivity: baseSens[1].enumerated().map { idx, v in
                    0.75 * v + 0.25 * baseSens[0][idx]
                },
                curve: curve,
                inhibition: [0.32, 0, 0],
                releaseGamma: 1.0,
                releaseKappa: 0.28),
            DonorCaptureLayer(
                name: "MCCL green->blue",
                sensitivity: baseSens[1],
                curve: curve,
                inhibition: [0, 0, 0.24],
                releaseGamma: 1.0,
                releaseKappa: 0.35),
            DonorCaptureLayer(
                name: "DIR-HQ red->green",
                sensitivity: baseSens[0],
                curve: curve,
                inhibition: [0, 0.20, 0],
                releaseGamma: 1.1,
                releaseKappa: 0.40),
        ]
        stock.donorLayers = Array(allDonors.prefix(donorCount))
        return stock
    }

    func testCompetitiveQDIHillReleaseProperties() {
        for kappa in [Float(0.15), 0.5, 1.0, 2.5] {
            for gamma in [Float(0.8), 1.0, 1.6] {
                XCTAssertEqual(FilmEngineInvocation.inhibitorRelease(
                    activation: 0, kappa: kappa, gamma: gamma), 0, accuracy: 1e-7)
                XCTAssertEqual(FilmEngineInvocation.inhibitorRelease(
                    activation: 1, kappa: kappa, gamma: gamma), 1, accuracy: 1e-6)
                let mid = FilmEngineInvocation.inhibitorRelease(
                    activation: 0.5, kappa: kappa, gamma: gamma)
                XCTAssertEqual(mid, 1.0 / (1.0 + kappa), accuracy: 1e-6)
            }
        }
        // Default kappa = 1, gamma = 1 reduces identically to linear activation.
        for a in stride(from: Float(0), through: 1.0, by: 0.125) {
            XCTAssertEqual(FilmEngineInvocation.inhibitorRelease(activation: a, kappa: 1, gamma: 1),
                           a, accuracy: 1e-7)
        }
        // Depletion (kappa < 1) accelerates early release (concave: r(0.25) > 0.25).
        XCTAssertGreaterThan(
            FilmEngineInvocation.inhibitorRelease(activation: 0.25, kappa: 0.25, gamma: 1), 0.25)
    }

    func testReceiverSusceptibilityScalesRowsAndPreservesUnitDefault() {
        let unit = CouplerGeometry(
            interlayerTransmission: [0.30, 0.35],
            release: [0.9, 0.8, 0.7],
            selfRetention: 0.12)
        let scaled = CouplerGeometry(
            interlayerTransmission: [0.30, 0.35],
            release: [0.9, 0.8, 0.7],
            selfRetention: 0.12,
            receiverSusceptibility: [0.8, 1.25, 0.95])
        let u = unit.matrix()
        let s = scaled.matrix()
        let scales: [Float] = [0.8, 1.25, 0.95]
        for r in 0..<3 {
            for d in 0..<3 {
                XCTAssertEqual(s[r][d], u[r][d] * scales[r], accuracy: 1e-6)
            }
        }
    }

    func testForwardQDINeutralInvarianceUnderGlareHalationDiffusionFringeAndLabScan() throws {
        let stock = forwardQDIStock(donorCount: 3, donorSecondary: true)
        var full = FotufilmEngine.Options()
        full.grainScale = 0
        full.halationScale = 1.0
        full.flareScale = 1.0
        full.diffusionFilter = DiffusionFilter.preset(.blackProMist, grade: .two)
        full.chromaticFringeAmount = 0.35
        full.paper = .labScan
        full.screenExposureEV = 0.8
        full.sceneHighlightStops = 2.5
        full.sceneToneStops = SIMD3(0.2, -1.8, 1.8)

        var noCouplers = full
        noCouplers.couplerScale = 0

        for stops in [Float(-2.5), -1.0, 0.0, 1.5, 3.0] {
            let level = 0.18 * exp2(stops)
            let image = uniform(level, level, level, size: 48)
            let a = FotufilmEngine(stock: stock, options: full).process(linearRGB: image)
            let b = FotufilmEngine(stock: stock, options: noCouplers).process(linearRGB: image)
            let pa = a[24, 24]
            let pb = b[24, 24]
            XCTAssertEqual(pa.0, pb.0, accuracy: 2e-5, "R neutral at \(stops) EV")
            XCTAssertEqual(pa.1, pb.1, accuracy: 2e-5, "G neutral at \(stops) EV")
            XCTAssertEqual(pa.2, pb.2, accuracy: 2e-5, "B neutral at \(stops) EV")
        }

        // Also verify legacy COUPLER_MODEL = 0 LabScanTiming curve-shift neutral invariance fix.
        var legacyStock = forwardQDIStock(donorCount: 1, donorSecondary: true)
        legacyStock.useForwardCouplerModel = false
        let legA = FotufilmEngine(stock: legacyStock, options: full)
            .process(linearRGB: uniform(0.18, 0.18, 0.18, size: 48))[24, 24]
        let legB = FotufilmEngine(stock: legacyStock, options: noCouplers)
            .process(linearRGB: uniform(0.18, 0.18, 0.18, size: 48))[24, 24]
        XCTAssertEqual(legA.0, legB.0, accuracy: 5e-4)
        XCTAssertEqual(legA.1, legB.1, accuracy: 5e-4)
        XCTAssertEqual(legA.2, legB.2, accuracy: 5e-4)

        // Texture mode on a uniform field must also leave the neutral scene untouched.
        var textureOpts = full
        textureOpts.stage = .texture
        textureOpts.textureStages = [.emulsionMTF, .halation, .adjacency, .enlarger]
        let flatIn = uniform(0.18, 0.18, 0.18, size: 48)
        let flatOut = FotufilmEngine(stock: stock, options: textureOpts).process(linearRGB: flatIn)
        let pTex = flatOut[24, 24]
        XCTAssertEqual(pTex.0, 0.18, accuracy: 1e-5)
        XCTAssertEqual(pTex.1, 0.18, accuracy: 1e-5)
        XCTAssertEqual(pTex.2, 0.18, accuracy: 1e-5)
    }

    func testMultiDonorAndLoopGainClampCPUAndHalideMetalParity() throws {
        let w = 64, h = 48
        var planar = ImageBuffer(width: w, height: h)
        var interleaved = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let idx = y * w + x
                let u = Float(x) / Float(w - 1)
                let v = Float(y) / Float(h - 1)
                let edge: Float = x >= w / 2 ? 1.8 : 0.25
                let r = 0.04 + 0.85 * u * edge
                let g = 0.04 + 0.95 * (1 - u) * edge
                let b = 0.04 + 0.70 * v
                planar.planes[0][idx] = r
                planar.planes[1][idx] = g
                planar.planes[2][idx] = b
                interleaved[idx * 4] = r
                interleaved[idx * 4 + 1] = g
                interleaved[idx * 4 + 2] = b
                interleaved[idx * 4 + 3] = 1
            }
        }

        for count in 0...3 {
            let stock = forwardQDIStock(donorCount: count, donorSecondary: true)
            var opts = options
            opts.couplerScale = 2.0
            opts.chromaticFringeAmount = 0.25
            let inv = FilmEngineInvocation(stock: stock, options: opts, width: w, height: h)
            XCTAssertEqual(inv.configuration[FilmEngineInvocation.couplerModelOffset], 1)
            XCTAssertEqual(Int(inv.configuration[FilmEngineInvocation.donorCountOffset]), count)
            for row in 0..<3 {
                XCTAssertLessThanOrEqual(
                    inv.configuration[FilmEngineInvocation.couplerEffectiveScaleOffset + row], 1.5)
            }

            // Verify monotonic effective log-exposure under clamped couplerScale = 2.0 on a green ramp.
            var prevDensity: Float = -100
            for step in 0...8 {
                let gVal = 0.02 * exp2(Float(step) * 0.75)
                let d = centerDensity(stock, opts, uniform(0.08, gVal, 0.08, size: 24))
                XCTAssertGreaterThanOrEqual(d.1, prevDensity - 1e-4,
                                            "donors=\(count) green monotonic at step \(step)")
                prevDensity = d.1
            }

            #if canImport(Metal)
            if let gpu = HalideMetalFilmRenderer.shared {
                var negOpts = opts
                negOpts.stage = .negative
                let cpuNeg = FotufilmEngine(stock: stock, options: negOpts)
                    .developNegative(linearRGB: planar)
                let gpuNeg = try XCTUnwrap(gpu.processLinearFloat(
                    interleaved, width: w, height: h, stock: stock, options: negOpts))
                let cpuOut = FotufilmEngine(stock: stock, options: opts).process(linearRGB: planar)
                let gpuOut = try XCTUnwrap(gpu.processLinearFloat(
                    interleaved, width: w, height: h, stock: stock, options: opts))
                for y in 4..<(h - 4) {
                    for x in 4..<(w - 4) {
                        let idx = y * w + x
                        for c in 0..<3 {
                            XCTAssertEqual(
                                gpuNeg[idx * 4 + c], cpuNeg.planes[c][idx],
                                accuracy: 4e-4,
                                "neg donors=\(count) (\(x),\(y)) c=\(c)")
                            XCTAssertEqual(
                                gpuOut[idx * 4 + c], max(cpuOut.planes[c][idx], 0),
                                accuracy: 2e-3,
                                "full donors=\(count) (\(x),\(y)) c=\(c)")
                        }
                    }
                }
            }
            #endif
        }
    }

    func testDonorOnlyStockCarriesSpatialApronAcrossTiles() throws {
        var stock = forwardQDIStock(donorCount: 1, donorSecondary: false)
        stock.couplerGeometry = nil
        stock.couplerInhibition = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
        stock.couplerDiffusionMM = 0.25
        stock.emulsionDiffusionMM = [0, 0, 0]
        stock.adjacencyStrength = 0

        let w = 256, h = 512
        var stepImage = ImageBuffer(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let idx = y * w + x
                let lower = y >= h / 2
                stepImage.planes[0][idx] = 0.12
                stepImage.planes[1][idx] = lower ? 1.20 : 0.04
                stepImage.planes[2][idx] = 0.12
            }
        }
        let opts = options
        let inv = FilmEngineInvocation(stock: stock, options: opts, width: w, height: h)
        XCTAssertTrue((inv.featureMask & FilmEngineFeature.couplerDiffusion) != 0)
        XCTAssertGreaterThan(inv.spatialSupport, 0)
        XCTAssertLessThan(
            HalideBackend.stripRows(width: w, height: h, apron: inv.spatialSupport, budget: 3 << 20),
            h)

        let whole = try XCTUnwrap(
            HalideBackend.process(image: stepImage, stock: stock, options: opts, memoryBudget: 1 << 30))
        let tiled = try XCTUnwrap(
            HalideBackend.process(image: stepImage, stock: stock, options: opts, memoryBudget: 3 << 20))
        let maxDiff = zip(whole.interleavedRGB(), tiled.interleavedRGB()).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxDiff, 1e-5)
    }

    func testMultiDonorRefusalOnWebAndLayeredTransportAndPackRoundTrip() throws {
        let single = forwardQDIStock(donorCount: 1, donorSecondary: true)
        let multi = forwardQDIStock(donorCount: 2, donorSecondary: true)

        XCTAssertNoThrow(try WebFilmProfile.prepare(
            stock: single, options: options, width: 64, height: 48))
        XCTAssertThrowsError(try WebFilmProfile.prepare(
            stock: multi, options: options, width: 64, height: 48)) { error in
            XCTAssertEqual(error as? WebFilmProfile.Failure, .multiDonor)
        }

        // Verify v4 FilmStockDefinition JSON round-trip and validation invariants.
        let baseDef = try XCTUnwrap(FilmStock.presetDefinitions["example-negative-400"])
        let encoder = JSONEncoder()
        let v3Data = try encoder.encode(baseDef)
        let v3JSON = try XCTUnwrap(String(data: v3Data, encoding: .utf8))
        XCTAssertFalse(v3JSON.contains("couplerReleaseKappa"),
                       "v3 stock encoding must omit default v4 keys")
        XCTAssertFalse(v3JSON.contains("donorLayers"),
                       "v3 stock encoding must omit empty donorLayers")

        var v4Def = baseDef
        v4Def.schemaVersion = 4
        v4Def.couplerReleaseKappa = [0.25, 0.30, 0.35]
        v4Def.couplerGeometry = CouplerGeometry(
            interlayerTransmission: [0.28, 0.32],
            release: [0.80, 0.75, 0.60],
            selfRetention: 0.09,
            receiverSusceptibility: [1.0, 1.1, 0.95])
        v4Def.couplerInhibition = v4Def.couplerGeometry!.matrix()
        v4Def.donorLayers = multi.donorLayers.map(FilmStockDefinition.DonorLayerSpec.init)
        v4Def.development = FilmStockDefinition.DevelopmentSpec(
            FilmDevelopmentProfile(
                developer: "C-41",
                temperatureC: 37.8,
                agitation: "continuous",
                source: "synthetic",
                sourcePage: 1,
                conditions: [
                    FilmDevelopmentCondition(
                        stops: 1,
                        label: "+1 stop",
                        timeMinutes: 4.25,
                        basis: .measured,
                        curves: v4Def.stock.curves,
                        donorCurves: multi.donorLayers.map(\.curve),
                        couplerScale: 1.05,
                        couplerGeometry: v4Def.couplerGeometry)
                ]))
        XCTAssertNoThrow(try v4Def.validate())
        let v4RoundTrip = try JSONDecoder().decode(
            FilmStockDefinition.self, from: encoder.encode(v4Def))
        XCTAssertEqual(v4RoundTrip.schemaVersion, 4)
        XCTAssertEqual(v4RoundTrip.couplerReleaseKappa, [0.25, 0.30, 0.35])
        XCTAssertEqual(v4RoundTrip.couplerGeometry, v4Def.couplerGeometry)
        XCTAssertEqual(v4RoundTrip.donorLayers?.count, 2)
        XCTAssertEqual(v4RoundTrip.development?.conditions.first?.couplerScale, 1.05)
        XCTAssertTrue(v4RoundTrip.stock.useForwardCouplerModel)

        // Reject multi-donor on schemaVersion 3.
        var badSchema = v4Def
        badSchema.schemaVersion = 3
        XCTAssertThrowsError(try badSchema.validate())

        // Reject >1 positive inhibition entry per donor on schemaVersion 4.
        var badDonor = v4Def
        badDonor.donorLayers?[0].inhibition = [0.25, 0.10, 0]
        XCTAssertThrowsError(try badDonor.validate())

        // Reject interlayerTransmission > 0.88 on schemaVersion 4 while accepting 0.88.
        var edgeTrans = v4Def
        edgeTrans.couplerGeometry?.interlayerTransmission = [0.88, 0.32]
        edgeTrans.couplerInhibition = edgeTrans.couplerGeometry!.matrix()
        XCTAssertNoThrow(try edgeTrans.validate())
        edgeTrans.couplerGeometry?.interlayerTransmission = [0.89, 0.32]
        edgeTrans.couplerInhibition = edgeTrans.couplerGeometry!.matrix()
        XCTAssertThrowsError(try edgeTrans.validate())

        // Omitting `donorCurves` (`nil`) on a development condition inherits reference donor curves.
        var inheritedDonorDef = v4Def
        inheritedDonorDef.development?.conditions[0].donorCurves = nil
        inheritedDonorDef.development?.conditions[0].couplerScale = nil
        XCTAssertNoThrow(try inheritedDonorDef.validate())
        let inheritedPushed = try inheritedDonorDef.stock.pushed(stops: 1)
        XCTAssertEqual(inheritedPushed.donorLayers.count, inheritedDonorDef.stock.donorLayers.count)
        for i in inheritedPushed.donorLayers.indices {
            XCTAssertEqual(inheritedPushed.donorLayers[i].curve.density(logExposure: 0),
                           inheritedDonorDef.stock.donorLayers[i].curve.density(logExposure: 0),
                           accuracy: 1e-6)
        }
    }

    func testPerRowLoopGainClampIsolatesOverdrivenRowAndPreviewSigmaFloor() throws {
        var stock = forwardQDIStock(donorCount: 1, donorSecondary: false)
        stock.couplerDiffusionMM = 0.009
        stock.couplerGeometry = CouplerGeometry(
            interlayerTransmission: [0.35, 0.08],
            release: [1.65, 1.80, 0.25],
            selfRetention: 0.12,
            receiverSusceptibility: [1.45, 0.85, 0.45])
        stock.couplerInhibition = stock.couplerGeometry!.matrix()

        var reachOpts = options
        reachOpts.couplerGapReachScales = [2.8, 1.0]
        let inv = FilmEngineInvocation(stock: stock, options: reachOpts, width: 512, height: 342)
        let s0 = inv.configuration[FilmEngineInvocation.couplerEffectiveScaleOffset + 0]
        let s2 = inv.configuration[FilmEngineInvocation.couplerEffectiveScaleOffset + 2]
        XCTAssertLessThan(s0, 1.0, "overdriven red-green gap must clamp row 0")
        XCTAssertEqual(s2, 1.0, accuracy: 1e-6,
                       "per-row clamp must not collaterally attenuate untouched blue row 2")

        // Preview sigma floor (`0.85 px`) activates on downsampled 512x342 preview with variance-matched
        // pointwise cross-layer share, while full-res 4500x3000 (`0.009 * 125 = 1.125 px`) stays strictly
        // physical (`crossPointwiseShare == 0`) and `couplerDiffusionMM == 0` stays 0.
        XCTAssertEqual(inv.configuration[Int(FOTUFILM_CONFIG_COUPLER_SIGMA)],
                       FilmEngineInvocation.couplerPreviewSigmaFloorPixels, accuracy: 1e-6)
        let previewPhysical = stock.couplerDiffusionMM * reachOpts.pixelsPerMM(width: 512, height: 342)
        let expectedPreviewPt = 1 - pow(previewPhysical / FilmEngineInvocation.couplerPreviewSigmaFloorPixels, 2)
        XCTAssertEqual(inv.configuration[FilmEngineInvocation.couplerCrossPointwiseShareOffset],
                       expectedPreviewPt, accuracy: 1e-5)
        let fullRes = FilmEngineInvocation(stock: stock, options: options, width: 4500, height: 3000)
        let expectedFullSigma = stock.couplerDiffusionMM * options.pixelsPerMM(width: 4500, height: 3000)
        XCTAssertEqual(fullRes.configuration[Int(FOTUFILM_CONFIG_COUPLER_SIGMA)],
                       expectedFullSigma, accuracy: 1e-5)
        XCTAssertEqual(fullRes.configuration[FilmEngineInvocation.couplerCrossPointwiseShareOffset],
                       0, accuracy: 1e-6)

        var zeroDiff = stock
        zeroDiff.couplerDiffusionMM = 0
        let zeroInv = FilmEngineInvocation(stock: zeroDiff, options: options, width: 512, height: 342)
        XCTAssertEqual(zeroInv.configuration[Int(FOTUFILM_CONFIG_COUPLER_SIGMA)], 0, accuracy: 1e-6)
        XCTAssertEqual(zeroInv.configuration[Int(FOTUFILM_CONFIG_COUPLER_RADIUS)], 0, accuracy: 1e-6)
        XCTAssertEqual(zeroInv.configuration[FilmEngineInvocation.couplerCrossPointwiseShareOffset],
                       0, accuracy: 1e-6)
    }

    func testSeparatedBaseSignedDyeValidationAndThirtyYearExpiredHeadroom() throws {
        var baseDef = try XCTUnwrap(FilmStock.presetDefinitions["example-negative-400"])
        baseDef.schemaVersion = 4
        let sampleCount = SpectralGrid.count
        let zeroWave = [Float](repeating: 0, count: sampleCount)
        var baseDensity = [Float](repeating: 0.12, count: sampleCount)
        var dyeRows = [[Float]](repeating: zeroWave, count: 3)
        for i in 0..<sampleCount {
            let nm = SpectralGrid.wavelengths[i]
            let bTerm: Float = 0.55 * exp(-((nm - 450) / 55) * ((nm - 450) / 55))
            let gTerm: Float = 0.35 * exp(-((nm - 550) / 60) * ((nm - 550) / 60))
            baseDensity[i] = 0.15 + bTerm + gTerm
            // Cyan dye: positive red primary, small negative green mask depletion (-0.08).
            let cPrimary: Float = 1.0 * exp(-((nm - 650) / 55) * ((nm - 650) / 55))
            let cMask: Float = 0.08 * exp(-((nm - 550) / 45) * ((nm - 550) / 45))
            dyeRows[0][i] = cPrimary - cMask
            // Magenta dye: positive green primary, negative blue yellow-mask depletion (-0.12).
            let mPrimary: Float = 1.0 * exp(-((nm - 550) / 50) * ((nm - 550) / 50))
            let mMask: Float = 0.12 * exp(-((nm - 450) / 45) * ((nm - 450) / 45))
            dyeRows[1][i] = mPrimary - mMask
            // Yellow dye: positive blue primary.
            dyeRows[2][i] = 1.0 * exp(-((nm - 450) / 45) * ((nm - 450) / 45))
        }
        let baseSensitivity = baseDef.stock.spectralProfile.layerSensitivity
        baseDef.spectral = .separatedBase(
            layerSensitivity: baseSensitivity,
            imageDyeDensity: dyeRows,
            minimumDensity: baseDensity)
        XCTAssertNoThrow(try baseDef.validate())

        // Verify 30-year expired film keeps positive headroom and finite NegativeScanCrosstalk.
        let stock = baseDef.stock
        let aged30 = stock.expired(years: 30)
        for c in 0..<3 {
            XCTAssertGreaterThan(aged30.curves[c].dMin, stock.curves[c].dMin)
        }
        let crosstalk = NegativeScanCrosstalk.weights(
            for: aged30, correction: .init(strength: 1, light: .rgb), neutral: nil)
        XCTAssertEqual(crosstalk.count, 3)
        XCTAssertTrue(crosstalk.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })

        // Negative secondary without .separatedBase must fail validation.
        var badEmbedded = baseDef
        badEmbedded.spectral = .samples(
            layerSensitivity: baseSensitivity,
            imageDyeDensity: dyeRows)
        XCTAssertThrowsError(try badEmbedded.validate())

        // V1: negative secondary exceeding minimumDensity + 30yr fog headroom (< 0.02) must fail.
        var badHeadroomRows = dyeRows
        for i in 0..<sampleCount {
            let nm = SpectralGrid.wavelengths[i]
            let excess: Float = 0.80 * exp(-((nm - 550) / 45) * ((nm - 550) / 45))
            badHeadroomRows[0][i] -= excess
        }
        var badHeadroom = baseDef
        badHeadroom.spectral = .separatedBase(
            layerSensitivity: baseSensitivity,
            imageDyeDensity: badHeadroomRows,
            minimumDensity: baseDensity)
        XCTAssertThrowsError(try badHeadroom.validate())
    }
}
