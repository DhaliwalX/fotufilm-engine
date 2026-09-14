import XCTest
@testable import FotufilmCore
#if canImport(Metal)
import Metal
import FotufilmMetal
#endif

final class ByteAlphaRenderingTests: XCTestCase {
    private var options: FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        return options
    }

    func testCPUByteAPIsReturnPremultipliedAlpha() throws {
        try XCTSkipUnless(HalideBackend.isAvailable, "Halide required")
        let engine = FotufilmEngine(stock: TestStocks.negative, options: options)
        let renderers: [([UInt8], Int, Int, Int) -> [UInt8]] = [engine.processSRGB8, engine.processDisplayP38]
        for render in renderers {
            let opaque = render(Array(repeating: [192, 192, 192, 255], count: 64).flatMap { $0 }, 8, 8, 4)
            for alpha: UInt8 in [0, 85, 170, 255] {
                let value = UInt8(Int(alpha) * 192 / 255)
                let pixel: [UInt8] = [value, value, value, alpha, 17]
                let output = render(Array(repeating: pixel, count: 64).flatMap { $0 }, 8, 8, 5)
                for i in 0..<64 {
                    XCTAssertEqual(output[5 * i + 3], alpha)
                    XCTAssertEqual(output[5 * i + 4], 17)
                    for c in 0..<3 {
                        XCTAssertLessThanOrEqual(output[5 * i + c], alpha)
                        XCTAssertEqual(Float(output[5 * i + c]), Float(opaque[4 * i + c]) * Float(alpha) / 255,
                            accuracy: alpha == 0 || alpha == 255 ? 0 : 1)
                    }
                }
            }
            let rgb = render(Array(repeating: [192, 192, 192], count: 64).flatMap { $0 }, 8, 8, 3)
            for i in 0..<64 { XCTAssertEqual(Array(rgb[3*i..<3*i+3]), Array(opaque[4*i..<4*i+3])) }
        }
    }

    #if canImport(Metal)
    func testMetalByteAPIsPreserveCoverageAndMatchCPU() throws {
        try XCTSkipUnless(HalideBackend.isAvailable, "Halide required")
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let engine = FotufilmEngine(stock: TestStocks.negative, options: options)
        for alpha: UInt8 in [0, 85, 170, 255] {
            let value = UInt8(Int(alpha) * 192 / 255)
            let input = Array(repeating: [value, value, value, alpha], count: 64).flatMap { $0 }
            let srgb = try XCTUnwrap(gpu.processSRGB8(input, width: 8, height: 8,
                stock: TestStocks.negative, options: options))
            let source = try XCTUnwrap(device.makeBuffer(bytes: input, length: input.count, options: .storageModeShared))
            let destination = try XCTUnwrap(device.makeBuffer(length: input.count, options: .storageModeShared))
            XCTAssertTrue(gpu.processRGBA8(input: source, output: destination, width: 8, height: 8,
                stock: TestStocks.negative, options: options))
            let p3 = Array(UnsafeBufferPointer(start: destination.contents().assumingMemoryBound(to: UInt8.self), count: input.count))
            for (actual, expected) in [(srgb, engine.processSRGB8(input, width: 8, height: 8)),
                                       (p3, engine.processDisplayP38(input, width: 8, height: 8))] {
                for i in 0..<64 {
                    XCTAssertEqual(actual[4*i+3], alpha)
                    for c in 0..<3 {
                        XCTAssertLessThanOrEqual(actual[4*i+c], alpha)
                        XCTAssertEqual(Float(actual[4*i+c]), Float(expected[4*i+c]), accuracy: alpha == 0 ? 0 : 2)
                    }
                }
            }
        }
    }
    #endif
}
