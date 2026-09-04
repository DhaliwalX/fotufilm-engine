#if canImport(CoreImage)
import XCTest
import CoreImage
import CoreGraphics
@testable import FotufilmImaging

final class RasterizeTests: XCTestCase {
    let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    lazy var context = CIContext(options: [
        .workingColorSpace: space,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false,
    ])

    func ramp(width: Int, height: Int) -> CIImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(y * 255 / max(height - 1, 1))
                pixels[i + 1] = UInt8(x * 255 / max(width - 1, 1))
                pixels[i + 2] = UInt8((x + y) % 256)
            }
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: context.makeImage()!)
    }

    func testBandedMatchesSingleCall() throws {
        let width = 97, height = 133
        let image = ramp(width: width, height: height)
        let whole = try XCTUnwrap(ImageResampling.rasterizeLinearFloat(
            image, width: width, height: height, context: context,
            colorSpace: space, pixelsPerBand: width * height))
        for bandRows in [1, 7, 32, 133, 500] {
            let banded = try XCTUnwrap(ImageResampling.rasterizeLinearFloat(
                image, width: width, height: height, context: context,
                colorSpace: space, pixelsPerBand: width * bandRows))
            XCTAssertEqual(banded, whole,
                           "bands of \(bandRows) rows did not reproduce the image")
        }
    }

    func testTopOfTheBitmapIsTopOfThePicture() throws {
        let width = 16, height = 64
        let image = ramp(width: width, height: height)
        let pixels = try XCTUnwrap(ImageResampling.rasterizeLinearFloat(
            image, width: width, height: height, context: context,
            colorSpace: space, pixelsPerBand: width * 5))
        let firstRow = pixels[0]
        let lastRow = pixels[(height - 1) * width * 4]
        XCTAssertLessThan(firstRow, 0.02, "first row should be the dark end")
        XCTAssertGreaterThan(lastRow, 0.9, "last row should be the bright end")
    }

    func testFloatRasterKeepsAdjacentSixteenBitCodesDistinct() throws {
        let width = 256, height = 256
        var source = [UInt16](repeating: 0, count: width * height * 4)
        for value in 0...65_535 {
            let code = UInt16(value)
            let base = value * 4
            source[base] = code
            source[base + 1] = code
            source[base + 2] = code
            source[base + 3] = .max
        }
        let data = source.withUnsafeBytes { Data($0) }
        let image = CIImage(
            bitmapData: data, bytesPerRow: width * 8,
            size: CGSize(width: width, height: height),
            format: .RGBA16, colorSpace: space)
        let pixels = try XCTUnwrap(ImageResampling.rasterizeLinearFloat(
            image, width: width, height: height, context: context,
            colorSpace: space, pixelsPerBand: width * 17))
        var values = Set<Float>()
        for pixel in 0..<(width * height) { values.insert(pixels[pixel * 4]) }
        XCTAssertEqual(values.count, 65_536,
                       "float rasterization collapsed distinct 16-bit scene codes")
    }
}
#endif
