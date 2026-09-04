import XCTest
@testable import FotufilmCore

final class DiffusionFilterTests: XCTestCase {

    private static var stock: FilmStock { FilmStock.presets["example-negative-400"]! }
    private let pitch: Float = 24.0 / 1000

    private func filter(radiusUM: Float = 12, strength: Float = 0.32,
                        albedo: Float = 0.95) -> DiffusionFilter {
        DiffusionFilter(id: "test", name: "test", interactedFraction: strength,
                        albedo: albedo, particleRadiusUM: radiusUM)
    }

    // MARK: The scattering profile

    func testBesselFunctionsMatchTheirPublishedValues() {
        let published: [(Float, Float, Float)] = [
            (0, 1, 0),
            (1, 0.7651977, 0.4400506),
            (2.404826, 0, 0.5191475),
            (3.831706, -0.4027594, 0),
            (5, -0.1775968, -0.3275791),
            (10, -0.2459358, 0.0434727),
        ]
        for (x, j0, j1) in published {
            XCTAssertEqual(besselJ0(x), j0, accuracy: 1e-6, "J0(\(x))")
            XCTAssertEqual(besselJ1(x), j1, accuracy: 1e-6, "J1(\(x))")
        }
        XCTAssertEqual(besselJ1(-3), -besselJ1(3), accuracy: 1e-7, "J1 is odd")
    }

    func testAiryEnergyMatchesTheTextbookRings() {
        XCTAssertEqual(DiffusionFilter.airyEnergyWithin(u: 3.831706), 0.83785, accuracy: 0.0005)
        XCTAssertEqual(DiffusionFilter.airyEnergyWithin(u: 7.015587), 0.91013, accuracy: 0.0005)
        XCTAssertEqual(DiffusionFilter.airyEnergyWithin(u: 0), 0)
        // Monotone, because it is a cumulative energy.
        var previous: Float = 0
        for step in 1...400 {
            let value = DiffusionFilter.airyEnergyWithin(u: Float(step) * 0.1)
            XCTAssertGreaterThanOrEqual(value, previous - 1e-6, "u = \(Float(step) * 0.1)")
            previous = max(previous, value)
        }
    }

    func testHaloGrowsInProportionToFocalLength() {
        let f = filter()
        let short = f.halo(stock: Self.stock, focalLengthMM: 25, pixelPitchMM: pitch)
        let long = f.halo(stock: Self.stock, focalLengthMM: 100, pixelPitchMM: pitch)
        for scale in 0..<3 {
            XCTAssertEqual(long.sigmasPixels[scale] / short.sigmasPixels[scale], 4,
                           accuracy: 0.02, "scale \(scale)")
        }
    }

    func testBiggerParticlesMakeATighterHalo() {
        let fine = filter(radiusUM: 6).halo(stock: Self.stock, focalLengthMM: 50,
                                            pixelPitchMM: pitch)
        let coarse = filter(radiusUM: 24).halo(stock: Self.stock, focalLengthMM: 50,
                                               pixelPitchMM: pitch)
        for scale in 0..<3 {
            XCTAssertEqual(fine.sigmasPixels[scale] / coarse.sigmasPixels[scale], 4,
                           accuracy: 0.05, "scale \(scale)")
        }
        // And the grade does not: doubling the loading moves how much scatters, not how far.
        let light = filter(strength: 0.1).halo(stock: Self.stock, focalLengthMM: 50,
                                               pixelPitchMM: pitch)
        let heavy = filter(strength: 0.4).halo(stock: Self.stock, focalLengthMM: 50,
                                               pixelPitchMM: pitch)
        XCTAssertEqual(light.sigmasPixels, heavy.sigmasPixels)
        XCTAssertEqual(heavy.scatteredShare / light.scatteredShare, 4, accuracy: 0.01)
    }

    func testRedScattersWiderThanBlueByTheRatioOfTheirWavelengths() {
        let halo = filter().halo(stock: Self.stock, focalLengthMM: 50, pixelPitchMM: pitch)
        let wavelengths = DiffusionFilter.recordWavelengths(stock: Self.stock)
        XCTAssertGreaterThan(wavelengths[0], wavelengths[1])
        XCTAssertGreaterThan(wavelengths[1], wavelengths[2])

        func effectiveSigma(_ record: Int) -> Float {
            let row = halo.weights[record]
            return zip(row, halo.sigmasPixels).map(*).reduce(0, +) / max(row.reduce(0, +), 1e-6)
        }
        let red = effectiveSigma(0), green = effectiveSigma(1), blue = effectiveSigma(2)
        XCTAssertGreaterThan(red, green)
        XCTAssertGreaterThan(green, blue)
        // The three-Gaussian basis compresses the spread a little, so the measured ratio runs
        // below the wavelength ratio rather than above it. Both are checked: a model that had
        // lost the chromatic term would sit at 1, and one that had exaggerated it would exceed
        // the wavelengths it is supposed to come from.
        let wavelengthRatio = wavelengths[0] / wavelengths[2]
        XCTAssertGreaterThan(red / blue, 1.25)
        XCTAssertLessThan(red / blue, wavelengthRatio)
    }

