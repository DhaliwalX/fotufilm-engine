import XCTest
import FotufilmHalide
@testable import FotufilmCore
#if canImport(Metal)
import Metal
@testable import FotufilmMetal
#endif

final class AnalyticalDevelopmentTests: XCTestCase {
    // Deliberately illustrative values, independent of any stock calibration.
    private var model: AnalyticalDevelopment {
        AnalyticalDevelopment(slope: [2, 1.8, 2.2], midpoint: [0, 0.1, -0.1],
                              budget: [3, 4, 3.5], capacity: [4, 4.2, 4.1],
                              inhibition: [[0.2, 0.7, 0.1], [0.4, 0.3, 0.2], [0.1, 0.3, 0.5]])
    }

    private func stock(spatial: Bool = false) -> FilmStock {
        var s = TestStocks.negative
        s.analyticalDevelopment = model
        s.flare = 0
        s.emulsionDiffusionMM = [0, 0, 0]
        s.mtfLumaShare = 0
        // Resolve the blur on this intentionally tiny test frame.
        s.couplerDiffusionMM = spatial ? 1.2 : 0
        return s
    }

    private var options: FotufilmEngine.Options {
        var o = FotufilmEngine.Options()
        o.grainScale = 0
        o.halationScale = 0
        o.paper = .labScan
        return o
    }

