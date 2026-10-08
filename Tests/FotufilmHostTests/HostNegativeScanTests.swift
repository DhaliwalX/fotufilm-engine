import XCTest
import CFotufilmHost
@testable import FotufilmHost
import FotufilmCore
import FotufilmEditModel
import FotufilmImaging
#if canImport(CoreImage) && canImport(ImageIO)
import CoreImage
import ImageIO
import UniformTypeIdentifiers
#endif

final class HostNegativeScanTests: XCTestCase {
    private let border = SIMD3<Float>(0.8, 0.45, 0.2)

    /// A 135 frame as linear Rec. 2020 RGBA: clear rebate above and below, a dense holder at the
    /// left, and a picture whose density rises left to right, with a light spot in the middle.
    private func strip(width: Int, height: Int) -> [Float] {
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let u = Double(x) / Double(width), v = Double(y) / Double(height)
            var density: [Float] = [0.02, 0.02, 0.02]
            if u < 0.04 {
                density = [4, 4, 4]
            } else if u > 0.97 {
                // An open holder: more light than any film passes.
                density = [-1, -1, -1]
            } else if u > 0.1, u < 0.9, v > 0.15, v < 0.85 {
                let scene = Float((u - 0.1) / 0.8)
                density = (0..<3).map { 0.2 + scene * (1.2 + 0.1 * Float($0)) }
                if abs(u - 0.5) < 0.05, abs(v - 0.5) < 0.05 { density = [0.4, 0.9, 1.3] }
            }
            for c in 0..<3 { rgba[(y * width + x) * 4 + c] = border[c] * pow(10, -density[c]) }
        } }
        return rgba
    }

    private func service(lights: URL? = nil) throws -> (HostService, OpaquePointer) {
        var error: UnsafeMutablePointer<CChar>?
        guard let engine = fotufilm_engine_create(&error) else {
            defer { fotufilm_free(error) }
            throw XCTSkip(error.map { String(cString: $0) } ?? "no engine")
        }
        let service = Unmanaged<HostEngine>.fromOpaque(UnsafeRawPointer(engine))
            .takeUnretainedValue().service
        service.negativeScans = HostNegativeScans(lights: HostNegativeLightFrames(
            directory: lights ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("fotufilm-lights-\(UUID().uuidString)")))
        return (service, engine)
    }

    private func call(_ service: HostService, _ method: String, _ params: [String: Any],
                      payload: [UInt8]? = nil) throws -> (json: [String: Any], payload: [UInt8]) {
        let data = try JSONSerialization.data(withJSONObject: params)
        let answer = try payload.map { bytes in
            try bytes.withUnsafeBytes { try service.call(method, params: data, payload: $0) }
        } ?? service.call(method, params: data, payload: nil)
        return (try JSONSerialization.jsonObject(with: answer.json) as? [String: Any] ?? [:],
                answer.payload)
    }

    /// Opens a strip held in memory as a negative document.
    private func open(_ service: HostService, width: Int, height: Int) -> Int {
        let image = HostImage(rgba: strip(width: width, height: height), width: width,
                              height: height, contentHeadroom: 1)
        let handle = service.register(image)
        let lights = service.negativeScans.lights
        service.negativeScans.add(HostNegativeScan(scan: image) { lights.frame($0)?.measured },
                                  handle: handle)
        return handle
    }

    /// A render request for a negative document read as `stock`, with the print's own controls.
    private func request(_ handle: Int, stock: String? = "gold200", maxEdge: Int? = nil,
                         negative: [String: Any] = [:], medium: String? = nil,
                         controls: [String: Any] = [:]) -> [String: Any] {
        var settings: [String: Any] = ["controls": controls]
        if let medium { settings["medium"] = medium }
        return ["handle": handle, "maxEdge": maxEdge ?? NSNull(),
                "edit": ["stock": stock.map { $0 as Any } ?? NSNull(), "params": [:], "negative": negative],
                "profileRequest": settings]
    }

    /// The editor's develop of a request: display-linear Display P3 RGBA.
    private func develop(_ service: HostService, _ body: [String: Any]) throws
        -> (rgba: [Float], width: Int, height: Int) {
        let prepared = try service.prepare(JSONSerialization.data(withJSONObject: body))
        let scene = try service.framedScene(prepared)
        let (width, height) = prepared.sizes.output
        var rgba = [Float](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBytes { buffer in
            try service.engine.develop(scene, width: width, height: height, contentHeadroom: 1,
                                       edit: prepared.edit,
                                       into: .init(maxEdge: 0, format: .rgba32FloatLinearP3,
                                                   pixels: buffer.baseAddress!,
                                                   rowBytes: width * 16, capacity: buffer.count))
        }
        return (rgba, width, height)
    }

    // MARK: - A negative document

    #if canImport(CoreImage)
    /// A light frame measured without Core Image evens a scan out as the apps' measurement does.
    func testPortableLightMeasurementMatchesCoreImage() throws {
        let width = 320, height = 200
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let dx = Float(x) / Float(width) - 0.5, dy = Float(y) / Float(height) - 0.5
            for c in 0..<3 {
                rgba[(y * width + x) * 4 + c] = (1 - 0.9 * (dx * dx + dy * dy)) * (0.6 + 0.1 * Float(c))
            }
        } }
        let photo = CIImage(bitmapData: rgba.withUnsafeBufferPointer { Data(buffer: $0) },
                            bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                            format: .RGBAf, colorSpace: NegativeScanImport.linearSpace)
        let apps = try NegativeLightFrame(photo: photo)
        let ours = try NegativeLightFrame(linearSRGB: rgba, width: width, height: height)
        XCTAssertEqual([ours.width, ours.height], [apps.width, apps.height])
        for (u, v) in [(0.5, 0.5), (0.1, 0.1), (0.9, 0.3), (0.3, 0.95)] as [(Float, Float)] {
            let a = apps.gain(x: u, y: v), b = ours.gain(x: u, y: v)
            for c in 0..<3 { XCTAssertEqual(a[c], b[c], accuracy: 0.03, "at \(u), \(v)") }
        }
    }
    #endif

    /// A negative develops through the editor's own print: the scan read as the edit's film
    /// against its film base, then whatever the Print panel sets.
    func testNegativeDocumentPrintsThroughTheEditorsPrint() throws {
        let (service, engine) = try service()
        defer { fotufilm_engine_destroy(engine) }
        let handle = open(service, width: 300, height: 200)

        // The rebate in the picture's top rows, picked as the Film panel picks it.
        let sampled = try JSONSerialization.jsonObject(with: service.call(
            "negativeSampleFilmBase",
            params: JSONSerialization.data(withJSONObject: [
                "render": request(handle, maxEdge: 150), "point": [0.5, 0.05]]),
            payload: nil).json) as? [Double]
        let measured = try XCTUnwrap(sampled)
        for c in 0..<3 {
            XCTAssertEqual(Float(measured[c]), border[c] * pow(10, -0.02), accuracy: 1e-3)
        }

        // Read as Gold 200 on Digital Reference: the denser negative prints brighter, and the open
        // holder, outside the film's densities, prints black.
        let reading = ["border": measured]
        let film = try develop(service, request(handle, maxEdge: 150, negative: reading))
        XCTAssertEqual([film.width, film.height], [150, 100])
        func green(_ print: (rgba: [Float], width: Int, height: Int), _ x: Int, _ y: Int) -> Float {
            print.rgba[(y * print.width + x) * 4 + 1]
        }
        XCTAssertGreaterThan(green(film, 120, 50), green(film, 30, 50))
        XCTAssertEqual(green(film, 149, 50), 0)

        // Until clear film is picked the base is estimated from the thinnest film of the scan
        // (here the open holder, which a pick then corrects).
        let estimated = try develop(service, request(handle, maxEdge: 150))
        XCTAssertNotEqual(green(estimated, 60, 50), green(film, 60, 50), accuracy: 1e-3)

        // The Print panel's own controls act on it: screen exposure, and an RA-4 paper.
        let brighter = try develop(service, request(handle, maxEdge: 150, negative: reading,
                                                    controls: ["screenExposure": 1]))
        XCTAssertGreaterThan(green(brighter, 60, 50), green(film, 60, 50))
        let paper = try develop(service, request(handle, maxEdge: 150, negative: reading,
                                                 medium: PrintPaper.crystalArchive.rawValue))
        XCTAssertNotEqual(green(paper, 60, 50), green(film, 60, 50), accuracy: 1e-3)

        // The editor's crop frames it like any photograph.
        var cropped = request(handle, maxEdge: 150, negative: reading)
        cropped["edit"] = (cropped["edit"] as! [String: Any]).merging([
            "crop": [[0.1, 0.15], [0.9, 0.15], [0.9, 0.85], [0.1, 0.85]],
        ]) { $1 }
        let framed = try develop(service, cropped)
        XCTAssertEqual(framed.width, 150)
        XCTAssertLessThan(framed.height, 100)

        // A slide has no negative to read; no film at all asks for one.
        let slide = try XCTUnwrap(FilmStock.presetIDs.first { FilmStock.presets[$0]!.isReversal })
        XCTAssertThrowsError(try develop(service, request(handle, stock: slide)))
        _ = try call(service, "release", ["handle": handle])
        XCTAssertNil(service.negativeScans.scan(handle))
    }

    /// With no film chosen (Normal) a negative develops as a plain positive, like any photograph
    /// without film: no print, and the photograph's own controls act on it.
    func testANegativeWithoutAFilmDevelopsAsAPlainPositive() throws {
        let (service, engine) = try service()
        defer { fotufilm_engine_destroy(engine) }
        let handle = open(service, width: 300, height: 200)
        let reading: [String: Any] = ["border": border.indices.map { Double(border[$0]) }]
        let plain = try develop(service, request(handle, stock: nil, maxEdge: 150, negative: reading))
        XCTAssertEqual([plain.width, plain.height], [150, 100])
        func green(_ print: (rgba: [Float], width: Int, height: Int), _ x: Int, _ y: Int) -> Float {
            print.rgba[(y * print.width + x) * 4 + 1]
        }
        // The denser negative is the brighter scene, and clear film is near black.
        XCTAssertGreaterThan(green(plain, 120, 50), green(plain, 30, 50))
        XCTAssertLessThan(green(plain, 75, 5), green(plain, 30, 50))
        // It is no print: the film's own reading of the same scan differs.
        let film = try develop(service, request(handle, maxEdge: 150, negative: reading))
        XCTAssertNotEqual(green(plain, 60, 50), green(film, 60, 50), accuracy: 1e-3)
        // Exposure brightens it, as it does a photograph.
        var exposed = request(handle, stock: nil, maxEdge: 150, negative: reading)
        exposed["edit"] = (exposed["edit"] as! [String: Any]).merging(["params": ["ev": 1]]) { $1 }
        XCTAssertGreaterThan(green(try develop(service, exposed), 60, 50), green(plain, 60, 50))
    }

    /// A frame measures its own densest end for its roll, and develops on the roll's colour: a
    /// roll of the frame's own colour is no change, another colour is, read as a film or not.
    func testAFrameMeasuresForItsRollAndDevelopsOnTheRollsColour() throws {
        let (service, engine) = try service()
        defer { fotufilm_engine_destroy(engine) }
        let handle = open(service, width: 300, height: 200)
        let reading: [String: Any] = ["border": border.indices.map { Double(border[$0]) }]
        let prepared = try service.prepare(JSONSerialization.data(
            withJSONObject: request(handle, maxEdge: 150, negative: reading)))
        let measure = try XCTUnwrap(prepared.negativeMeasure)
        let dense = try XCTUnwrap(measure["denseEnd"] as? [Double])
        XCTAssertEqual(dense.count, 3)
        XCTAssertGreaterThan(dense[1], 0.05)
        XCTAssertEqual((measure["border"] as? [Double])?.map(Float.init), [border.x, border.y, border.z])

        func green(_ print: (rgba: [Float], width: Int, height: Int)) -> Float {
            print.rgba[(50 * print.width + 60) * 4 + 1]
        }
        func red(_ print: (rgba: [Float], width: Int, height: Int)) -> Float {
            print.rgba[(50 * print.width + 60) * 4]
        }
        func rolled(_ colour: [Double]) -> [String: Any] {
            reading.merging(["roll": ["colour": colour, "frames": 12]]) { $1 }
        }
        let own = [dense[0] / dense[1], dense[2] / dense[1]]
        let warmer = [own[0] * 0.8, own[1]]
        for stock in ["gold200", nil] as [String?] {
            let alone = try develop(service, request(handle, stock: stock, maxEdge: 150, negative: reading))
            let same = try develop(service, request(handle, stock: stock, maxEdge: 150, negative: rolled(own)))
            let other = try develop(service, request(handle, stock: stock, maxEdge: 150,
                                                     negative: rolled(warmer)))
            XCTAssertEqual(red(same), red(alone), accuracy: 1e-4, stock ?? "Normal")
            XCTAssertNotEqual(red(other), red(alone), accuracy: 1e-3, stock ?? "Normal")
            // The roll's colour leaves green, which times the frame, where it was.
            XCTAssertEqual(green(other), green(alone), accuracy: 2e-2, stock ?? "Normal")
        }
        // The measurement stays the frame's own whatever roll it is balanced on.
        let onRoll = try service.prepare(JSONSerialization.data(
            withJSONObject: request(handle, maxEdge: 150, negative: rolled(warmer))))
        XCTAssertEqual(onRoll.negativeMeasure?["denseEnd"] as? [Double], dense)
    }

    /// The print stage on the CPU and on the GPU make the same print of a scan.
    func testCPUAndGPUPrintsAgree() throws {
        let (service, engine) = try service()
        defer { fotufilm_engine_destroy(engine) }
        guard service.engine.developer.kind != "cpu", FotufilmEngine.isHalideBackendAvailable else {
            throw XCTSkip("needs both developers")
        }
        let width = 120, height = 80
        let scan = strip(width: width, height: height)
        let stock = try NegativeScanPrint.film("gold200")
        let reading = try NegativeScanPrint.Reading(
            stock: stock, border: border,
            balance: ApproximateNegativeScan.balance(
                stock: stock, border: border,
                preview: HostNegativeScan.planes(scan, width: width, height: height)))
        var edit = FotufilmEngine.Options()
        edit.paper = .crystalArchive
        let options = reading.printing(edit, stock: stock)
        func print(_ developer: HostDeveloper) throws -> [Float] {
            var out = [Float](repeating: 0, count: width * height * 4)
            try developer.printScan(
                width: width, height: height, stock: stock, options: options,
                calibration: reading.calibration, shouldContinue: { true },
                readScan: { rows, into in
                    for (local, y) in rows.enumerated() {
                        for i in 0..<(width * 4) { into[local * width * 4 + i] = scan[y * width * 4 + i] }
                    }
                },
                writeRows: { rows, from in
                    for (local, y) in rows.enumerated() {
                        for i in 0..<(width * 4) { out[y * width * 4 + i] = from[local * width * 4 + i] }
                    }
                })
            return out
        }
        let gpu = try print(service.engine.developer), cpu = try print(HalideCPUDeveloper())
        var worst: Float = 0
        for i in gpu.indices where i % 4 != 3 { worst = max(worst, abs(gpu[i] - cpu[i])) }
        XCTAssertLessThan(worst, 0.01)
    }

    /// Prints the strip through `developer` with `edit`'s light controls on the print.
    private func printStrip(_ developer: HostDeveloper, width: Int = 120, height: Int = 80,
                            edit: FotufilmEngine.Options,
                            finish: PrintFinish? = nil) throws -> [Float] {
        let scan = strip(width: width, height: height)
        let stock = try NegativeScanPrint.film("gold200")
        let reading = try NegativeScanPrint.Reading(
            stock: stock, border: border,
            balance: ApproximateNegativeScan.balance(
                stock: stock, border: border,
                preview: HostNegativeScan.planes(scan, width: width, height: height)))
        var options = reading.printing(edit, stock: stock)
        if let finish { options.printFinish = finish }
        var out = [Float](repeating: 0, count: width * height * 4)
        try developer.printScan(
            width: width, height: height, stock: stock, options: options,
            calibration: reading.calibration, shouldContinue: { true },
            readScan: { rows, into in
                for (local, y) in rows.enumerated() {
                    for i in 0..<(width * 4) { into[local * width * 4 + i] = scan[y * width * 4 + i] }
                }
            },
            writeRows: { rows, from in
                for (local, y) in rows.enumerated() {
                    for i in 0..<(width * 4) { out[y * width * 4 + i] = from[local * width * 4 + i] }
                }
            })
        return out
    }

    /// The print's finish is `PrintFinish.apply` on the print it finishes, on every developer.
    func testLightControlsFinishThePrintAsPrintFinishDoes() throws {
        let (service, engine) = try service()
        defer { fotufilm_engine_destroy(engine) }
        var developers: [HostDeveloper] = [HalideCPUDeveloper()]
        if service.engine.developer.kind != "cpu" { developers.append(service.engine.developer) }
        var edit = FotufilmEngine.Options()
        edit.paper = .crystalArchive
        let finish = PrintFinish(gains: SIMD3(1.2, 1, 0.8), highlights: -0.7, shadows: 0.6,
                                 saturation: 1.3, vibrance: 0.4)
        for developer in developers {
            let plain = try printStrip(developer, edit: edit)
            let finished = try printStrip(developer, edit: edit, finish: finish)
            var worst: Float = 0
            // Where a GPU's delivery clipped the print out of gamut, it finished the unclipped value.
            for i in stride(from: 0, to: plain.count, by: 4)
            where (0..<3).allSatisfy({ plain[i + $0] > 0 }) {
                let expected = finish.apply(SIMD3(plain[i], plain[i + 1], plain[i + 2]))
                for c in 0..<3 {
                    worst = max(worst, abs(finished[i + c] - expected[c]) / max(expected[c], 0.01))
                }
            }
            XCTAssertLessThan(worst, 0.01, developer.name)
        }
    }

    /// Exposure moves an enlarged print about a stop at mid-grey, through the enlarger; warmth
    /// warms it, on paper through filtration and on a screen after the print alike.
    func testExposureAndWarmthReachThePrint() throws {
        let developer = HalideCPUDeveloper()
        func luminance(_ rgba: [Float], _ i: Int) -> Float {
            (SIMD3(rgba[i], rgba[i + 1], rgba[i + 2]) * PrintFinish.luminance).sum()
        }
        var paper = FotufilmEngine.Options()
        paper.paper = .crystalArchive
        let plain = try printStrip(developer, edit: paper)
        // The strip's picture row at mid-grey.
        let width = 120, row = 40
        let pixels = (12..<108).map { (row * width + $0) * 4 }
        let mid = try XCTUnwrap(pixels.min { abs(luminance(plain, $0) - 0.18) < abs(luminance(plain, $1) - 0.18) })
        var brighter = paper
        brighter.exposureEV = 1
        let stops = log2(luminance(try printStrip(developer, edit: brighter), mid) / luminance(plain, mid))
        XCTAssertEqual(stops, 1, accuracy: 0.35)
        for medium in [PrintPaper.crystalArchive, .screen] {
            var edit = FotufilmEngine.Options()
            edit.paper = medium
            let neutral = try printStrip(developer, edit: edit)
            edit.whiteBalance.kelvin = 4500
            let warm = try printStrip(developer, edit: edit)
            XCTAssertGreaterThan(warm[mid] / warm[mid + 2], neutral[mid] / neutral[mid + 2] * 1.1,
                                 medium.rawValue)
        }
    }

    /// Light frames are kept, listed and forgotten; an edit that names one evens out the scan.
    func testLightFramesAreKeptAndEvenTheScan() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-lights-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (service, engine) = try service(lights: directory)
        defer { fotufilm_engine_destroy(engine) }
        let width = 96, height = 64
        func lamp(_ x: Int, _ y: Int) -> Float {
            let dx = Float(x) / Float(width) - 0.5, dy = Float(y) / Float(height) - 0.5
            return 1 - 1.2 * (dx * dx + dy * dy)
        }
        let light = try NegativeLightFrame(linearSRGB: (0..<(width * height * 4)).map { i in
            i % 4 == 3 ? 1 : lamp((i / 4) % width, (i / 4) / width)
        }, width: width, height: height)
        let kept = try service.negativeScans.lights.add(light)
        let listed = try JSONSerialization.jsonObject(with: service.call(
            "negativeLightFrames", params: Data("{}".utf8), payload: nil).json) as? [[String: String]]
        XCTAssertEqual(listed?.map { $0["id"] }, [kept.id])

        // Film of one density on the uneven lamp reads even once the lamp is divided out.
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { for c in 0..<3 {
            rgba[(y * width + x) * 4 + c] = 0.3 * lamp(x, y)
        } } }
        let lights = service.negativeScans.lights
        let scan = HostNegativeScan(scan: HostImage(rgba: rgba, width: width, height: height,
                                                    contentHeadroom: 1)) {
            lights.frame($0)?.measured
        }
        XCTAssertTrue(try scan.image(light: nil) === scan.scan)
        let even = try scan.image(light: kept.id).scene(width: width, height: height)
        XCTAssertTrue(try scan.image(light: kept.id) === scan.image(light: kept.id))
        let centre = even[(32 * width + 48) * 4], corner = even[(4 * width + 4) * 4]
        XCTAssertEqual(corner / centre, 1, accuracy: 0.05)
        XCTAssertLessThan(rgba[(4 * width + 4) * 4] / rgba[(32 * width + 48) * 4], 0.8)

        _ = try service.call("negativeRemoveLightFrame",
                             params: JSONSerialization.data(withJSONObject: ["id": kept.id]),
                             payload: nil)
        XCTAssertTrue(service.negativeScans.lights.all().isEmpty)
        XCTAssertTrue(try scan.image(light: kept.id) === scan.scan)
    }

    #if canImport(ImageIO)
    /// A scan opened from a file as a negative: a document like any photograph's, described with
    /// the films its base looks like and the kept light frames, its linear profile honoured.
    func testOpeningANegativeFileOpensADocument() throws {
        let (service, engine) = try service()
        defer { fotufilm_engine_destroy(engine) }
        let width = 120, height = 80
        let rgba = strip(width: width, height: height)
        var samples = [UInt16](repeating: 65535, count: width * height * 4)
        for i in 0..<(width * height) {
            let srgb = AutomaticNegativeScan.rec2020ToSRGB(SIMD3(rgba[i * 4], rgba[i * 4 + 1],
                                                                 rgba[i * 4 + 2]))
            for c in 0..<3 { samples[i * 4 + c] = UInt16(min(max(srgb[c], 0), 1) * 65535) }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("negative-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = samples.withUnsafeBytes { Data($0) }
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: width * 8, space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let opened = try call(service, "importPath", ["path": url.path, "negative": true])
        let handle = try XCTUnwrap(opened.json["handle"] as? Int)
        XCTAssertEqual(opened.json["naturalWidth"] as? Int, width)
        XCTAssertFalse(opened.payload.isEmpty)
        let negative = try XCTUnwrap(opened.json["negative"] as? [String: Any])
        XCTAssertNotNil(negative["suggestions"] as? [Any])
        XCTAssertNotNil(negative["lightFrames"] as? [Any])
        XCTAssertNotNil(service.negativeScans.scan(handle))

        // The clear film reads back as it was written, through the file's linear profile.
        let sampled = try JSONSerialization.jsonObject(with: service.call(
            "negativeSampleFilmBase",
            params: JSONSerialization.data(withJSONObject: [
                "render": request(handle), "point": [0.5, 0.05]]),
            payload: nil).json) as? [Double]
        for c in 0..<3 {
            XCTAssertEqual(Float(try XCTUnwrap(sampled)[c]), border[c] * pow(10, -0.02),
                           accuracy: 0.01)
        }
        // The same file opened as a photograph is no negative.
        let photo = try call(service, "importPath", ["path": url.path])
        XCTAssertNil(photo.json["negative"])
        XCTAssertNil(service.negativeScans.scan(photo.json["handle"]))
    }

    /// A scan with no colour profile is the scanner's raw output: its samples are linear light,
    /// though ImageIO would read them as sRGB.
    func testAnUntaggedScanIsReadAsLinearSamples() throws {
        let width = 4, height = 2, sample: [Float] = [0.16, 0.2, 0.08]
        // A minimal uncompressed 16-bit RGB TIFF, with no profile.
        var bytes: [UInt8] = Array("II".utf8) + [42, 0, 8, 0, 0, 0]
        func short(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8)] }
        func long(_ v: Int) -> [UInt8] { short(v & 0xffff) + short(v >> 16) }
        let entries: [(tag: Int, type: Int, count: Int, value: Int)] = [
            (256, 3, 1, width), (257, 3, 1, height), (258, 3, 3, 0), (259, 3, 1, 1), (262, 3, 1, 2),
            (273, 4, 1, 0), (277, 3, 1, 3), (278, 3, 1, height), (279, 4, 1, width * height * 6),
            (284, 3, 1, 1),
        ]
        let ifdEnd = 8 + 2 + entries.count * 12 + 4, depths = ifdEnd, pixels = depths + 6
        bytes += short(entries.count)
        for entry in entries {
            let value = entry.tag == 258 ? depths : entry.tag == 273 ? pixels : entry.value
            bytes += short(entry.tag) + short(entry.type) + long(entry.count)
                + (entry.type == 3 && entry.count == 1 ? short(value) + [0, 0] : long(value))
        }
        bytes += long(0) + short(16) + short(16) + short(16)
        for _ in 0..<(width * height) { for v in sample { bytes += short(Int(v * 65535)) } }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("untagged-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(bytes).write(to: url)
        XCTAssertFalse(CoreImageScanDecoder.statesEncoding(Data(bytes)))

        let scan = try CoreImageScanDecoder().decodeScan(url)
        let rgba = scan.scene(width: width, height: height)
        let expected = ColorScience.linearSRGBToRec2020(SIMD3(sample[0], sample[1], sample[2]))
        for c in 0..<3 { XCTAssertEqual(rgba[c], expected[c], accuracy: 0.002) }
    }
    #endif
}
