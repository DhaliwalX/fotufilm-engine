import XCTest
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif
import CFotufilmHost
@testable import FotufilmHost

/// Native presentation through the C interface: a render that names a layer develops into the
/// presenter's surfaces and answers with frame ids instead of pictures.
final class HostPresentationTests: XCTestCase {
    /// A presenter that keeps what it is shown in memory, reached through C callbacks as a host's.
    final class MemoryPresenter {
        struct Shown {
            var layer: String
            var width: Int, height: Int, format: Int32
            var bytes: [UInt8]
            var info: [String: Any]
        }
        var headroom: Float = 1
        var shown: [Shown] = []
        var lent = 0
        private var next: UInt64 = 0

        var callbacks: fotufilm_presenter {
            fotufilm_presenter(
                context: Unmanaged.passUnretained(self).toOpaque(),
                headroom: { context in
                    Unmanaged<MemoryPresenter>.fromOpaque(context!).takeUnretainedValue().headroom
                },
                acquire: { context, width, height, format, surface in
                    let presenter = Unmanaged<MemoryPresenter>.fromOpaque(context!)
                        .takeUnretainedValue()
                    let row = Int(width) * (format == Int32(FOTUFILM_SURFACE_RGBA8_DISPLAY_P3) ? 4 : 8)
                    // Rows padded, as a platform's surfaces are.
                    let rowBytes = (row + 63) / 64 * 64
                    let pixels = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * Int(height),
                                                                  alignment: 64)
                    surface!.pointee = fotufilm_surface(
                        width: width, height: height, format: format, pixels: pixels,
                        row_bytes: rowBytes, native: nil, host: nil)
                    presenter.lent += 1
                    return Int32(FOTUFILM_OK)
                },
                present: { context, layer, surface, info in
                    let presenter = Unmanaged<MemoryPresenter>.fromOpaque(context!)
                        .takeUnretainedValue()
                    let s = surface!.pointee
                    let row = Int(s.width) * (s.format == Int32(FOTUFILM_SURFACE_RGBA8_DISPLAY_P3) ? 4 : 8)
                    var bytes = [UInt8](repeating: 0, count: row * Int(s.height))
                    for y in 0..<Int(s.height) {
                        bytes.withUnsafeMutableBytes {
                            ($0.baseAddress! + y * row).copyMemory(
                                from: s.pixels! + y * s.row_bytes, byteCount: row)
                        }
                    }
                    s.pixels!.deallocate()
                    presenter.lent -= 1
                    let fields = (try? JSONSerialization.jsonObject(
                        with: Data(String(cString: info!).utf8))) as? [String: Any] ?? [:]
                    presenter.shown.append(Shown(layer: String(cString: layer!),
                                                 width: Int(s.width), height: Int(s.height),
                                                 format: s.format, bytes: bytes, info: fields))
                    presenter.next += 1
                    return presenter.next
                },
                discard: { context, surface in
                    surface!.pointee.pixels?.deallocate()
                    Unmanaged<MemoryPresenter>.fromOpaque(context!).takeUnretainedValue().lent -= 1
                })
        }
    }

    #if canImport(ImageIO)
    func testRendersPresentFramesInsteadOfPictures() throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let engine = fotufilm_engine_create(&error) else {
            defer { fotufilm_free(error) }
            throw XCTSkip(error.map { String(cString: $0) } ?? "no engine")
        }
        defer { fotufilm_engine_destroy(engine) }
        let presenter = MemoryPresenter()
        var callbacks = presenter.callbacks
        fotufilm_engine_set_presenter(engine, &callbacks)

        func call(_ method: String, _ params: String) throws -> (json: [String: Any], payload: Int) {
            var answer = fotufilm_answer()
            var error: UnsafeMutablePointer<CChar>?
            defer { fotufilm_answer_free(&answer); fotufilm_free(error) }
            guard fotufilm_host_call(engine, method, params, nil, 0, &answer, &error)
                    == Int32(FOTUFILM_OK) else {
                throw XCTSkip(error.map { String(cString: $0) } ?? method)
            }
            let json = try JSONSerialization.jsonObject(
                with: Data(String(cString: answer.json).utf8)) as? [String: Any] ?? [:]
            return (json, answer.payload_length)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-present-\(UUID().uuidString).png")
        try writeRamp(to: url, width: 120, height: 80)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try XCTUnwrap(call("importPath", #"{"path": "\#(url.path)"}"#).json["handle"])

        // A film preview goes to the preview layer, with the undeveloped picture beside it.
        let film = """
        {"handle": \(handle), "maxEdge": null, "present": {"slot": "preview", "scope": "a"},
         "edit": {"stock": "gold200", "params": {}}, "profileRequest": {"controls": {}}}
        """
        let rendered = try call("render", film)
        XCTAssertEqual(rendered.payload, 0, "no picture crosses to the page")
        XCTAssertNil(rendered.json["payloads"])
        let presented = try XCTUnwrap(rendered.json["presented"] as? [String: Any])
        XCTAssertEqual(presented["dynamicRange"] as? String, "sdr")
        XCTAssertEqual(presenter.shown.map(\.layer), ["preview", "preview.original"])
        XCTAssertEqual(presented["frame"] as? Int, 1)
        XCTAssertEqual(presented["original"] as? Int, 2)
        let preview = presenter.shown[0]
        XCTAssertEqual([preview.width, preview.height], [120, 80])
        XCTAssertEqual(preview.format, Int32(FOTUFILM_SURFACE_RGBA8_DISPLAY_P3))
        XCTAssertEqual(preview.info["scope"] as? String, "a")
        // The ramp runs dark to light across the picture.
        XCTAssertLessThan(preview.bytes[4], preview.bytes[(120 - 2) * 4])
        XCTAssertEqual(presenter.lent, 0)

        // The same edit again presents the develop again, and the unchanged original not at all.
        let again = try XCTUnwrap(try call("render", film).json["presented"] as? [String: Any])
        XCTAssertEqual(again["original"] as? Int, 2)
        XCTAssertEqual(presenter.shown.count, 3)
        XCTAssertEqual(presenter.shown[2].bytes, preview.bytes)

        // A viewport tile is cut from the same develop into the detail layer.
        let tile = try call("render", """
        {"handle": \(handle), "maxEdge": null, "present": {"slot": "detail", "scope": "b"},
         "viewport": {"width": 120, "height": 80, "region": {"x": 60, "y": 0, "width": 60, "height": 40}},
         "edit": {"stock": "gold200", "params": {}}, "profileRequest": {"controls": {}}}
        """)
        XCTAssertEqual(tile.json["renderMilliseconds"] as? Double, 0)
        let detail = try XCTUnwrap(presenter.shown.first { $0.layer == "detail" })
        XCTAssertEqual([detail.width, detail.height], [60, 40])
        XCTAssertEqual(Array(detail.bytes[0..<(60 * 4)]),
                       Array(preview.bytes[(60 * 4)..<(120 * 4)]))

        // The histogram reads the presented develop as a picture on request.
        let image = try call("presentedImage", "{}")
        XCTAssertGreaterThan(image.payload, 0)
        XCTAssertEqual(image.json["width"] as? Int, 120)

        // With room above SDR white, a picture that may reach past it is presented in extended
        // range; a print on paper stays SDR.
        presenter.headroom = 3
        let open = try XCTUnwrap(try call("render", """
        {"handle": \(handle), "maxEdge": null, "present": {"slot": "preview", "scope": "a"},
         "stage": null, "edit": {"params": {"ev": 1.5}}, "profileRequest": {"controls": {}}}
        """).json["presented"] as? [String: Any])
        XCTAssertEqual(open["dynamicRange"] as? String, "hdr")
        XCTAssertEqual(open["headroom"] as? Double, 3)
        let extended = try XCTUnwrap(presenter.shown.last { $0.layer == "preview" })
        XCTAssertEqual(extended.format, Int32(FOTUFILM_SURFACE_RGBA16F_EXTENDED_LINEAR_P3))
        let light = extended.bytes.withUnsafeBytes { raw in
            (0..<(extended.width * extended.height)).map {
                HostPresentation.float(raw.load(fromByteOffset: $0 * 8, as: UInt16.self))
            }
        }
        XCTAssertTrue(light.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 3 })
        XCTAssertGreaterThan(light.max() ?? 0, 1, "the bright end reaches past SDR white")
        // Below SDR white the extended frame matches the standard one: EDR adds range above it,
        // not a different picture.
        let normal = """
        {"handle": \(handle), "maxEdge": null, "present": {"slot": "preview", "scope": "a"},
         "stage": null, "edit": {"params": {}}, "profileRequest": {"controls": {}}}
        """
        func shownLight() throws -> [Float] {
            let frame = try XCTUnwrap(presenter.shown.last { $0.layer == "preview" })
            let count = frame.width * frame.height
            if frame.format == Int32(FOTUFILM_SURFACE_RGBA8_DISPLAY_P3) {
                return (0..<count).map { i in
                    let c = Float(frame.bytes[i * 4 + 1]) / 255
                    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                }
            }
            return frame.bytes.withUnsafeBytes { raw in
                (0..<count).map { HostPresentation.float(raw.load(fromByteOffset: $0 * 8 + 2, as: UInt16.self)) }
            }
        }
        _ = try call("render", normal)
        let hdrRow = try shownLight()
        presenter.headroom = 1
        _ = try call("render", normal)
        let sdrRow = try shownLight()
        presenter.headroom = 3
        for x in stride(from: 10, to: 110, by: 20) {
            XCTAssertEqual(hdrRow[x], sdrRow[x], accuracy: 0.002 + sdrRow[x] * 0.01, "at \(x)")
        }
        let print = try XCTUnwrap(try call("render", film).json["presented"] as? [String: Any])
        XCTAssertEqual(print["dynamicRange"] as? String, "sdr")

        // Without a presenter the answer carries pictures again.
        fotufilm_engine_set_presenter(engine, nil)
        XCTAssertGreaterThan(try call("render", film).payload, 0)
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

    func testHalfFloatsRoundTrip() {
        for value: Float in [0, 0.25, 1, 1.5, 3.75, 16] {
            XCTAssertEqual(HostPresentation.float(HostPresentation.half(value)), value)
        }
    }
}
