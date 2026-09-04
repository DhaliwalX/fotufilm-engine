import XCTest
import CoreImage
@testable import FotufilmCore
@testable import FotufilmImaging

final class LensCorrectionFilterTests: XCTestCase {
    private let size = 257

    override func setUpWithError() throws {
        try XCTSkipUnless(LensCorrectionFilter.isAvailable,
                          "Core Image kernel language unavailable")
    }

    private let context = CIContext(options: [.workingColorSpace: NSNull(),
                                              .outputColorSpace: NSNull()])

    private var halfDiagonal: Float {
        0.5 * sqrt(Float(size * size + size * size))
    }

    private func radiusRamp() -> CIImage {
        var pixels = [Float](repeating: 0, count: size * size * 4)
        let centre = Float(size) / 2
        for y in 0..<size {
            for x in 0..<size {
                let dx = Float(x) + 0.5 - centre, dy = Float(y) + 0.5 - centre
                let r = sqrt(dx * dx + dy * dy) / halfDiagonal
                let i = (y * size + x) * 4
                pixels[i] = r
                pixels[i + 1] = r
                pixels[i + 2] = r
                pixels[i + 3] = 1
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data,
                       bytesPerRow: size * 4 * MemoryLayout<Float>.size,
                       size: CGSize(width: size, height: size),
                       format: .RGBAf, colorSpace: nil)
    }

    private func render(_ image: CIImage) -> [Float] {
        var out = [Float](repeating: 0, count: size * size * 4)
        out.withUnsafeMutableBytes { raw in
            context.render(image, toBitmap: raw.baseAddress!,
                           rowBytes: size * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: size,
                                          height: size),
                           format: .RGBAf, colorSpace: nil)
        }
        return out
    }

