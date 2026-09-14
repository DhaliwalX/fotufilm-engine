#if canImport(Metal)
import XCTest
import FotufilmCore
@testable import FotufilmMetal

final class ByteColourConversionTests: XCTestCase {
    func testParallelSpansPreserveSerialColourAndAlpha() {
        // Captured from the serial implementation at 50d8513. Exercise every alpha,
        // zero pixels, and both sides of a span boundary, including a partial tail.
        let cases: [(Int, UInt64)] = [
            (0, 0xcbf29ce484222325),
            (1, 0x88fbccca21d7dfe2),
            (65535, 0x1dfa0bed552f1572),
            (65536, 0x37e72efd57506ad1),
            (65537, 0x2457269227d786d5),
            (131075, 0x5306b1fc6ffce132),
        ]
        for (count, p3Digest) in cases {
            var input = [UInt8](repeating: 0, count: count * 4)
            var state: UInt32 = 0xdecaf
            for index in input.indices {
                state = state &* 1664525 &+ 1013904223
                input[index] = UInt8(state >> 24)
            }
            for pixel in 0..<count { input[4 * pixel + 3] = UInt8(pixel & 255) }
            var output = input
            HalideMetalFilmRenderer.convertSRGBToEncodedDisplayP3(input, into: &output)
            XCTAssertEqual(digest(output), p3Digest, "sRGB to P3, \(count) pixels")
            HalideMetalFilmRenderer.convertEncodedDisplayP3ToSRGB(input, into: &output)
            // The output now preserves associated alpha. Compare the parallel conversion
            // with the exact transfer functions, allowing one code for its transfer table.
            for pixel in 0..<count {
                let offset = 4 * pixel
                let alpha = Float(input[offset + 3])
                let p3 = SIMD3<Float>((0..<3).map {
                    ColorScience.srgbToLinear(min(Float(input[offset + $0]) / max(alpha, 1), 1))
                })
                let srgb = ColorScience.linearDisplayP3ToSRGB(p3)
                XCTAssertEqual(output[offset + 3], input[offset + 3])
                for c in 0..<3 {
                    let expected = (min(max(ColorScience.linearToSrgb(srgb[c]), 0), 1) * alpha).rounded()
                    XCTAssertEqual(Float(output[offset + c]), expected, accuracy: 1)
                    XCTAssertLessThanOrEqual(Float(output[offset + c]), alpha)
                }
            }
        }
    }

    private func digest(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}
#endif
