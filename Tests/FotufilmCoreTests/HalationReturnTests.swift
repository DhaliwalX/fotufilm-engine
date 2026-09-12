import XCTest
@testable import FotufilmCore

final class HalationReturnTests: XCTestCase {
    func testCineStillDefaultsAndRecordBalance() throws {
        for (id, green, blue): (String, Float, Float) in [
            ("cinestill800t", 0.00404992, 0.00000376),
            ("cinestill400d", 0.0068812, 0.00004288),
        ] {
            let stock = try XCTUnwrap(FilmStock.named(id))
            XCTAssertEqual(stock.halationStrength[0], 0.12, accuracy: 1e-7)
            XCTAssertEqual(stock.halationStrength[1], green, accuracy: 1e-9)
            XCTAssertEqual(stock.halationStrength[2], blue, accuracy: 1e-10)
            let construction = try XCTUnwrap(stock.layeredTransport)
            for c in 0..<3 {
                XCTAssertEqual(construction.returnedToDirect[c][0], Double(stock.halationStrength[c]), accuracy: 1e-8)
            }
            let lower = try HalationReturn.ratios(for: stock, overriding: 0.03)
            for c in 0..<3 { XCTAssertEqual(lower[c], stock.halationStrength[c] / 4, accuracy: 1e-8) }
        }
    }

    func testOverrideMatchesStockRatiosInBothRenderersAndInvalidatesLayeredCache() throws {
        try XCTSkipUnless(TransportBackend.cpu.isAvailable)
        let stock = TestStocks.negative
        var source = ImageBuffer(width: 65, height: 49, fill: 0.01)
        for y in 21...27 { for x in 29...35 { for c in 0..<3 { source.planes[c][y * 65 + x] = 16 } } }
        for model in HalationModel.allCases {
            var options = TransportFixtures.quiet
            options.localTone = false; options.paper = .ektacolorEdge; options.halationModel = model
            options.format = FilmFormat(name: "small transport bench", frameHeightMM: 2)
            var outputs = [Float: ImageBuffer]()
            for ratio: Float in [0.03, 0.12, 0.24, 0.03] {
                options.halationReturnRatio = ratio
                let actual = try FotufilmEngine(stock: stock, options: options).processChecked(linearRGB: source)
                var changed = stock
                changed.halationStrength = stock.halationStrength.map { $0 / stock.halationStrength[0] * ratio }
                var reference = options; reference.halationReturnRatio = nil
                let expected = try FotufilmEngine(stock: changed, options: reference).processChecked(linearRGB: source)
                equal(actual, expected, tolerance: 0.00002)
                if let previous = outputs[ratio] { equal(actual, previous, tolerance: 0.000002) }
                outputs[ratio] = actual
            }
            XCTAssertGreaterThan(zip(outputs[0.03]!.planes[0], outputs[0.24]!.planes[0]).map { abs($0 - $1) }.max()!, 0.001)
        }
    }

    func testZeroDisablesReturnAndUniformColoursStayAnchored() throws {
        try XCTSkipUnless(TransportBackend.cpu.isAvailable)
        for model in HalationModel.allCases {
            var options = TransportFixtures.quiet
            options.localTone = false; options.halationModel = model; options.paper = .ektacolorEdge
            for colour: [Float] in [[0.18, 0.18, 0.18], [2, 0.04, 0.1]] {
                let field = ImageBuffer(width: 11, height: 9, planes: colour.map { Array(repeating: $0, count: 99) })
                options.halationReturnRatio = 0
                let zero = try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: field)
                options.halationReturnRatio = 0.24
                let stronger = try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: field)
                equal(zero, stronger, tolerance: 0.00005)
            }
            var source = ImageBuffer(width: 33, height: 25, fill: 0.02)
            for c in 0..<3 { source.planes[c][412] = 16 }
            options.halationReturnRatio = 0
            let zero = try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: source)
            options.halationReturnRatio = nil; options.halationScale = 0
            let off = try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: source)
            equal(zero, off, tolerance: 0.00005)
        }
    }

    func testInvalidRatiosFailBothCheckedRenderers() throws {
        for ratio: Float in [-0.01, 1.01, .infinity, .nan] { for model in HalationModel.allCases {
            var options = TransportFixtures.quiet
            options.halationModel = model; options.halationReturnRatio = ratio
            XCTAssertThrowsError(try FotufilmEngine(stock: TestStocks.negative, options: options)
                .processChecked(linearRGB: ImageBuffer(width: 3, height: 3, fill: 0.18)))
        } }
    }

    func testSpectralConstructionPreservesRelativeReturnsAndGeometry() throws {
        var model = TransportFixtures.stack
        model.returnedToDirect[0] = SpectralGrid.wavelengths.map { $0 < 580 ? 0.02 : 0.08 }
        let result = try HalationReturn.applying(0.12, to: model)
        XCTAssertEqual(result.returnedToDirect[0].reduce(0, +) / Double(SpectralGrid.count), 0.12, accuracy: 1e-8)
        let scale = result.returnedToDirect[0][0] / model.returnedToDirect[0][0]
        XCTAssertEqual(result.returnedToDirect[1][0], model.returnedToDirect[1][0] * scale, accuracy: 1e-10)
        XCTAssertEqual(result.layers, model.layers)
        XCTAssertEqual(result.recordDepthMM, model.recordDepthMM)
        XCTAssertEqual(result.coreSigmaMM, model.coreSigmaMM)
    }

    func testLayeredCPUMetalAgreementWithReturnOverride() throws {
        try XCTSkipUnless(TransportBackend.metal.isAvailable)
        var options = TransportFixtures.quiet
        options.localTone = false; options.paper = .ektacolorEdge
        options.halationModel = .layered; options.halationReturnRatio = 0.12
        var source = ImageBuffer(width: 49, height: 33, fill: 0.01)
        for i in 770...785 { for c in 0..<3 { source.planes[c][i] = 12 } }
        let cpu = try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: source)
        options.transportBackend = .metal
        let metal = try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: source)
        equal(cpu, metal, tolerance: 0.00005)
    }

    private func equal(_ a: ImageBuffer, _ b: ImageBuffer, tolerance: Float,
                       file: StaticString = #filePath, line: UInt = #line) {
        for c in 0..<3 {
            XCTAssertLessThanOrEqual(zip(a.planes[c], b.planes[c]).map { abs($0 - $1) }.max() ?? 0,
                                     tolerance, "channel \(c)", file: file, line: line)
        }
    }
}
