import XCTest
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class AdjacencyTests: XCTestCase {
    private func options(height: Int) -> FotufilmEngine.Options {
        var o = FotufilmEngine.Options()
        o.adjacencyModel = .screenedDiffusion
        o.format = FilmFormat(name: "Resolved adjacency fixture", frameHeightMM: Float(height) / 90)
        o.grainScale = 0
        o.halationScale = 0
        o.flareScale = 0
        o.localTone = false
        o.stage = .negative
        return o
    }

    private func edge(width: Int = 128, height: Int = 64) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let value: Float = x < width / 2 ? 0.06 : 0.5
                for c in 0..<3 { image.planes[c][y * width + x] = value }
            }
        }
        return image
    }

    func testLegacyPackDefaultAndScreenedRoundTrip() throws {
        var definition = FilmStockDefinition(id: "fixture", stock: TestStocks.monochrome)
        let legacy = try JSONEncoder().encode(definition)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("adjacencyModel"))
        XCTAssertEqual(try JSONDecoder().decode(FilmStockDefinition.self, from: legacy)
            .stock.adjacencyModel, .gaussian)
        definition.adjacencyModel = .screenedDiffusion
        let encoded = try JSONEncoder().encode(definition)
        XCTAssertEqual(try JSONDecoder().decode(FilmStockDefinition.self, from: encoded)
            .stock.adjacencyModel, .screenedDiffusion)
    }

    func testUniformFieldsHoldAndDensityStaysWithinCapacity() {
        for stock in TestStocks.all {
            var on = options(height: 32)
            var off = on
            off.couplerScale = 0
            // Isolate intra-layer adjacency from inter-layer inhibition.
            var isolated = stock
            isolated.couplerGeometry = nil
            isolated.couplerInhibition = Array(repeating: [0, 0, 0], count: 3)
            for value: Float in [0, 0.001, 0.18, 32] {
                let input = ImageBuffer(width: 32, height: 32,
                    interleavedRGB: Array(repeating: value, count: 32 * 32 * 3))
                let actual = FotufilmEngine(stock: isolated, options: on).developNegative(linearRGB: input)
                let expected = FotufilmEngine(stock: isolated, options: off).developNegative(linearRGB: input)
                for c in 0..<3 {
                    for i in 0..<input.pixelCount {
                        XCTAssertEqual(actual.planes[c][i], expected.planes[c][i], accuracy: 2e-5)
                    }
                }
            }
            on.couplerScale = 10
            let extreme = FotufilmEngine(stock: isolated, options: on)
                .developNegative(linearRGB: edge())
            for c in 0..<3 {
                XCTAssertTrue(extreme.planes[c].allSatisfy {
                    $0.isFinite && $0 >= isolated.curves[c].dMin - 1e-5
                        && $0 <= isolated.curves[c].dMax + 1e-5
                })
            }
        }
    }

    func testBorderAndFringeHaveDensityDependentAsymmetry() {
        let input = edge()
        let result = FotufilmEngine(stock: TestStocks.monochrome, options: options(height: 64))
            .developNegative(linearRGB: input)
        let row = 32 * 128
        let fringe = result.planes[0][row + 8] - result.planes[0][row + 63]
        let border = result.planes[0][row + 64] - result.planes[0][row + 120]
        XCTAssertGreaterThan(fringe, 0.001)
        XCTAssertGreaterThan(border, fringe * 1.5,
            "the denser side must receive a larger correction than the low-density fringe")
    }

    func testScreenedTransportStripesMatchWholeFrame() throws {
        let width = 128, height = 768
        var input = edge(width: width, height: height)
        for y in 0..<height where y % 83 < 17 {
            for x in 0..<width {
                for c in 0..<3 { input.planes[c][y * width + x] *= 4 }
            }
        }
        let o = options(height: height)
        let stock = TestStocks.monochrome
        let whole = try XCTUnwrap(HalideBackend.process(
            image: input, stock: stock, options: o, memoryBudget: 1 << 30))
        let apron = FilmEngineInvocation(stock: stock, options: o,
            width: width, height: height).spatialSupport
        XCTAssertLessThan(HalideBackend.stripRows(width: width, height: height,
            apron: apron, budget: 3 << 20), height)
        let striped = try XCTUnwrap(HalideBackend.process(
            image: input, stock: stock, options: o, memoryBudget: 3 << 20))
        let maximum = zip(whole.interleavedRGB(), striped.interleavedRGB())
            .map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maximum, 1.0 / 4096)
    }

    #if canImport(Metal)
    func testScreenedCPUAndMetalDensityAgreement() throws {
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let input = edge()
        var rgba = [Float](repeating: 1, count: input.pixelCount * 4)
        for i in 0..<input.pixelCount {
            for c in 0..<3 { rgba[i * 4 + c] = input.planes[c][i] }
        }
        let stocks = TestStocks.all + [try XCTUnwrap(FilmStock.named("gold200"))]
        for stock in stocks {
            let o = options(height: input.height)
            let cpu = FotufilmEngine(stock: stock, options: o).developNegative(linearRGB: input)
            let metal = try XCTUnwrap(gpu.processLinearFloat(rgba,
                width: input.width, height: input.height, stock: stock, options: o))
            var maximum: Float = 0
            for i in 0..<input.pixelCount {
                for c in 0..<3 { maximum = max(maximum, abs(cpu.planes[c][i] - metal[i * 4 + c])) }
            }
            XCTAssertLessThan(maximum, 2e-4, "\(stock.name): \(maximum)")
        }
    }
    #endif
}
