#if canImport(Metal)
import Metal
import XCTest
@testable import FotufilmCore
import FotufilmMetal

final class PipelineStageMetalTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide engine required")
    }

    private let width = 96
    private let height = 64

    private func scene() -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let ramp = Float(x) / Float(width - 1)
                let checker = (x / 4 + y / 4) % 2 == 0 ? Float(1.3) : Float(0.7)
                let specular = (x - 12) * (x - 12) + (y - 12) * (y - 12) < 9 ? Float(24) : Float(1)
                pixels[index] = 0.02 + 0.9 * ramp * checker * specular
                pixels[index + 1] = 0.02 + 0.7 * (1 - ramp) * checker * specular
                pixels[index + 2] = 0.02 + 0.5 * ramp * ramp * checker * specular
                pixels[index + 3] = 1
            }
        }
        return pixels
    }

    private func options(stage: PipelineStage) -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.stage = stage
        options.format = .super35
        options.seed = 0x5EED
        return options
    }

    func testNegativeThenPrintReproducesFullOnMetal() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else {
            throw XCTSkip("Halide Metal unavailable")
        }
        let input = scene()
        for stock in [TestStocks.negative, TestStocks.monochrome] {
            let full = try XCTUnwrap(gpu.processLinearFloat(
                input, width: width, height: height, stock: stock,
                options: options(stage: .full), frameIndex: 7))
            let negative = try XCTUnwrap(gpu.processLinearFloat(
                input, width: width, height: height, stock: stock,
                options: options(stage: .negative), frameIndex: 7))
            let split = try XCTUnwrap(gpu.processLinearFloat(
                negative, width: width, height: height, stock: stock,
                options: options(stage: .print), frameIndex: 7))

            for index in 0..<(width * height * 4) {
                XCTAssertEqual(split[index], full[index],
                               accuracy: max(abs(full[index]), 1) * 4e-6,
                               "\(stock.name) component \(index)")
            }
        }
    }

    func testTheInterchangeCarriesAlphaThrough() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else {
            throw XCTSkip("Halide Metal unavailable")
        }
        var input = scene()
        for pixel in 0..<(width * height) {
            input[pixel * 4 + 3] = Float(pixel % 5) / 4
        }
        let negative = try XCTUnwrap(gpu.processLinearFloat(
            input, width: width, height: height, stock: TestStocks.negative,
            options: options(stage: .negative)))
        let printed = try XCTUnwrap(gpu.processLinearFloat(
            negative, width: width, height: height, stock: TestStocks.negative,
            options: options(stage: .print)))
        for pixel in 0..<(width * height) {
            XCTAssertEqual(negative[pixel * 4 + 3], input[pixel * 4 + 3], accuracy: 0)
            XCTAssertEqual(printed[pixel * 4 + 3], input[pixel * 4 + 3], accuracy: 0)
        }
    }

    func testTextureInvariantsOnMetal() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else {
            throw XCTSkip("Halide Metal unavailable")
        }
        let input = scene()
        var nothing = options(stage: .texture)
        nothing.textureStages = .none
        let copied = try XCTUnwrap(gpu.processLinearFloat(
            input, width: width, height: height, stock: TestStocks.negative,
            options: nothing))
        for index in 0..<(width * height * 4) {
            XCTAssertEqual(copied[index], input[index], accuracy: 0,
                           "component \(index) moved with nothing selected")
        }

        var uniform = [Float](repeating: 0.18, count: width * height * 4)
        for pixel in 0..<(width * height) { uniform[pixel * 4 + 3] = 1 }
        var deterministic = options(stage: .texture)
        deterministic.textureStages = [.emulsionMTF, .halation, .adjacency, .enlarger]
        let flat = try XCTUnwrap(gpu.processLinearFloat(
            uniform, width: width, height: height, stock: TestStocks.negative,
            options: deterministic))
        for pixel in 0..<(width * height) {
            for channel in 0..<3 {
                XCTAssertEqual(flat[pixel * 4 + channel], 0.18, accuracy: 0.18 * 2e-5,
                               "channel \(channel) moved on a uniform field")
            }
        }
    }

    func testTextureCarriesLuminanceSeparatedMTFOnMetal() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else {
            throw XCTSkip("Halide Metal unavailable")
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let input = scene()
        let byteCount = input.count * MemoryLayout<Float>.stride
        let source = try XCTUnwrap(device.makeBuffer(
            bytes: input, length: byteCount, options: .storageModeShared))
        let output = try XCTUnwrap(device.makeBuffer(
            length: byteCount, options: .storageModeShared))

        var stock = TestStocks.negative
        stock.mtfLumaShare = 0.8
        stock.lumaDiffusionMM = 0.0008
        stock.emulsionDiffusionSecondaryMM = [0.0018, 0.0015, 0.0012]
        stock.emulsionDiffusionPrimaryShare = [0.35, 0.55, 0.75]
        var selected = options(stage: .texture)
        selected.textureStages = [.emulsionMTF]
        selected.flareScale = 0
        selected.format = FilmFormat(name: "test", frameHeightMM: 0.25)

        let invocation = FilmEngineInvocation(
            stock: stock, options: selected, width: width, height: height)
        XCTAssertNotEqual(invocation.featureMask & FilmEngineFeature.mtfLuma, 0,
                          "the luminance arm is not active, so this test is vacuous")
        XCTAssertEqual(invocation.featureMask & FilmEngineFeature.flare, 0,
                       "flare would store four planes before the texture branch")

        for realtime in [false, true] {
            XCTAssertTrue(gpu.processLinearFloat(
                input: source, output: output, width: width, height: height,
                stock: stock, options: selected, realtime: realtime),
                realtime ? "realtime Texture Only failed" : "reference Texture Only failed")
        }
    }
}
#endif
