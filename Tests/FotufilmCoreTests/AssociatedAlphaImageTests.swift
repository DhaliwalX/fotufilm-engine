#if canImport(CoreImage)
import CoreGraphics
import CoreImage
import XCTest
@testable import FotufilmImaging

final class AssociatedAlphaImageTests: XCTestCase {
    func testColorSamplesSurviveZeroAlpha() throws {
        let source: [Float] = [4, 2, 1, 0]
        let data = source.withUnsafeBytes { Data($0) }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let colorSpace = try XCTUnwrap(
            CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.last.rawValue
            | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        let image = try XCTUnwrap(CGImage(
            width: 1, height: 1, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: 16, space: colorSpace, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))

        let color = try XCTUnwrap(AssociatedAlphaImage.colorSamples(from: image))
        XCTAssertEqual(color.alphaInfo, .noneSkipLast)

        let ci = CIImage(cgImage: color)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        var rgba = [Float](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes {
            context.render(ci, toBitmap: $0.baseAddress!, rowBytes: 16,
                           bounds: ci.extent, format: .RGBAf,
                           colorSpace: colorSpace)
        }
        XCTAssertEqual(rgba[0], 4, accuracy: 0.000_001)
        XCTAssertEqual(rgba[1], 2, accuracy: 0.000_001)
        XCTAssertEqual(rgba[2], 1, accuracy: 0.000_001)
        XCTAssertEqual(rgba[3], 1, accuracy: 0.000_001)
    }

    func testImagesWithoutASeparateAlphaSampleAreRejected() throws {
        let source: [Float] = [1, 1, 1, 0]
        let data = source.withUnsafeBytes { Data($0) }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let colorSpace = try XCTUnwrap(
            CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let image = try XCTUnwrap(CGImage(
            width: 1, height: 1, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: 16, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))

        XCTAssertNil(AssociatedAlphaImage.colorSamples(from: image))
    }
}
#endif
