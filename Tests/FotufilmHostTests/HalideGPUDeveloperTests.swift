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

    /// A scene with detail at every scale the film reaches, so a tile with too little context
    /// around it would show.
    private func detailed(width: Int, height: Int) -> [Float] {
        var scene = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let spot: Float = (x / 37 + y / 29) % 5 == 0 ? 6 : 0.12
                scene[i] = spot * (0.6 + 0.4 * Float(x) / Float(width))
                scene[i + 1] = spot * 0.8
                scene[i + 2] = spot * (0.6 + 0.4 * Float(y) / Float(height))
            }
        }
        return scene
    }

    private func worst(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    /// A frame developed in tiles, as one the device cannot hold is, comes out as it does whole.
    func testTilesDevelopAsTheWholeFrame() throws {
        guard let gpu = HalideGPUDeveloper() else { throw XCTSkip("no CUDA or Vulkan device") }
        guard let stock = FilmStock.named("cinestill800t") else { throw XCTSkip("no CineStill") }
        let (width, height) = (1100, 800)
        let scene = detailed(width: width, height: height)
        let options = FotufilmEngine.Options()
        let whole = try develop(gpu, scene, width: width, height: height, stock: stock,
                                options: options)
        setenv("FOTUFILM_GPU_TILE_PIXELS", "250000", 1)
        defer { unsetenv("FOTUFILM_GPU_TILE_PIXELS") }
        let tiled = try develop(gpu, scene, width: width, height: height, stock: stock,
                                options: options)
        XCTAssertLessThan(worst(whole, tiled), 1e-5)
    }

    /// Layered Transport develops on the device, its transport on the CPU kernels, and differs
    /// from the legacy halation it replaces; in tiles it comes out as it does whole.
    func testDevelopsLayeredTransport() throws {
        guard let gpu = HalideGPUDeveloper() else { throw XCTSkip("no CUDA or Vulkan device") }
        guard let stock = FilmStock.named("cinestill800t") else { throw XCTSkip("no CineStill") }
        let (width, height) = (640, 480)
        let scene = detailed(width: width, height: height)
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        let legacy = try develop(gpu, scene, width: width, height: height, stock: stock,
                                 options: options)
        options.halationModel = .layered
        let layered = try develop(gpu, scene, width: width, height: height, stock: stock,
                                  options: options)
        XCTAssertTrue(layered.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(worst(layered, legacy), 1e-3, "Layered develops as Legacy")
        setenv("FOTUFILM_GPU_TILE_PIXELS", "120000", 1)
        defer { unsetenv("FOTUFILM_GPU_TILE_PIXELS") }
        let tiled = try develop(gpu, scene, width: width, height: height, stock: stock,
                                options: options)
        XCTAssertLessThan(worst(layered, tiled), 1e-5)
    }

    /// A scanned negative prints on the device: the film base prints darker than dense film.
    func testPrintsAScannedNegative() throws {
        guard let gpu = HalideGPUDeveloper() else { throw XCTSkip("no CUDA or Vulkan device") }
        guard let stock = FilmStock.named("portra400") else { throw XCTSkip("no Portra 400") }
        let (width, height) = (64, 32)
        let border = SIMD3<Float>(0.5, 0.3, 0.15)
        let calibration = try ApproximateNegativeScan(stock: stock, border: border)
        var printed = [Float]()
        try gpu.printScan(width: width, height: height, stock: stock,
                          options: FotufilmEngine.Options(), calibration: calibration,
                          shouldContinue: { true },
                          readScan: { rows, into in
                              for i in 0..<(rows.count * width) {
                                  // Clear film on the left half, dense film on the right.
                                  let transmitted: Float = i % width < width / 2 ? 1 : 0.05
                                  into[i * 4] = border.x * transmitted
                                  into[i * 4 + 1] = border.y * transmitted
                                  into[i * 4 + 2] = border.z * transmitted
                                  into[i * 4 + 3] = 1
                              }
                          },
                          writeRows: { _, from in printed = Array(from) })
        XCTAssertEqual(printed.count, width * height * 4)
        XCTAssertTrue(printed.allSatisfy(\.isFinite))
        let clear = printed[(height / 2 * width + 2) * 4 + 1]
        let dense = printed[(height / 2 * width + width - 3) * 4 + 1]
        XCTAssertLessThan(clear, dense)
    }
}
#endif