    func testTheHaloKeepsAllTheLightItScattered() {
        for radius in [Float(6), 12, 35] {
            for focal in [Float(24), 50, 200] {
                let halo = filter(radiusUM: radius).halo(
                    stock: Self.stock, focalLengthMM: focal, pixelPitchMM: pitch,
                    maximumSigmaPixels: 125)
                for (record, row) in halo.weights.enumerated() {
                    XCTAssertEqual(row.reduce(0, +), 1, accuracy: 1e-4,
                                   "radius \(radius), focal \(focal), record \(record)")
                    for weight in row { XCTAssertGreaterThanOrEqual(weight, 0) }
                }
                // And the sharp, scattered and absorbed shares are the whole beam.
                let f = filter(radiusUM: radius)
                XCTAssertEqual(f.directShare + f.scatteredShare + f.absorbedShare, 1,
                               accuracy: 1e-6)
            }
        }
    }

    func testTheTruncatedTailStaysSmall() {
        let f = filter()
        // Focal lengths whose widest scale still fits under the cap: what is missing there is
        // the basis's own limit, not the cap's.
        for focal in [Float(24), 50] {
            let halo = f.halo(stock: Self.stock, focalLengthMM: focal, pixelPitchMM: pitch,
                              maximumSigmaPixels: 125)
            XCTAssertLessThan(halo.sigmasPixels[2], 125, "focal \(focal) should be uncapped")
            XCTAssertLessThan(halo.truncatedShare, 0.05, "focal \(focal)")
        }
        // Capping the widest sigma moves more tail energy inward, which increases the diagnostic.
        let capped = f.halo(stock: Self.stock, focalLengthMM: 400, pixelPitchMM: pitch,
                            maximumSigmaPixels: 125)
        XCTAssertGreaterThan(capped.truncatedShare, 0.10)
        XCTAssertEqual(capped.sigmasPixels[2], 125, accuracy: 0.01)
        for row in capped.weights {
            XCTAssertEqual(row.reduce(0, +), 1, accuracy: 1e-4)
        }
    }

    // MARK: Through the engine

    func testNoFilterChangesNothing() {
        let bare = FilmEngineInvocation(stock: Self.stock, options: FotufilmEngine.Options(),
                                        width: 256, height: 256)
        XCTAssertEqual(bare.featureMask & FilmEngineFeature.diffusion, 0)
        XCTAssertEqual(bare.configuration[FilmEngineInvocation.diffusionDirectOffset], 1)
        for i in 0..<9 {
            XCTAssertEqual(bare.configuration[FilmEngineInvocation.diffusionKernelOffset + i], 0)
        }
        var misty = FotufilmEngine.Options()
        misty.diffusionFilter = filter()
        let fitted = FilmEngineInvocation(stock: Self.stock, options: misty,
                                          width: 256, height: 256)
        XCTAssertNotEqual(fitted.featureMask & FilmEngineFeature.diffusion, 0)
        XCTAssertLessThan(fitted.configuration[FilmEngineInvocation.diffusionDirectOffset], 1)
        // The halo reaches across the frame, so a tile has to see further than it did.
        XCTAssertGreaterThan(fitted.spatialSupport, bare.spatialSupport)
        XCTAssertGreaterThan(fitted.lightSupport, bare.lightSupport)
    }

    func testThePackedSharesAccountForTheWholeBeam() {
        var options = FotufilmEngine.Options()
        let f = filter(albedo: 0.3)
        options.diffusionFilter = f
        let invocation = FilmEngineInvocation(stock: Self.stock, options: options,
                                              width: 256, height: 256)
        let direct = invocation.configuration[FilmEngineInvocation.diffusionDirectOffset]
        XCTAssertEqual(direct, f.directShare, accuracy: 1e-6)
        for record in 0..<3 {
            var scattered: Float = 0
            for scale in 0..<3 {
                scattered += invocation.configuration[
                    FilmEngineInvocation.diffusionKernelOffset + record * 3 + scale]
            }
            XCTAssertEqual(direct + scattered + f.absorbedShare, 1, accuracy: 1e-4,
                           "record \(record)")
        }
    }

    func testDonorCaptureRecordGetsItsOwnDiffusionWeights() throws {
        var donorStock = Self.stock
        let donor = TestStocks.donor
        donorStock.donorLayers = [donor]
        let f = filter(albedo: 0.6)
        let halo = f.halo(stock: donorStock, focalLengthMM: 50,
                          pixelPitchMM: pitch, maximumSigmaPixels: 256.0 / 8)
        XCTAssertEqual(halo.weights.count, 4)

        var options = FotufilmEngine.Options()
        options.diffusionFilter = f
        options.couplerScale = 1
        options.focalLengthMM = 50
        options.format = FilmFormat(name: "Diffusion test", frameHeightMM: 256 * pitch)
        let invocation = FilmEngineInvocation(
            stock: donorStock, options: options, width: 256, height: 256)
        let packed = (0..<3).map {
            invocation.configuration[
                FilmEngineInvocation.donorDiffusionKernelOffset + $0]
        }
        XCTAssertEqual(packed.reduce(0, +), f.scatteredShare, accuracy: 1e-4)
        XCTAssertEqual(packed, halo.weights[3].map { $0 * f.scatteredShare })
    }

