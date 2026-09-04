import XCTest
@testable import FotufilmCore

final class CharacteristicCurveTests: XCTestCase {
    let curve = CharacteristicCurve(dMin: 0.2, gamma: 0.6, toe: -1.0, toeWidth: 0.4, shoulder: 1.7, shoulderWidth: 0.55)

    func testMonotonic() {
        var previous = -Float.infinity
        for i in 0...200 {
            let x = -4 + Float(i) * 0.04
            let d = curve.density(logExposure: x)
            XCTAssertGreaterThan(d, previous)
            previous = d
        }
    }

    func testAsymptotes() {
        XCTAssertEqual(curve.density(logExposure: -8), curve.dMin, accuracy: 1e-3)
        XCTAssertEqual(curve.density(logExposure: 8), curve.dMax, accuracy: 1e-3)
        XCTAssertEqual(curve.dMax, 0.2 + 0.6 * 2.7, accuracy: 1e-5)
    }

    func testStraightLineSlope() {
        var peak: Float = 0
        for i in 0...100 {
            let x = curve.toe + (curve.shoulder - curve.toe) * Float(i) / 100
            let d1 = curve.density(logExposure: x - 0.01)
            let d2 = curve.density(logExposure: x + 0.01)
            peak = max(peak, (d2 - d1) / 0.02)
        }
        XCTAssertLessThanOrEqual(peak, curve.gamma + 1e-4)
        XCTAssertGreaterThan(peak, curve.gamma * 0.85)
    }

    func testInverse() {
        for target: Float in [0.35, 0.8, 1.2, 1.6] {
            let x = curve.logExposure(density: target)
            XCTAssertEqual(curve.density(logExposure: x), target, accuracy: 1e-4)
        }
    }

    func testSecondaryPopulationAddsItsDensityAndRange() {
        let component = CharacteristicCurveComponent(
            gamma: 0.24, toe: -0.35, toeWidth: 0.18,
            shoulder: 1.25, shoulderWidth: 0.30)
        let combined = CharacteristicCurve(
            dMin: curve.dMin, gamma: curve.gamma, toe: curve.toe,
            toeWidth: curve.toeWidth, shoulder: curve.shoulder,
            shoulderWidth: curve.shoulderWidth, secondary: component)

        XCTAssertEqual(combined.dMax, curve.dMax + 0.24 * 1.60, accuracy: 1e-6)
        for x: Float in [-2, -0.5, 0, 0.8, 2.5] {
            XCTAssertEqual(combined.density(logExposure: x),
                           curve.density(logExposure: x)
                            + component.density(logExposure: x),
                           accuracy: 1e-6)
        }
        for target: Float in [0.35, 0.9, 1.6, 2.0] {
            let x = combined.logExposure(density: target)
            XCTAssertEqual(combined.density(logExposure: x), target, accuracy: 1e-4)
        }
    }

    func testPresetCurvesNeverDipBelowBaseFogAndAreMonotone() {
        for (key, stock) in FilmStock.presets {
            for (layer, c) in stock.curves.enumerated() {
                var previous = -Float.infinity
                var x: Float = -12
                while x <= 12 {
                    let d = c.density(logExposure: x)
                    XCTAssertGreaterThanOrEqual(d, c.dMin - 1e-5,
                        "\(key) layer \(layer) fell below dMin at x=\(x)")
                    XCTAssertGreaterThanOrEqual(d, previous - 1e-5,
                        "\(key) layer \(layer) density decreased at x=\(x)")
                    previous = d
                    x += 0.01
                }
                XCTAssertEqual(c.density(logExposure: -12), c.dMin, accuracy: 1e-4)
            }
        }
    }
}