    private func pixel(_ pixels: [Float], atRadius r: Float)
        -> (red: Float, green: Float, blue: Float) {
        let centre = Float(size) / 2
        let x = Int(centre + r * halfDiagonal)
        let y = Int(centre)
        let i = (y * size + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }

    private let probes: [Float] = [0.2, 0.3, 0.4, 0.5, 0.6, 0.65]

    // MARK: -

    func testAnIdentityStackHandsBackTheSamePicture() {
        let input = radiusRamp()
        let output = LensCorrectionFilter.apply(input,
                                                stack: LensCorrectionStack([]))
        XCTAssertEqual(render(output), render(input))
    }

    func testDistortionReadsFromWhereTheModelSays() {
        for k1: Float in [-0.08, 0.05] {
            let stack = LensCorrectionStack([
                LensCorrection(distortion: .poly3(k1: k1))
            ])
            let pixels = render(LensCorrectionFilter.apply(radiusRamp(),
                                                           stack: stack))
            for r in probes {
                let expected = stack.sample(atRadius: r).green
                let got = pixel(pixels, atRadius: r).green
                XCTAssertEqual(got, expected, accuracy: 0.004,
                               "k1 = \(k1) at r = \(r)")
            }
        }
    }

    func testDistortionActuallyMovesThePicture() {
        let stack = LensCorrectionStack([
            LensCorrection(distortion: .poly3(k1: -0.08))
        ])
        let corrected = render(LensCorrectionFilter.apply(radiusRamp(),
                                                          stack: stack))
        let untouched = render(radiusRamp())
        var moved = 0
        for r in probes {
            let a = pixel(corrected, atRadius: r).green
            let b = pixel(untouched, atRadius: r).green
            if abs(a - b) > 0.01 { moved += 1 }
        }
        XCTAssertEqual(moved, probes.count,
                       "every probe should have shifted")
    }

    func testChromaSplitsRedAndBlueAndLeavesGreen() {
        let stack = LensCorrectionStack([
            LensCorrection(lateralChroma: .linear(red: 1.02, blue: 0.98))
        ])
        let pixels = render(LensCorrectionFilter.apply(radiusRamp(),
                                                       stack: stack))
        for r in probes {
            let got = pixel(pixels, atRadius: r)
            let want = stack.sample(atRadius: r)
            XCTAssertEqual(got.red, want.red, accuracy: 0.004, "red at \(r)")
            XCTAssertEqual(got.green, r, accuracy: 0.004, "green at \(r)")
            XCTAssertEqual(got.blue, want.blue, accuracy: 0.004, "blue at \(r)")
            XCTAssertGreaterThan(got.red, got.blue,
                                 "the channels should have parted at \(r)")
        }
    }

    func testAFilesOwnWarpMovesThePixelsItSaysItDoes() {
        var correction = LensCorrection()
        correction.planeWarp = LensCorrection.PlaneWarp(
            red: .init(k0: 1, k1: 0.05),
            green: .init(k0: 1, k1: 0.04),
            blue: .init(k0: 1, k1: 0.03))
        let stack = LensCorrectionStack([correction])
        let pixels = render(LensCorrectionFilter.apply(radiusRamp(),
                                                       stack: stack))
        for r in probes {
            let got = pixel(pixels, atRadius: r)
            let want = stack.sample(atRadius: r)
            XCTAssertEqual(got.red, want.red, accuracy: 0.004, "red at \(r)")
            XCTAssertEqual(got.green, want.green, accuracy: 0.004,
                           "green at \(r)")
            XCTAssertEqual(got.blue, want.blue, accuracy: 0.004, "blue at \(r)")
            XCTAssertGreaterThan(got.red, got.blue,
                                 "the planes should have parted at \(r)")
        }
    }

    func testVignettingMultipliesByTheModelledGain() {
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5,
                                          alpha: 1, colorSpace: CGColorSpaceCreateDeviceRGB())!)
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let stack = LensCorrectionStack([
            LensCorrection(vignetting: .radial(k1: -0.4, k2: 0.05, k3: 0))
        ])
        let pixels = render(LensCorrectionFilter.apply(flat, stack: stack))
        for r in probes {
            let expected = 0.5 * stack.sample(atRadius: r).gain
            XCTAssertEqual(pixel(pixels, atRadius: r).green, expected,
                           accuracy: 0.01, "gain at r = \(r)")
        }
        // The centre is untouched, which is what makes it a falloff and not an exposure change.
        let centre = pixel(pixels, atRadius: 0).green
        XCTAssertEqual(centre, 0.5, accuracy: 0.005)
    }

    func testEverythingTogetherMatchesTheModel() {
        let stack = LensCorrectionStack([
            LensCorrection(distortion: .ptLens(a: 0.004, b: -0.021, c: 0.009),
                           vignetting: .radial(k1: -0.3, k2: 0, k3: 0),
                           lateralChroma: .linear(red: 1.01, blue: 0.99)),
            LensAdjustment(distortion: -0.3, vignetting: -0.2).correction,
        ])
        let pixels = render(LensCorrectionFilter.apply(radiusRamp(),
                                                       stack: stack))
        for r in probes {
            let want = stack.sample(atRadius: r)
            let got = pixel(pixels, atRadius: r)
            XCTAssertEqual(got.red, want.red * want.gain, accuracy: 0.006,
                           "red at \(r)")
            XCTAssertEqual(got.green, want.green * want.gain, accuracy: 0.006,
                           "green at \(r)")
            XCTAssertEqual(got.blue, want.blue * want.gain, accuracy: 0.006,
                           "blue at \(r)")
        }
    }

    func testTheFrameKeepsItsExtent() {
        let input = radiusRamp()
        let stack = LensCorrectionStack([
            LensCorrection(distortion: .poly3(k1: -0.08))
        ])
        XCTAssertEqual(LensCorrectionFilter.apply(input, stack: stack).extent,
                       input.extent)
    }

    func testReachingPastTheFrameHoldsTheEdgeRatherThanGoingTransparent() {
        let stack = LensCorrectionStack([
            LensCorrection(distortion: .poly3(k1: -0.12))
        ])
        let pixels = render(LensCorrectionFilter.apply(radiusRamp(),
                                                       stack: stack))
        for index in stride(from: 0, to: size * size * 4, by: 4) {
            XCTAssertEqual(pixels[index + 3], 1,
                           "a pixel went transparent at \(index / 4)")
        }
    }
}
