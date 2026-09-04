import XCTest
@testable import FotufilmCore

final class HalationTests: XCTestCase {

    private static let physicalProfile = HalationProfile(
        roundTripOpticalDepth: [0.7, 1.0, 1.3],
        angularExponent: [0.8, 1.1, 1.5],
        diffuseShare: [0.08, 0.14, 0.22],
        diffuseSigmaMM: [0.018, 0.014, 0.010],
        bounceRetention: [0.18, 0.12, 0.08],
        recordDepthMM: [0, 0.006, 0.012])

    func testReturnMatrixSplitsTheMixAndDefaultsToTheDiagonal() {
        let base = FilmFormat.still35.base
        let returned: [Float] = [0.12, 0.044, 0.0176]

        let plain = Halation.kernel(returned: returned, base: base)
        for receiver in 0..<3 {
            for source in 0..<3 {
                XCTAssertEqual(plain.matrix[receiver][source],
                               source == receiver ? plain.mix[receiver] : 0,
                               "no matrix keeps the share on the diagonal")
            }
        }

        // The zero blue row falls back to its diagonal rather than dropping the share.
        let sheetMatrix: [[Float]] = [[0.0999, 0, 0.0016],
                                      [0.0002, 0.0033, 0],
                                      [0, 0, 0]]
        let routed = Halation.kernel(returned: returned, base: base,
                                     returnMatrix: sheetMatrix)
        XCTAssertEqual(routed.mix, plain.mix)
        for receiver in 0..<3 {
            let rowSum = routed.matrix[receiver].reduce(0, +)
            XCTAssertEqual(rowSum, routed.mix[receiver], accuracy: 1e-6,
                           "receiver \(receiver) keeps its amplitude")
        }
        XCTAssertEqual(routed.matrix[2], [0, 0, routed.mix[2]])
        // The routing itself is the sheet's row shape.
        XCTAssertEqual(routed.matrix[0][2] / routed.matrix[0][0],
                       sheetMatrix[0][2] / sheetMatrix[0][0], accuracy: 1e-4)
        XCTAssertGreaterThan(routed.matrix[0][0], routed.matrix[0][2],
                             "the red row stays diagonal-dominant")
    }

    func testHaloRadiusIsTheCriticalAngleReturn() {
        let base = FilmBase.acetate(thicknessMM: 0.13)
        XCTAssertEqual(base.criticalAngle * 180 / .pi, 42.51, accuracy: 0.02)
        XCTAssertEqual(base.haloRadiusMM,
                       2 * 0.13 * tan(asin(1 / 1.48)), accuracy: 1e-6)
        XCTAssertEqual(base.haloRadiusMM, 0.238, accuracy: 0.002)

        let estar = FilmBase.estar(thicknessMM: 0.13)
        XCTAssertLessThan(estar.haloRadiusMM, base.haloRadiusMM)
    }

    func testFormatsCarryTheirDatasheetSupports() {
        XCTAssertEqual(FilmFormat.still35.base.thicknessMM, 0.13, accuracy: 1e-6)
        XCTAssertEqual(FilmFormat.mediumFormat120.base.thicknessMM, 0.10, accuracy: 1e-6)
        XCTAssertEqual(FilmFormat.largeFormat4x5.base.refractiveIndex, 1.64, accuracy: 1e-6)

        XCTAssertLessThan(FilmFormat.mediumFormat120.base.haloRadiusMM,
                          FilmFormat.still35.base.haloRadiusMM)
    }

    func testStandardSupportsCarryDispersionAndCustomSupportsKeepTheirIndex() {
        let acetate = FilmBase.acetate(thicknessMM: 0.13)
        XCTAssertEqual((0..<3).map { acetate.refractiveIndex(forRecord: $0) },
                       [1.474, 1.480, 1.489])

        let custom = FilmBase(thicknessMM: 0.13, refractiveIndex: 1.52)
        XCTAssertEqual((0..<3).map { custom.refractiveIndex(forRecord: $0) },
                       [1.52, 1.52, 1.52])

        let dispersed = FilmBase(
            thicknessMM: 0.13, refractiveIndex: 1.52,
            recordRefractiveIndices: [1.50, 1.52, 1.54])
        let returned: [Float] = [0.08, 0.03, 0.01]
        XCTAssertNotEqual(HalationRuntime.kernel(returned: returned, base: custom),
                          HalationRuntime.kernel(returned: returned, base: dispersed))
    }

