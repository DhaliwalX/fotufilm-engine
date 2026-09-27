import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// The web editor's native backend (`web/src/backend/macos/host.js`) answered in Swift: every
/// call is a method name, JSON parameters and optional bytes, and every answer JSON plus named
/// byte ranges of one payload. A host only moves messages; what they mean lives here.
public final class HostService {
    public struct Answer {
        public var json: Data
        public var payload: [UInt8]
    }

    public unowned let engine: HostEngine
    private let lock = NSLock()
    private var images: [Int: HostImage] = [:]
    private var nextHandle = 1
    /// The last develop, kept so panning a zoomed picture only cuts new tiles from it.
    private var developed: (key: String, width: Int, height: Int, pixels: [UInt8])?
    private var originals: (key: String, width: Int, height: Int, pixels: [UInt8])?
    /// Movie uploads in progress (`HostService+Video.swift`).
    let videos = HostVideoLibrary()

    /// Where Copy Photo puts the picture, when the platform has a clipboard; tests use a private
    /// one.
    var clipboard: HostClipboard? = HostPlatform.current.clipboard
    /// Installs the plug-ins for other editors, when the platform has them; tests install into a
    /// temporary directory.
    var plugins: HostPluginInstaller? = HostPlatform.current.plugins
    /// What this person has chosen before, for Choose Film Per Photo; tests use their own file.
    var filmPreferences = HostFilmPreferences(file: HostFilmPreferences.defaultFile)

    public init(engine: HostEngine) {
        self.engine = engine
    }

