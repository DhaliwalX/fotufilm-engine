#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal
import Metal

final class HybridSplitTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide engine required")
    }

    func patternedSRGB(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let ramp = UInt8((x * 255) / max(width - 1, 1))
                switch (y * 4) / height {
                case 0: pixels[i] = ramp; pixels[i + 1] = 40; pixels[i + 2] = 40
                case 1: pixels[i] = 40; pixels[i + 1] = ramp; pixels[i + 2] = 40
                case 2: pixels[i] = 40; pixels[i + 1] = 40; pixels[i + 2] = ramp
                default: pixels[i] = ramp; pixels[i + 1] = ramp; pixels[i + 2] = ramp
                }
                pixels[i + 3] = 255
            }
        }
        return pixels
    }

    struct Difference {
        var mean = 0.0
        var max = 0
    }

    func compare(_ a: MTLBuffer, _ b: MTLBuffer, count: Int) -> Difference {
        let pa = a.contents().assumingMemoryBound(to: UInt8.self)
        let pb = b.contents().assumingMemoryBound(to: UInt8.self)
        var difference = Difference()
        for i in 0..<count {
            let d = abs(Int(pa[i]) - Int(pb[i]))
            difference.mean += Double(d)
            difference.max = Swift.max(difference.max, d)
        }
        difference.mean /= Double(count)
        return difference
    }

    func runSplit(stock: FilmStock, options: FotufilmEngine.Options,
                  grainTolerance: Bool, label: String) throws {
        guard let gpu = HalideMetalFilmRenderer.shared else {
            throw XCTSkip("Halide Metal unavailable")
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let width = 320, height = 192
        let input = patternedSRGB(width: width, height: height)
        let byteCount = width * height * 4
        let inputBuffer = try XCTUnwrap(device.makeBuffer(length: byteCount, options: .storageModeShared))
        input.withUnsafeBytes { inputBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: byteCount) }
        let fused = try XCTUnwrap(device.makeBuffer(length: byteCount, options: .storageModeShared))
        let split = try XCTUnwrap(device.makeBuffer(length: byteCount, options: .storageModeShared))
        let density = try XCTUnwrap(device.makeBuffer(length: byteCount * 2, options: .storageModeShared))

        XCTAssertTrue(gpu.processRGBA8(
            input: inputBuffer, output: fused, width: width, height: height,
            stock: stock, options: options, frameIndex: 3), "\(label): fused failed")
        XCTAssertTrue(gpu.processRGBA8Head(
            input: inputBuffer, density: density, width: width, height: height,
            stock: stock, options: options, frameIndex: 3), "\(label): head failed")
        XCTAssertTrue(gpu.processRGBA8Tail(
            density: density, output: split, width: width, height: height,
            stock: stock, options: options, frameIndex: 3), "\(label): tail failed")

        let difference = compare(fused, split, count: byteCount)
        XCTAssertLessThan(difference.mean, 0.35, "\(label): mean drift")
        XCTAssertLessThanOrEqual(difference.max, grainTolerance ? 48 : 4,
                                 "\(label): worst pixel")

        let split8 = split.contents().assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 3, to: byteCount, by: 4 * 977) {
            XCTAssertEqual(split8[i], 255, "\(label): alpha at byte \(i)")
        }
    }

    func testSplitMatchesFusedGrainless() throws {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        for stock in TestStocks.all {
            try runSplit(stock: stock, options: options, grainTolerance: false,
                         label: "\(stock.name) grainless")
        }
    }

    func testSplitMatchesFusedWithGrain() throws {
        let options = FotufilmEngine.Options()
        for stock in TestStocks.all {
            try runSplit(stock: stock, options: options, grainTolerance: true,
                         label: "\(stock.name) grain")
        }
    }
}
#endif
