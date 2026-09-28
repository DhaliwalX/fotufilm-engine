#if os(Linux)
import XCTest
import FotufilmCore
@testable import FotufilmHost

/// Linux's GPU developer against the portable CPU one, on a machine with CUDA (or Vulkan, with
/// FOTUFILM_GPU_DEVICE=vulkan). Skipped where no device answers.
final class HalideGPUDeveloperTests: XCTestCase {
    private func develop(_ developer: HostDeveloper, _ scene: [Float], width: Int, height: Int,
                         stock: FilmStock, options: FotufilmEngine.Options) throws -> [Float] {
        var out = [Float]()
        try developer.develop(scene, width: width, height: height, stock: stock, noFilm: false,
                              options: options, pace: HostDevelopPace(), encode: false, knee: nil,
                              shouldContinue: { true }) { rows, range, encoded in
            XCTAssertEqual(range, 0..<height)
            XCTAssertFalse(encoded)
            out = Array(rows)
        }
        return out
    }

    func testDevelopsAsTheCPUDoes() throws {
        guard let gpu = HalideGPUDeveloper() else { throw XCTSkip("no CUDA or Vulkan device") }
        guard let stock = FilmStock.named("portra400") else { throw XCTSkip("no Portra 400") }
        let (width, height) = (96, 64)
        var scene = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                // Exposure ramps across, hue steps down.
                let level = Float(pow(2.0, Double(x) / Double(width) * 8 - 6))
                scene[i] = level * (y % 3 == 0 ? 1.4 : 0.8)
                scene[i + 1] = level
                scene[i + 2] = level * (y % 3 == 2 ? 1.5 : 0.7)
            }
        }
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        let developed = try develop(gpu, scene, width: width, height: height, stock: stock,
                                    options: options)
        let reference = try develop(HalideCPUDeveloper(), scene, width: width, height: height,
                                    stock: stock, options: options)
        XCTAssertEqual(developed.count, reference.count)
        var worst: Float = 0
        for i in developed.indices where i % 4 != 3 {
            worst = max(worst, abs(developed[i] - max(reference[i], 0)))
        }
        XCTAssertLessThan(worst, 1e-3, "GPU and CPU disagree by \(worst)")
        XCTAssertEqual(gpu.kind, ProcessInfo.processInfo.environment["FOTUFILM_GPU_DEVICE"] == "vulkan"
                       ? "vulkan" : "cuda")
        XCTAssertNotNil(HostPlatform.current.developer)
    }
}
#endif
