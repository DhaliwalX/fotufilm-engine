#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal
import Metal

final class FilmGrainMetalTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide engine required")
    }

    /// The Metal road lays the CPU's film grain: every laying of the tiles, pixel for pixel.
    func testMetalLaysTheCPUsFilmGrain() throws {
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared, "Halide Metal unavailable")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let side = 192
        var image = ImageBuffer(width: side, height: side)
        for c in 0..<3 {
            for i in 0..<image.pixelCount { image.planes[c][i] = 0.01 * pow(2, Float(i % side) / 24) }
        }
        let bytes = side * side * 16
        let input = try XCTUnwrap(device.makeBuffer(length: bytes, options: .storageModeShared))
        let output = try XCTUnwrap(device.makeBuffer(length: bytes, options: .storageModeShared))
        let interleaved = input.contents().assumingMemoryBound(to: Float.self)
        for i in 0..<image.pixelCount {
            for c in 0..<3 { interleaved[i * 4 + c] = image.planes[c][i] }
            interleaved[i * 4 + 3] = 1
        }
        for stock in [TestStocks.negative, TestStocks.monochrome] {
            var flat = stock
            flat.flare = 0
            var options = FotufilmEngine.Options()
            options.grainModel = .film
            options.halationScale = 0
            // The layered transport runs its own road; the film grain kernel is the Halide graph's.
            options.halationModel = .legacy
            options.couplerScale = 0
            options.seed = 0x1234_5678
            options.format = FilmFormat(name: "film grain metal", frameHeightMM: 0.4)
            var plain = options
            plain.grainScale = 0
            XCTAssertNil(options.transportConstruction(for: flat))
            let cpu = FotufilmEngine(stock: flat, options: options).process(linearRGB: image)
            let clean = FotufilmEngine(stock: flat, options: plain).process(linearRGB: image)
            XCTAssertTrue(gpu.processLinearFloat(input: input, output: output, width: side,
                                                 height: side, stock: flat, options: options,
                                                 realtime: false), "\(stock.name): Metal failed")
            let metal = output.contents().assumingMemoryBound(to: Float.self)
            for c in 0..<3 {
                var cc = 0.0, mm = 0.0, cm = 0.0, worst: Float = 0
                for i in 0..<image.pixelCount {
                    let a = Double(cpu.planes[c][i] - clean.planes[c][i])
                    let b = Double(metal[i * 4 + c] - clean.planes[c][i])
                    cc += a * a; mm += b * b; cm += a * b
                    worst = max(worst, abs(cpu.planes[c][i] - metal[i * 4 + c]))
                }
                let correlation = cm / max((cc * mm).squareRoot(), 1e-30)
                XCTAssertGreaterThan(cc, 0, "\(stock.name) channel \(c) lays grain")
                XCTAssertGreaterThan(correlation, 0.999, "\(stock.name) channel \(c)")
                XCTAssertLessThan(worst, 1e-3, "\(stock.name) channel \(c)")
            }
        }
    }
}
#endif
