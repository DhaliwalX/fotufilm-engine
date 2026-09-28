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

    /// Opens a strip held in memory as a session scan.
    private func open(_ service: HostService, width: Int, height: Int) -> Int {
        let image = HostImage(rgba: strip(width: width, height: height), width: width,
                              height: height, contentHeadroom: 1)
        let handle = service.register(image)
        let lights = service.negativeScans.lights
        service.negativeScans.add(HostNegativeScan(scan: image, isRAW: false) {
            lights.frame($0)?.measured
        }, handle: handle)
        return handle
    }

    private func recipeJSON(_ recipe: NegativeScanRecipe) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe))
    }

    // MARK: - Framing

    /// Sizes follow the apps' Core Image framing: turns swap the sides, the crop is the integral
    /// rectangle of the straightened frame and the long edge draws it down.
    func testLayoutMatchesTheAppsRounding() {
        var recipe = NegativeScanRecipe()
        recipe.quarterTurns = 1
        recipe.crop = .init(x: 0.1, y: 0.2, width: 0.8, height: 0.5)
        let layout = HostNegativeScan.layout(scanWidth: 3000, scanHeight: 2000, recipe: recipe,
                                             longEdge: 1000, cropped: true)
        XCTAssertEqual(layout.oriented.width, 2000)
        XCTAssertEqual(layout.oriented.height, 3000)
        XCTAssertEqual(layout.keptWidth, 1600)
        XCTAssertEqual(layout.keptHeight, 1500)
        XCTAssertEqual(layout.width, 1000)
        XCTAssertEqual(layout.height, 937)
        let whole = HostNegativeScan.layout(scanWidth: 300, scanHeight: 200, recipe: recipe,
                                            longEdge: nil, cropped: false)
        XCTAssertEqual([whole.width, whole.height], [200, 300])
    }

    /// Each pixel of a framed picture is the part of the scan the recipe shows there: a quarter
    /// turn clockwise puts the scan's left edge at the top, a flip puts its right edge left.
    func testFramingFollowsTurnsAndFlips() {
        let width = 40, height = 20
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            rgba[(y * width + x) * 4] = Float(x)
            rgba[(y * width + x) * 4 + 1] = Float(y)
        } }
        let image = HostImage(rgba: rgba, width: width, height: height, contentHeadroom: 1)
        var recipe = NegativeScanRecipe()
        recipe.quarterTurns = 1
        let turned = HostNegativeScan.frame(image, recipe: recipe, longEdge: nil, cropped: true,
                                            wide: true, light: nil)
        XCTAssertEqual([turned.width, turned.height], [20, 40])
        // Top-left of the turned picture is the scan's bottom-left.
        XCTAssertEqual(turned.rgba[0], 0, accuracy: 1e-4)
        XCTAssertEqual(turned.rgba[1], 19, accuracy: 1e-4)
        recipe = NegativeScanRecipe()
        recipe.mirrored = true
        let flipped = HostNegativeScan.frame(image, recipe: recipe, longEdge: nil, cropped: true,
                                             wide: true, light: nil)
        XCTAssertEqual(flipped.rgba[0], 39, accuracy: 1e-4)
        XCTAssertEqual(flipped.rgba[1], 0, accuracy: 1e-4)
    }

    #if canImport(CoreImage)
    /// The apps frame with Core Image (`NegativeScan.framed`); the host's arithmetic framing must
    /// show the same picture at the same size for every orientation, straightening and crop.
    func testFramingMatchesCoreImage() throws {
        let width = 360, height = 240
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let u = Float(x) / Float(width), v = Float(y) / Float(height)
            rgba[(y * width + x) * 4] = 0.1 + 0.8 * u
            rgba[(y * width + x) * 4 + 1] = 0.1 + 0.8 * v
            rgba[(y * width + x) * 4 + 2] = 0.3 + 0.2 * sin(6 * u) * cos(4 * v)
        } }
        let image = HostImage(rgba: rgba, width: width, height: height, contentHeadroom: 1)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        let source = CIImage(bitmapData: rgba.withUnsafeBufferPointer { Data(buffer: $0) },
                             bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                             format: .RGBAf, colorSpace: space)
        let context = CIContext(options: [.workingColorSpace: space, .cacheIntermediates: false])
        var recipes: [NegativeScanRecipe] = []
        for turns in 0..<4 {
            for mirrored in [false, true] {
                var recipe = NegativeScanRecipe()
                recipe.quarterTurns = turns
                recipe.mirrored = mirrored
                recipe.straighten = turns == 2 ? -7.5 : 4
                recipe.crop = .init(x: 0.12, y: 0.2, width: 0.7, height: 0.6)
                recipes.append(recipe)
            }
        }
        for recipe in recipes {
            for longEdge in [nil, 120] as [Int?] {
                let ours = HostNegativeScan.frame(image, recipe: recipe, longEdge: longEdge,
                                                  cropped: true, wide: true, light: nil)
                let theirs = coreImageFrame(source, recipe, longEdge: longEdge)
                XCTAssertEqual(ours.width, Int(theirs.extent.width), "\(recipe)")
                XCTAssertEqual(ours.height, Int(theirs.extent.height), "\(recipe)")
                var expected = [Float](repeating: 0, count: ours.width * ours.height * 4)
                context.render(theirs, toBitmap: &expected, rowBytes: ours.width * 16,
                               bounds: CGRect(x: 0, y: 0, width: ours.width, height: ours.height),
                               format: .RGBAf, colorSpace: space)
                var error: Float = 0
                // The outermost pixels meet the resamplers' edge handling (Lanczos reaches past a
                // drawn-down crop); the picture is inside.
                let m = longEdge == nil ? 2 : 4
                for y in m..<(ours.height - m) { for x in m..<(ours.width - m) {
                    for c in 0..<3 {
                        let i = (y * ours.width + x) * 4 + c
                        error = max(error, abs(ours.rgba[i] - expected[i]))
                    }
                } }
                XCTAssertLessThan(error, longEdge == nil ? 1e-3 : 0.01, "turns \(recipe.quarterTurns) mirrored \(recipe.mirrored) edge \(String(describing: longEdge))")
            }
        }
    }

    /// `NegativeScan.framed` from the apps (shared/FotufilmApp/NegativeScanDevelop.swift).
    private func coreImageFrame(_ picture: CIImage, _ recipe: NegativeScanRecipe,
                                longEdge: Int?) -> CIImage {
        func atOrigin(_ image: CIImage) -> CIImage {
            image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                    y: -image.extent.minY))
        }
        var picture = picture
        if recipe.mirrored {
            picture = atOrigin(picture.transformed(by: CGAffineTransform(scaleX: -1, y: 1)))
        }
        let turns = ((recipe.quarterTurns % 4) + 4) % 4
        if turns > 0 {
            picture = atOrigin(picture.transformed(
                by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2)))
        }
        if recipe.straighten != 0 {
            let e = picture.extent
            let scale = NegativeScanRecipe.straightenScale(size: e.size, degrees: recipe.straighten)
            let turn = CGAffineTransform(translationX: -e.midX, y: -e.midY)
                .concatenating(CGAffineTransform(rotationAngle: recipe.straighten * .pi / 180))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY))
            picture = picture.transformed(by: turn).cropped(to: e)
        }
        let e = picture.extent
        let crop = recipe.crop.clamped()
        let rect = CGRect(x: crop.x * e.width, y: (1 - crop.y - crop.height) * e.height,
                          width: crop.width * e.width, height: crop.height * e.height)
            .integral.intersection(e)
        picture = atOrigin(picture.cropped(to: rect))
        guard let longEdge else { return picture }
        let scale = min(1, CGFloat(longEdge) / max(picture.extent.width, picture.extent.height))
        guard scale < 1 else { return picture }
        let width = max(1, (picture.extent.width * scale).rounded(.down))
        let height = max(1, (picture.extent.height * scale).rounded(.down))
        return atOrigin(picture.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1,
        ])).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

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

    // MARK: - The session

    /// Open, preview both readings, sample the border by dragging over the rebate, find the
    /// frame, and import the positive.
    func testSessionPrintsAndImportsThePositive() throws {
        let (service, engine) = try service()
        defer { fotufilm_engine_destroy(engine) }
        let handle = open(service, width: 300, height: 200)
        var recipe = NegativeScanRecipe()

        // Automatic: a positive of the framed scan.
        let automatic = try call(service, "negativeScanRender",
                                 ["handle": handle, "recipe": recipeJSON(recipe), "maxEdge": 150])
        XCTAssertEqual(automatic.json["width"] as? Int, 150)
        XCTAssertEqual(automatic.json["height"] as? Int, 100)
        XCTAssertFalse(automatic.payload.isEmpty)

        // The rebate in the picture's top rows, as a drag over the whole negative marks it.
        let sampled = try call(service, "negativeScanSampleBorder", [
            "handle": handle, "recipe": recipeJSON(recipe),
            "area": ["x": 0.3, "y": 0.02, "width": 0.4, "height": 0.08],
        ]).json
        let measured = try XCTUnwrap(sampled["border"] as? [Double])
        for c in 0..<3 {
            XCTAssertEqual(Float(measured[c]), border[c] * pow(10, -0.02), accuracy: 1e-3)
        }
        recipe.border = measured.map(Float.init)
        recipe.borderArea = try JSONDecoder().decode(
            NegativeScanRecipe.Area.self,
            from: JSONSerialization.data(withJSONObject: sampled["borderArea"]!))

        // Film: gold200 on the display receiver; the light spot prints darker than the thin end.
        recipe.conversion = .film
        recipe.stockID = "gold200"
        let film = try XCTUnwrap(service.negativeScans.scan(handle)
            .print(recipe, longEdge: 150, engine: service.engine))
        let thin = film.rgba[(50 * 150 + 30) * 4 + 1], dense = film.rgba[(50 * 150 + 120) * 4 + 1]
        XCTAssertGreaterThan(dense, thin, "the denser negative prints brighter")
        // The open holder is outside the film's densities and prints black.
        XCTAssertEqual(film.rgba[(50 * 150 + 149) * 4 + 1], 0)

        // Exposure brightens a print on the display receiver only through the screen exposure.
        var brighter = recipe
        brighter.exposure = 1
        let lifted = try service.negativeScans.scan(handle)
            .print(brighter, longEdge: 150, engine: service.engine)
        XCTAssertGreaterThan(lifted.rgba[(50 * 150 + 60) * 4 + 1], film.rgba[(50 * 150 + 60) * 4 + 1])

        // Find Frame crops to the picture between the rebate and the holder.
        let found = try call(service, "negativeScanDetectFrame",
                             ["handle": handle, "recipe": recipeJSON(recipe)]).json
        let crop = try XCTUnwrap(found["crop"] as? [String: Double])
        XCTAssertEqual(crop["x"]!, 0.1, accuracy: 0.03)
        XCTAssertEqual(crop["y"]!, 0.15, accuracy: 0.03)

        // The committed positive is a new photograph at the scan's full size.
        recipe.quarterTurns = 1
        let committed = try call(service, "negativeScanCommit",
                                 ["handle": handle, "recipe": recipeJSON(recipe)]).json
        XCTAssertEqual(committed["naturalWidth"] as? Int, 200)
        XCTAssertEqual(committed["naturalHeight"] as? Int, 300)
        XCTAssertNotEqual(committed["handle"] as? Int, handle)

        // A slide has no negative to read.
        recipe.stockID = try XCTUnwrap(FilmStock.presetIDs.first { FilmStock.presets[$0]!.isReversal })
        XCTAssertThrowsError(try call(service, "negativeScanRender",
                                      ["handle": handle, "recipe": recipeJSON(recipe)]))
        _ = try call(service, "release", ["handle": handle])
        XCTAssertThrowsError(try service.negativeScans.scan(handle))
    }

    /// The print stage on the CPU and on the GPU make the same print of a scan.
    func testCPUAndGPUPrintsAgree() throws {
        let (service, engine) = try service()
        defer { fotufilm_engine_destroy(engine) }
        guard service.engine.developer.kind != "cpu", FotufilmEngine.isHalideBackendAvailable else {
            throw XCTSkip("needs both developers")
        }
        let width = 120, height = 80
        let scan = HostImage(rgba: strip(width: width, height: height), width: width,
                             height: height, contentHeadroom: 1)
        var recipe = NegativeScanRecipe()
        recipe.conversion = .film
        recipe.stockID = "gold200"
        recipe.paperID = PrintPaper.crystalArchive.rawValue
        let stock = try NegativeScanPrint.film("gold200")
        let framed = HostNegativeScan.frame(scan, recipe: recipe, longEdge: nil, cropped: true,
                                            wide: true, light: nil)
        let film = try NegativeScanPrint.film(
            recipe, stock: stock, border: [border.x, border.y, border.z],
            balance: ApproximateNegativeScan.balance(stock: stock, border: border,
                                                     preview: HostNegativeScan.planes(framed)))
        func print(_ developer: HostDeveloper) throws -> [Float] {
            var out = [Float](repeating: 0, count: width * height * 4)
            try developer.printScan(
                width: width, height: height, stock: stock, options: film.options,
                calibration: film.calibration, shouldContinue: { true },
                readScan: { rows, into in
                    for (local, y) in rows.enumerated() {
                        for i in 0..<(width * 4) { into[local * width * 4 + i] = framed.rgba[y * width * 4 + i] }
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

    /// Light frames are kept, listed and forgotten; a recipe that names one evens out the scan.
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
        let image = HostImage(rgba: rgba, width: width, height: height, contentHeadroom: 1)
        var recipe = NegativeScanRecipe()
        recipe.lightFrameID = kept.id
        let even = HostNegativeScan.frame(image, recipe: recipe, longEdge: nil, cropped: true,
                                          wide: true, light: service.negativeScans.lights
                                            .frame(kept.id)?.measured)
        let centre = even.rgba[(32 * width + 48) * 4], corner = even.rgba[(4 * width + 4) * 4]
        XCTAssertEqual(corner / centre, 1, accuracy: 0.05)
        XCTAssertLessThan(rgba[(4 * width + 4) * 4] / rgba[(32 * width + 48) * 4], 0.8)

        _ = try service.call("negativeRemoveLightFrame",
                             params: JSONSerialization.data(withJSONObject: ["id": kept.id]),
                             payload: nil)
        XCTAssertTrue(service.negativeScans.lights.all().isEmpty)
    }

    #if canImport(ImageIO)
    /// A scan opened from a file: the answer lists the negative films with their receivers,
    /// starts on an installed film, and offers the scan encoding for a non-RAW file.
    func testOpeningAScanFileDescribesTheSession() throws {
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

        let opened = try call(service, "negativeScanOpen", ["path": url.path]).json
        let handle = try XCTUnwrap(opened["handle"] as? Int)
        XCTAssertEqual(opened["naturalWidth"] as? Int, width)
        XCTAssertEqual(opened["raw"] as? Bool, false)
        let films = try XCTUnwrap(opened["films"] as? [[String: Any]])
        XCTAssertTrue(films.contains { $0["id"] as? String == "gold200" })
        XCTAssertFalse(films.contains {
            FilmStock.presets[$0["id"] as! String]!.isReversal
        })
        let gold = try XCTUnwrap(films.first { $0["id"] as? String == "gold200" })
        XCTAssertEqual((gold["papers"] as? [[String: String]])?.first?["id"], PrintPaper.screen.rawValue)
        XCTAssertEqual((opened["recipe"] as? [String: Any])?["stockID"] as? String, "gold200")

        // The clear film reads back as it was written, through the file's linear profile.
        let scan = try service.negativeScans.scan(handle)
        let sampled = try scan.border(in: .init(x: 0.4, y: 0.02, width: 0.2, height: 0.08),
                                      light: nil)
        for c in 0..<3 {
            XCTAssertEqual(sampled[c], border[c] * pow(10, -0.02), accuracy: 0.01)
        }
        let negative = try call(service, "negativeScanRender", [
            "handle": handle, "recipe": opened["recipe"]!, "negative": true, "cropped": false,
        ])
        XCTAssertEqual(negative.json["width"] as? Int, width)
    }
    #endif
}
