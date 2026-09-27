import XCTest
import CFotufilmHost
@testable import FotufilmHost
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

final class CInterfaceTests: XCTestCase {
    private static let request = """
    {"handle": 1, "previewQuality": "draft", "maxEdge": 64,
     "edit": {"stock": "gold200", "params": {"ev": 0.5, "temperature": 5200}},
     "profileRequest": {"controls": {"push": 0}, "format": "35mm"}}
    """

    private func makeEngine() throws -> OpaquePointer {
        var error: UnsafeMutablePointer<CChar>?
        guard let engine = fotufilm_engine_create(&error) else {
            defer { fotufilm_free(error) }
            throw XCTSkip(error.map { String(cString: $0) } ?? "no engine")
        }
        return engine
    }

    func testDescribeListsTheFilms() throws {
        let engine = try makeEngine()
        defer { fotufilm_engine_destroy(engine) }
        XCTAssertEqual(fotufilm_api_version(), FOTUFILM_API_VERSION)
        let text = try XCTUnwrap(fotufilm_engine_describe(engine))
        defer { fotufilm_free(text) }
        let body = try JSONSerialization.jsonObject(with: Data(String(cString: text).utf8))
            as? [String: Any]
        let stocks = try XCTUnwrap(body?["stocks"] as? [[String: Any]])
        XCTAssertTrue(stocks.contains { $0["id"] as? String == "gold200" })
    }

    func testRenderSizeFollowsTheLongEdge() {
        let image = HostImage(rgba: [Float](repeating: 0.18, count: 300 * 200 * 4),
                              width: 300, height: 200, contentHeadroom: 1)
        XCTAssertEqual(image.renderSize(maxEdge: 150).width, 150)
        XCTAssertEqual(image.renderSize(maxEdge: 150).height, 100)
        XCTAssertEqual(image.renderSize(maxEdge: 0).width, 300)
        XCTAssertEqual(image.renderSize(maxEdge: 900).height, 200)
    }

    func testReductionKeepsTheMeanLight() {
        var rgba = [Float](repeating: 1, count: 7 * 5 * 4)
        for i in 0..<(7 * 5) { rgba[i * 4] = Float(i % 7) / 6 }
        let reduced = AreaResample.reduce(rgba, width: 7, height: 5, to: 3, 2)
        let mean = stride(from: 0, to: reduced.count, by: 4).map { reduced[$0] }.reduce(0, +) / 6
        XCTAssertEqual(mean, 0.5, accuracy: 1e-5)
    }

    #if canImport(ImageIO)
    /// A grey ramp PNG, opened and developed through nothing but the C functions.
    func testOpenAndRenderThroughTheCInterface() throws {
        let engine = try makeEngine()
        defer { fotufilm_engine_destroy(engine) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-host-\(UUID().uuidString).png")
        try writeRamp(to: url, width: 160, height: 120)
        defer { try? FileManager.default.removeItem(at: url) }

        var error: UnsafeMutablePointer<CChar>?
        guard let image = fotufilm_image_open(engine, url.path, &error) else {
            defer { fotufilm_free(error) }
            return XCTFail(error.map { String(cString: $0) } ?? "open failed")
        }
        defer { fotufilm_image_release(image) }
        var width: UInt32 = 0, height: UInt32 = 0
        fotufilm_image_size(image, &width, &height)
        XCTAssertEqual([width, height], [160, 120])
        fotufilm_render_size(image, 64, &width, &height)
        XCTAssertEqual([width, height], [64, 48])

        var pixels = [UInt8](repeating: 0, count: 64 * 48 * 4)
        var info = fotufilm_render_info()
        let status = pixels.withUnsafeMutableBytes { buffer -> Int32 in
            var target = fotufilm_render_target(
                max_edge: 64, format: Int32(FOTUFILM_PIXELS_RGBA8_DISPLAY_P3),
                pixels: buffer.baseAddress, row_bytes: 64 * 4, capacity: buffer.count)
            return fotufilm_render(engine, image, Self.request, &target, &info, &error)
        }
        defer { fotufilm_free(error) }
        XCTAssertEqual(status, Int32(FOTUFILM_OK), error.map { String(cString: $0) } ?? "")
        XCTAssertEqual([info.width, info.height], [64, 48])
        // A ramp from black to white still runs dark to light once it is a print.
        let left = pixels[(24 * 64 + 2) * 4 + 1], right = pixels[(24 * 64 + 61) * 4 + 1]
        XCTAssertLessThan(left, right)
        XCTAssertEqual(pixels[3], 255)

        var small = [UInt8](repeating: 0, count: 16)
        let refused = small.withUnsafeMutableBytes { buffer -> Int32 in
            var target = fotufilm_render_target(
                max_edge: 64, format: Int32(FOTUFILM_PIXELS_RGBA8_DISPLAY_P3),
                pixels: buffer.baseAddress, row_bytes: 64 * 4, capacity: buffer.count)
            var tooSmall: UnsafeMutablePointer<CChar>?
            defer { fotufilm_free(tooSmall) }
            return fotufilm_render(engine, image, Self.request, &target, nil, &tooSmall)
        }
        XCTAssertEqual(refused, Int32(FOTUFILM_TARGET_TOO_SMALL))
    }

    func testUnknownFilmIsReported() throws {
        let engine = try makeEngine()
        defer { fotufilm_engine_destroy(engine) }
        let host = HostImage(rgba: [Float](repeating: 0.18, count: 8 * 8 * 4),
                             width: 8, height: 8, contentHeadroom: 1)
        let image = OpaquePointer(Unmanaged.passRetained(host).toOpaque())
        defer { fotufilm_image_release(image) }
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        var error: UnsafeMutablePointer<CChar>?
        let status = pixels.withUnsafeMutableBytes { buffer -> Int32 in
            var target = fotufilm_render_target(
                max_edge: 0, format: Int32(FOTUFILM_PIXELS_RGBA8_DISPLAY_P3),
                pixels: buffer.baseAddress, row_bytes: 32, capacity: buffer.count)
            return fotufilm_render(engine, image,
                                   #"{"edit": {"stock": "nope"}, "profileRequest": {}}"#,
                                   &target, nil, &error)
        }
        defer { fotufilm_free(error) }
        XCTAssertEqual(status, Int32(FOTUFILM_ERROR))
        XCTAssertTrue(error.map { String(cString: $0) }?.contains("nope") ?? false)
    }

    private func writeRamp(to url: URL, width: Int, height: Int) throws {
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
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    #endif
}
