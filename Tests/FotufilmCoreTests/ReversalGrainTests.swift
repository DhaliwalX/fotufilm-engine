import XCTest
import FotufilmHalide
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class ReversalGrainTests: XCTestCase {
    func testMaterialDefaultsAndExplicitLegacySelection() throws {
        XCTAssertEqual(TestStocks.reversal.grainDensityLaw, .dyeCloudReversal)
        XCTAssertEqual(TestStocks.negative.grainDensityLaw, .dyeCloud)
        XCTAssertEqual(TestStocks.monochrome.grainDensityLaw, .silver)
        for id in ["provia100f", "velvia50", "kodachrome64"] {
            XCTAssertEqual(try XCTUnwrap(FilmStock.named(id)).grainDensityLaw,
                           .dyeCloudReversal, id)
        }
        var definition = FilmStockDefinition(id: "legacy", stock: TestStocks.reversal)
        definition.grainDensityLaw = .dyeCloudSelwyn
        definition.grainReversalProfile = nil
        let decoded = try JSONDecoder().decode(
            FilmStockDefinition.self, from: JSONEncoder().encode(definition))
        XCTAssertEqual(decoded.stock.grainDensityLaw.rawValue, 2)
        definition.grainDensityLaw = nil
        XCTAssertEqual(definition.stock.grainDensityLaw, .dyeCloudReversal)
        XCTAssertEqual(definition.stock.grainReversalProfile, [1.1, 3])
    }

    func testProfileRoundTripValidationAndKernelLayout() throws {
        var definition = FilmStockDefinition(id: "profile", stock: TestStocks.reversal)
        definition.grainReversalProfile = [1.35, 4.5]
        let decoded = try JSONDecoder().decode(
            FilmStockDefinition.self, from: JSONEncoder().encode(definition))
        try decoded.validate()
        XCTAssertEqual(decoded.stock.grainReversalProfile, [1.35, 4.5])
        let invocation = FilmEngineInvocation(stock: decoded.stock,
            options: FotufilmEngine.Options(), width: 64, height: 64)
        let offset = FilmEngineInvocation.grainReversalProfileOffset
        XCTAssertEqual(offset, FOTUFILM_CONFIG_GRAIN_REVERSAL_PROFILE)
        XCTAssertEqual(offset, 18034, "handwritten Metal must use the same offset")
        XCTAssertEqual(Array(invocation.configuration[offset..<(offset + 2)]), [1.35, 4.5])
        XCTAssertEqual(invocation.configuration.count, FOTUFILM_FRAME_CONFIGURATION_COUNT)
        for profile: [Float] in [[], [1], [1, 3, 4], [0, 3], [2.1, 3],
                                 [1, 0], [1, 11], [.nan, 3], [1, .infinity]] {
            definition.grainReversalProfile = profile
            XCTAssertThrowsError(try definition.validate(), "\(profile)")
        }
    }

    func testAnchorFogAndSaturatingShape() {
        var stock = TestStocks.reversal
        for profile: [Float] in [[1.1, 3], [1.35, 4.5], [2, 10]] {
            stock.grainReversalProfile = profile
            for fog: Float in [0, 0.02, 0.12] {
                stock.grainFogDensity = fog
                for layer in 0..<3 {
                    let anchor = stock.granularityAnchorDensity(layer: layer)
                    XCTAssertEqual(stock.grainDensityModulation(layer: layer, netDensity: anchor),
                                   1, accuracy: 1e-6)
                    var previous: Float = -1
                    for net: Float in [0, 0.1, 0.4, 1, 1.7, 2.8, 3.5] {
                        let actual = stock.grainDensityModulation(layer: layer, netDensity: net)
                        let p = profile[0], ds = profile[1], d = net + fog, a = anchor + fog
                        let expected = pow(d / a, p)
                            * sqrt((1 + pow(a / ds, 2 * p)) / (1 + pow(d / ds, 2 * p)))
                        XCTAssertEqual(actual, expected, accuracy: 1e-5)
                        XCTAssertGreaterThanOrEqual(actual, previous)
                        previous = actual
                    }
                }
            }
        }
        stock.grainReversalProfile = [1.1, 3]
        stock.grainFogDensity = 0
        var legacy = stock
        legacy.grainDensityLaw = .dyeCloudSelwyn
        XCTAssertLessThan(stock.grainDensityModulation(layer: 1, netDensity: 0.2),
                          0.6 * legacy.grainDensityModulation(layer: 1, netDensity: 0.2))
        XCTAssertGreaterThan(stock.grainDensityModulation(layer: 1, netDensity: 2.8),
                             1.3 * legacy.grainDensityModulation(layer: 1, netDensity: 2.8))
        let limit = 1 / sqrt(stock.reversalGranularityVariance(0.9))
        XCTAssertEqual(stock.grainDensityModulation(layer: 1, netDensity: 100),
                       limit, accuracy: 0.002)
        XCTAssertEqual(stock.grainDensityModulation(layer: 1, netDensity: -1), 0)
    }

    func testLuminanceReadoutIncludesRecordCovariance() {
        let correlated: [Float] = [-1, 1, -1, 1]
        XCTAssertEqual(GranularityMeter.luminanceSigma(
            [correlated, correlated, correlated]), 1, accuracy: 1e-6)
        let independent: [[Float]] = [correlated, [-1, -1, 1, 1], [-1, 1, 1, -1]]
        XCTAssertEqual(GranularityMeter.luminanceSigma(independent),
                       sqrt(0.3 * 0.3 + 0.6 * 0.6 + 0.1 * 0.1), accuracy: 1e-6)
        XCTAssertEqual(GranularityMeter.luminanceSigma(
            [correlated, correlated.map { -$0 / 2 }, [0, 0, 0, 0]]), 0, accuracy: 1e-6)
    }

    func testRenderedReversalFollowsDevelopedDensityAndKeepsItsAnchor() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide required")
        var stock = TestStocks.reversal
        stock.grainReversalProfile = [1.35, 4.5]
        stock.flare = 0
        let curve = stock.curves[1]
        let densities: [Float] = [0.2, 0.9, 1.6, 2.8]
        let readings = densities.map { net -> GranularityMeter.Measurement in
            // Reversal complements the formed density before grain is evaluated.
            let exposure = 0.18 * pow(10, curve.logExposure(density: curve.dMax - net))
            return GranularityMeter.measure(stock, pxPerMM: 250, seed: 0x5EED,
                                             exposure: exposure)
        }
        for reading in readings {
            XCTAssertGreaterThan(reading.luminanceSigma, 0)
            XCTAssertEqual(reading.ratios[1] / readings[1].ratios[1], 1, accuracy: 0.005)
        }
        XCTAssertEqual(readings[1].sigma[1] / stock.grainStrength, 1,
                       accuracy: GranularityMeter.uniformRelativeTolerance)
    }

