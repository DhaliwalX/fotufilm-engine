#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal

final class ReleasedProfileRenderingTests: XCTestCase {
    func testEveryReleasedProfileMatchesCPUOnMetal() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide engine required")
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared, "Halide Metal unavailable")
        let side = 32
        var scene = ImageBuffer(width: side, height: side)
        var rgba = [Float](repeating: 1, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let pixel = y * side + x
                let exposure = 0.18 * pow(Float(2), Float(x) / Float(side - 1) * 12 - 7)
                let tint: [Float] = y < side / 2 ? [1, 1, 1] : [1, 0.4, 0.15]
                for channel in 0..<3 {
                    scene.planes[channel][pixel] = exposure * tint[channel]
                    rgba[pixel * 4 + channel] = scene.planes[channel][pixel]
                }
            }
        }
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        XCTAssertEqual(FilmStock.presetIDs.count, 40)
        for id in FilmStock.presetIDs {
            let stock = try XCTUnwrap(FilmStock.named(id), id)
            let cpu = FotufilmEngine(stock: stock, options: options).process(linearRGB: scene)
            let metal = try XCTUnwrap(gpu.processLinearFloat(
                rgba, width: side, height: side, stock: stock, options: options), id)
            var worst: Float = 0
            for pixel in 0..<(side * side) {
                for channel in 0..<3 {
                    let reference = cpu.planes[channel][pixel]
                    let actual = metal[pixel * 4 + channel]
                    XCTAssertTrue(reference.isFinite && actual.isFinite, id)
                    worst = max(worst, abs(reference - actual) / max(1, abs(reference)))
                }
            }
            XCTAssertLessThanOrEqual(worst, 2e-4, "\(id): CPU/Metal relative error")
            print("PROFILE \(id): CPU/Metal worst error \(worst)")
        }
    }
}
#endif
