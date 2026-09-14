import XCTest
@testable import FotufilmCore

final class CPUProcessMemoryTests: XCTestCase {
    func testCheckedAPICanRejectOrExplicitlyBudgetSpatialSupport() throws {
        try XCTSkipUnless(HalideBackend.isAvailable, "Halide required")
        let image = ImageBuffer(width: 8, height: 8, fill: 0.18)
        let engine = FotufilmEngine(stock: TestStocks.negative)
        XCTAssertThrowsError(try engine.processChecked(linearRGB: image, cpuMemoryBudget: 1))
        let explicit = try engine.processChecked(linearRGB: image, cpuMemoryBudget: 8 * 8 * 64)
        let ordinary = try engine.processChecked(linearRGB: image)
        XCTAssertEqual(explicit.planes, ordinary.planes)
    }

    func testLargeReleasedStocksStayWithinEstimatedBudget() throws {
        let budget = HalideBackend.defaultMemoryBudget
        for id in ["portra400", "cinestill800t", "hp5plus400"] {
            let stock = try XCTUnwrap(FilmStock.named(id))
            for (width, height) in [(6000, 4000), (9000, 6000), (12000, 10000)] {
                let apron = max(1, FilmEngineInvocation(stock: stock, options: .init(),
                    width: width, height: height).spatialSupport)
                let tile = try HalideBackend.tileSize(width: width, height: height,
                    apron: apron, budget: budget)
                XCTAssertGreaterThan(tile.width, 0)
                XCTAssertGreaterThan(tile.height, 0)
                let paddedWidth = min(width, tile.width + 2 * apron)
                let paddedHeight = min(height, tile.height + 2 * apron)
                let bytesPerPixel = HalideBackend.processBytesPerPixel + (tile.width < width ? 12 : 0)
                XCTAssertLessThanOrEqual(paddedWidth * paddedHeight * bytesPerPixel, budget,
                    "\(id) \(width)×\(height) exceeded its budget")
            }
        }
    }

    func testPlannerHandlesFullFramesNarrowFramesAndInsufficientBudgets() throws {
        let whole = try HalideBackend.tileSize(width: 100, height: 50, apron: 1000, budget: 320_000)
        XCTAssertEqual(whole.width, 100)
        XCTAssertEqual(whole.height, 50)
        for (width, height) in [(9000, 30), (30, 9000), (2000, 2000)] {
            let tile = try HalideBackend.tileSize(width: width, height: height, apron: 70, budget: 2 << 20)
            let bytesPerPixel = 64 + (tile.width < width ? 12 : 0)
            XCTAssertLessThanOrEqual(min(width, tile.width + 140) * min(height, tile.height + 140)
                * bytesPerPixel, 2 << 20)
        }
        XCTAssertThrowsError(try HalideBackend.tileSize(width: 6000, height: 4000, apron: 2000, budget: 1 << 20))
        XCTAssertThrowsError(try HalideBackend.tileSize(width: 10, height: 10, apron: 1, budget: 0))
    }

    func testTiledRenderingMatchesWholeFrameAcrossBothAxes() throws {
        try XCTSkipUnless(HalideBackend.isAvailable, "Halide required")
        let width = 513, height = 385
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let value: Float = (x / 37 + y / 29).isMultiple(of: 2) ? 3.5 : 0.03
                for c in 0..<3 { image.planes[c][y * width + x] = value * (0.8 + Float(c) * 0.2) }
            }
        }
        var options = FotufilmEngine.Options()
        options.highlights = -0.3
        options.shadows = 0.2
        for (stock, stage, noFilm) in [
            (TestStocks.negative, PipelineStage.full, false),
            (TestStocks.reversal, .negative, false),
            (TestStocks.monochrome, .texture, false),
            (TestStocks.negative, .full, true),
        ] {
            options.stage = stage
            let apron = max(1, FilmEngineInvocation(stock: stock, options: options,
                width: width, height: height, noFilm: noFilm).spatialSupport)
            let budget = 2 << 20
            let tile = try HalideBackend.tileSize(width: width, height: height, apron: apron, budget: budget)
            XCTAssertLessThan(tile.width, width)
            XCTAssertLessThan(tile.height, height)
            let whole = try XCTUnwrap(HalideBackend.process(image: image, stock: stock,
                options: options, memoryBudget: 1 << 30, noFilm: noFilm))
            let tiled = try XCTUnwrap(HalideBackend.process(image: image, stock: stock,
                options: options, memoryBudget: budget, noFilm: noFilm))
            var worst: Float = 0
            for c in 0..<3 {
                for i in 0..<image.pixelCount {
                    XCTAssertTrue(tiled.planes[c][i].isFinite)
                    worst = max(worst, abs(tiled.planes[c][i] - whole.planes[c][i]))
                }
            }
            XCTAssertLessThan(worst, 1.0 / 4096, "\(stock.name) \(stage) tile seams")
        }
    }
}