    private func scene(width: Int = 32, height: Int = 16) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let rgb: [Float] = x < width / 2 ? [0.05, 1.5, 0.1] : [2, 0.03, 0.8]
                for c in 0..<3 { image.planes[c][y * width + x] = rgb[c] }
            }
        }
        return image
    }

    func testPhysicalBoundsFeedbackResidualAndSelectiveShoulder() throws {
        try model.validate()
        for scale: Float in [0, 1, 100] {
            for x: Float in [-10, -2, 0, 2, 10] {
                let e: [Float] = [x, -x, 0.5 * x]
                let s = model.developedFraction(logExposure: e, scale: scale)
                for i in 0..<3 {
                    let n = 1 / (1 + exp(-model.slope[i] * (e[i] - model.midpoint[i])))
                    XCTAssertGreaterThanOrEqual(s[i], 0)
                    XCTAssertLessThanOrEqual(s[i], n + 1e-7)
                    let c = zip(model.inhibition[i], s).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    let fixed = n * -expm1(-model.budget[i]
                        / (1 + FilmEngineInvocation.effectiveCouplerScale(scale) * c))
                    XCTAssertEqual(s[i], fixed, accuracy: 2e-7)
                }
            }
        }
        let neutral = model.developedFraction(logExposure: [10, 10, 10])
        let selective = model.developedFraction(logExposure: [10, -10, -10])
        XCTAssertGreaterThan(selective[0], neutral[0] + 0.03)
    }

    func testValidationAndPackRoundTrip() throws {
        var invalid = model
        invalid.inhibition[0][1] = 100
        XCTAssertThrowsError(try invalid.validate())
        invalid = model
        invalid.budget = [1]
        XCTAssertThrowsError(try invalid.validate())
        var definition = FilmStockDefinition(id: "analytical-test", stock: stock())
        try definition.validate()
        let decoded = try JSONDecoder().decode(FilmStockDefinition.self,
                                               from: JSONEncoder().encode(definition))
        XCTAssertEqual(decoded.analyticalDevelopment, model)
        definition.isReversal = true
        XCTAssertThrowsError(try definition.validate())
    }

    func testConfigurationStagesAndDensityDomain() {
        let invocation = FilmEngineInvocation(stock: stock(), options: options, width: 32, height: 16)
        XCTAssertEqual(invocation.configuration.count, FOTUFILM_FRAME_CONFIGURATION_COUNT)
        XCTAssertEqual(FilmEngineInvocation.analyticalDevelopmentOffset,
                       FOTUFILM_CONFIG_ANALYTICAL_DEVELOPMENT)
        XCTAssertEqual(AnalyticalDevelopment.iterations, FOTUFILM_ANALYTICAL_ITERATIONS)
        XCTAssertNotEqual(invocation.featureMask & FilmEngineFeature.analyticalDevelopment, 0)
        XCTAssertEqual(invocation.featureMask & (FilmEngineFeature.couplers | FilmEngineFeature.adjacency), 0)
        XCTAssertEqual(FilmEngineInvocation.staged(invocation.featureMask, stage: .print)
                       & FilmEngineFeature.analyticalDevelopment, 0)
        XCTAssertEqual(stock().densityRanges, model.capacity)
        XCTAssertNotEqual(SpectralRuntime.cacheIdentifier(for: stock()),
                          SpectralRuntime.cacheIdentifier(for: TestStocks.negative))
    }

    func testCoupledConfigurationPreservesSampledTimingCurves() throws {
        var s = stock()
        for c in 0..<3 {
            let base = s.curves[c].dMin
            s.curves[c].sampled = try SampledCharacteristicCurve(
                logExposure: [-2, -0.5, 0.5, 2],
                density: [base, base + 0.3, base + 1.1, base + 2])
        }
        let invocation = FilmEngineInvocation(stock: s, options: options, width: 32, height: 16)
        for c in 0..<3 {
            for x: Float in [-3, -2, -0.2, 0.5, 1, 3] {
                XCTAssertEqual(try XCTUnwrap(FilmEngineInvocation.sampledFilmDensity(
                    configuration: invocation.configuration, channel: c, logExposure: x)),
                    s.curves[c].density(logExposure: x), accuracy: 1e-6)
            }
        }
        let offset = Int(FOTUFILM_CONFIG_ANALYTICAL_DEVELOPMENT)
        XCTAssertEqual(Array(invocation.configuration[offset...]), model.configuration)
    }

    func testCPUDevelopmentAndPrintSeam() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        let engine = FotufilmEngine(stock: stock(), options: options)
        let image = scene()
        let density = engine.developNegative(linearRGB: image)
        let invocation = FilmEngineInvocation(stock: stock(), options: options,
                                              width: image.width, height: image.height)
        // Independent pointwise reference, including the spectral exposure-domain seam.
        for x in [0, image.width - 1] {
            let scene = SIMD3<Float>(image.planes[0][x], image.planes[1][x], image.planes[2][x])
            let domain = ColorScience.linearRec2020ToExposureDomain(scene)
            let radiance = max(domain.x, domain.y, domain.z)
            let records = invocation.spectral.exposure.sample(domain / radiance) * (radiance / 0.18)
            let fraction = model.developedFraction(logExposure: (0..<3).map { log10(max(records[$0], 1e-6)) })
            for c in 0..<3 {
                XCTAssertEqual(density.planes[c][x], stock().curves[c].dMin + model.capacity[c] * fraction[c],
                               accuracy: 2e-5, "CPU must execute the new law")
            }
        }
        let full = engine.process(linearRGB: image)
        let printed = engine.printPositive(negativeDensity: density)
        for c in 0..<3 {
            for i in 0..<image.pixelCount {
                XCTAssertGreaterThanOrEqual(density.planes[c][i], stock().curves[c].dMin)
                XCTAssertLessThanOrEqual(density.planes[c][i], stock().curves[c].dMin + model.capacity[c])
                XCTAssertEqual(full.planes[c][i], printed.planes[c][i], accuracy: 2e-5)
            }
        }
    }

    #if canImport(Metal)
    func testCPUAndMetalAgreeWithAndWithoutSpatialFeedback() throws {
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let image = scene()
        var pixels = [Float](repeating: 1, count: image.pixelCount * 4)
        for i in 0..<image.pixelCount {
            for c in 0..<3 { pixels[4 * i + c] = image.planes[c][i] }
        }
        var local: ImageBuffer?
        for spatial in [false, true] {
            var o = options
            o.stage = .negative
            let s = stock(spatial: spatial)
            let cpu = FotufilmEngine(stock: s, options: o).developNegative(linearRGB: image)
            if let local {
                let difference = (0..<3).flatMap { c in
                    zip(local.planes[c], cpu.planes[c]).map { abs($0 - $1) }
                }.max() ?? 0
                XCTAssertGreaterThan(difference, 1e-4, "feedback blur must affect a chromatic edge")
            } else { local = cpu }
            let metal = try XCTUnwrap(gpu.processLinearFloat(
                pixels, width: image.width, height: image.height, stock: s, options: o))
            var maximum: Float = 0
            for i in 0..<image.pixelCount {
                for c in 0..<3 {
                    maximum = max(maximum, abs(cpu.planes[c][i] - metal[4 * i + c]))
                }
            }
            print("Analytical development spatial=\(spatial): max CPU/Metal density error \(maximum)")
            XCTAssertLessThan(maximum, 3e-4)
        }
    }

    func testHandwrittenBackendRejectsUnsupportedChemistry() throws {
        let renderer = try XCTUnwrap(HandwrittenMetalFilmRenderer())
        XCTAssertFalse(renderer.prepareLinearHDR(key: "analytical", stock: stock(),
                                                 options: options, frameWidth: 32, frameHeight: 16))
    }
    #endif
}
