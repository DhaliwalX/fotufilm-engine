import XCTest
@testable import FotufilmHost
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// The writers' fills read the SDR shoulder and transfer from a table; they have to give the
/// codes the curve itself gives.
final class HostVideoPixelsTests: XCTestCase {
    private let knee: Float = 0.9

    private func light(_ count: Int) -> [Float] {
        var state: UInt32 = 12345
        return (0..<count).map { index in
            state = state &* 1_664_525 &+ 1_013_904_223
            let unit = Float(state >> 8) / Float(1 << 24)
            // Mostly the picture's range, some deep shadow, some highlight, the odd negative.
            switch index % 7 {
            case 0: return unit * 0.004
            case 1: return unit * 3
            case 2: return unit - 0.1
            default: return unit
            }
        }
    }

    func testSignalTableFollowsTheCurve() {
        let signal = SDRSignal.table(knee: knee)
        for value in light(200_000) + [0, 1e-7, 0.0031308, 0.9, 1, 1.9999, 2, 5, -1, .nan] {
            let exact = ColorScience.linearToSrgb(ColorScience.displayShoulder(value, knee: knee))
            XCTAssertEqual(signal[value], value.isNaN ? 0 : exact, accuracy: 2e-6, "\(value)")
        }
    }

    func testFillsGiveTheCurvesCodes() {
        let (width, height) = (64, 32)
        let pixels = light(width * height * 4)
        let converter = FilmDisplayP3SDRConversion(shoulderKnee: knee)
        var encoded = [Float](repeating: 0, count: pixels.count)
        pixels.withUnsafeBufferPointer { source in
            encoded.withUnsafeMutableBufferPointer {
                converter.convert(source, from: 0, count: pixels.count, into: $0)
            }
        }

        var rgb16 = [UInt16](repeating: 0, count: width * height * 4)
        var luma = [UInt16](repeating: 0, count: width * height)
        var chroma = [UInt16](repeating: 0, count: width * height / 2)
        pixels.withUnsafeBytes { bytes in
            rgb16.withUnsafeMutableBytes {
                HostVideoPixels.fillRGB16(bytes, width: width, height: height, knee: knee, hdr: false,
                                          into: $0.baseAddress!, rowBytes: width * 8,
                                          layout: .rgbaLittleEndian)
            }
            luma.withUnsafeMutableBufferPointer { luma in
                chroma.withUnsafeMutableBufferPointer { chroma in
                    HostVideoPixels.fillP010(bytes, width: width, height: height, knee: knee,
                                             hdr: false, luma: luma.baseAddress!, lumaStride: width,
                                             chroma: chroma.baseAddress!, chromaStride: width)
                }
            }
        }

        for index in 0..<(width * height) {
            for c in 0..<3 {
                let expected = Int((min(max(encoded[index * 4 + c], 0), 1) * 65535).rounded())
                XCTAssertLessThanOrEqual(abs(Int(rgb16[index * 4 + c]) - expected), 1)
            }
        }
        func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * width + x) * 4
            return SIMD3(encoded[i], encoded[i + 1], encoded[i + 2])
        }
        func code(_ value: Float) -> Int { Int(min(max(value.rounded(), 0), 1023)) }
        for cy in 0..<(height / 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let expected = SDRVideoTransfer.encode420(
                    topLeft: rgb(x, cy * 2), topRight: rgb(x + 1, cy * 2),
                    bottomLeft: rgb(x, cy * 2 + 1), bottomRight: rgb(x + 1, cy * 2 + 1))
                XCTAssertLessThanOrEqual(abs(Int(luma[cy * 2 * width + x] >> 6)
                                             - code(expected.luma.x * 876 + 64)), 1)
                XCTAssertLessThanOrEqual(abs(Int(chroma[cy * width + x] >> 6)
                                             - code(expected.u * 896 + 512)), 1)
                XCTAssertLessThanOrEqual(abs(Int(chroma[cy * width + x + 1] >> 6)
                                             - code(expected.v * 896 + 512)), 1)
            }
        }
    }
}
