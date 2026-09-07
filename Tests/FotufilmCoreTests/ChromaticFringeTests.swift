import XCTest
import FotufilmHalide
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class ChromaticFringeTests: XCTestCase {
    private func options(height: Int, amount: Float = 0.2) -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.chromaticFringeAmount = amount
        options.chromaticFringeRadiusMM = 0.1
        options.format = FilmFormat(name: "Resolved fringe fixture", frameHeightMM: Float(height) / 90)
        options.grainScale = 0
        options.halationScale = 0
        options.flareScale = 0
        options.localTone = false
        options.stage = .negative
        return options
    }

    private var isolated: FilmStock {
        var stock = TestStocks.negative
        stock.couplerGeometry = nil
        // Only the red-sensitive receiver sees the green-sensitive donor.
        stock.couplerInhibition = [[0, 0.5, 0], [0, 0, 0], [0, 0, 0]]
        stock.couplerDiffusionMM = 0.01
        stock.adjacencyStrength = 0
        return stock
    }

    private func edge(width: Int = 128, height: Int = 64) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                image.planes[0][y * width + x] = 0.18
                image.planes[1][y * width + x] = x < width / 2 ? 0.03 : 0.8
                image.planes[2][y * width + x] = 0.18
            }
        }
        return image
    }

    func testPackCompatibilityRoundTripAndValidation() throws {
        var definition = FilmStockDefinition(id: "fringe-fixture", stock: TestStocks.negative)
        let legacy = try JSONEncoder().encode(definition)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("chromaticFringe"))
        let decoded = try JSONDecoder().decode(FilmStockDefinition.self, from: legacy).stock
        XCTAssertEqual(decoded.chromaticFringeAmount, 0)
        XCTAssertEqual(decoded.chromaticFringeRadiusMM, 0.1)
        definition.chromaticFringeAmount = 0.15
        definition.chromaticFringeRadiusMM = 0.12
        let data = try JSONEncoder().encode(definition.validated())
        let authored = try JSONDecoder().decode(FilmStockDefinition.self, from: data).stock
        XCTAssertEqual(authored.chromaticFringeAmount, 0.15)
        XCTAssertEqual(authored.chromaticFringeRadiusMM, 0.12)
        definition.chromaticFringeAmount = 1.01
        XCTAssertThrowsError(try definition.validated())
        definition.chromaticFringeAmount = 0.2
        for radius: Float in [-1, .nan, .infinity, 2.1] {
            definition.chromaticFringeRadiusMM = radius
            XCTAssertThrowsError(try definition.validated())
        }
    }

    func testABIAndPhysicalScaleAndNeutralAnchor() {
        let stock = isolated
        let on = FilmEngineInvocation(stock: stock, options: options(height: 64), width: 128, height: 64)
        let off = FilmEngineInvocation(stock: stock, options: options(height: 64, amount: 0), width: 128, height: 64)
        XCTAssertEqual(FilmEngineInvocation.chromaticFringeAmountOffset, Int(FOTUFILM_CONFIG_CHROMATIC_FRINGE_AMOUNT))
        XCTAssertEqual(FilmEngineInvocation.chromaticFringeSigmaOffset, Int(FOTUFILM_CONFIG_CHROMATIC_FRINGE_SIGMA))
        XCTAssertEqual(FilmEngineInvocation.chromaticFringeRadiusOffset, Int(FOTUFILM_CONFIG_CHROMATIC_FRINGE_RADIUS))
        XCTAssertEqual(on.configuration.count, Int(FOTUFILM_FRAME_CONFIGURATION_COUNT))
        XCTAssertEqual(on.configuration[FilmEngineInvocation.chromaticFringeSigmaOffset], 9, accuracy: 1e-5)
        XCTAssertGreaterThan(on.spatialSupport, off.spatialSupport)
        let anchor = FilmEngineInvocation.couplerWarpOffset
        let end = anchor + 3 * FilmEngineInvocation.couplerWarpSamples
        XCTAssertEqual(Array(on.configuration[anchor..<end]), Array(off.configuration[anchor..<end]))
        let doubled = FilmEngineInvocation(stock: stock, options: options(height: 64), width: 256, height: 128)
        XCTAssertEqual(doubled.configuration[FilmEngineInvocation.chromaticFringeSigmaOffset], 18, accuracy: 1e-5)
        var cropped = options(height: 64)
        cropped.frameCoverage = 0.5
        let crop = FilmEngineInvocation(stock: stock, options: cropped, width: 128, height: 64)
        XCTAssertEqual(crop.configuration[FilmEngineInvocation.chromaticFringeSigmaOffset], 18, accuracy: 1e-5)
    }

    func testInactiveRequestsAndInvalidOptionsAreHarmless() {
        var variants = [options(height: 64, amount: 0)]
        var equalRadius = options(height: 64)
        equalRadius.chromaticFringeRadiusMM = isolated.couplerDiffusionMM
        variants.append(equalRadius)
        var invalid = options(height: 64)
        invalid.chromaticFringeAmount = .nan
        variants.append(invalid)
        invalid = options(height: 64)
        invalid.chromaticFringeRadiusMM = .infinity
        variants.append(invalid)
        var noCouplers = options(height: 64)
        noCouplers.couplerScale = 0
        variants.append(noCouplers)
        var noSpatial = options(height: 64)
        noSpatial.stage = .texture
        noSpatial.textureStages = []
        variants.append(noSpatial)
        for option in variants {
            let invocation = FilmEngineInvocation(stock: isolated, options: option, width: 128, height: 64)
            XCTAssertEqual(invocation.configuration[FilmEngineInvocation.chromaticFringeAmountOffset], 0)
            XCTAssertEqual(invocation.configuration[FilmEngineInvocation.chromaticFringeRadiusOffset], 0)
        }
        for stock in [TestStocks.monochrome, FilmStock.noFilm] {
            let invocation = FilmEngineInvocation(stock: stock, options: options(height: 64), width: 128, height: 64)
            XCTAssertEqual(invocation.configuration[FilmEngineInvocation.chromaticFringeAmountOffset], 0)
        }
    }

    func testZeroAmountAndEqualRadiiPreserveImageExactly() {
        let image = edge()
        let off = options(height: image.height, amount: 0)
        let expected = FotufilmEngine(stock: isolated, options: off).developNegative(linearRGB: image)
        var same = options(height: image.height)
        same.chromaticFringeRadiusMM = isolated.couplerDiffusionMM
        let actual = FotufilmEngine(stock: isolated, options: same).developNegative(linearRGB: image)
        XCTAssertEqual(actual.interleavedRGB(), expected.interleavedRGB())
    }

    func testUniformNeutralAndColoredFieldsRemainUnchangedIncludingBorders() {
        for values: [Float] in [[0.18, 0.18, 0.18], [0.04, 0.8, 0.15], [0, 0, 0], [8, 2, 4]] {
            let image = ImageBuffer(width: 32, height: 32,
                interleavedRGB: Array(repeating: values, count: 32 * 32).flatMap { $0 })
            let on = FotufilmEngine(stock: isolated, options: options(height: 32)).developNegative(linearRGB: image)
            let off = FotufilmEngine(stock: isolated, options: options(height: 32, amount: 0)).developNegative(linearRGB: image)
            let maximum = zip(on.interleavedRGB(), off.interleavedRGB()).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThan(maximum, 2e-5)
        }
    }

    func testChromaticChangeUsesOnlyTheReceivingLayerAndRemainsBounded() {
        let image = edge()
        let stock = isolated
        let on = FotufilmEngine(stock: stock, options: options(height: image.height)).developNegative(linearRGB: image)
        let off = FotufilmEngine(stock: stock, options: options(height: image.height, amount: 0)).developNegative(linearRGB: image)
        let delta = zip(on.planes[0], off.planes[0]).map { $0 - $1 }
        XCTAssertGreaterThan(delta.max() ?? 0, 1e-4)
        XCTAssertLessThan(delta.min() ?? 0, -1e-4)
        XCTAssertEqual(on.planes[1], off.planes[1])
        XCTAssertEqual(on.planes[2], off.planes[2])
        for c in 0..<3 {
            XCTAssertTrue(on.planes[c].allSatisfy {
                $0.isFinite && $0 >= stock.curves[c].dMin - 1e-5 && $0 <= stock.curves[c].dMax + 1e-5
            })
        }
    }

    func testBroadTransportMatchesStripRendering() throws {
        let width = 96, height = 768
        var image = edge(width: width, height: height)
        for y in 0..<height where y % 97 < 31 {
            for x in 0..<width { image.planes[1][y * width + x] *= 3 }
        }
        let o = options(height: height)
        let apron = FilmEngineInvocation(stock: isolated, options: o, width: width, height: height).spatialSupport
        XCTAssertLessThan(HalideBackend.stripRows(width: width, height: height, apron: apron, budget: 3 << 20), height)
        let whole = try XCTUnwrap(HalideBackend.process(image: image, stock: isolated, options: o, memoryBudget: 1 << 30))
        let striped = try XCTUnwrap(HalideBackend.process(image: image, stock: isolated, options: o, memoryBudget: 3 << 20))
        let maximum = zip(whole.interleavedRGB(), striped.interleavedRGB()).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maximum, 1.0 / 4096)
    }

    #if canImport(Metal)
    func testCPUAndMetalAgreementWithBothAdjacencyModels() throws {
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let image = edge()
        var rgba = [Float](repeating: 1, count: image.pixelCount * 4)
        for i in 0..<image.pixelCount {
            for c in 0..<3 { rgba[i * 4 + c] = image.planes[c][i] }
        }
        for stock in [isolated, TestStocks.reversal, try XCTUnwrap(FilmStock.named("gold200"))] {
            for model in AdjacencyModel.allCases {
                var o = options(height: image.height)
                o.adjacencyModel = model
                let cpu = FotufilmEngine(stock: stock, options: o).developNegative(linearRGB: image)
                let metal = try XCTUnwrap(gpu.processLinearFloat(rgba, width: image.width, height: image.height, stock: stock, options: o))
                var maximum: Float = 0
                for i in 0..<image.pixelCount {
                    for c in 0..<3 { maximum = max(maximum, abs(cpu.planes[c][i] - metal[i * 4 + c])) }
                }
                XCTAssertLessThan(maximum, 3e-4, "\(stock.name), \(model): \(maximum)")
            }
        }
    }
    #endif
}
