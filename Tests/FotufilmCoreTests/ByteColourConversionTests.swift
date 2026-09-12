#if canImport(Metal)
import XCTest
@testable import FotufilmMetal

final class ByteColourConversionTests: XCTestCase {
    func testParallelSpansPreserveSerialColourAndAlpha() {
        // Captured from the serial implementation at 50d8513. Exercise every alpha,
        // zero pixels, and both sides of a span boundary, including a partial tail.
        let cases: [(Int, UInt64, UInt64)] = [
            (0, 0xcbf29ce484222325, 0xcbf29ce484222325),
            (1, 0x88fbccca21d7dfe2, 0x3d8911041cd5afdf),
            (65535, 0x1dfa0bed552f1572, 0xf1c08309fa6de307),
            (65536, 0x37e72efd57506ad1, 0xde225e2695e3a1d3),
            (65537, 0x2457269227d786d5, 0x60616a3b211efe6a),
            (131075, 0x5306b1fc6ffce132, 0x192b74de9ce41608),
        ]
        for (count, p3Digest, srgbDigest) in cases {
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
            XCTAssertEqual(digest(output), srgbDigest, "P3 to sRGB, \(count) pixels")
        }
    }

    private func digest(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}
#endif
