import XCTest
import FotufilmCore
import FotufilmImaging

/// The kernels prepare a scan as the Swift references read it.
final class NegativeScanPreparationTests: XCTestCase {
    private let width = 37, height = 23

    private func scan() -> [Float] {
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { for c in 0..<3 {
            let t = Float(x) / Float(width - 1), u = Float(y) / Float(height - 1)
            rgba[(y * width + x) * 4 + c] = [0.8, 0.45, 0.2][c] * pow(10, -(0.1 + 1.2 * t + 0.2 * u))
        } } }
        // Film that passes no light, and a sample that is not a number.
        rgba[0] = 0
        rgba[(width + 1) * 4 + 1] = .nan
        rgba[(width + 2) * 4 + 3] = 0.25
        return rgba
    }

    private func light() -> NegativeLightFrame {
        let w = 5, h = 3
        return NegativeLightFrame(width: w, height: h, gains: (0..<(w * h * 3)).map {
            0.7 + 0.05 * Float($0 % 11)
        })
    }

    private func prepare(_ rgba: [Float], light: NegativeLightFrame?,
                         plain: PlainNegativeScan?) throws -> [Float] {
        guard FotufilmEngine.isHalideBackendAvailable else { throw XCTSkip("needs Halide") }
        var out = rgba
        try NegativeScanPreparation.prepare(&out, width: width, height: height,
                                            light: light.map { ($0.width, $0.height, $0.gains) },
                                            plain: plain)
        return out
    }

    private func evened(_ rgba: [Float], _ light: NegativeLightFrame) -> [Float] {
        var out = rgba
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            let srgb = AutomaticNegativeScan.rec2020ToSRGB(SIMD3(rgba[i], rgba[i + 1], rgba[i + 2]))
            let rgb = ColorScience.linearSRGBToRec2020(srgb / light.gain(
                x: (Float(x) + 0.5) / Float(width), y: (Float(y) + 0.5) / Float(height)))
            for c in 0..<3 { out[i + c] = rgb[c] }
        } }
        return out
    }

    private func assertClose(_ a: [Float], _ b: [Float], _ tolerance: Float,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for i in a.indices where !(a[i].isNaN && b[i].isNaN) {
            XCTAssertEqual(a[i], b[i], accuracy: tolerance * max(1, abs(b[i])),
                           "sample \(i)", file: file, line: line)
        }
    }

    func testTheLightDividesOutAsNegativeLightFrameGain() throws {
        let rgba = scan(), light = light()
        assertClose(try prepare(rgba, light: light, plain: nil), evened(rgba, light), 1e-5)
    }

    func testThePlainReadingIsPlainNegativeScan() throws {
        let rgba = scan()
        let plain = PlainNegativeScan(border: SIMD3(0.8, 0.45, 0.2), denseEnd: SIMD3(1.3, 1.2, 1.1))
        var expected = rgba
        for i in 0..<(width * height) {
            let light = plain.light(of: SIMD3(rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]))
            for c in 0..<3 { expected[i * 4 + c] = light[c] }
        }
        let prepared = try prepare(rgba, light: nil, plain: plain)
        assertClose(prepared, expected, 1e-4)
        // Film passing no light in one channel, or none to read, is black; alpha is kept.
        XCTAssertEqual(Array(prepared[0..<3]), [0, 0, 0])
        XCTAssertEqual(Array(prepared[((width + 1) * 4)..<((width + 1) * 4 + 3)]), [0, 0, 0])
        XCTAssertEqual(prepared[(width + 2) * 4 + 3], 0.25)
    }

    func testEvenedThenRead() throws {
        let rgba = scan(), light = light()
        let plain = PlainNegativeScan(border: SIMD3(0.8, 0.45, 0.2), denseEnd: nil)
        var expected = evened(rgba, light)
        for i in 0..<(width * height) {
            let read = plain.light(of: SIMD3(expected[i * 4], expected[i * 4 + 1], expected[i * 4 + 2]))
            for c in 0..<3 { expected[i * 4 + c] = read[c] }
        }
        assertClose(try prepare(rgba, light: light, plain: plain), expected, 1e-4)
    }
}