    func testReflectanceIsFresnelBelowTheCriticalAngleAndUnityAbove() {
        let n: Float = 1.48
        XCTAssertEqual(Halation.reflectance(cosTheta: 1, index: n),
                       pow((n - 1) / (n + 1), 2), accuracy: 1e-6)
        let critical = asin(1 / n)
        var previous: Float = 0
        for step in 0...20 {
            let theta = critical * Float(step) / 20
            let value = Halation.reflectance(cosTheta: cos(theta), index: n)
            XCTAssertGreaterThanOrEqual(value, previous - 1e-6)
            previous = value
        }
        XCTAssertEqual(previous, 1, accuracy: 1e-3)
        XCTAssertEqual(Halation.reflectance(cosTheta: cos(critical + 0.2), index: n),
                       1, accuracy: 1e-6)
    }

    func testTransmittanceInvertsTheReturnedFraction() {
        for fraction: Float in [0.001, 0.008, 0.03, 0.055, 0.12, 0.3] {
            let t = Halation.transmittance(returning: fraction, index: 1.48)
            XCTAssertEqual(Halation.returnedFraction(transmittance: t, index: 1.48),
                           fraction, accuracy: fraction * 1e-3)
        }
    }

    func testPolarizedMultiBounceCountsBothInterfaceReflections() {
        let optics = Halation.Optics(index: 1.48)
        let transmittance: Float = 0.6
        var expected: Float = 0
        for index in 0..<Halation.angleSamples {
            let perTrip = Halation.survival(
                transmittance: transmittance, cosTheta: optics.cosines[index])
            var survival = perTrip
            var returned: Float = 0
            for bounce in 1...Halation.bounceCount {
                let reflectionCount = Float(2 * bounce - 1)
                returned += 0.5 * (
                    pow(optics.reflectancesS[index], reflectionCount)
                        + pow(optics.reflectancesP[index], reflectionCount)) * survival
                survival *= perTrip
            }
            expected += returned * optics.lambertian[index]
        }
        expected *= optics.step

        XCTAssertEqual(Halation.returnedFraction(transmittance: transmittance,
                                                 optics: optics),
                       expected, accuracy: 1e-6)
    }

    func testMoreAbsorptionMeansLessAndTighterHalation() {
        let base = FilmBase.acetate(thicknessMM: 0.13)
        var previousRadius: Float = 0
        for fraction: Float in [0.002, 0.008, 0.03, 0.10, 0.30] {
            let profile = Halation.Profile(returning: fraction, base: base,
                                           optics: .init(index: 1.48))
            var radius: Float = 0
            for step in 1...400 {
                let distance = Float(step) * 0.01
                if profile.edgeSpread(distance: distance) > 0.05 { radius = distance }
            }
            XCTAssertGreaterThan(radius, previousRadius,
                                 "a weaker antihalation path should reach further")
            previousRadius = radius
        }
    }

    func testEdgeSpreadStartsAtHalfAndDecaysMonotonically() {
        let base = FilmBase.acetate(thicknessMM: 0.13)
        let profile = Halation.Profile(returning: 0.055, base: base,
                                       optics: .init(index: 1.48))
        XCTAssertEqual(profile.edgeSpread(distance: 0),
                       0.5, accuracy: 1e-4, "half the scattered light lands each side")
        var previous: Float = 0.5
        for step in 1...60 {
            let value = profile.edgeSpread(distance: Float(step) * 0.02)
            XCTAssertLessThanOrEqual(value, previous + 1e-6)
            previous = value
        }
        XCTAssertLessThan(previous, 0.01)
    }