final class PipelineTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
    }

    func uniform(_ r: Float, _ g: Float, _ b: Float, size: Int = 32) -> ImageBuffer {
        var img = ImageBuffer(width: size, height: size)
        for i in 0..<img.pixelCount {
            img.planes[0][i] = r
            img.planes[1][i] = g
            img.planes[2][i] = b
        }
        return img
    }

    func centerPixel(_ img: ImageBuffer) -> (Float, Float, Float) {
        img[img.width / 2, img.height / 2]
    }

    var cleanOptions: FotufilmEngine.Options {
        var o = FotufilmEngine.Options()
        o.grainScale = 0
        return o
    }

    func testStripedRenderMatchesWholeFrame() throws {
        let width = 128, height = 768
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let bright = abs(x - width / 2) < width / 10
                    && abs(y - height / 2) < height / 10
                let v: Float = bright ? 6 : 0.18 * Float(x) / Float(width) + 0.02
                image.planes[0][i] = v * 1.05
                image.planes[1][i] = v
                image.planes[2][i] = v * 0.92
            }
        }
        var options = FotufilmEngine.Options()
        options.format = .super8
        for stock in TestStocks.all {
            let whole = try XCTUnwrap(HalideBackend.process(
                image: image, stock: stock, options: options,
                memoryBudget: 1 << 30))
            let apron = max(1, FilmEngineInvocation(
                stock: stock, options: options,
                width: width, height: height).spatialSupport)
            let budget = 3 << 20
            XCTAssertLessThan(
                HalideBackend.stripRows(width: width, height: height,
                                        apron: apron, budget: budget),
                height, "\(stock.name) did not actually stripe")
            let tiled = try XCTUnwrap(HalideBackend.process(
                image: image, stock: stock, options: options,
                memoryBudget: budget))
            var worst: Float = 0
            for c in 0..<3 {
                for i in 0..<whole.pixelCount {
                    worst = max(worst, abs(whole.planes[c][i] - tiled.planes[c][i]))
                }
            }
            XCTAssertLessThan(worst, 1.0 / 4096, "\(stock.name) seams between strips")
        }
    }

    func testMidGrayPrintsToMidGray() {
        for stock in TestStocks.all {
            let sim = FotufilmEngine(stock: stock, options: cleanOptions)
            let out = sim.process(linearRGB: uniform(0.18, 0.18, 0.18))
            let (r, g, b) = centerPixel(out)
            for v in [r, g, b] {
                XCTAssertEqual(v, 0.18, accuracy: 0.01, "\(stock.name) mid-gray drifted")
            }
        }
    }

    func testReversalDensityFallsAsExposureRises() {
        for stock in [TestStocks.reversal] {
            for layer in 0..<3 {
                let shadow = stock.developedDensity(layer: layer, logExposure: -1)
                let mid = stock.developedDensity(layer: layer, logExposure: 0)
                let highlight = stock.developedDensity(layer: layer, logExposure: 1)
                XCTAssertGreaterThan(shadow, mid, "\(stock.name) layer \(layer)")
                XCTAssertGreaterThan(mid, highlight, "\(stock.name) layer \(layer)")
            }
        }
    }

    func testReversalOutputIsDirectPositiveAndPaperIndependent() {
        let input = uniform(0.18, 0.18, 0.18)
        var altered = TestStocks.reversal
        altered.paperCurve = CharacteristicCurve(
            dMin: 0.3, gamma: 1.1, toe: -2, toeWidth: 0.4,
            shoulder: 2, shoulderWidth: 0.4)
        let original = FotufilmEngine(stock: TestStocks.reversal, options: cleanOptions)
            .process(linearRGB: input)
        let changed = FotufilmEngine(stock: altered, options: cleanOptions)
            .process(linearRGB: input)
        XCTAssertEqual(original.planes[0], changed.planes[0],
                       "reversal transparency must bypass print paper")
        let (r, g, b) = centerPixel(original)
        XCTAssertEqual(r, 0.18, accuracy: 0.01)
        XCTAssertEqual(g, 0.18, accuracy: 0.01)
        XCTAssertEqual(b, 0.18, accuracy: 0.01)
    }

    func testGrayRampStaysNeutral() {
        let sim = FotufilmEngine(stock: TestStocks.negative, options: cleanOptions)
        for stops in [-2.0, -1.0, 1.0, 2.0, 3.0] {
            let v = 0.18 * Float(exp2(stops))
            let out = sim.process(linearRGB: uniform(v, v, v))
            let (r, g, b) = centerPixel(out)
            let maxC = max(r, g, b), minC = min(r, g, b)
            let tolerance: Float = abs(stops) <= 1 ? 0.04 : 0.07
            XCTAssertLessThan(maxC - minC, tolerance, "neutral at \(stops) stops came out \(r), \(g), \(b)")
        }
    }

    func testTonalOrderingAndLatitude() {
        let sim = FotufilmEngine(stock: TestStocks.negative, options: cleanOptions)
        var previous: Float = -1
        var values: [Float] = []
        for stops in stride(from: -4.0, through: 4.0, by: 1.0) {
            let v = 0.18 * Float(exp2(stops))
            let (r, g, b) = centerPixel(sim.process(linearRGB: uniform(v, v, v)))
            let lum = (r + g + b) / 3
            XCTAssertGreaterThan(lum, previous, "tone curve must be monotonic")
            previous = lum
            values.append(lum)
        }
        XCTAssertLessThan(values[7], 0.95, "+3 stops should retain highlight detail")
        XCTAssertGreaterThan(values[0], 0.0)
        XCTAssertLessThan(values[0], 0.05)
    }

    func testGrainIsDeterministicAndScales() {
        var options = FotufilmEngine.Options()
        options.seed = 1234
        let sim = FotufilmEngine(stock: TestStocks.negative, options: options)
        let input = uniform(0.18, 0.18, 0.18, size: 64)
        let a = sim.process(linearRGB: input)
        let b = sim.process(linearRGB: input)
        XCTAssertEqual(a.planes[1], b.planes[1], "same seed must give identical grain")

        func variance(_ plane: [Float]) -> Float {
            let mean = plane.reduce(0, +) / Float(plane.count)
            return plane.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(plane.count)
        }
        var noGrain = options
        noGrain.grainScale = 0
        let clean = FotufilmEngine(stock: TestStocks.negative, options: noGrain).process(linearRGB: input)
        XCTAssertGreaterThan(variance(a.planes[1]), variance(clean.planes[1]), "grain must add variance")
        XCTAssertEqual(variance(clean.planes[1]), 0, accuracy: 1e-9, "uniform input without grain must be flat")
    }

    func testRenderedClumpCoversTheAreaTheClumpCountAssumes() {
        for stock in TestStocks.all {
            let rendered = 4 * Float.pi * stock.grainClumpSigmaMM * stock.grainClumpSigmaMM
            let coverage = min(max(stock.grainAnchorCoverage, 1e-4), 0.99)
            let counted = -log(1 - coverage) / stock.grainClumpsPerMM2
            XCTAssertEqual(rendered, counted, accuracy: counted * 1e-5,
                           "\(stock.name) renders a clump of \(rendered) mm2 where the "
                               + "count assumes \(counted) mm2")
        }
    }

    func testClumpCountIsTheBooleanIntensityWithNothingLeftToChoose() {
        for stock in TestStocks.all {
            let anchor = stock.granularityAnchorDensity(layer: 1) + stock.grainFogDensity
            let coverage = 1 - pow(10, -anchor)
            let expected = -log(1 - coverage)
                / (Float.pi * stock.grainSizeMM * stock.grainSizeMM)
            XCTAssertEqual(stock.grainClumpsPerMM2, expected,
                           accuracy: expected * 1e-4, stock.name)
        }
    }

    func testApertureResponseMatchesNumericalIntegration() {
        XCTAssertEqual(FilmStock.granularityApertureResponse(clumpSigmaMM: 0.0025),
                       0.9396, accuracy: 5e-4)
        XCTAssertEqual(FilmStock.granularityApertureResponse(clumpSigmaMM: 0.004),
                       0.9018, accuracy: 5e-4)
        XCTAssertEqual(FilmStock.granularityApertureResponse(clumpSigmaMM: 0.005),
                       0.8761, accuracy: 5e-4)

        // A point clump is the white-noise limit the plain aperture-area scaling assumed.
        XCTAssertEqual(FilmStock.granularityApertureResponse(clumpSigmaMM: 1e-5), 1,
                       accuracy: 1e-3)
        XCTAssertEqual(FilmStock.granularityApertureResponse(clumpSigmaMM: 0), 1)

        // Coarser clumps always cost more of the reading.
        var previous: Float = 1
        for step in 1...40 {
            let response = FilmStock.granularityApertureResponse(
                clumpSigmaMM: Float(step) * 0.0005)
            XCTAssertLessThan(response, previous, "response rose at step \(step)")
            previous = response
        }
    }

    func testMonochromeStockIsNeutral() {
        let sim = FotufilmEngine(stock: TestStocks.monochrome)
        let out = sim.process(linearRGB: uniform(0.6, 0.2, 0.3, size: 48))
        for i in 0..<out.pixelCount {
            XCTAssertEqual(out.planes[0][i], out.planes[1][i])
            XCTAssertEqual(out.planes[1][i], out.planes[2][i])
        }
    }

    func testCouplersChangeColorSeparation() {
        var without = cleanOptions
        without.couplerScale = 0
        // Put the green donor well above its neighbours so the thresholded release has a material
        // chromatic effect after the neutral anchor and print transform.
        let input = uniform(0.02, 2.0, 0.02)
        let a = centerPixel(FotufilmEngine(stock: TestStocks.negative, options: cleanOptions).process(linearRGB: input))
        let b = centerPixel(FotufilmEngine(stock: TestStocks.negative, options: without).process(linearRGB: input))
        func saturation(_ p: (Float, Float, Float)) -> Float {
            let mx = max(p.0, p.1, p.2), mn = min(p.0, p.1, p.2)
            return mx > 0 ? (mx - mn) / mx : 0
        }
        // With nonlinear release, the direction at one printed swatch depends on whether each
        // donor is below or above its threshold. The stage must still have a material chromatic
        // effect; receiver-specific suppression and its sign are covered in CouplerTests.
        XCTAssertGreaterThan(abs(saturation(a) - saturation(b)), 1e-3,
                             "inter-image effects should change color separation")
    }

    func testHalationSpreadsHighlights() {
        let size = 256
        var img = ImageBuffer(width: size, height: size)
        for y in 96..<160 {
            for x in 96..<160 {
                let i = y * size + x
                img.planes[0][i] = 4
                img.planes[1][i] = 4
                img.planes[2][i] = 4
            }
        }
        var options = cleanOptions
        let withH = FotufilmEngine(stock: TestStocks.negative, options: options).process(linearRGB: img)
        options.halationScale = 0
        let withoutH = FotufilmEngine(stock: TestStocks.negative, options: options).process(linearRGB: img)
        let probe = 163 * size + 128
        XCTAssertGreaterThan(withH.planes[0][probe], withoutH.planes[0][probe] + 1e-4)
        let glowR = withH.planes[0][probe] - withoutH.planes[0][probe]
        let glowB = withH.planes[2][probe] - withoutH.planes[2][probe]
        XCTAssertGreaterThan(glowR, glowB)

        let coreSize = 128
        var coreImage = ImageBuffer(width: coreSize, height: coreSize)
        for y in 56..<72 {
            for x in 56..<72 {
                let i = y * coreSize + x
                coreImage.planes[0][i] = 0.72
                coreImage.planes[1][i] = 0.72
                coreImage.planes[2][i] = 0.72
            }
        }
        options.halationScale = 1
        let withCore = FotufilmEngine(stock: TestStocks.negative, options: options)
            .developNegative(linearRGB: coreImage)
        options.halationScale = 0
        let withoutCore = FotufilmEngine(stock: TestStocks.negative, options: options)
            .developNegative(linearRGB: coreImage)
        let center = 64 * coreSize + 64
        for layer in 0..<3 {
            XCTAssertGreaterThanOrEqual(withCore.planes[layer][center] + 1e-5,
                                        withoutCore.planes[layer][center],
                                        "halation dimmed highlight core layer \(layer)")
        }
    }

    func testSubPixelHalationScalesRideAsIdentityRatherThanAtTheFloorRadius() {
        // The continuous basis solves compact lobes well under a pixel at ordinary output
        // resolutions. Clamping those to the smallest expressible radius rendered them at the
        // floor's own width — a 1.41 px chain for a 0.36 px Gaussian — which smeared the fitted
        // scale balance exactly where it matters. A scale finer than any radius is passed as
        // zero and rides through the pipeline as identity instead.
        XCTAssertEqual(FilmEngineInvocation.halationBoxRadius(sigmaPixels: 0.29), 0,
                       "below the half-a-pixel guard the scale is off entirely")
        XCTAssertEqual(FilmEngineInvocation.halationBoxRadius(sigmaPixels: 0.36), 0)
        XCTAssertEqual(FilmEngineInvocation.halationBoxRadius(sigmaPixels: 0.72), 0)
        XCTAssertEqual(FilmEngineInvocation.halationBoxRadius(sigmaPixels: 1.4), 0)
        XCTAssertEqual(FilmEngineInvocation.halationBoxRadius(sigmaPixels: 1.42), 1,
                       "at sqrt(2) px the one-radius chain is the right width")
        XCTAssertEqual(FilmEngineInvocation.halationBoxRadius(sigmaPixels: 12.5), 12)
    }

    func testHalationOnAMidtoneEdgeStaysWithinTheReflectedFraction() {
        let size = 128
        var image = ImageBuffer(width: size, height: size)
        for y in 0..<size {
            for x in (size / 2)..<size {
                let i = y * size + x
                image.planes[0][i] = 0.18
                image.planes[1][i] = 0.18
                image.planes[2][i] = 0.18
            }
        }
        var enabled = cleanOptions
        enabled.couplerScale = 0
        var disabled = enabled
        disabled.halationScale = 0
        let withH = FotufilmEngine(stock: TestStocks.negative, options: enabled).process(linearRGB: image)
        let withoutH = FotufilmEngine(stock: TestStocks.negative, options: disabled).process(linearRGB: image)

        let mix = Halation.mix(returning: TestStocks.negative.halationStrength[0])
        var worst: Float = 0
        for c in 0..<3 {
            for i in 0..<image.pixelCount {
                worst = max(worst, abs(withH.planes[c][i] - withoutH.planes[c][i]))
            }
        }
        XCTAssertLessThan(worst, mix * 0.18,
                          "midtone edge bloomed beyond the light the base returns")

        for c in 0..<3 {
            for y in stride(from: 4, to: size, by: 16) {
                for x in [2, size - 3] {
                    let i = y * size + x
                    XCTAssertEqual(withH.planes[c][i], withoutH.planes[c][i], accuracy: 2e-5,
                                   "flat field moved in channel \(c)")
                }
            }
        }
    }

    func testHDRInputEngagesFilmShoulder() {
        let sim = FotufilmEngine(stock: TestStocks.negative, options: cleanOptions)
        func greenDensity(_ stops: Float) -> Float {
            let v = 0.18 * exp2(stops)
            let negative = sim.developNegative(linearRGB: uniform(v, v, v))
            return negative.planes[1][negative.pixelCount / 2]
        }
        let d4 = greenDensity(4), d6 = greenDensity(6), d8 = greenDensity(8)
        XCTAssertGreaterThan(d6, d4 + 0.05, "+6 stops must develop more than +4")
        XCTAssertGreaterThan(d8, d6 + 0.01, "the far shoulder must still respond at +8")
        XCTAssertLessThan(d8, sim.stock.curves[1].dMax, "density stays below dMax")
    }

    func testAdjacencyProducesMackieLinesOnBWEdges() {
        let size = 128
        var img = ImageBuffer(width: size, height: size)
        for y in 0..<size {
            for x in 0..<size {
                let v: Float = x < size / 2 ? 0.06 : 0.5
                let i = y * size + x
                img.planes[0][i] = v; img.planes[1][i] = v; img.planes[2][i] = v
            }
        }
        var options = cleanOptions
        options.halationScale = 0
        options.format = .super8
        let sim = FotufilmEngine(stock: TestStocks.monochrome, options: options)
        let negative = sim.developNegative(linearRGB: img)
        let row = (size / 2) * size
        let flatBright = negative.planes[0][row + size - 4]
        let flatDark = negative.planes[0][row + 3]
        var nearEdgeBright: Float = -1
        var nearEdgeDark: Float = .infinity
        for x in (size / 2 - 8)..<(size / 2 + 8) {
            let d = negative.planes[0][row + x]
            if x >= size / 2 { nearEdgeBright = max(nearEdgeBright, d) }
            else { nearEdgeDark = min(nearEdgeDark, d) }
        }
        XCTAssertGreaterThan(nearEdgeBright, flatBright + 0.005,
                             "bright side of the edge must overshoot (Mackie line)")
        XCTAssertLessThan(nearEdgeDark, flatDark - 0.001,
                          "dark side of the edge must undershoot")
    }

    func testFlareLiftsShadowsInBrightScenes() {
        let size = 64
        func scene(background: Float) -> ImageBuffer {
            var img = ImageBuffer(width: size, height: size)
            for i in 0..<img.pixelCount {
                let x = i % size, y = i / size
                let dark = abs(x - size / 2) < 4 && abs(y - size / 2) < 4
                let v: Float = dark ? 0.01 : background
                img.planes[0][i] = v; img.planes[1][i] = v; img.planes[2][i] = v
            }
            return img
        }
        var options = cleanOptions
        options.halationScale = 0
        // Capture glare is opt-in now; this test is what it does when asked for.
        options.flareScale = 1
        let sim = FotufilmEngine(stock: TestStocks.negative, options: options)
        let center = (size / 2) * size + size / 2
        let brightScene = sim.process(linearRGB: scene(background: 1.0)).planes[1][center]
        let darkScene = sim.process(linearRGB: scene(background: 0.01)).planes[1][center]
        // As a proportion of the shadow, not a fixed number of display-linear
        // units: how far the lift carries depends on the density scale the
        // print lands on, which is the paper's property rather than the
        // glare's. The measured sheet is 2.10 D where the invented curve was
        // 2.44, and the lift measures 9.3% of the shadow on it.
        XCTAssertGreaterThan(brightScene, darkScene * 1.05,
                             "veiling glare must lift shadows when the scene is bright: "
                                 + "\(brightScene) against \(darkScene)")
    }

    func testAreaWeightedFlareCountsAHighlightBetweenSamplePoints() {
        let width = 127, height = 93
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            pixels[index * 4] = 0.02
            pixels[index * 4 + 1] = 0.02
            pixels[index * 4 + 2] = 0.02
            pixels[index * 4 + 3] = 1
        }
        let highlight = (11 * width + 7) * 4
        pixels[highlight] = 64
        pixels[highlight + 1] = 64
        pixels[highlight + 2] = 64
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: cleanOptions,
            width: width, height: height)
        pixels.withUnsafeBufferPointer { buffer in
            let exact = invocation.measuredFlareMean(
                linearRGBA: buffer.baseAddress!, width: width, rows: height)
            let areaWeighted = invocation.measuredAreaWeightedFlareMean(
                linearRGBA: buffer.baseAddress!, width: width, height: height)
            for channel in 0..<3 {
                XCTAssertEqual(areaWeighted[channel], exact[channel], accuracy: 2e-5)
                XCTAssertGreaterThan(areaWeighted[channel], 0.02)
            }
        }
    }

    func testSpectralLookupDoesNotTrapOnNonFiniteCoordinates() {
        let table = SpectralLUT(dimension: 2, values: [Float](repeating: 1, count: 32))
        for point in [
            SIMD3<Float>(.nan, 0.5, 0.5),
            SIMD3<Float>(0.5, .infinity, 0.5),
            SIMD3<Float>(0.5, 0.5, -.infinity),
        ] {
            XCTAssertEqual(table.sample(point), .zero)
        }
    }

    func testSpectralDyeOverlapIsAnchoredAtMidGray() {
        var plain = TestStocks.negative
        var ideal = plain.spectralProfile.imageDyeDensity
        for wavelength in 0..<SpectralGrid.count {
            let winner = (0..<3).max { ideal[$0][wavelength] < ideal[$1][wavelength] }!
            for layer in 0..<3 { ideal[layer][wavelength] = layer == winner ? 1 : 0 }
        }
        plain.spectralProfile.imageDyeDensity = ideal
        let with = FotufilmEngine(stock: TestStocks.negative, options: cleanOptions)
        let without = FotufilmEngine(stock: plain, options: cleanOptions)
        let gray = uniform(0.18, 0.18, 0.18)
        let a = centerPixel(with.process(linearRGB: gray))
        let b = centerPixel(without.process(linearRGB: gray))
        XCTAssertEqual(a.0, b.0, accuracy: 5e-3)
        XCTAssertEqual(a.1, b.1, accuracy: 5e-3)
        XCTAssertEqual(a.2, b.2, accuracy: 5e-3)
        let red = uniform(0.5, 0.05, 0.05)
        let ra = centerPixel(with.process(linearRGB: red))
        let rb = centerPixel(without.process(linearRGB: red))
        // Against the neutral rather than against a constant, because that is
        // what "anchored at mid-gray" claims: real dyes and block dyes agree
        // on the grey and part on the saturated colour. A bare threshold also
        // has to be re-derived whenever the print's density scale moves, and
        // the old 0.002 sat below the 5e-3 the neutral above is allowed.
        let neutralDelta = abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
        let redDelta = abs(ra.0 - rb.0) + abs(ra.1 - rb.1) + abs(ra.2 - rb.2)
        XCTAssertGreaterThan(redDelta, 0.001, "crosstalk must affect saturated colors")
        XCTAssertGreaterThan(redDelta, 10 * neutralDelta,
                             "crosstalk must land on colour, not on the grey axis: "
                                 + "red \(redDelta), neutral \(neutralDelta)")
    }

    func testSilverGrainRemainsContinuousAtHighEnlargement() {
        var options = FotufilmEngine.Options()
        options.halationScale = 0
        options.couplerScale = 0
        options.format = FilmFormat(name: "crop", frameHeightMM: 1.5)
        let sim = FotufilmEngine(stock: TestStocks.monochrome, options: options)
        let negative = sim.developNegative(linearRGB: uniform(0.18, 0.18, 0.18, size: 128))
        let plane = negative.planes[0]
        let mean = plane.reduce(0, +) / Float(plane.count)
        var m2: Float = 0, m3: Float = 0
        for v in plane {
            let d = v - mean
            m2 += d * d
            m3 += d * d * d
        }
        m2 /= Float(plane.count)
        m3 /= Float(plane.count)
        XCTAssertEqual(m3 / pow(m2, 1.5), 0, accuracy: 0.08,
                       "silver grain must not resolve into sparse positive impulses")
    }

    func testPortraitAndLandscapeGetSamePhysicalScale() {
        let w = 96, h = 48
        var landscape = ImageBuffer(width: w, height: h)
        var portrait = ImageBuffer(width: h, height: w)
        for y in 0..<h {
            for x in 0..<w {
                let v: Float = (abs(x - w / 2) < 6 && abs(y - h / 2) < 6) ? 8 : 0.05
                for c in 0..<3 {
                    landscape.planes[c][y * w + x] = v
                    portrait.planes[c][x * h + (h - 1 - y)] = v
                }
            }
        }
        var options = cleanOptions
        options.format = .super8
        let sim = FotufilmEngine(stock: TestStocks.negative, options: options)
        let outL = sim.process(linearRGB: landscape)
        let outP = sim.process(linearRGB: portrait)
        for y in 0..<h {
            for x in 0..<w {
                let l = outL.planes[0][y * w + x]
                let p = outP.planes[0][x * h + (h - 1 - y)]
                XCTAssertEqual(l, p, accuracy: 1e-4,
                               "rotated frame diverged at (\(x),\(y))")
            }
        }
    }

    func testSRGB8RoundTripShape() {
        let width = 16, height = 16
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        for i in 0..<(width * height) { pixels[i * 4 + 3] = 255 }
        let out = FotufilmEngine(stock: TestStocks.negative).processSRGB8(pixels, width: width, height: height)
        XCTAssertEqual(out.count, pixels.count)
        XCTAssertEqual(out[3], 255, "alpha must pass through untouched")
    }

    func testSRGB8ConvertsPrimariesAtTheWorkingSpaceBoundary() {
        let width = 8, height = 8
        let source = SIMD3<UInt8>(230, 40, 20)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            pixels[index * 4] = source.x
            pixels[index * 4 + 1] = source.y
            pixels[index * 4 + 2] = source.z
            pixels[index * 4 + 3] = 255
        }
        var options = cleanOptions
        options.seed = 17
        let simulator = FotufilmEngine(stock: TestStocks.negative, options: options)
        let actual = simulator.processSRGB8(pixels, width: width, height: height)

        let linearSRGB = SIMD3<Float>(
            ColorScience.srgbToLinear(Float(source.x) / 255),
            ColorScience.srgbToLinear(Float(source.y) / 255),
            ColorScience.srgbToLinear(Float(source.z) / 255))
        let working = ColorScience.linearSRGBToRec2020(linearSRGB)
        let rendered = simulator.process(linearRGB: uniform(
            working.x, working.y, working.z, size: width))
        let seed = UInt32(truncatingIfNeeded: options.seed)
        for index in 0..<(width * height) {
            let printP3 = SIMD3<Float>(
                ColorScience.displayShoulder(rendered.planes[0][index]),
                ColorScience.displayShoulder(rendered.planes[1][index]),
                ColorScience.displayShoulder(rendered.planes[2][index]))
            let printSRGB = ColorScience.linearDisplayP3ToSRGB(printP3)
            for channel in 0..<3 {
                let encoded = ColorScience.linearToSrgb(
                    min(max(printSRGB[channel], 0), 1))
                let dither = triangularDither(
                    index: UInt32(index), channel: UInt32(channel), seed: seed)
                let expected = UInt8(clamp(encoded * 255 + 0.5 + dither, 0, 255))
                XCTAssertEqual(actual[index * 4 + channel], expected)
            }
        }
    }

    func testHalideHandlesNonVectorAlignedDimensions() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        let width = 19, height = 23
        var input = ImageBuffer(width: width, height: height)
        for i in 0..<input.pixelCount {
            input.planes[0][i] = Float(i % width) / Float(width)
            input.planes[1][i] = 0.18
            input.planes[2][i] = Float(i / width) / Float(height)
        }
        var options = FotufilmEngine.Options()
        options.format = .super8
        options.grainScale = 0
        let negative = try XCTUnwrap(
            HalideBackend.develop(image: input, stock: TestStocks.negative, options: options))
        let positive = try XCTUnwrap(
            HalideBackend.print(density: negative, stock: TestStocks.negative, options: options))
        XCTAssertEqual(positive.width, width)
        XCTAssertEqual(positive.height, height)
        XCTAssertTrue(positive.planes.flatMap { $0 }.allSatisfy(\.isFinite))
    }
}

