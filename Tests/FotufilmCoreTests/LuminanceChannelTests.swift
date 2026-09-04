import XCTest
@testable import FotufilmCore

final class LuminanceChannelTests: XCTestCase {
    private func requireEngine() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
    }

    private func negative(correlation: Float) -> FilmStock {
        var stock = TestStocks.negative
        stock.grainLumaCorrelation = correlation
        return stock
    }

    private func developFlatField(_ stock: FilmStock, size: Int,
                                  options: FotufilmEngine.Options) -> ImageBuffer {
        var image = ImageBuffer(width: size, height: size)
        for channel in 0..<3 {
            for index in 0..<image.pixelCount { image.planes[channel][index] = 0.18 }
        }
        return FotufilmEngine(stock: stock, options: options).developNegative(linearRGB: image)
    }

    private func grainOnlyOptions() -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.halationScale = 0
        options.couplerScale = 0
        return options
    }

    private func assertLumaArmIsActive(_ stock: FilmStock,
                                       options: FotufilmEngine.Options, size: Int,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        let invocation = FilmEngineInvocation(stock: stock, options: options,
                                              width: size, height: size)
        XCTAssertNotEqual(invocation.featureMask & FilmEngineFeature.mtfLuma, 0,
                          "the luminance arm is not active, so this test is vacuous",
                          file: file, line: line)
    }

    private func standardDeviation(_ values: [Float]) -> Float {
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Float(values.count)
        return variance.squareRoot()
    }

    private func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let meanA = a.reduce(0, +) / Float(a.count)
        let meanB = b.reduce(0, +) / Float(b.count)
        var covariance: Float = 0, varianceA: Float = 0, varianceB: Float = 0
        for index in 0..<a.count {
            let da = a[index] - meanA, db = b[index] - meanB
            covariance += da * db
            varianceA += da * da
            varianceB += db * db
        }
        return covariance / (varianceA * varianceB).squareRoot()
    }

    func testGranularityIsInvariantToCorrelation() throws {
        try requireEngine()
        var ratios: [Float] = []
        for rho in [Float(0), 0.35, 0.7, 1] {
            ratios.append(GranularityMeter.ratio(negative(correlation: rho)))
        }
        for (index, ratio) in ratios.enumerated() {
            XCTAssertEqual(ratio, ratios[0], accuracy: 0.03,
                           "granularity drifted at correlation index \(index): "
                               + "\(ratio) vs \(ratios[0])")
        }
        XCTAssertGreaterThan(ratios[0], 0, "the grain stage produced no noise")
    }

    func testCorrelationCouplesTheLayers() throws {
        try requireEngine()
        let size = 256
        let options = grainOnlyOptions()

        let independent = developFlatField(negative(correlation: 0), size: size,
                                           options: options)
        let shared = developFlatField(negative(correlation: 1), size: size,
                                      options: options)

        let independentRG = correlation(independent.planes[0], independent.planes[1])
        let sharedRG = correlation(shared.planes[0], shared.planes[1])

        XCTAssertLessThan(abs(independentRG), 0.1,
                          "uncorrelated layers should share no grain: \(independentRG)")
        XCTAssertGreaterThan(sharedRG, 0.9,
                             "fully correlated layers should share one field: \(sharedRG)")
    }

    func testMonochromeRemainsASingleGrainField() throws {
        try requireEngine()
        XCTAssertEqual(TestStocks.monochrome.grainLumaCorrelation, 1,
                       "a monochrome stock must be packed as one grain field")
        let developed = developFlatField(TestStocks.monochrome, size: 128,
                                         options: grainOnlyOptions())
        let redGreen = correlation(developed.planes[0], developed.planes[1])
        XCTAssertGreaterThan(redGreen, 0.99,
                             "monochrome layers diverged: \(redGreen)")
    }

    func testCorrelationIsClampedWhenAStockIsBuilt() {
        let outOfRange = FilmStock(
            name: "clamp", sensitivity: TestStocks.negative.sensitivity,
            curves: TestStocks.negative.curves,
            couplerInhibition: TestStocks.negative.couplerInhibition,
            couplerDiffusionMM: TestStocks.negative.couplerDiffusionMM,
            grainStrength: TestStocks.negative.grainStrength,
            grainSizeMM: TestStocks.negative.grainSizeMM,
            grainLayerWeights: TestStocks.negative.grainLayerWeights,
            grainLumaCorrelation: 4,
            halationStrength: TestStocks.negative.halationStrength,
            paperCurve: TestStocks.negative.paperCurve)
        XCTAssertEqual(outOfRange.grainLumaCorrelation, 1)
    }

    func testMTFLumaSeparationCannotMoveAFlatField() throws {
        try requireEngine()
        var separated = TestStocks.negative
        separated.mtfLumaShare = 1
        separated.lumaDiffusionMM = 0.0005
        separated.emulsionDiffusionSecondaryMM = [0.0018, 0.0015, 0.0012]
        separated.emulsionDiffusionPrimaryShare = [0.35, 0.55, 0.75]

        var options = FotufilmEngine.Options()
        options.halationScale = 0
        options.couplerScale = 0
        options.grainScale = 0
        let size = 128
        options.format = FilmFormat(name: "test", frameHeightMM: 0.25)
        assertLumaArmIsActive(separated, options: options, size: size)

        let plain = developFlatField(TestStocks.negative, size: size, options: options)
        let luma = developFlatField(separated, size: size, options: options)

        for channel in 0..<3 {
            for index in 0..<plain.pixelCount {
                XCTAssertEqual(luma.planes[channel][index],
                               plain.planes[channel][index], accuracy: 1e-5,
                               "the luminance arm moved a flat field on layer \(channel)")
            }
        }
    }

    func testMTFLumaSeparationSharpensLuminanceDetail() throws {
        try requireEngine()
        var separated = TestStocks.negative
        separated.mtfLumaShare = 1
        separated.lumaDiffusionMM = 0.0005

        var options = FotufilmEngine.Options()
        options.halationScale = 0
        options.couplerScale = 0
        options.grainScale = 0
        let size = 128
        options.format = FilmFormat(name: "test", frameHeightMM: 0.25)
        assertLumaArmIsActive(separated, options: options, size: size)

        var image = ImageBuffer(width: size, height: size)
        for y in 0..<size {
            for x in 0..<size {
                let value: Float = x < size / 2 ? 0.05 : 0.60
                for channel in 0..<3 { image.planes[channel][y * size + x] = value }
            }
        }
        let plain = FotufilmEngine(stock: TestStocks.negative, options: options)
            .developNegative(linearRGB: image)
        let luma = FotufilmEngine(stock: separated, options: options)
            .developNegative(linearRGB: image)

        func edgeSlope(_ buffer: ImageBuffer) -> Float {
            let row = size / 2
            let left = buffer.planes[1][row * size + size / 2 - 1]
            let right = buffer.planes[1][row * size + size / 2]
            return abs(right - left)
        }
        XCTAssertGreaterThan(edgeSlope(luma), edgeSlope(plain),
                             "a sharper luminance sigma should steepen the edge")
    }
}