    func testMixNormalizesAgainstTheSensitometricPatch() {
        XCTAssertEqual(Halation.mix(returning: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(Halation.mix(returning: 0.055), 0.055 / 1.055, accuracy: 1e-6)
        XCTAssertLessThan(Halation.mix(returning: 10), 1, "the mix can never reach 1")
    }

    func testHazeBroadensTheScalesInQuadratureAndZeroIsTheCleanSupport() {
        let base = FilmBase.acetate(thicknessMM: 0.13)
        let returned: [Float] = [0.03, 0.011, 0.0044]
        for profile in [nil, Self.physicalProfile] {
            let clean = Halation.kernel(returned: returned, base: base,
                                        profile: profile)
            XCTAssertEqual(Halation.kernel(returned: returned, base: base,
                                           profile: profile, hazeMM: 0), clean)
            let haze: Float = 0.05
            let fuzzy = Halation.kernel(returned: returned, base: base,
                                        profile: profile, hazeMM: haze)
            for (a, b) in zip(clean.sigmaMM, fuzzy.sigmaMM) {
                XCTAssertEqual(b, (a * a + haze * haze).squareRoot(),
                               accuracy: 1e-6)
            }
            XCTAssertEqual(fuzzy.ringRadiusMM, clean.ringRadiusMM)
            XCTAssertEqual(fuzzy.weights, clean.weights)
            XCTAssertEqual(fuzzy.mix, clean.mix)
        }
    }

    func testKernelWeightsFormAPartitionOfUnity() {
        for strengths in [[Float(0.055), 0.020, 0.008], [0.008, 0.004, 0.002],
                          [0.30, 0.12, 0.05], [0.03, 0.03, 0.03]] {
            let kernel = Halation.kernel(returned: strengths,
                                         base: .acetate(thicknessMM: 0.13))
            for row in kernel.weights {
                XCTAssertEqual(row.reduce(0, +), 1, accuracy: 1e-4)
                for weight in row { XCTAssertGreaterThanOrEqual(weight, 0) }
            }
            XCTAssertEqual(kernel.sigmaMM.sorted(), kernel.sigmaMM)
        }
    }

    func testPhysicalProfileSeparatesReturnedEnergyFromShape() {
        let base = FilmBase.acetate(thicknessMM: 0.13)
        let weak = Halation.kernel(returned: [0.005, 0.002, 0.001], base: base,
                                   profile: Self.physicalProfile)
        let strong = Halation.kernel(returned: [0.08, 0.03, 0.012], base: base,
                                     profile: Self.physicalProfile)

        XCTAssertEqual(weak.sigmaMM, strong.sigmaMM)
        XCTAssertEqual(weak.ringRadiusMM, strong.ringRadiusMM)
        XCTAssertEqual(weak.weights, strong.weights)
        XCTAssertNotEqual(weak.mix, strong.mix)
        XCTAssertEqual(weak.ringRadiusMM, [0, 0, 0])
    }

    func testPhysicalProfileShapeParametersDoNotMoveReturnedEnergy() {
        let base = FilmBase.acetate(thicknessMM: 0.13)
        let returned: [Float] = [0.03, 0.012, 0.004]
        let compact = HalationProfile(
            roundTripOpticalDepth: [1.8, 1.8, 1.8],
            angularExponent: [3, 3, 3],
            diffuseShare: [0.3, 0.3, 0.3],
            diffuseSigmaMM: [0.01, 0.01, 0.01],
            bounceRetention: [0.03, 0.03, 0.03])
        let broad = HalationProfile(
            roundTripOpticalDepth: [0.3, 0.3, 0.3],
            angularExponent: [0.2, 0.2, 0.2],
            diffuseShare: [0.02, 0.02, 0.02],
            diffuseSigmaMM: [0.03, 0.03, 0.03],
            bounceRetention: [0.4, 0.4, 0.4])
        let compactKernel = Halation.kernel(returned: returned, base: base,
                                            profile: compact)
        let broadKernel = Halation.kernel(returned: returned, base: base,
                                          profile: broad)

        XCTAssertEqual(compactKernel.mix, broadKernel.mix)
        XCTAssertNotEqual(compactKernel.weights, broadKernel.weights)
    }

    func testRecordDepthIsStockSpecificAndChangesProfileShape() {
        let base = FilmBase.acetate(thicknessMM: 0.13)
        let returned: [Float] = [0.06, 0.02, 0.008]
        var elevated = Self.physicalProfile
        elevated.recordDepthMM = [0.020, 0.026, 0.032]

        let reference = Halation.kernel(returned: returned, base: base,
                                        profile: Self.physicalProfile)
        let shifted = Halation.kernel(returned: returned, base: base,
                                      profile: elevated)

        XCTAssertEqual(reference.mix, shifted.mix)
        XCTAssertNotEqual(reference.sigmaMM, shifted.sigmaMM)
    }

    func testPhysicalContinuousBasisTracksItsOpticalEdgeProfile() {
        let base = FilmBase.acetate(thicknessMM: 0.13)
        let kernel = Halation.kernel(returned: [0.03, 0.012, 0.004], base: base,
                                     profile: Self.physicalProfile)
        XCTAssertEqual(kernel.ringRadiusMM, [0, 0, 0])
        for layer in 0..<3 {
            let physical = Halation.PhysicalProfile(
                base: base,
                recordDepthMM: Self.physicalProfile.recordDepthMM?[layer] ?? 0,
                optics: .shared(index: base.refractiveIndex(forRecord: layer)),
                opticalDepth: Self.physicalProfile.roundTripOpticalDepth[layer],
                angularExponent: Self.physicalProfile.angularExponent[layer],
                diffuseShare: Self.physicalProfile.diffuseShare[layer],
                diffuseSigmaMM: Self.physicalProfile.diffuseSigmaMM[layer],
                bounceRetention: Self.physicalProfile.bounceRetention[layer])
            var worst: Float = 0
            for step in 0...320 {
                let distance = Float(step) / 320 * 8 * base.haloRadiusMM
                let exact = physical.edgeSpread(distance: distance)
                var fitted: Float = 0
                for scale in 0..<Halation.scaleCount {
                    fitted += kernel.weights[layer][scale]
                        * Halation.gaussianEdgeSpread(
                            distance: distance, sigma: kernel.sigmaMM[scale])
                }
                worst = max(worst, abs(fitted - exact))
            }
            XCTAssertLessThan(worst / 0.5, 0.10,
                              "physical halo edge fit off by \(worst / 0.5) in layer \(layer)")
        }
    }

    func testPhysicalFalloffIsContinuousAndMonotone() {
        let base = FilmBase.acetate(thicknessMM: 0.13)
        let kernel = Halation.kernel(returned: [0.03, 0.012, 0.004], base: base,
                                     profile: Self.physicalProfile)
        for layer in 0..<3 {
            var previous: Float = 0.5
            for step in 0...1_024 {
                let distance = Float(step) / 1_024 * 12 * base.haloRadiusMM
                let value = zip(kernel.weights[layer], kernel.sigmaMM).reduce(Float(0)) {
                    $0 + $1.0 * Halation.gaussianEdgeSpread(
                        distance: distance, sigma: $1.1)
                }
                XCTAssertLessThanOrEqual(value, previous + 1e-7)
                previous = value
            }
        }
    }

    func testPhysicalProfileRoundTripsThroughAStockDefinition() throws {
        var stock = TestStocks.negative
        stock.halationProfile = Self.physicalProfile
        stock.estimatedHalationProfile = Self.physicalProfile
        let encoded = try JSONEncoder().encode(
            FilmStockDefinition(id: "physical-halation", stock: stock))
        let decoded = try JSONDecoder().decode(FilmStockDefinition.self, from: encoded)
        XCTAssertEqual(decoded.halationProfile, Self.physicalProfile)
        XCTAssertEqual(decoded.estimatedHalationProfile, Self.physicalProfile)
        XCTAssertEqual(decoded.stock.halationProfile, Self.physicalProfile)
        XCTAssertEqual(decoded.stock.estimatedHalationProfile, Self.physicalProfile)
    }

    func testEstimatedProfileIsOptInAndCalibratedProfileWins() {
        var stock = TestStocks.negative
        stock.halationProfile = nil
        stock.estimatedHalationProfile = Self.physicalProfile

        XCTAssertNil(stock.resolvedHalationProfile(useEstimate: false))
        XCTAssertEqual(stock.resolvedHalationProfile(useEstimate: true), Self.physicalProfile)

        var options = FotufilmEngine.Options()
        var invocation = FilmEngineInvocation(stock: stock, options: options,
                                              width: 128, height: 128)
        XCTAssertEqual(invocation.featureMask & FilmEngineFeature.annularHalation, 0)

        options.useEstimatedHalationProfile = true
        invocation = FilmEngineInvocation(stock: stock, options: options,
                                          width: 128, height: 128)
        XCTAssertNotEqual(invocation.featureMask & FilmEngineFeature.halation, 0)
        XCTAssertEqual(invocation.featureMask & FilmEngineFeature.annularHalation, 0)

        let calibrated = HalationProfile(
            roundTripOpticalDepth: [2, 2, 2], angularExponent: [3, 3, 3],
            diffuseShare: [0, 0, 0], diffuseSigmaMM: [0, 0, 0],
            bounceRetention: [0, 0, 0])
        stock.halationProfile = calibrated
        XCTAssertEqual(stock.resolvedHalationProfile(useEstimate: true), calibrated)
    }

    func testFittedHaloTracksTheExactOpticsAtAnEdge() {
        for base in [FilmBase.acetate(thicknessMM: 0.13),
                     .acetate(thicknessMM: 0.10), .estar(thicknessMM: 0.19)] {
            for strengths in [[Float(0.055), 0.020, 0.008], [0.008, 0.004, 0.002],
                              [0.30, 0.12, 0.05], [0.002, 0.001, 0.0005]] {
                let kernel = Halation.kernel(returned: strengths, base: base)
                for (layer, fraction) in strengths.enumerated() {
                    let profile = Halation.Profile(
                        returning: fraction, base: base, recordDepthMM: 0,
                        optics: .shared(index: base.refractiveIndex(forRecord: layer)))
                    var worst: Float = 0
                    for step in 0...240 {
                        let distance = Float(step) / 240 * 10 * kernel.sigmaMM[2]
                        let exact = profile.edgeSpread(distance: distance)
                        var fitted: Float = 0
                        for (weight, sigma) in zip(kernel.weights[layer], kernel.sigmaMM) {
                            fitted += weight * Halation.gaussianEdgeSpread(
                                distance: distance, sigma: sigma)
                        }
                        worst = max(worst, abs(fitted - exact))
                    }
                    XCTAssertLessThan(worst / 0.5, 0.14,
                                      "halo profile off by \(worst / 0.5) at layer \(layer)")
                }
            }
        }
    }

    func testRedHalatesWiderThanBlue() {
        func spread(_ strengths: [Float]) -> [Float] {
            let kernel = Halation.kernel(returned: strengths,
                                         base: .acetate(thicknessMM: 0.13))
            return kernel.weights.map { row in
                zip(row, kernel.sigmaMM).map { $0 * $1 * $1 }.reduce(0, +).squareRoot()
            }
        }
        let portra = spread(TestStocks.negative.halationStrength)
        XCTAssertGreaterThan(portra[0], portra[1])
        XCTAssertGreaterThan(portra[1], portra[2])

        let stripped = spread([0.30, 0.12, 0.05])
        XCTAssertGreaterThan(stripped[0] / stripped[2], portra[0] / portra[2])
    }

    func testAnOrdinaryMidtoneHalatesAndABrighterOneHalatesMore() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.couplerScale = 0
        var without = options
        without.halationScale = 0

        func halo(source: Float) -> Float {
            let size = 192
            var image = ImageBuffer(width: size, height: size)
            for plane in 0..<3 {
                for i in 0..<image.pixelCount { image.planes[plane][i] = 0.05 }
            }
            for y in 80..<112 {
                for x in 80..<112 {
                    let i = y * size + x
                    for plane in 0..<3 { image.planes[plane][i] = source }
                }
            }
            let probe = 113 * size + 96
            let lit = FotufilmEngine(stock: TestStocks.negative, options: options)
                .developNegative(linearRGB: image)
            let dark = FotufilmEngine(stock: TestStocks.negative, options: without)
                .developNegative(linearRGB: image)
            return lit.planes[0][probe] - dark.planes[0][probe]
        }

        let midtone = halo(source: 0.18)
        let brighter = halo(source: 0.72)
        XCTAssertGreaterThan(midtone, 1e-4,
                             "an ordinary midtone must still halate")
        XCTAssertGreaterThan(brighter, midtone,
                             "a brighter source must throw a stronger halo")
    }

    func testHalationIsExactlyNeutralOnAUniformField() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        for value: Float in [0.05, 0.18, 1.0, 8.0] {
            let size = 96
            var image = ImageBuffer(width: size, height: size)
            for plane in 0..<3 {
                for i in 0..<image.pixelCount { image.planes[plane][i] = value }
            }
            var off = options
            off.halationScale = 0
            let lit = FotufilmEngine(stock: TestStocks.negative, options: options)
                .developNegative(linearRGB: image)
            let dark = FotufilmEngine(stock: TestStocks.negative, options: off)
                .developNegative(linearRGB: image)
            let probe = size * size / 2 + size / 2
            for layer in 0..<3 {
                XCTAssertEqual(lit.planes[layer][probe], dark.planes[layer][probe],
                               accuracy: 1e-4,
                               "uniform \(value) moved in layer \(layer)")
            }
        }
    }