    public func call(_ method: String, params: Data, payload: UnsafeRawBufferPointer?) throws -> Answer {
        let parameters = (try? JSONSerialization.jsonObject(with: params)) as? [String: Any] ?? [:]
        switch method {
        case "prepare":
            return try answer(["stocks": engine.stockIDs, "backend": engine.backendName,
                               "catalogue": try catalogue()])
        case "import":
            guard let payload, payload.count > 0 else {
                throw HostEngine.Failure(description: "The photograph's bytes did not arrive.")
            }
            return try importImage(name: parameters["name"] as? String ?? "photo",
                                   bytes: payload)
        case "importPath":
            // A file the host chose (open panel, Finder, a drop): read in place, so its bytes
            // never cross the bridge.
            guard let path = parameters["path"] as? String, !path.isEmpty else {
                throw HostEngine.Failure(description: "No file was named.")
            }
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw HostEngine.Failure(
                    description: "\(URL(fileURLWithPath: path).lastPathComponent) cannot be read.")
            }
            let url = URL(fileURLWithPath: path)
            if HostPlatform.current.videoSource?.isMovie(url) == true,
               parameters["negative"] as? Bool != true {
                return try importMovie(at: url, owned: false,
                                       playback: parameters["playback"] as? Bool == true)
            }
            let image = try HostImage.open(url)
            // A camera RAW read in place can be exported as itself.
            if image.isRAW { image.originalFile = url }
            return try imported(image)
        case "exportOriginal":
            return try answer(exportOriginal(parameters))
        case "preview":
            let image = try self.image(parameters["handle"])
            return try answer(image.descriptor, images: ["preview": previewPNG(image)])
        case "release":
            if let handle = parameters["handle"] as? Int {
                lock.lock()
                images[handle] = nil
                lock.unlock()
            }
            videos.release(parameters["handle"])
            return try answer([:])
        case "render":
            return try render(params)
        case "beginVideo", "appendVideo", "importVideo", "exportVideo":
            return try video(method, params: params, payload: payload, progress: nil)
        case "lensPlan":
            let image = try self.image(parameters["handle"])
            let lens = try JSONDecoder().decode(
                SceneGeometry.Lens.self,
                from: JSONSerialization.data(withJSONObject: parameters["lens"] ?? [:]))
            return Answer(json: try JSONEncoder().encode(lensPlan(image, lens)), payload: [])
        case "analyseNegative":
            let image = try self.image(parameters["handle"])
            let plan = try AutomaticNegativeScan(preview: negativePreview(image, rec2020: false),
                                                 monochrome: parameters["monochrome"] as? Bool ?? false)
            return try answer(["weak": plan.weak, "sampleCount": plan.sampleCount,
                               "parameters": plan.parameters,
                               "nativePlan": ["parameters": plan.parameters]])
        case "convertNegative":
            return try convertNegative(parameters)
        case "suggestNegativeFilms":
            let image = try self.image(parameters["handle"])
            let catalogue = NegativeFilmSuggestions(stocks: FilmStock.presets)
            let reading = NegativeFilmSuggestions.read(preview: negativePreview(image, rec2020: true))
            let suggestions = reading.map { catalogue.suggest($0, limit: 3) } ?? []
            return try answer(value: suggestions.map { suggestion -> [String: Any] in
                ["films": suggestion.films.map { ["id": $0.id, "name": $0.name] },
                 "likelihood": suggestion.likelihood]
            })
        case "stages":
            return try answer(value: stages(parameters))
        case "printFrame":
            return Answer(json: try HostFrames.answer(parameters), payload: [])
        case "autoAdjust":
            return try answer(autoAdjust(params))
        case "sampleScene":
            return try answer(value: sampleScene(parameters))
        case "export":
            return try answer(export(params, parameters: parameters))
        case "exportOptions":
            return try answer(exportOptions(parameters))
        case "suggestFilm":
            return try answer(suggestFilm(parameters))
        case "recordFilmChoice":
            guard let photoID = parameters["photoID"] as? String,
                  let film = parameters["film"] as? String else {
                throw HostEngine.Failure(description: "A film choice needs a photograph and a film.")
            }
            filmPreferences.record(photoID: photoID, chosenFilmID: film)
            return try answer(["observations": filmPreferences.observationCount])
        case "forgetFilmChoices":
            filmPreferences.forget()
            return try answer([:])
        case "copyImage":
            return try answer(copyImage(parameters))
        case "plugins", "installPlugin", "revealPlugin":
            return try plugin(method, parameters)
        case "lensCatalogue":
            let data = Self.lensCatalogueURL.flatMap { try? Data(contentsOf: $0) }
            let profiles = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
            return try answer(value: profiles)
        case "importLensCatalogue":
            guard let profiles = parameters["profiles"] as? [Any], let url = Self.lensCatalogueURL else {
                throw HostEngine.Failure(description: "Choose a Fotufilm lens-profile JSON catalogue.")
            }
            let data = try JSONSerialization.data(withJSONObject: profiles)
            let catalogue = try LensCatalogue.load(from: data)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return try answer(value: catalogue.profiles.count)
        case "removeLensCatalogue":
            if let url = Self.lensCatalogueURL { try? FileManager.default.removeItem(at: url) }
            return try answer(value: NSNull())
        default:
            throw HostEngine.Failure(description: "\(method) is not available in this host yet.")
        }
    }

    private var catalogueEntries: [[String: Any]]?

    /// The film library, built once: the screen conversions solve their meter tables.
    private func catalogue() throws -> [[String: Any]] {
        if let catalogueEntries { return catalogueEntries }
        let entries = try WebStockCatalogue.entries()
        catalogueEntries = entries
        return entries
    }

    // MARK: Images

    func image(_ handle: Any?) throws -> HostImage {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = handle as? Int, let image = images[handle] else {
            throw HostEngine.Failure(description: "That photograph is no longer open.")
        }
        return image
    }

    private func importImage(name: String, bytes: UnsafeRawBufferPointer) throws -> Answer {
        // The decoders read files, and RAW decoding wants the extension as its hint.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-import", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            UUID().uuidString + "." + (URL(fileURLWithPath: name).pathExtension))
        try Data(bytes: bytes.baseAddress!, count: bytes.count).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try imported(HostImage.open(file))
    }

    /// Export Original: the camera RAW file itself, copied where the save panel chose. No edit
    /// and no size applies, as in the Mac app.
    private func exportOriginal(_ parameters: [String: Any]) throws -> [String: Any] {
        let image = try self.image(parameters["handle"])
        guard let source = image.originalFile else {
            throw HostEngine.Failure(description: "Export Original needs a camera RAW opened from a file.")
        }
        guard let path = parameters["path"] as? String, !path.isEmpty else {
            throw HostEngine.Failure(description: "No destination was chosen.")
        }
        let destination = URL(fileURLWithPath: path)
        if destination.standardizedFileURL != source.standardizedFileURL {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return ["filename": destination.lastPathComponent]
    }

    /// Keeps a decoded photograph under a new handle and describes it to the editor.
    private func imported(_ image: HostImage) throws -> Answer {
        var descriptor = image.descriptor
        descriptor["handle"] = register(image)
        return try answer(descriptor, images: ["preview": previewPNG(image)])
    }

    /// Opens a lease on a photograph the host already holds; the editor releases it.
    @discardableResult
    public func register(_ image: HostImage) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let handle = nextHandle
        nextHandle += 1
        images[handle] = image
        return handle
    }

    /// The photograph as decoded, bounded for the library and the strip.
    func previewPNG(_ image: HostImage) -> [UInt8] {
        let size = image.renderSize(maxEdge: 2048)
        let pixels = image.display(image.scene(width: size.width, height: size.height),
                                   width: size.width, height: size.height)
        return pixels.withUnsafeBytes {
            StoredPNG.encode($0.baseAddress!, width: size.width, height: size.height,
                             rowBytes: size.width * 4)
        }
    }

    // MARK: Rendering

    struct RenderRequest: Decodable {
        struct Viewport: Decodable {
            struct Region: Decodable { var x, y, width, height: Int }
            var width: Int
            var height: Int
            var region: Region
        }
        var handle: Int
        var maxEdge: Int?
        var cropMode: Bool?
        var viewport: Viewport?
        var edit: SceneGeometry
    }

    /// A render request resolved against its photograph: the geometry, the sizes it delivers at,
    /// and the edit as the engine reads it.
    struct Prepared {
        var request: RenderRequest
        var edit: WebNativeEdit
        var image: HostImage
        var geometry: SceneGeometry
        var maxEdge: Int?
        var sizes: (frame: (Int, Int), output: (Int, Int))
    }

    func prepare(_ params: Data) throws -> Prepared {
        let request: RenderRequest, edit: WebNativeEdit
        do {
            request = try JSONDecoder().decode(RenderRequest.self, from: params)
            edit = try JSONDecoder().decode(WebNativeEdit.self, from: params)
        } catch {
            throw HostEngine.Failure(description: "Unreadable render request: \(error)")
        }
        let image = try self.image(request.handle)
        image.video?.select(params)
        let geometry = request.cropMode == true ? request.edit.uncropped() : request.edit
        // A viewport asks for part of a larger virtual picture: develop the whole frame at that
        // size, bounded by the photograph's own pixels, and cut the region out of it.
        var maxEdge = request.maxEdge
        let full = geometry.sizes(width: image.width, height: image.height, maxEdge: nil)
        if let viewport = request.viewport {
            let ratio = Double(max(viewport.width, viewport.height))
                / Double(max(full.output.0, full.output.1))
            maxEdge = ratio >= 1 ? nil
                : max(1, Int((Double(max(full.frame.0, full.frame.1)) * ratio).rounded()))
        }
        // A limit at or past the photograph's own size is no limit, and keys the same develop.
        if let limit = maxEdge, limit <= 0 || limit >= max(full.frame.0, full.frame.1) { maxEdge = nil }
        let sizes = geometry.sizes(width: image.width, height: image.height, maxEdge: maxEdge)
        return Prepared(request: request, edit: edit, image: image, geometry: geometry,
                        maxEdge: maxEdge, sizes: sizes)
    }

    private func render(_ params: Data) throws -> Answer {
        let started = DispatchTime.now().uptimeNanoseconds
        let prepared = try prepare(params)
        let (request, image, geometry) = (prepared.request, prepared.image, prepared.geometry)
        let (maxEdge, sizes) = (prepared.maxEdge, prepared.sizes)
        let (width, height) = sizes.output
        var body = (try? JSONSerialization.jsonObject(with: params)) as? [String: Any] ?? [:]

        // A frame surrounds the whole picture, never a tile of it, and changes how it develops.
        let plan = request.viewport == nil
            ? try (body["printFrame"] as? [String: Any]).flatMap {
                try HostFrames.plan($0, width: width, height: height)
            }
            : nil
        var edit = prepared.edit
        if let plan {
            HostFrames.settings(&body, for: plan)
            edit = try JSONDecoder().decode(WebNativeEdit.self,
                                            from: JSONSerialization.data(withJSONObject: body))
        }

        // Cache keys: everything but the viewport decides the developed frame.
        let sceneKey = "\(request.handle)|\(image.frameKey)|\(maxEdge ?? 0)|\(request.cropMode == true)|\(geometry)"
        var keyed = body
        for name in ["viewport", "maxEdge", "handle", "haveOriginal"] { keyed[name] = nil }
        let developKey = sceneKey + "|" + String(decoding: (try? JSONSerialization.data(
            withJSONObject: keyed, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        let frameKey = sceneKey + "|" + String(describing: plan?.json["placement"] ?? "")

        let scene = try sceneFor(image, geometry: geometry, sizes: sizes)
        var renderMilliseconds = 0.0
        if developed?.key != developKey {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let developStart = DispatchTime.now().uptimeNanoseconds
            if let stage = body["stage"] as? Int {
                pixels = try developStage(stage, difference: body["difference"] as? Bool ?? false,
                                          scene: scene, width: width, height: height,
                                          image: image, edit: edit)
            } else {
                pixels = try developSelective(scene, width: width, height: height, image: image,
                                              edit: edit, body: body,
                                              cropMode: request.cropMode == true)
            }
            renderMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - developStart) / 1e6
            var frame = (pixels: pixels, width: width, height: height)
            if let plan, let framed = HostFrames.frame(pixels, width: width, height: height, plan: plan) {
                frame = framed
            }
            developed = (developKey, frame.width, frame.height, frame.pixels)
        }
        if originals?.key != frameKey {
            var frame = (pixels: image.display(scene, width: width, height: height),
                         width: width, height: height)
            if let plan, let framed = HostFrames.frame(frame.pixels, width: width, height: height,
                                                       plan: plan) {
                frame = framed
            }
            originals = (frameKey, frame.width, frame.height, frame.pixels)
        }
        let developedFrame = developed!, originalFrame = originals!
        let (frameWidth, frameHeight) = (developedFrame.width, developedFrame.height)

        // The region of the picture to deliver, in developed pixels.
        var region = (x: 0, y: 0, width: frameWidth, height: frameHeight)
        if let viewport = request.viewport {
            let sx = Double(width) / Double(viewport.width)
            let sy = Double(height) / Double(viewport.height)
            let x = max(0, min(width - 1, Int((Double(viewport.region.x) * sx).rounded(.down))))
            let y = max(0, min(height - 1, Int((Double(viewport.region.y) * sy).rounded(.down))))
            let right = min(width, Int((Double(viewport.region.x + viewport.region.width) * sx)
                .rounded(.up)))
            let bottom = min(height, Int((Double(viewport.region.y + viewport.region.height) * sy)
                .rounded(.up)))
            region = (x, y, max(1, right - x), max(1, bottom - y))
        }
        func png(_ frame: (key: String, width: Int, height: Int, pixels: [UInt8])) -> [UInt8] {
            frame.pixels.withUnsafeBytes {
                StoredPNG.encode($0.baseAddress! + (region.y * frame.width + region.x) * 4,
                                 width: region.width, height: region.height,
                                 rowBytes: frame.width * 4)
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        var answerBody: [String: Any] = [
            "width": region.width, "height": region.height, "colorSpace": "display-p3",
            "previewType": "image/png", "backend": engine.backendName,
            "elapsed": elapsed, "renderMilliseconds": renderMilliseconds,
        ]
        if let plan { answerBody["framePlan"] = plan.json }
        // How many subjects a subject selection found, for the inspector's status.
        if ((body["edit"] as? [String: Any])?["selective"] as? [String: Any])?["kind"] as? String
            == "subject", request.cropMode != true {
            answerBody["subjects"] = subjectCache?.subject?.count ?? 0
        }
        // The undeveloped picture changes only with the photograph, geometry and region: the
        // page names the one it holds and it crosses again only when it differs.
        let originalKey = "\(originalFrame.key)|\(region)"
        answerBody["originalKey"] = originalKey
        var images = ["preview": png(developedFrame)]
        if body["haveOriginal"] as? String != originalKey { images["original"] = png(originalFrame) }
        return try answer(answerBody, images: images)
    }

    /// The photograph's develop, with a selective adjustment blended over it when the edit has
    /// one and the crop tool is not showing.
    private func developSelective(_ scene: [Float], width: Int, height: Int, image: HostImage,
                                  edit: WebNativeEdit, body: [String: Any],
                                  cropMode: Bool) throws -> [UInt8] {
        func develop(_ edit: WebNativeEdit) throws -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                try engine.develop(scene, width: width, height: height,
                                   contentHeadroom: image.contentHeadroom, edit: edit,
                                   frameIndex: image.pace.frameIndex,
                                   realtime: image.pace.realtime,
                                   into: .init(maxEdge: 0, format: .rgba8DisplayP3,
                                               pixels: buffer.baseAddress!, rowBytes: width * 4,
                                               capacity: buffer.count))
            }
            return pixels
        }
        let ground = try develop(edit)
        guard !cropMode,
              let saved = (body["edit"] as? [String: Any])?["selective"] as? [String: Any]
        else { return ground }
        let selection = try JSONDecoder().decode(HostSelection.self,
                                                 from: JSONSerialization.data(withJSONObject: saved))
        guard selection.isActive else { return ground }
        let showMask = body["showMask"] as? Bool ?? false
        var subject: [Float]?
        if selection.isSubject {
            // With nobody found the photograph stays as it is and the inspector says so.
            guard let found = subjects(scene, width: width, height: height, image: image),
                  found.count > 0 else { return ground }
            subject = found.weights(at: selection.point, width: width, height: height,
                                    edge: selection.subjectEdge,
                                    feather: selection.subjectFeather)
        }
        let selected = showMask ? nil : try develop(selection.develop(edit))
        return selection.composite(ground: ground, selected: selected, scene: scene, width: width,
                                   height: height, showMask: showMask, subject: subject)
    }

    private var subjectCache: (key: String, subject: HostSubject?)?

    /// Subject detection over the framed photograph, kept per photograph and geometry: the model
    /// sees the picture at no more than 1024 pixels, so a preview and an export share a reading.
    func subjects(_ scene: [Float], width: Int, height: Int, image: HostImage) -> HostSubject? {
        let key = sceneCache.map { $0.key.split(separator: "|").prefix(2).joined(separator: "|") }
            ?? "\(ObjectIdentifier(image))"
        if let subjectCache, subjectCache.key == key { return subjectCache.subject }
        let scale = min(1, 1024 / Double(max(width, height)))
        let (w, h) = (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
        let reduced = scale < 1 ? AreaResample.reduce(scene, width: width, height: height, to: w, h)
                                : scene
        let subject = HostPlatform.current.subjects?.detect(
            image.display(reduced, width: w, height: h), width: w, height: h)
        subjectCache = (key, subject)
        return subject
    }

    // MARK: Pipeline walk

    /// The walk's steps for a film, as the pipeline inspector lists them. Layered transport
    /// develops in one piece and has none, as in the browser.
    private func stages(_ parameters: [String: Any]) throws -> [[String: Any]] {
        guard parameters["halationModel"] as? String != "layered",
              let stock = engine.stock(parameters["stock"] as? String) else { return [] }
        var settings: [String: Any] = ["controls": [
            "digitalReference": parameters["digitalReference"] as? String ?? "auto-levels"]]
        if let medium = parameters["medium"] as? String { settings["medium"] = medium }
        let edit = try JSONDecoder().decode(WebNativeEdit.self, from: JSONSerialization.data(
            withJSONObject: ["edit": ["stock": parameters["stock"]!], "profileRequest": settings]))
        let options = try engine.options(edit, stock: stock, contentHeadroom: 1)
        return PipelineWalk.steps(stock: stock, options: options).map { ["id": $0.id, "label": $0.label] }
    }

    /// One step of the walk, or its difference from the step before, amplified as the browser
    /// amplifies it: a peak change under half a code value shows as is, a larger one is scaled so
    /// it fills the range about mid-grey.
    private func developStage(_ index: Int, difference: Bool, scene: [Float], width: Int,
                              height: Int, image: HostImage, edit: WebNativeEdit) throws -> [UInt8] {
        guard let stock = engine.stock(edit.edit.stock) else {
            throw HostEngine.Failure(description: "Pipeline inspection needs a film.")
        }
        let steps = PipelineWalk.steps(stock: stock, options: try engine.options(
            edit, stock: stock, contentHeadroom: image.contentHeadroom))
        guard steps.indices.contains(index) else {
            throw HostEngine.Failure(description: "This pipeline stage is unavailable.")
        }
        func develop(_ step: PipelineWalk.Step) throws -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                try engine.develop(scene, width: width, height: height, film: step.stock,
                                   options: step.options,
                                   into: .init(maxEdge: 0, format: .rgba8DisplayP3,
                                               pixels: buffer.baseAddress!, rowBytes: width * 4,
                                               capacity: buffer.count))
            }
            return pixels
        }
        let pixels = try develop(steps[index])
        guard difference, index > 0 else { return pixels }
        let before = try develop(steps[index - 1])
        var peak: Float = 0
        for i in pixels.indices where i % 4 != 3 {
            peak = max(peak, abs(Float(pixels[i]) - Float(before[i])))
        }
        let gain: Float = peak < 0.5 ? 1 : min(128, 127 / peak)
        return pixels.indices.map { i in
            i % 4 == 3 ? 255
                : UInt8(clamp(128 + (Float(pixels[i]) - Float(before[i])) * gain, 0, 255))
        }
    }

    // MARK: Negatives

    /// The 512-pixel planar copy of a scan the automatic analyses read, in linear sRGB for the
    /// inversion's statistics or linear Rec.2020 for reading the film base.
    private func negativePreview(_ image: HostImage, rec2020: Bool) -> ImageBuffer {
        let (width, height) = image.renderSize(maxEdge: 512)
        return planes(image.scene(width: width, height: height), width: width, height: height,
                      sRGB: !rec2020)
    }

    private func planes(_ rgba: [Float], width: Int, height: Int, sRGB: Bool) -> ImageBuffer {
        var buffer = ImageBuffer(width: width, height: height)
        for i in 0..<(width * height) {
            var rgb = SIMD3(rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2])
            if sRGB { rgb = AutomaticNegativeScan.rec2020ToSRGB(rgb) }
            for c in 0..<3 { buffer.planes[c][i] = rgb[c] }
        }
        return buffer
    }

    /// Inverts the scan with the plan the analysis solved, the contrast adjusted as the browser
    /// adjusts it, into a new photograph the editor owns.
    private func convertNegative(_ parameters: [String: Any]) throws -> Answer {
        let image = try self.image(parameters["handle"])
        guard var solved = (parameters["nativePlan"] as? [String: Any])?["parameters"] as? [Double],
              solved.count == 8, solved.allSatisfy(\.isFinite) else {
            throw HostEngine.Failure(description: "Invalid negative conversion settings.")
        }
        // The inverse sigmoid's slope at mid-grey (web/src/negative-conversion.js).
        solved[6] *= pow(2, parameters["contrast"] as? Double ?? 0)
        let (width, height) = image.renderSize(maxEdge: parameters["maxEdge"] as? Int ?? 0)
        let scan = planes(image.scene(width: width, height: height), width: width, height: height,
                          sRGB: true)
        let positive = try AutomaticNegativeScan(parameters: solved.map(Float.init)).convert(scan)
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            let rgb = ColorScience.linearSRGBToRec2020(SIMD3(positive.planes[0][i],
                                                             positive.planes[1][i],
                                                             positive.planes[2][i]))
            rgba[i * 4] = rgb.x
            rgba[i * 4 + 1] = rgb.y
            rgba[i * 4 + 2] = rgb.z
        }
        let converted = HostImage(rgba: rgba, width: width, height: height, contentHeadroom: 1)
        converted.lensShot = image.lensShot
        var descriptor = converted.descriptor
        descriptor["handle"] = register(converted)
        return try answer(descriptor, images: ["preview": previewPNG(converted)])
    }

    // MARK: Measuring and exporting

    /// Exposure, highlights and shadows solved against the film's latitude from the framed
    /// scene's regional stops, as the Mac app's Auto does (`DesktopEditorModel`).
    private func autoAdjust(_ params: Data) throws -> [String: Any] {
        var body = (try? JSONSerialization.jsonObject(with: params)) as? [String: Any] ?? [:]
        let edit = body["edit"] as? [String: Any] ?? [:]
        body["maxEdge"] = 1024
        body["profileRequest"] = body["profileRequest"] ?? [:]
        let prepared = try prepare(JSONSerialization.data(withJSONObject: body))
        let scene = try sceneFor(prepared.image, geometry: prepared.geometry, sizes: prepared.sizes)
        let (width, height) = prepared.sizes.output
        var measurement = ToneBaseMeasurement(frameWidth: width, frameHeight: height,
                                              balance: SIMD3(1, 1, 1), exposureGain: 1)
        scene.withUnsafeBufferPointer { measurement.add(linearRGBA: $0.baseAddress!, rows: 0..<height) }
        let window: (shadows: Float, highlights: Float)
        if let id = edit["stock"] as? String {
            guard let stock = FilmStock.presets[id] else {
                throw HostEngine.Failure(description: "Film \(id) is not installed.")
            }
            let correction = ((edit["profile"] as? [String: Any])?["printCorrection"] as? Double) ?? 0
            window = AutoAdjustment.latitude(stock: stock, printCorrection: Float(correction))
        } else {
            window = PlainDevelop.latitude
        }
        guard let stops = AutoAdjustment.SceneStops(regionStops: measurement.regionStops()) else {
            return ["ev": 0, "highlights": 0, "shadows": 0]
        }
        let solution = AutoAdjustment.solve(scene: stops, window: window)
        return ["ev": Double(min(max(solution.exposureEV, -3), 3)),
                "highlights": Double(min(max(solution.highlights, -1), 1)),
                "shadows": Double(min(max(solution.shadows, -1), 1))]
    }

    /// Scene-linear Rec.2020 at a point of the framed photograph, in unit coordinates.
    private func sampleScene(_ parameters: [String: Any]) throws -> Any {
        guard var render = parameters["render"] as? [String: Any],
              let point = parameters["point"] as? [Double], point.count == 2,
              (0...1).contains(point[0]), (0...1).contains(point[1]) else { return NSNull() }
        render["viewport"] = nil
        let prepared = try prepare(JSONSerialization.data(withJSONObject: render))
        let scene = try sceneFor(prepared.image, geometry: prepared.geometry, sizes: prepared.sizes)
        let (width, height) = prepared.sizes.output
        let x = min(width - 1, Int(point[0] * Double(width)))
        let y = min(height - 1, Int(point[1] * Double(height)))
        // A 5 x 5 mean, so a sample is the colour there rather than one grain of noise.
        var sum = SIMD3<Double>(repeating: 0), count = 0.0
        for sy in max(0, y - 2)...min(height - 1, y + 2) {
            for sx in max(0, x - 2)...min(width - 1, x + 2) {
                let i = (sy * width + sx) * 4
                sum += SIMD3(Double(scene[i]), Double(scene[i + 1]), Double(scene[i + 2]))
                count += 1
            }
        }
        return [sum.x / count, sum.y / count, sum.z / count]
    }

    /// Develops the whole frame at the export size and writes it where the host's save panel said.
    private func export(_ params: Data, parameters: [String: Any]) throws -> [String: Any] {
        guard let path = parameters["path"] as? String else {
            throw HostEngine.Failure(description: "No destination was chosen.")
        }
        guard let encoder = HostPlatform.current.encoder else {
            throw HostEngine.Failure(description: "This build has no image encoder.")
        }
        let type = parameters["type"] as? String ?? "image/png"
        let quality = (parameters["quality"] as? Double).map { min(max($0, 0.01), 1) } ?? 0.95
        var still = try developStill(parameters, deep: type == "image/tiff",
                                     hdr: type == "image/heic" && parameters["hdr"] as? Bool == true
                                        && encoder.writesHDR)
        still.metadata = (parameters["metadata"] as? String).flatMap(HostMetadataPolicy.init)
            ?? .default
        let written = try encoder.write(still, type: type, quality: quality,
                                        to: URL(fileURLWithPath: path))
        return ["filename": URL(fileURLWithPath: path).lastPathComponent, "width": written.width,
                "height": written.height, "hdr": still.hlg != nil]
    }

    /// The developed picture on the clipboard, as the Mac app's Copy Photo puts it: the print as
    /// it stands, in 8-bit Display P3.
    private func copyImage(_ parameters: [String: Any]) throws -> [String: Any] {
        guard let clipboard else {
            throw HostEngine.Failure(description: "This host has no clipboard.")
        }
        var still = try developStill(parameters, deep: false, hdr: false)
        still.metadata = .strip
        let copied = try clipboard.copy(still)
        return ["width": copied.width, "height": copied.height]
    }

    /// What the export dialog may offer for this edit: HDR only where the platform writes it and
    /// the film delivers light above display white (`supportsHDRDelivery`), as the Mac app's
    /// export sheet decides.
    private func exportOptions(_ parameters: [String: Any]) throws -> [String: Any] {
        let prepared = try prepare(JSONSerialization.data(withJSONObject: parameters))
        return [
            "metadata": HostMetadataPolicy.allCases.map(\.rawValue),
            "hdr": (HostPlatform.current.encoder?.writesHDR ?? false)
                && parameters["printFrame"] as? [String: Any] == nil
                && deliversHDR(prepared.edit),
        ]
    }

    func deliversHDR(_ edit: WebNativeEdit) -> Bool {
        guard let stock = engine.stock(edit.edit.stock) else { return true }
        return (try? engine.options(edit, stock: stock, contentHeadroom: 1))?
            .supportsHDRDelivery(for: stock) ?? false
    }

    /// The whole frame of a render request at its delivered size, print frame included: 8-bit
    /// Display P3, or 16-bit when `deep`, and the HLG picture beside it when `hdr` and the film
    /// delivers one.
    private func developStill(_ parameters: [String: Any], deep: Bool, hdr: Bool) throws
        -> HostStill {
        var body = parameters
        body["viewport"] = nil
        var prepared = try prepare(JSONSerialization.data(withJSONObject: body))
        let scene = try sceneFor(prepared.image, geometry: prepared.geometry, sizes: prepared.sizes)
        let (width, height) = prepared.sizes.output
        let plan = try (body["printFrame"] as? [String: Any]).flatMap {
            try HostFrames.plan($0, width: width, height: height)
        }
        if let plan {
            HostFrames.settings(&body, for: plan)
            prepared.edit = try JSONDecoder().decode(
                WebNativeEdit.self, from: JSONSerialization.data(withJSONObject: body))
        }
        // Photo Quality: exact film math unless the page asks for Fast, as the Mac app exports.
        let exact = parameters["photoQuality"] as? String != "fast"
        func develop(_ format: HostEngine.PixelFormat) throws -> [UInt8] {
            let stride = format == .rgba8DisplayP3 ? 4 : 16
            var pixels = [UInt8](repeating: 0, count: width * height * stride)
            try pixels.withUnsafeMutableBytes { buffer in
                try engine.develop(scene, width: width, height: height,
                                   contentHeadroom: prepared.image.contentHeadroom,
                                   edit: prepared.edit, exactMath: exact,
                                   into: .init(maxEdge: 0, format: format,
                                               pixels: buffer.baseAddress!,
                                               rowBytes: width * stride, capacity: buffer.count))
            }
            return pixels
        }
        let stock = engine.stock(prepared.edit.edit.stock)
        let knee = stock.flatMap { stock in
            try? engine.options(prepared.edit, stock: stock, contentHeadroom: 1)
                .sdrShoulderKnee(for: stock)
        } ?? FilmSDRDelivery.boundedShoulderKnee
        let wantsHDR = hdr && plan == nil && deliversHDR(prepared.edit)
        // One develop in linear light serves both a deep file and the HDR picture.
        let linear = deep || wantsHDR
            ? try develop(.rgba32FloatLinearP3).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            : nil
        var still = HostStill(
            pixels: deep ? .display16(HostExport.display16(linear: linear!, width: width,
                                                           height: height, knee: knee))
                         : .display8(try develop(.rgba8DisplayP3)),
            width: width, height: height, frame: plan?.configuration,
            capture: prepared.image.captureMetadata)
        if wantsHDR, let linear {
            still.hlg = HostExport.hlg16(linear: linear, width: width, height: height)
        }
        return still
    }

    /// The correction for a lens setting on this photograph: the chosen or matched profile from
    /// the imported catalogue, then the sliders (`WebLensRequest`, as the browser plans it).
    private func lensPlan(_ image: HostImage, _ lens: SceneGeometry.Lens) throws -> WebLensRequest.Plan {
        let catalogue = Self.lensCatalogueURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? LensCatalogue.load(from: $0) } ?? LensCatalogue()
        let profile = lens.profileID.flatMap { id in catalogue.profiles.first { $0.id == id } }
            ?? image.lensShot.flatMap(catalogue.match)
        var request: [String: Any] = [
            "adjustment": ["distortion": lens.distortion, "vignetting": lens.vignetting,
                           "redCyan": lens.redCyan, "blueYellow": lens.blueYellow],
            "amount": lens.amount ?? 1,
        ]
        if let profile {
            request["profile"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        }
        if let shot = image.lensShot {
            request["shot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shot))
        }
        return try JSONDecoder().decode(WebLensRequest.self,
                                        from: JSONSerialization.data(withJSONObject: request)).plan()
    }

    private var sceneCache: (key: String, scene: [Float])?

    /// The photograph through the edit's geometry at the frame's size, scene-linear.
    /// The prepared request's picture through its geometry, scene-linear.
    func framedScene(_ prepared: Prepared) throws -> [Float] {
        try sceneFor(prepared.image, geometry: prepared.geometry, sizes: prepared.sizes)
    }

    func sceneFor(_ image: HostImage, geometry: SceneGeometry,
                          sizes: (frame: (Int, Int), output: (Int, Int))) throws -> [Float] {
        let key = "\(ObjectIdentifier(image))|\(image.frameKey)|\(geometry)|\(sizes.frame)|\(sizes.output)"
        if let sceneCache, sceneCache.key == key { return sceneCache.scene }
        // Reduce the unrotated photograph to the frame's scale first, so the one bilinear
        // resample never skips pixels.
        let swapped = geometry.rotation % 2 != 0
        let frameWidth = swapped ? sizes.frame.1 : sizes.frame.0
        let frameHeight = swapped ? sizes.frame.0 : sizes.frame.1
        let reduced = image.scene(width: frameWidth, height: frameHeight)
        let table = try geometry.lens.map { try lensPlan(image, $0) }
            .flatMap { $0.identity ? nil : $0.table }
        let scene = geometry.isIdentity && (frameWidth, frameHeight) == sizes.output
            ? reduced
            : geometry.apply(reduced, width: frameWidth, height: frameHeight,
                             orientedSize: (swapped ? image.height : image.width,
                                            swapped ? image.width : image.height),
                             output: sizes.output, lensTable: table)
        sceneCache = (key, scene)
        return scene
    }

    /// The imported lens catalogue, shared with the Mac app (`LensCatalogueStore`).
    static var lensCatalogueURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Fotufilm/lens-profiles.json")
    }

    // MARK: Answers

    /// An answer that is a bare JSON value rather than an object.
    func answer(value: Any) throws -> Answer {
        Answer(json: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
               payload: [])
    }

    func answer(_ body: [String: Any], images: [String: [UInt8]] = [:]) throws -> Answer {
        var body = body
        var payload: [UInt8] = []
        var ranges: [String: [Int]] = [:]
        for (name, bytes) in images.sorted(by: { $0.key < $1.key }) {
            // Page views of the payload start on 64-byte boundaries, as the bridge aligns it.
            while payload.count % 64 != 0 { payload.append(0) }
            ranges[name] = [payload.count, bytes.count]
            payload += bytes
        }
        if !ranges.isEmpty { body["payloads"] = ranges }
        return Answer(json: try JSONSerialization.data(withJSONObject: body), payload: payload)
    }
}
