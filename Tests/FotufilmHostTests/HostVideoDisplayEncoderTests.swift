#if canImport(Metal)
import XCTest
import Metal
import FotufilmCore
@testable import FotufilmHost

final class HostVideoDisplayEncoderTests: XCTestCase {
    func testGPUReconstructsEightBitCodesAndMatchesCPU() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let encoder = try XCTUnwrap(MetalVideoDisplayEncoder(device: device))
        var scene: [Float] = []
        var expected: [UInt8] = []
        // Exhaust each channel's codes against several different companion colors.
        for c in 0..<3 {
            for code in 0..<256 {
                for companion in stride(from: 0, through: 255, by: 51) {
                    var codes = SIMD3<Float>(Float(companion), Float(255 - companion), Float(companion))
                    codes[c] = Float(code)
                    let linear = SIMD3(ColorScience.srgbToLinear(codes.x / 255),
                                       ColorScience.srgbToLinear(codes.y / 255),
                                       ColorScience.srgbToLinear(codes.z / 255))
                    let rgb = ColorScience.linearDisplayP3ToRec2020(linear)
                    scene += [rgb.x, rgb.y, rgb.z, 0.3]
                    expected += [UInt8(codes.x), UInt8(codes.y), UInt8(codes.z), 255]
                }
            }
        }
        let actual = try convert(scene, encoder: encoder, device: device)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual, cpu(scene))
    }

    func testGPUHandlesOutOfRangeLightAndQuantizationBoundaries() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let encoder = try XCTUnwrap(MetalVideoDisplayEncoder(device: device))
        var scene: [Float] = []
        let values: [Float] = [-1, 0, 0.0001, 0.18, 1, 4, .infinity, -.infinity, .nan]
        for r in values { for g in values { for b in values { scene += [r, g, b, 1] } } }
        for code in 0..<255 {
            let threshold = ColorScience.srgbToLinear((Float(code) + 0.5) / 255)
            for value in [threshold.nextDown, threshold, threshold.nextUp] {
                scene += [value, value, value, 1]
            }
        }
        let actual = try convert(scene, encoder: encoder, device: device)
        let reference = cpu(scene)
        let maximum = zip(actual, reference).map { abs(Int($0) - Int($1)) }.max() ?? 0
        // A final floating-point bit at a rounding boundary may choose the adjacent code.
        XCTAssertLessThanOrEqual(maximum, 1)
    }

    private func convert(_ scene: [Float], encoder: MetalVideoDisplayEncoder,
                         device: MTLDevice) throws -> [UInt8] {
        let staging = try XCTUnwrap(device.makeBuffer(length: scene.count * 4, options: .storageModeShared))
        let output = try XCTUnwrap(device.makeBuffer(length: scene.count, options: .storageModeShared))
        XCTAssertTrue(scene.withUnsafeBufferPointer {
            encoder.encode($0, staging: staging, output: output, pixels: scene.count / 4)
        })
        return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: UInt8.self),
                                         count: scene.count))
    }

    private func cpu(_ scene: [Float]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: scene.count)
        scene.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBytes { target in
                HostVideoPixels.encodeDisplay8(source.baseAddress!, width: scene.count / 4,
                                               height: 1, into: target.baseAddress!)
            }
        }
        return output
    }
}
#endif