final class BlurTests: XCTestCase {
    func testApproximateGaussianMatchesEnergyNormalizedBoxReference() throws {
        let width = 19, height = 13, sigma: Float = 3.2
        var actual = (0..<(width * height)).map {
            sin(Float($0) * 0.37) + cos(Float($0 / width) * 0.61)
        }
        var expected = actual
        let boxWidth = sqrt(12 * sigma * sigma / 3 + 1)
        let radius = max(1, Int((boxWidth - 1) / 2))

        func boxPass(_ input: [Float], horizontal: Bool) -> [Float] {
            var output = [Float](repeating: 0, count: input.count)
            for y in 0..<height {
                for x in 0..<width {
                    var sum: Float = 0, count: Float = 0
                    for offset in -radius...radius {
                        let sampleX = horizontal ? x + offset : x
                        let sampleY = horizontal ? y : y + offset
                        guard sampleX >= 0, sampleX < width,
                              sampleY >= 0, sampleY < height else { continue }
                        sum += input[sampleY * width + sampleX]
                        count += 1
                    }
                    output[y * width + x] = sum / count
                }
            }
            return output
        }

        for _ in 0..<3 {
            expected = boxPass(expected, horizontal: true)
            expected = boxPass(expected, horizontal: false)
        }
        if HalideBackend.isAvailable {
            actual = try XCTUnwrap(
                HalideBackend.approximateGaussian(actual, width: width, height: height, radius: radius))
        } else {
            Blur.approximateGaussian(&actual, width: width, height: height, sigma: sigma)
        }
        for i in actual.indices {
            XCTAssertEqual(actual[i], expected[i], accuracy: 2e-5, "pixel \(i)")
        }
    }

