#if canImport(CoreImage)
import XCTest
import CoreImage
import CoreGraphics
@testable import FotufilmImaging

final class ResamplingTests: XCTestCase {
    static let chartEdge = 2400

    static func chart() -> CIImage {
        let w = chartEdge, h = chartEdge * 3 / 4
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let pitches = [2, 3, 4, 5, 6, 8, 12, 16]
        for y in 0..<h {
            for x in 0..<w {
                var v = 0.5
                let pitch = pitches[min(7, x * 8 / w)]
                if y < h / 3 {
                    v = (y % pitch) < pitch / 2 ? 0.85 : 0.15
                } else if y < h * 2 / 3 {
                    v = ((y % pitch) < pitch / 2) != ((x % pitch) < pitch / 2)
                        ? 0.85 : 0.15
                } else {
                    let dx = Double(x) - Double(w) / 2
                    let dy = Double(y) - Double(h) * 5 / 6
                    v = 0.5 + 0.35 * cos((dx * dx + dy * dy) / 900)
                }
                let i = (y * w + x) * 4
                let b = UInt8(max(0, min(255, (v * 255).rounded())))
                pixels[i] = b; pixels[i + 1] = b; pixels[i + 2] = b
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: context.makeImage()!)
    }

    let ciContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false,
    ])

    func measure(_ image: CIImage) -> (aliasing: Double, detail: Double) {
        var output = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX, y: -image.extent.minY))
        output = output.cropped(to: CGRect(
            x: 0, y: 0, width: output.extent.width.rounded(.down),
            height: output.extent.height.rounded(.down)))
        let w = Int(output.extent.width), h = Int(output.extent.height)
        var pixels = [Float](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { raw in
            ciContext.render(
                output, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                bounds: output.extent, format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        func deviation(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Double {
            var sum = 0.0, square = 0.0, count = 0.0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let v = Double(pixels[(y * w + x) * 4 + 1])
                    sum += v; square += v * v; count += 1
                }
            }
            let mean = sum / count
            return (square / count - mean * mean).squareRoot()
        }
        return (deviation(0, Int(Double(w) * 0.24),
                          Int(Double(h) * 0.36), Int(Double(h) * 0.63)),
                deviation(Int(Double(w) * 0.90), w,
                          Int(Double(h) * 0.02), Int(Double(h) * 0.30)))
    }

    func testPrefilterRemovesAliasingLanczosLeavesBehind() {
        let chart = Self.chart()
        for longEdge in [2200, 2000, 1800, 1600] {
            let plain = measure(ImageResampling.lanczosOnly(chart, longEdge: longEdge))
            let filtered = measure(ImageResampling.downsample(chart, longEdge: longEdge))
            XCTAssertLessThan(
                filtered.aliasing, plain.aliasing * 0.5,
                "at \(longEdge) px the prefilter barely helped: "
                + "\(plain.aliasing) -> \(filtered.aliasing)")
            XCTAssertGreaterThan(
                filtered.detail, plain.detail * 0.85,
                "at \(longEdge) px the prefilter cost too much detail: "
                + "\(plain.detail) -> \(filtered.detail)")
        }
    }

    func testPrefilterDoesNothingWhereLanczosIsAlreadyAdequate() {
        let chart = Self.chart()
        for longEdge in [1200, 1000, 800] {
            let plain = measure(ImageResampling.lanczosOnly(chart, longEdge: longEdge))
            let filtered = measure(ImageResampling.downsample(chart, longEdge: longEdge))
            XCTAssertEqual(filtered.detail, plain.detail, accuracy: 0.001,
                           "at \(longEdge) px the prefilter softened for no reason")
            XCTAssertLessThanOrEqual(filtered.aliasing, plain.aliasing + 0.001)
        }
    }

    func testUpscaleAndIdentityAreUntouched() {
        let chart = Self.chart()
        for longEdge in [Self.chartEdge, Self.chartEdge * 2] {
            let output = ImageResampling.downsample(chart, longEdge: longEdge)
            XCTAssertEqual(output.extent, chart.extent)
        }
    }
}
#endif
