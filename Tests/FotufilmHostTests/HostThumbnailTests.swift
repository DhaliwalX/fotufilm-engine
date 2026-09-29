import XCTest
#if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import ImageIO
import UniformTypeIdentifiers
@testable import FotufilmHost

/// Photographs opened together wait in the strip as thumbnails; only the one chosen is decoded.
final class HostThumbnailTests: XCTestCase {
    func testThumbnailIsUprightAndBounded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-thumbnail-\(UUID().uuidString).jpg")
        // A 600 × 300 ramp, dark to light across, that the file says to turn a quarter clockwise.
        try writeRamp(to: url, width: 600, height: 300, orientation: 6)
        defer { try? FileManager.default.removeItem(at: url) }

        let thumbnail = try ImageIOThumbnailer().thumbnail(url, maxEdge: 256)
        XCTAssertEqual([thumbnail.width, thumbnail.height], [128, 256])
        XCTAssertEqual(thumbnail.pixels.count, 128 * 256 * 4)
        // Upright, the ramp runs dark to light down the picture.
        let top = thumbnail.pixels[(2 * 128 + 64) * 4]
        let bottom = thumbnail.pixels[(253 * 128 + 64) * 4]
        XCTAssertLessThan(top, 40)
        XCTAssertGreaterThan(bottom, 215)
        XCTAssertEqual(thumbnail.pixels[3], 255)
    }

    func testUnreadableFileThrows() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-thumbnail-\(UUID().uuidString).jpg")
        FileManager.default.createFile(atPath: url.path, contents: Data("not a photo".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ImageIOThumbnailer().thumbnail(url, maxEdge: 256))
    }

    private func writeRamp(to url: URL, width: Int, height: Int, orientation: Int) throws {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = UInt8(x * 255 / (width - 1))
                let i = (y * width + x) * 4
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
                                   [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
#endif
