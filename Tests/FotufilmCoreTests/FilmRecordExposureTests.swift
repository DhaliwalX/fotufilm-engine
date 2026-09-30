import XCTest
@testable import FotufilmCore

final class FilmRecordExposureTests: XCTestCase {
    private func engine() throws -> FotufilmEngine {
        try XCTSkipUnless(HalideBackend.isAvailable, "Halide required")
        let stock = try XCTUnwrap(FilmStock.named("example-negative-400"))
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        return FotufilmEngine(stock: stock, options: options)
    }

    func testZeroFieldIsAnIdentityAndInvalidValuesThrow() throws {
        let engine = try engine()
        let image = ImageBuffer(width: 24, height: 18, fill: 0.18)
        let ordinary = try engine.processChecked(linearRGB: image)
        let zero = try engine.processChecked(linearRGB: image,
            additionalRecordExposure: FilmRecordExposure { region, buffer in
                XCTAssertEqual(buffer.count, region.width * region.height * 4)
                XCTAssertTrue(buffer.allSatisfy { $0 == 0 })
                XCTAssertEqual(region.frameWidth, 24)
                XCTAssertEqual(region.frameHeight, 18)
            })
        XCTAssertEqual(ordinary.planes, zero.planes)
        for invalid in [Float.nan, Float.infinity, -1] {
            XCTAssertThrowsError(try engine.processChecked(linearRGB: image,
                additionalRecordExposure: FilmRecordExposure { _, buffer in buffer[0] = invalid }))
        }
        enum WriterFailure: Error { case failed }
        XCTAssertThrowsError(try engine.processChecked(linearRGB: image,
            additionalRecordExposure: FilmRecordExposure { _, _ in throw WriterFailure.failed })) {
            XCTAssertTrue($0 is WriterFailure)
        }
    }

    func testAbsoluteRegionFieldAgreesAcrossWholeFrameAndTwoDimensionalTiles() throws {
        let engine = try engine()
        let width = 257, height = 193
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width { for c in 0..<3 {
            image.planes[c][y * width + x] = Float((x / 13 + y / 17 + c) % 4) * 0.25 + 0.04
        } } }
        let field = FilmRecordExposure { region, values in
            for y in 0..<region.height { for x in 0..<region.width {
                let i = (y * region.width + x) * 4
                values[i] = Float(x + region.x) / Float(region.frameWidth) * 0.1
                values[i+1] = Float(y + region.y) / Float(region.frameHeight) * 0.08
                values[i+2] = 0.04
                values[i+3] = 0.3
            } }
        }
        let budget = 512 << 10
        let apron = max(1, FilmEngineInvocation(stock: engine.stock, options: engine.options,
            width: width, height: height).spatialSupport)
        let tile = try HalideBackend.tileSize(width: width, height: height, apron: apron,
            budget: budget, additionalBytesPerPixel: 16)
        XCTAssertLessThan(tile.width, width)
        XCTAssertLessThan(tile.height, height)
        let whole = try engine.processChecked(linearRGB: image, cpuMemoryBudget: 1 << 28,
            additionalRecordExposure: field)
        let tiled = try engine.processChecked(linearRGB: image, cpuMemoryBudget: budget,
            additionalRecordExposure: field)
        let ordinary = try engine.processChecked(linearRGB: image)
        var worst: Float = 0, effect: Float = 0
        for c in 0..<3 { for i in 0..<image.pixelCount {
            worst = max(worst, abs(whole.planes[c][i] - tiled.planes[c][i]))
            effect = max(effect, abs(whole.planes[c][i] - ordinary.planes[c][i]))
        } }
        XCTAssertLessThan(worst, 1.0 / 4096)
        XCTAssertGreaterThan(effect, 0.01)
    }

    func testTileBudgetIncludesTheFourRecordField() throws {
        for (width, height, apron) in [(6000,4000,30), (9000,30,70), (30,9000,70), (100,50,1)] {
            let budget = 2 << 20
            let tile = try HalideBackend.tileSize(width: width, height: height, apron: apron,
                budget: budget, additionalBytesPerPixel: 16)
            let bytes = min(width, tile.width + 2 * apron) * min(height, tile.height + 2 * apron)
                * (80 + (tile.width < width ? 12 : 0))
            XCTAssertLessThanOrEqual(bytes, budget)
        }
    }
}
