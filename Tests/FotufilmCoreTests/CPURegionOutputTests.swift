import XCTest
import FotufilmHalide
@testable import FotufilmCore

final class CPURegionOutputTests: XCTestCase {
    private struct Rect { let x: Int, y: Int, width: Int, height: Int }

    func testCompactRegionsMatchWholeFrameWithGlobalMeasurementsAndSeed() throws {
        try XCTSkipUnless(HalideBackend.isAvailable, "Halide required")
        let width = 193, height = 137, count = width * height
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width { for c in 0..<3 {
            let light: Float = (x / 23 + y / 17).isMultiple(of: 2) ? 2.4 : 0.025
            image.planes[c][y * width + x] = light * (0.8 + Float(c) * 0.2) + Float(x) / Float(width) * 0.12
        } } }
        var options = FotufilmEngine.Options()
        options.highlights = -0.3; options.shadows = 0.2; options.localTone = true
        options.seed = 9183
        let rectangles = [Rect(x: 0, y: 0, width: 37, height: 29),
                          Rect(x: 71, y: 49, width: 43, height: 31),
                          Rect(x: width - 27, y: height - 23, width: 27, height: 23),
                          Rect(x: 101, y: 63, width: 1, height: 1)]
        for stock in [TestStocks.negative, TestStocks.reversal, TestStocks.monochrome] {
            let whole = try XCTUnwrap(HalideBackend.process(image: image, stock: stock, options: options))
            var invocation = try FilmEngineInvocation(validating: stock, options: options, width: width, height: height)
            let flat = image.planes.flatMap { $0 }
            flat.withUnsafeBufferPointer { input in
                let r = input.baseAddress!, g = r + count, b = g + count
                if invocation.sceneMeteringActive { invocation.measureToneBase(planarR: r, g: g, b: b, width: width, height: height) }
                if invocation.featureMask & FilmEngineFeature.flare != 0 {
                    var sums = [SIMD3<Double>](repeating: .zero, count: height)
                    sums.withUnsafeMutableBufferPointer {
                        invocation.flareExposureRowSums(planarR: r, g: g, b: b, width: width, rows: height, into: $0)
                    }
                    let mean = sums.reduce(.zero, +) / Double(count)
                    invocation.flareMean = SIMD3(Float(mean.x), Float(mean.y), Float(mean.z))
                }
            }
            let apron = max(1, invocation.spatialSupport)
            for rectangle in rectangles {
                let x = max(0, rectangle.x - apron), y = max(0, rectangle.y - apron)
                let right = min(width, rectangle.x + rectangle.width + apron)
                let bottom = min(height, rectangle.y + rectangle.height + apron)
                let tw = right - x, th = bottom - y, tn = tw * th
                var tile = [Float](repeating: 0, count: tn * 3)
                for c in 0..<3 { for row in 0..<th { for column in 0..<tw {
                    tile[c * tn + row * tw + column] = image.planes[c][(y + row) * width + x + column]
                } } }
                let outputCount = rectangle.width * rectangle.height, stride = outputCount + 2
                var output = [Float](repeating: -123, count: stride * 3)
                let mask = invocation.featureMask, seed = invocation.seed
                let dimension = Int32(invocation.spectral.exposure.dimension)
                let status = tile.withUnsafeBufferPointer { input in output.withUnsafeMutableBufferPointer { result in
                    invocation.configuration.withUnsafeBufferPointer { configuration in
                        invocation.withSpectralPointers { exposure, film, paper in
                            fotufilm_halide_process_region(input.baseAddress!, input.baseAddress! + tn, input.baseAddress! + tn * 2,
                                result.baseAddress! + 1, result.baseAddress! + stride + 1, result.baseAddress! + stride * 2 + 1,
                                Int32(tw), Int32(th), Int32(width), Int32(height), Int32(x), Int32(y),
                                Int32(rectangle.x - x), Int32(rectangle.y - y), Int32(rectangle.width), Int32(rectangle.height),
                                configuration.baseAddress!, exposure, film, paper, dimension, mask, seed, nil)
                        }
                    }
                } }
                XCTAssertEqual(status, 0)
                var worst: Float = 0
                for c in 0..<3 {
                    XCTAssertEqual(output[c * stride], -123); XCTAssertEqual(output[(c + 1) * stride - 1], -123)
                    for row in 0..<rectangle.height { for column in 0..<rectangle.width {
                        let actual = output[c * stride + 1 + row * rectangle.width + column]
                        XCTAssertTrue(actual.isFinite)
                        worst = max(worst, abs(actual - whole.planes[c][(rectangle.y + row) * width + rectangle.x + column]))
                    } }
                }
                XCTAssertLessThan(worst, 1.0 / 4096, "\(stock.name) compact region \(rectangle) differs from whole frame")
            }
        }
    }
}
