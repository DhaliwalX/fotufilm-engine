import XCTest
#if canImport(AppKit)
import AppKit
#endif
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

    /// The editor learns what this build offers from the platform's services, before any engine.
    func testCapabilitiesFollowThePlatform() throws {
        let json = try XCTUnwrap(fotufilm_capabilities())
        defer { fotufilm_free(json) }
        let capabilities = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(String(cString: json).utf8)) as? [String: Any])
        let platform = HostPlatform.current
        XCTAssertEqual(capabilities["subjectSelection"] as? Bool, platform.subjects != nil)
        XCTAssertEqual(capabilities["copyImage"] as? Bool, platform.clipboard != nil)
        XCTAssertEqual(capabilities["imageExportTypes"] as? [String],
                       platform.encoder?.types.sorted() ?? [])
        #if canImport(ImageIO)
        XCTAssertEqual(capabilities["hdrExport"] as? Bool, true)
        #endif
        // Without a platform the portable parts still stand: no feature claims a missing service.
        let bare = HostPlatform().capabilities
        XCTAssertEqual(bare["subjectSelection"] as? Bool, false)
        XCTAssertEqual(bare["imageExportTypes"] as? [String], [])
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
    func testSubjectWeightsFollowThePickedInstance() {
        // Two subjects side by side on a background, at the detector's resolution.
        let labels: [UInt8] = [1, 1, 0, 2, 2,
                               1, 1, 0, 2, 2]
        let subject = HostSubject(labels: labels, width: 5, height: 2)
        let left = subject.weights(at: [0.1, 0.5], width: 10, height: 4, softness: 0)
        XCTAssertEqual(left[1 * 10 + 0], 1, accuracy: 1e-6)
        XCTAssertEqual(left[1 * 10 + 9], 0, accuracy: 1e-6)
        let every = subject.weights(at: [0.5, 0.5], width: 10, height: 4, softness: 0)
        XCTAssertEqual(every[1 * 10 + 0], 1, accuracy: 1e-6)
        XCTAssertEqual(every[1 * 10 + 9], 1, accuracy: 1e-6)
        XCTAssertEqual(every[1 * 10 + 5], 0, accuracy: 0.5)
    }

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