    func testGaussianPreservesMean() {
        let w = 40, h = 40
        var plane = [Float](repeating: 0, count: w * h)
        plane[20 * w + 20] = 100
        let before = plane.reduce(0, +)
        Blur.gaussian(&plane, width: w, height: h, sigma: 2)
        XCTAssertEqual(plane.reduce(0, +), before, accuracy: 0.1)
    }

    func testPoissonFieldIsCenteredUnitVarianceAndSkewed() {
        for lambda: Float in [0.05, 0.7, 8, 64] {
            var gen = PoissonFieldGenerator(seed: 99, lambda: lambda)
            let count = 200_000
            var sum: Double = 0, sq: Double = 0, cube: Double = 0
            for _ in 0..<count {
                let v = Double(gen.next())
                sum += v; sq += v * v; cube += v * v * v
            }
            let mean = sum / Double(count)
            let variance = sq / Double(count) - mean * mean
            XCTAssertEqual(mean, 0, accuracy: 0.03, "lambda \(lambda)")
            XCTAssertEqual(variance, 1, accuracy: 0.05, "lambda \(lambda)")
            let skew = (cube / Double(count) - 3 * mean * variance - mean * mean * mean)
                / pow(variance, 1.5)
            if lambda < 1 {
                XCTAssertGreaterThan(skew, 0.8, "small lambda must be strongly skewed")
            } else if lambda >= 64 {
                XCTAssertEqual(skew, 0, accuracy: 0.1, "large lambda is the Gaussian limit")
            }
        }
    }
}