    func testPhysicalHalationIsExactlyNeutralOnAUniformField() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        var stock = TestStocks.negative
        stock.halationProfile = Self.physicalProfile
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.couplerScale = 0
        options.format = FilmFormat(name: "profile-test", frameHeightMM: 2)
        var off = options
        off.halationScale = 0

        for value: Float in [0.05, 0.18, 1, 8] {
            let size = 96
            var image = ImageBuffer(width: size, height: size)
            for plane in 0..<3 {
                for index in 0..<image.pixelCount { image.planes[plane][index] = value }
            }
            let lit = FotufilmEngine(stock: stock, options: options)
                .developNegative(linearRGB: image)
            let dark = FotufilmEngine(stock: stock, options: off)
                .developNegative(linearRGB: image)
            let probe = size * size / 2 + size / 2
            for layer in 0..<3 {
                XCTAssertEqual(lit.planes[layer][probe], dark.planes[layer][probe],
                               accuracy: 1e-4,
                               "physical profile moved uniform \(value) in layer \(layer)")
            }
        }
    }

    func testRenderedPhysicalFalloffHasNoSecondaryRings() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        var stock = TestStocks.negative
        stock.halationProfile = Self.physicalProfile
        stock.halationReturnMatrix = nil
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.couplerScale = 0
        options.format = FilmFormat(name: "continuous-falloff-test", frameHeightMM: 3)
        var off = options
        off.halationScale = 0

        let size = 256
        var image = ImageBuffer(width: size, height: size)
        for plane in 0..<3 {
            for index in 0..<image.pixelCount { image.planes[plane][index] = 0.01 }
        }
        for y in 80..<176 {
            for x in 80..<176 {
                let index = y * size + x
                for plane in 0..<3 { image.planes[plane][index] = 4 }
            }
        }
        let withHalation = FotufilmEngine(stock: stock, options: options)
            .developNegative(linearRGB: image)
        let withoutHalation = FotufilmEngine(stock: stock, options: off)
            .developNegative(linearRGB: image)

        let excess = (176..<232).map { x -> Float in
            let index = 128 * size + x
            return withHalation.planes[0][index] - withoutHalation.planes[0][index]
        }
        let peak = excess.indices.max { excess[$0] < excess[$1] } ?? 0
        XCTAssertLessThanOrEqual(peak, 3, "primary halo peak moved away from the source edge")
        for index in (peak + 1)..<excess.count {
            XCTAssertLessThanOrEqual(excess[index], excess[index - 1] + 2e-5,
                                     "secondary halo ring at x=\(176 + index)")
        }
    }

    func testRemjetBackedStockHalatesFarLessThanAnUndercoatedOne() {
        let backed = TestStocks.remjetBacked.halationStrength
        let undercoated = TestStocks.negative.halationStrength
        for layer in 0..<3 {
            XCTAssertLessThan(backed[layer], undercoated[layer] / 2)
        }
        let base = FilmBase.acetate(thicknessMM: 0.135)
        XCTAssertLessThan(Halation.kernel(returned: backed, base: base).mix[0],
                          Halation.kernel(returned: undercoated, base: base).mix[0])
    }
}