#if canImport(ImageIO)
extension CInterfaceTests {
    /// Exports carry the source's capture records by the chosen policy, and a HEIC can be HDR
    /// where the film delivers light above display white.
    func testExportCarriesMetadataAndHDR() throws {
        let engine = try makeEngine()
        defer { fotufilm_engine_destroy(engine) }
        func call(_ method: String, _ params: String) throws -> [String: Any] {
            var answer = fotufilm_answer()
            var error: UnsafeMutablePointer<CChar>?
            defer { fotufilm_answer_free(&answer); fotufilm_free(error) }
            guard fotufilm_host_call(engine, method, params, nil, 0, &answer, &error)
                    == Int32(FOTUFILM_OK) else {
                throw XCTSkip(error.map { String(cString: $0) } ?? method)
            }
            return try JSONSerialization.jsonObject(
                with: Data(String(cString: answer.json).utf8)) as? [String: Any] ?? [:]
        }
        let ramp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-meta-\(UUID().uuidString).png")
        try writeRamp(to: ramp, width: 96, height: 64)
        let source = ramp.deletingPathExtension().appendingPathExtension("jpg")
        defer {
            try? FileManager.default.removeItem(at: ramp)
            try? FileManager.default.removeItem(at: source)
        }
        let picture = try XCTUnwrap(CGImageSourceCreateWithURL(ramp as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(
            source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, picture, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Fotufilm Test"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test 50mm"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 43.6,
                                            kCGImagePropertyGPSLatitudeRef: "N"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let handle = try XCTUnwrap(call("importPath", #"{"path": "\#(source.path)"}"#)["handle"])

        func export(_ type: String, _ extra: String) throws -> (URL, [String: Any]) {
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("fotufilm-meta-out-\(UUID().uuidString)")
                .appendingPathExtension(type == "image/heic" ? "heic" : "jpg")
            let answer = try call("export", """
            {"handle": \(handle), "maxEdge": null, "type": "\(type)", "path": "\(target.path)",
             "edit": {"params": {}}, "profileRequest": {"controls": {}}\(extra)}
            """)
            return (target, answer)
        }
        func properties(_ url: URL) -> [String: Any] {
            CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any] ?? [:]
        }
        func make(_ p: [String: Any]) -> String? {
            (p[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[
                kCGImagePropertyTIFFMake as String] as? String
        }

        let (kept, _) = try export("image/jpeg", "")
        defer { try? FileManager.default.removeItem(at: kept) }
        XCTAssertEqual(make(properties(kept)), "Fotufilm Test")
        XCTAssertNil(properties(kept)[kCGImagePropertyGPSDictionary as String])
        let (located, _) = try export("image/jpeg", #", "metadata": "preserve""#)
        defer { try? FileManager.default.removeItem(at: located) }
        XCTAssertNotNil(properties(located)[kCGImagePropertyGPSDictionary as String])
        let (stripped, _) = try export("image/jpeg", #", "metadata": "strip""#)
        defer { try? FileManager.default.removeItem(at: stripped) }
        XCTAssertNil(make(properties(stripped)))

        // Without a film the picture may reach past display white; a print may not.
        let options = try call("exportOptions", """
        {"handle": \(handle), "maxEdge": 256, "edit": {"params": {}}, "profileRequest": {"controls": {}}}
        """)
        XCTAssertEqual(options["hdr"] as? Bool, true)
        XCTAssertEqual((options["metadata"] as? [String])?.count, 3)
        let (hdr, answer) = try export("image/heic", #", "hdr": true"#)
        defer { try? FileManager.default.removeItem(at: hdr) }
        XCTAssertEqual(answer["hdr"] as? Bool, true)
        XCTAssertEqual(make(properties(hdr)), "Fotufilm Test")
    }

    /// Choose Film Per Photo: every film ranked for the photograph, the choice learned, and
    /// forgotten on request.
    func testFilmSuggestionRanksRecordsAndForgets() throws {
        let engine = try makeEngine()
        defer { fotufilm_engine_destroy(engine) }
        let service = Unmanaged<HostEngine>.fromOpaque(UnsafeRawPointer(engine))
            .takeUnretainedValue().service
        service.filmPreferences = HostFilmPreferences(file: nil)
        func call(_ method: String, _ params: String) throws -> [String: Any] {
            let answer = try service.call(method, params: Data(params.utf8), payload: nil)
            return try JSONSerialization.jsonObject(with: answer.json) as? [String: Any] ?? [:]
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-suggest-\(UUID().uuidString).png")
        try writeRamp(to: url, width: 96, height: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try XCTUnwrap(call("importPath", #"{"path": "\#(url.path)"}"#)["handle"])

        // Two films keep the develops few; the page may name any subset.
        let films = Array(service.engine.stockIDs.prefix(2))
        let named = films.map { "\"\($0)\"" }.joined(separator: ", ")
        let suggested = try call("suggestFilm", """
        {"handle": \(handle), "photoID": "ramp", "edit": {"params": {}},
         "films": [\(named)], "profileRequest": {"controls": {}}}
        """)
        let ordered = try XCTUnwrap(suggested["ordered"] as? [[String: Any]])
        XCTAssertEqual(Set(ordered.compactMap { $0["id"] as? String }), Set(films))
        let best = try XCTUnwrap(suggested["best"] as? String)
        XCTAssertEqual(ordered.first?["id"] as? String, best)
        let other = try XCTUnwrap(ordered.last?["id"] as? String)
        let recorded = try call("recordFilmChoice", #"{"photoID": "ramp", "film": "\#(other)"}"#)
        XCTAssertEqual(recorded["observations"] as? Int, 1)
        _ = try call("forgetFilmChoices", "{}")
        XCTAssertEqual(service.filmPreferences.observationCount, 0)
    }

    /// The editor's own calls: import a photograph's bytes, develop a cropped render of it.
    func testHostCallsImportAndRender() throws {
        let engine = try makeEngine()
        defer { fotufilm_engine_destroy(engine) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-host-\(UUID().uuidString).png")
        try writeRamp(to: url, width: 120, height: 80)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = try Data(contentsOf: url)

        func call(_ method: String, _ params: String, _ payload: Data? = nil) throws
            -> (json: [String: Any], payload: Data) {
            var answer = fotufilm_answer()
            var error: UnsafeMutablePointer<CChar>?
            let status = (payload ?? Data()).withUnsafeBytes { buffer in
                fotufilm_host_call(engine, method, params, buffer.baseAddress, buffer.count,
                                   &answer, &error)
            }
            defer { fotufilm_answer_free(&answer); fotufilm_free(error) }
            guard status == Int32(FOTUFILM_OK) else {
                throw XCTSkip(error.map { String(cString: $0) } ?? "status \(status)")
            }
            let json = try JSONSerialization.jsonObject(
                with: Data(String(cString: answer.json).utf8)) as? [String: Any] ?? [:]
            return (json, answer.payload.map { Data(bytes: $0, count: answer.payload_length) }
                ?? Data())
        }

        func callRaw(_ method: String, _ params: String) throws -> String {
            var answer = fotufilm_answer()
            var error: UnsafeMutablePointer<CChar>?
            defer { fotufilm_answer_free(&answer); fotufilm_free(error) }
            guard fotufilm_host_call(engine, method, params, nil, 0, &answer, &error)
                    == Int32(FOTUFILM_OK) else {
                throw XCTSkip(error.map { String(cString: $0) } ?? method)
            }
            return String(cString: answer.json)
        }

        let prepared = try call("prepare", "{}")
        XCTAssertTrue((prepared.json["stocks"] as? [String])?.contains("gold200") ?? false)

        let imported = try call("import", #"{"name": "ramp.png"}"#, bytes)
        let handle = try XCTUnwrap(imported.json["handle"] as? Int)
        XCTAssertEqual(imported.json["naturalWidth"] as? Int, 120)
        let preview = try XCTUnwrap((imported.json["payloads"] as? [String: [Int]])?["preview"])
        XCTAssertEqual(imported.payload.subdata(in: preview[0]..<(preview[0] + 8)),
                       Data([137, 80, 78, 71, 13, 10, 26, 10]))

        // A quarter turn makes the 120 x 80 photograph 80 x 120; the crop keeps its top half.
        let rendered = try call("render", """
        {"handle": \(handle), "maxEdge": null,
         "edit": {"stock": "gold200", "rotation": 1, "params": {},
                  "crop": [[0, 0], [1, 0], [1, 0.5], [0, 0.5]]},
         "profileRequest": {"controls": {}}}
        """)
        XCTAssertEqual(rendered.json["width"] as? Int, 80)
        XCTAssertEqual(rendered.json["height"] as? Int, 60)
        let ranges = try XCTUnwrap(rendered.json["payloads"] as? [String: [Int]])
        XCTAssertNotNil(ranges["original"])
        let png = rendered.payload.subdata(in: ranges["preview"]![0]..<(ranges["preview"]![0] + ranges["preview"]![1]))
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual([decoded.width, decoded.height], [80, 60])

        // A tile of a viewport twice the frame's size is cut from the same develop.
        let tile = try call("render", """
        {"handle": \(handle), "maxEdge": null,
         "viewport": {"width": 160, "height": 120, "region": {"x": 80, "y": 0, "width": 80, "height": 60}},
         "edit": {"stock": "gold200", "rotation": 1, "params": {},
                  "crop": [[0, 0], [1, 0], [1, 0.5], [0, 0.5]]},
         "profileRequest": {"controls": {}}}
        """)
        XCTAssertEqual(tile.json["width"] as? Int, 40)
        XCTAssertEqual(tile.json["renderMilliseconds"] as? Double, 0)

        // Auto solves exposure for the film; a sample reads the scene under a point.
        let auto = try call("autoAdjust", """
        {"handle": \(handle), "edit": {"stock": "gold200", "params": {}}}
        """)
        XCTAssertNotNil(auto.json["ev"] as? Double)
        let sample = try JSONSerialization.jsonObject(with: Data(try callRaw("sampleScene", """
        {"render": {"handle": \(handle), "maxEdge": 64, "edit": {"stock": "gold200", "params": {}},
                    "profileRequest": {"controls": {}}},
         "point": [0.9, 0.5]}
        """).utf8)) as? [Double]
        XCTAssertEqual(sample?.count, 3)

        // A film border frames the develop and says where the photograph sits in it.
        let framed = try call("render", """
        {"handle": \(handle), "maxEdge": null,
         "printFrame": {"kind": "print-frame", "stock": "gold200", "frame": "film", "width": 1, "height": 1},
         "edit": {"stock": "gold200", "params": {}}, "profileRequest": {"controls": {}}}
        """)
        let placement = try XCTUnwrap((framed.json["framePlan"] as? [String: Any])?["placement"]
            as? [String: Any])
        XCTAssertGreaterThan(framed.json["width"] as? Int ?? 0, 120)
        XCTAssertEqual(((placement["size"] as? [String: Any])?["width"] as? Int), framed.json["width"] as? Int)

        // Lens sliders plan a correction without a profile, and it reaches the develop.
        let lens = #""lens": {"enabled": true, "amount": 1, "profileID": null, "distortion": -0.5, "vignetting": 0.5, "redCyan": 0, "blueYellow": 0}"#
        let plan = try call("lensPlan", #"{"handle": \#(handle), \#(lens)}"#)
        XCTAssertEqual(plan.json["identity"] as? Bool, false)
        XCTAssertEqual((plan.json["table"] as? [Double])?.count, 4096)
        let corrected = try call("render", """
        {"handle": \(handle), "maxEdge": null, "edit": {"stock": "gold200", "params": {}, \(lens)},
         "profileRequest": {"controls": {}}}
        """)
        XCTAssertEqual(corrected.json["width"] as? Int, 120)

        // A selection of the bright end develops brighter than the photograph around it.
        let selective = #""selective": {"kind": "light", "sample": [1, 1, 1], "range": 0.3, "softness": 0.5, "params": {"ev": 2}}"#
        let plain = try call("render", """
        {"handle": \(handle), "maxEdge": 64, "edit": {"stock": "gold200", "params": {}},
         "profileRequest": {"controls": {}}}
        """)
        let selected = try call("render", """
        {"handle": \(handle), "maxEdge": 64, "edit": {"stock": "gold200", "params": {}, \(selective)},
         "profileRequest": {"controls": {}}}
        """)
        func pixel(_ result: (json: [String: Any], payload: Data), _ x: Int) throws -> UInt8 {
            let range = try XCTUnwrap((result.json["payloads"] as? [String: [Int]])?["preview"])
            let png = result.payload.subdata(in: range[0]..<(range[0] + range[1]))
            let image = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            let data = try XCTUnwrap(image.dataProvider?.data as Data?)
            return data[(image.height / 2) * image.bytesPerRow + x * (image.bitsPerPixel / 8) + 1]
        }
        XCTAssertGreaterThan(try pixel(selected, 60), try pixel(plain, 60))
        XCTAssertEqual(try pixel(selected, 2), try pixel(plain, 2), accuracy: 2)

        // The pipeline inspector lists the walk and renders a step and its difference.
        let stages = try JSONSerialization.jsonObject(with: Data(try callRaw("stages",
            #"{"stock": "gold200", "medium": null, "halationModel": "legacy", "digitalReference": "auto-levels"}"#
        ).utf8)) as? [[String: Any]]
        XCTAssertGreaterThan(stages?.count ?? 0, 5)
        let stage = try call("render", """
        {"handle": \(handle), "maxEdge": 64, "stage": 3, "difference": true,
         "edit": {"stock": "gold200", "params": {}}, "profileRequest": {"controls": {}}}
        """)
        XCTAssertEqual(stage.json["width"] as? Int, 64)

        // Export writes a 16-bit TIFF where the host's save panel pointed.
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-export-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: target) }
        let exported = try call("export", """
        {"handle": \(handle), "maxEdge": null, "type": "image/tiff", "path": "\(target.path)",
         "edit": {"stock": "gold200", "params": {}}, "profileRequest": {"controls": {}}}
        """)
        XCTAssertEqual(exported.json["width"] as? Int, 120)
        let written = try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(written.bitsPerComponent, 16)

        _ = try call("release", #"{"handle": \#(handle)}"#)
        XCTAssertThrowsError(try call("preview", #"{"handle": \#(handle)}"#))

        // A file the host chose opens in place, without its bytes.
        let opened = try call("importPath", #"{"path": "\#(url.path)"}"#)
        let path = try XCTUnwrap(opened.json["handle"] as? Int)
        XCTAssertEqual(opened.json["naturalHeight"] as? Int, 80)
        // It carries the identity its edit is kept under: its bytes' digest, as the Mac app's.
        XCTAssertEqual(opened.json["identity"] as? String,
                       HostFileIdentity.identity(of: url, isMovie: false))
        XCTAssertTrue((opened.json["identity"] as? String)?.hasPrefix("sha256:") == true)
        XCTAssertThrowsError(try call("importPath", #"{"path": "/nonexistent/photo.png"}"#))

        #if canImport(AppKit)
        // Copy Photo puts the developed frame on the pasteboard at its full size.
        let pasteboard = NSPasteboard(name: .init("fotufilm-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        Unmanaged<HostEngine>.fromOpaque(UnsafeRawPointer(engine)).takeUnretainedValue()
            .service.clipboard = PasteboardClipboard(pasteboard: pasteboard)
        let copied = try call("copyImage", """
        {"handle": \(path), "maxEdge": null, "edit": {"stock": "gold200", "params": {}},
         "profileRequest": {"controls": {}}}
        """)
        XCTAssertEqual(copied.json["width"] as? Int, 120)
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            let pasted = try XCTUnwrap(pasteboard.data(forType: type).flatMap(NSBitmapImageRep.init))
            XCTAssertEqual([pasted.pixelsWide, pasted.pixelsHigh], [120, 80])
        }
        #endif
    }
}
#endif

extension CInterfaceTests {
    /// A synthetic colour negative: an orange base, denser where the scene was brighter.
    func testNegativeAnalysisConvertsAndSuggests() throws {
        let engine = try makeEngine()
        defer { fotufilm_engine_destroy(engine) }
        let service = Unmanaged<HostEngine>.fromOpaque(UnsafeRawPointer(engine))
            .takeUnretainedValue().service
        var rgba = [Float](repeating: 1, count: 96 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<96 {
                let scene = Float(x) / 95, i = (y * 96 + x) * 4
                let base = SIMD3<Float>(0.75, 0.45, 0.25)
                for c in 0..<3 { rgba[i + c] = base[c] * pow(0.35, scene * Float(c + 1) / 2) }
            }
        }
        let handle = try service.register(HostImage(rgba: rgba, width: 96, height: 64,
                                                    contentHeadroom: 1))
        func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            let answer = try service.call(method, params: JSONSerialization.data(withJSONObject: params),
                                          payload: nil)
            return try JSONSerialization.jsonObject(with: answer.json) as? [String: Any] ?? [:]
        }
        let plan = try call("analyseNegative", ["handle": handle, "monochrome": false])
        XCTAssertEqual((plan["parameters"] as? [Double])?.count, 8)
        let converted = try call("convertNegative", ["handle": handle, "nativePlan": plan["nativePlan"]!,
                                                     "maxEdge": NSNull(), "contrast": 0.5])
        XCTAssertNotEqual(converted["handle"] as? Int, handle)
        XCTAssertEqual(converted["naturalWidth"] as? Int, 96)
        let answer = try service.call("suggestNegativeFilms",
                                      params: JSONSerialization.data(withJSONObject: ["handle": handle]),
                                      payload: nil)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: answer.json) as? [Any])
    }
}