    func testDonorCaptureRecordDevelopsThroughDiffusion() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        var donorStock = Self.stock
        donorStock.donorLayers = [TestStocks.donor]
        var image = ImageBuffer(width: 48, height: 32)
        for i in 0..<image.pixelCount {
            image.planes[0][i] = 0.04 + Float(i % image.width) / Float(image.width)
            image.planes[1][i] = 0.18
            image.planes[2][i] = 0.7 - 0.4 * Float(i / image.width) / Float(image.height)
        }
        var options = FotufilmEngine.Options()
        options.diffusionFilter = filter()
        options.grainScale = 0
        let density = FotufilmEngine(stock: donorStock, options: options)
            .developNegative(linearRGB: image)
        XCTAssertTrue(density.planes.flatMap { $0 }.allSatisfy(\.isFinite))
    }

    func testAWhiteMistLeavesAUniformFieldAlone() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        let size = 192
        var image = ImageBuffer(width: size, height: size)
        for plane in 0..<3 {
            for i in 0..<image.pixelCount { image.planes[plane][i] = 0.18 }
        }
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        let bare = FotufilmEngine(stock: Self.stock, options: options)
            .developNegative(linearRGB: image)
        options.diffusionFilter = filter(albedo: 1)
        let misted = FotufilmEngine(stock: Self.stock, options: options)
            .developNegative(linearRGB: image)
        let probe = (size / 2) * size + size / 2
        for layer in 0..<3 {
            XCTAssertEqual(misted.planes[layer][probe], bare.planes[layer][probe],
                           accuracy: 2e-4, "layer \(layer)")
        }

        // A black mist is not a no-op, and must not be: its particles absorb, so the same flat
        // field comes back darker by what they swallowed.
        options.diffusionFilter = filter(albedo: 0.3)
        let blackened = FotufilmEngine(stock: Self.stock, options: options)
            .developNegative(linearRGB: image)
        for layer in 0..<3 {
            XCTAssertLessThan(blackened.planes[layer][probe],
                              bare.planes[layer][probe] - 0.02, "layer \(layer)")
        }
    }

    func testAHighlightBloomsIntoTheDarkAroundIt() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        let size = 512
        var image = ImageBuffer(width: size, height: size)
        for plane in 0..<3 {
            for i in 0..<image.pixelCount { image.planes[plane][i] = 0.02 }
        }
        for dy in -3...3 {
            for dx in -3...3 {
                let i = (size / 2 + dy) * size + size / 2 + dx
                for plane in 0..<3 { image.planes[plane][i] = 200 }
            }
        }
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.focalLengthMM = 50
        let bare = FotufilmEngine(stock: Self.stock, options: options)
            .developNegative(linearRGB: image)
        options.diffusionFilter = filter()
        let misted = FotufilmEngine(stock: Self.stock, options: options)
            .developNegative(linearRGB: image)

        func lift(_ r: Int) -> Float {
            let i = (size / 2) * size + size / 2 + r
            return misted.planes[0][i] - bare.planes[0][i]
        }
        // Lifted near the highlight, falling away with distance, and gone by the far corner.
        XCTAssertGreaterThan(lift(24), 0.3)
        XCTAssertGreaterThan(lift(24), lift(96))
        XCTAssertGreaterThan(lift(96), lift(200))
        XCTAssertLessThan(lift(240), 0.02)

        // And the highlight itself is *dimmer*, because that is where the scattered light came
        // from. A halo that only added would be a glow pasted on rather than light moved.
        let centre = (size / 2) * size + size / 2
        XCTAssertLessThan(misted.planes[0][centre], bare.planes[0][centre])
    }

    func testFineDetailSurvivesAtTheUnscatteredShare() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        let size = 192
        var image = ImageBuffer(width: size, height: size)
        // A one-pixel checker about mid grey, small enough that the film curve is straight
        // across it, so what comes back is the stage's own arithmetic and not the emulsion's.
        for y in 0..<size {
            for x in 0..<size {
                let value: Float = (x + y) % 2 == 0 ? 0.20 : 0.16
                for plane in 0..<3 { image.planes[plane][y * size + x] = value }
            }
        }
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        let f = filter()
        func modulation(_ filter: DiffusionFilter?) -> Float {
            options.diffusionFilter = filter
            let out = FotufilmEngine(stock: Self.stock, options: options)
                .developNegative(linearRGB: image)
            let y = size / 2, x = size / 2
            let even = out.planes[1][y * size + x]
            let odd = out.planes[1][y * size + x + 1]
            return abs(even - odd)
        }
        let bare = modulation(nil)
        let misted = modulation(f)
        XCTAssertGreaterThan(bare, 1e-3, "the checker has to be visible without the filter")
        XCTAssertEqual(misted / bare, f.directShare, accuracy: 0.04)
    }
}
