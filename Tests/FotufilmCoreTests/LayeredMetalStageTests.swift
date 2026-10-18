#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal

final class LayeredMetalStageTests: XCTestCase {
    func testMetalTransportStagesAgreeWithCPUAndPreserveAlpha() throws {
        guard FotufilmEngine.isHalideBackendAvailable,
              HalideMetalFilmRenderer.shared != nil else { throw XCTSkip("Metal/Halide unavailable") }
        let width = 32, height = 24
        var scene = ImageBuffer(width: width, height: height)
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let light: Float = x == width / 2 && y == height / 2 ? 4 : 0.03 + Float(x) / 64
                for c in 0..<3 {
                    scene.planes[c][i] = light * (1 - Float(c) * 0.15)
                    rgba[4 * i + c] = scene.planes[c][i]
                }
                rgba[4 * i + 3] = Float((x + y) % 5) / 4
            }
        }
        var options = TransportFixtures.quiet
        options.layeredTransport = TransportFixtures.stack
        options.localTone = false
        options.paper = .screen
        options.transportBackend = .cpu
        let reference = try FotufilmEngine(stock: TestStocks.negative, options: options)
            .processChecked(linearRGB: scene)
        let actual = try LayeredMetalTransport.process(rgba, width: width, height: height,
            stock: TestStocks.negative, options: options)
        var maximum: Float = 0
        for i in 0..<scene.pixelCount {
            for c in 0..<3 {
                XCTAssertTrue(actual[4 * i + c].isFinite)
                maximum = max(maximum, abs(actual[4 * i + c] - reference.planes[c][i]))
            }
            XCTAssertEqual(actual[4 * i + 3], rgba[4 * i + 3])
        }
        XCTAssertLessThan(maximum, 0.0001)
    }

    /// A staged Layered frame keeps the encoding `carriesOutputTransform` promised — Resolve
    /// fails the frame otherwise — and premultiplies by the scene's alpha, not the records'.
    func testStagedLayeredFrameCarriesTheOutputTransformItPromised() throws {
        guard FotufilmEngine.isHalideBackendAvailable,
              let renderer = HalideMetalFilmRenderer.shared else { throw XCTSkip("Metal/Halide unavailable") }
        let width = 32, height = 24
        var options = TransportFixtures.quiet
        options.layeredTransport = TransportFixtures.stack
        options.localTone = false
        options.paper = .screen
        let stock = TestStocks.negative
        XCTAssertTrue(renderer.carriesOutputTransform(
            stock: stock, options: options, width: width, height: height, realtime: true))
        let staging = try XCTUnwrap(renderer.borrowFrameStaging(pixels: width * height))
        defer { renderer.recycleFrameStaging(staging) }

        func render(premultiplied: Bool) throws -> [Float] {
            for i in 0..<(width * height) {
                let x = i % width, y = i / width
                for c in 0..<3 { staging.scenePixels[4 * i + c] = (0.03 + Float(x) / 64) * (1 - Float(c) * 0.15) }
                staging.scenePixels[4 * i + 3] = Float((x + y) % 5) / 4
            }
            var transform: FilmOutputTransform? = .displayP3()
            transform?.premultiplied = premultiplied
            XCTAssertTrue(renderer.developStaged(
                staging, width: width, height: height, stock: stock, options: options,
                outputTransform: &transform, realtime: true))
            XCTAssertNotNil(transform, "carriesOutputTransform and developStaged disagreed")
            return Array(UnsafeBufferPointer(start: staging.developedPixels, count: width * height * 4))
        }
        let straight = try render(premultiplied: false)
        let premultiplied = try render(premultiplied: true)
        for i in 0..<(width * height) {
            let alpha = straight[4 * i + 3]
            XCTAssertEqual(premultiplied[4 * i + 3], alpha)
            for c in 0..<3 {
                XCTAssertEqual(premultiplied[4 * i + c], straight[4 * i + c] * alpha, accuracy: 1e-6)
            }
        }
    }
}
#endif