#if canImport(Metal)
    func testReversalGrainMatchesCPUAndMetalWithDeterministicSeeds() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide required")
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let side = 256
        var stock = TestStocks.reversal
        stock.flare = 0
        stock.adjacencyStrength = 0
        var options = FotufilmEngine.Options()
        options.stage = .negative
        options.halationScale = 0
        options.couplerScale = 0
        options.format = FilmFormat(name: "resolved grain", frameHeightMM: 1)
        options.seed = 0x5EED
        // CPU uses inverse-CDF tables; Metal can use direct draws. Compare the measured
        // density variance on a resolved uniform field, not individual random samples.
        for profile: [Float] in [[1.1, 3], [1.35, 4.5]] {
            stock.grainReversalProfile = profile
            for net: Float in [0.2, 0.9, 2.8] {
                let exposure = 0.18 * pow(10, stock.curves[1].logExposure(
                    density: stock.curves[1].dMax - net))
                var input = [Float](repeating: exposure, count: side * side * 4)
                for pixel in 0..<(side * side) { input[pixel * 4 + 3] = 1 }
                let linear = ImageBuffer(width: side, height: side, planes:
                    [[Float]](repeating: [Float](repeating: exposure, count: side * side), count: 3))
                let cpu = FotufilmEngine(stock: stock, options: options)
                    .developNegative(linearRGB: linear)
                func render() throws -> [Float] {
                    try XCTUnwrap(gpu.processLinearFloat(input, width: side, height: side,
                                                         stock: stock, options: options))
                }
                let metal = try render()
                XCTAssertEqual(metal, try render())
                for channel in 0..<3 {
                    let metalValues = (0..<(side * side)).map { metal[$0 * 4 + channel] }
                    let cpuValues = cpu.planes[channel]
                    let sigmaRatio = GranularityMeter.sigma(metalValues)
                        / GranularityMeter.sigma(cpuValues)
                    XCTAssertEqual(sigmaRatio, 1,
                                   accuracy: GranularityMeter.uniformRelativeTolerance,
                                   "profile \(profile), density \(net), channel \(channel)")
                    let meanDifference = (metalValues.reduce(0, +) - cpuValues.reduce(0, +))
                        / Float(side * side)
                    XCTAssertEqual(meanDifference, 0, accuracy: 0.008)
                }
                options.seed += 1
                XCTAssertNotEqual(metal, try render())
                options.seed -= 1
            }
        }
    }
#endif
}
