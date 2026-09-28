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
}
#endif
