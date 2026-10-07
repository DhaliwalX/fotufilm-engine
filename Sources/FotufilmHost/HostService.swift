import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
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
    /// The last develop, kept so panning a zoomed picture only cuts new tiles from it: 8-bit
    /// Display P3, or extended-linear half floats when it was developed for an EDR layer.
    private var developed: (key: String, width: Int, height: Int, format: HostSurfaceFormat,
                            pixels: [UInt8])?
    /// The undeveloped pictures last delivered, least recently used first: the settled preview,
    /// a moving edit's drafts and the detail view each keep theirs.
    private var originals: [(key: String, width: Int, height: Int, pixels: [UInt8])] = []
    /// Where the host draws the photograph itself, when it does (`HostPresentation.swift`).
    public var presenter: HostPresenter?
    /// The undeveloped frame each layer last showed, so it is presented again only when it
    /// changes.
    private var presentedOriginals: [String: (key: String, id: UInt64)] = [:]
    /// Movie uploads in progress (`HostService+Video.swift`).
    let videos = HostVideoLibrary()
    /// Scans open in a negative-scan session (`HostService+NegativeScan.swift`); tests keep their
    /// light frames apart.
    var negativeScans = HostNegativeScans(lights: HostNegativeLightFrames(
        directory: HostNegativeLightFrames.defaultDirectory))

    /// Where Copy Photo puts the picture, when the platform has a clipboard; tests use a private
    /// one.
    var clipboard: HostClipboard? = HostPlatform.current.clipboard
    /// Installs the plug-ins for other editors, when the platform has them; tests install into a
    /// temporary directory.
    var plugins: HostPluginInstaller? = HostPlatform.current.plugins
    /// What this person has chosen before, for Choose Film Per Photo; tests use their own file.
    var filmPreferences = HostFilmPreferences(file: HostFilmPreferences.defaultFile)
    /// Check for Updates (`HostUpdates.swift`), where the platform has a release channel.
    lazy var updates: HostUpdates? = {
        guard let channel = HostPlatform.current.updates,
              let digest = HostPlatform.current.fileDigest else { return nil }
        return HostUpdates(channel: channel, digest: digest)
    }()

    public init(engine: HostEngine) {
        self.engine = engine
    }

    /// Whether every call's duration goes to stderr, as `FOTUFILM_HOST_TIMINGS` asks.
    static let logsTimings = ProcessInfo.processInfo.environment["FOTUFILM_HOST_TIMINGS"] != nil

    public func call(_ method: String, params: Data, payload: UnsafeRawBufferPointer?) throws -> Answer {
        let parameters = (try? JSONSerialization.jsonObject(with: params)) as? [String: Any] ?? [:]
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            if Self.logsTimings {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
                let detail = ["maxEdge", "previewQuality", "stage", "present"]
                    .compactMap { key in parameters[key].map { "\(key)=\($0)" } }
                    .joined(separator: " ")
                FileHandle.standardError.write(Data(String(
                    format: "fotufilm call %@ %.1f ms %@\n", method, ms, detail).utf8))
            }
        }
        switch method {
        case "prepare":
            return try answer(["stocks": engine.stockIDs, "backend": engine.backendName,
                               "catalogue": try catalogue()])
        case "import":
            guard let payload, payload.count > 0 else {
                throw HostEngine.Failure(description: "The photograph's bytes did not arrive.")
            }
            return try importImage(name: parameters["name"] as? String ?? "photo",
                                   bytes: payload,
                                   negative: parameters["negative"] as? Bool == true)
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
            let negative = parameters["negative"] as? Bool == true
            let isMovie = !negative && HostPlatform.current.videoSource?.isMovie(url) == true
            var opened = negative ? try importNegative(url)
                : isMovie
                ? try importMovie(at: url, owned: false,
                                  playback: parameters["playback"] as? Bool == true)
                : try imported({
                    let image = try HostImage.open(url)
                    // A camera RAW read in place can be exported as itself.
                    if image.isRAW { image.originalFile = url }
                    return image
                }())
            // What the editor keeps this file's last edit under.
            if let identity = HostFileIdentity.identity(of: url, isMovie: isMovie),
               var body = try JSONSerialization.jsonObject(with: opened.json) as? [String: Any] {
                body["identity"] = identity
                opened.json = try JSONSerialization.data(withJSONObject: body)
            }
            return opened
        case "exportOriginal":
            return try answer(exportOriginal(parameters))
        case "thumbnail":
            return try thumbnail(parameters, payload: payload)
        case "release":
            if let handle = parameters["handle"] as? Int {
                lock.lock()
                images[handle] = nil
                lock.unlock()
            }
            videos.release(parameters["handle"])
            negativeScans.release(parameters["handle"])
            return try answer([:])
        case "render":
            return try render(params)
        case "presentedImage":
            return try presentedImage()
        case "beginVideo", "appendVideo", "importVideo", "exportVideo":
            return try video(method, params: params, payload: payload, progress: nil)
        case "lensPlan":
            let image = try self.image(parameters["handle"])
            let lens = try JSONDecoder().decode(
                SceneGeometry.Lens.self,
                from: JSONSerialization.data(withJSONObject: parameters["lens"] ?? [:]))
            return Answer(json: try JSONEncoder().encode(lensPlan(image, lens)), payload: [])
        case let method where Self.negativeScanMethods.contains(method):
            return try negativeScan(method, parameters: parameters, payload: payload)
        case "stages":
            return try answer(value: stages(parameters))
        case "printFrame":
            return Answer(json: try HostFrames.answer(parameters), payload: [])
        case "autoAdjust":
            return try answer(autoAdjust(params))
        case "sampleScene":
            return try answer(value: sampleScene(parameters))
        case "export":
            return try answer(HostActivity.during("Exporting a photograph") {
                try export(params, parameters: parameters)
            })
        case "exportOptions":
            return try answer(exportOptions(parameters))
        case "exportBatch":
            return try answer(exportBatch(parameters, progress: { _ in }))
        case "fileIdentities":
            return try answer(fileIdentities(parameters))
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
        case "filmChoices":
            // How many choices it has learned from: nothing to forget greys Forget out.
            return try answer(["observations": filmPreferences.observationCount])
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
        case "updateCheck", "updateStatus", "updateInstall", "updateCancel", "updateNotes":
            guard let updates else {
                throw HostEngine.Failure(description: "This host cannot check for updates.")
            }
            switch method {
            case "updateCheck": updates.check(prereleases: parameters["prereleases"] as? Bool ?? false)
            case "updateInstall": try updates.install()
            case "updateCancel": updates.cancel()
            case "updateNotes": try updates.openNotes()
            default: break
            }
            return try answer(updates.status())
        case "filmPacks", "importFilmPack", "removeFilmPack":
            return try filmPacks(method, parameters: parameters, payload: payload)
        case "removeLensCatalogue":
            if let url = Self.lensCatalogueURL { try? FileManager.default.removeItem(at: url) }
            return try answer(value: NSNull())
        default:
            throw HostEngine.Failure(description: "\(method) is not available in this host yet.")
        }
    }

    private var catalogueEntries: [[String: Any]]?

    /// The installed films changed (a film pack added or removed): the engine reloads them, and
    /// the library and the last develop are built again from what is there now.
    func filmsChanged() {
        engine.reloadFilms()
        catalogueEntries = nil
        developed = nil
    }

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

    private func importImage(name: String, bytes: UnsafeRawBufferPointer,
                             negative: Bool) throws -> Answer {
        // The decoders read files, and RAW decoding wants the extension as its hint.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-import", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            UUID().uuidString + "." + URL(fileURLWithPath: name).pathExtension)
        let data = Data(bytes: bytes.baseAddress!, count: bytes.count)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try negative ? importNegative(file) : imported(HostImage.open(file))
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
        return ["filename": destination.lastPathComponent, "path": destination.path]
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
        /// Nil when the photograph is named another way: a batch export's file.
        var handle: Int?
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

        /// The edit with what the photograph and its framing decide, as the Mac app's develop
        /// reads them off the scene (`FilmRender.develop`): a gauge nobody picked follows the
        /// frame the camera exposed (`EditState.resolvedFormat(sensor:)`), and a crop is an
        /// enlargement of the film it keeps.
        func developing(_ decoded: WebNativeEdit) -> WebNativeEdit {
            var edit = decoded.following(image.sensorFrame)
            edit.frameCoverage = geometry.frameCoverage(width: image.width, height: image.height)
            return edit
        }

        /// A render request's body read again after the host changed it (a print frame's
        /// settings), developed on this photograph and framing.
        func edit(_ body: [String: Any]) throws -> WebNativeEdit {
            developing(try JSONDecoder().decode(WebNativeEdit.self,
                                                from: JSONSerialization.data(withJSONObject: body)))
        }
    }

    /// `image` stands in for the request's handle: a photograph the call opened itself.
    /// A negative — the handle's, or `negative` for a scan the call opened itself — reads its
    /// scan (`readNegative`) unless `readsNegative` is false, for a call that looks at the scan.
    func prepare(_ params: Data, image source: HostImage? = nil,
                 negative: HostNegativeScan? = nil, readsNegative: Bool = true) throws -> Prepared {
        let request: RenderRequest, decoded: WebNativeEdit
        do {
            request = try JSONDecoder().decode(RenderRequest.self, from: params)
            decoded = try JSONDecoder().decode(WebNativeEdit.self, from: params)
        } catch {
            throw HostEngine.Failure(description: "Unreadable render request: \(error)")
        }
        let image = try source ?? self.image(request.handle)
        image.video?.select(params)
        let geometry = (request.cropMode == true ? request.edit.uncropped() : request.edit)
            .snapped(width: image.width, height: image.height)
        // A viewport asks for part of a larger virtual picture: develop the whole frame at that
        // size, bounded by the photograph's own pixels, and cut the region out of it.
        var maxEdge = request.maxEdge
        let full = geometry.sizes(width: image.width, height: image.height, maxEdge: nil)
        if let viewport = request.viewport { maxEdge = max(viewport.width, viewport.height) }
        // A limit at or past the picture's own size is no limit, and keys the same develop.
        if let limit = maxEdge, limit <= 0 || limit >= max(full.output.0, full.output.1) { maxEdge = nil }
        let sizes = geometry.sizes(width: image.width, height: image.height, maxEdge: maxEdge)
        var prepared = Prepared(request: request, edit: decoded, image: image, geometry: geometry,
                                maxEdge: maxEdge, sizes: sizes)
        prepared.edit = prepared.developing(decoded)
        if let scan = negative ?? (source == nil ? negativeScans.scan(request.handle) : nil) {
            if readsNegative {
                try readNegative(&prepared, scan: scan)
            } else {
                prepared.image = try scan.image(light: decoded.edit.negative?.lightFrame)
            }
        }
        return prepared
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
            edit = try prepared.edit(body)
        }

        // A request that names a layer is shown by the host's compositor, in extended range when
        // the film delivers light above display white and the display has room for it.
        let presentation = presenter.flatMap { presenter in
            HostPresentation.Request(body).map { (presenter: presenter, request: $0) }
        }
        let ceiling = presentation.flatMap { presentation -> Float? in
            let headroom = presentation.presenter.headroom
            guard headroom > 1.01, body["stage"] as? Int == nil, plan == nil,
                  !hasSelection(body), deliversHDR(edit) else { return nil }
            // Rounded, so a headroom that wavers does not develop the frame again.
            return (min(headroom, PrintEncoding.hdrDisplayCeiling) * 20).rounded() / 20
        }

        // Cache keys: everything but the viewport and where the picture goes decides the
        // developed frame, and the range it is delivered in.
        let sceneKey = "\(request.handle ?? 0)|\(ObjectIdentifier(image).hashValue)|\(image.frameKey)|\(maxEdge ?? 0)|\(request.cropMode == true)|\(geometry)"
        var keyed = body
        for name in ["viewport", "maxEdge", "handle", "haveOriginal", "present"] { keyed[name] = nil }
        let developKey = sceneKey + "|" + String(decoding: (try? JSONSerialization.data(
            withJSONObject: keyed, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
            + (ceiling.map { "|edr \($0)" } ?? "")
        let draft = body["draft"] as? Bool == true
        let frameKey = sceneKey + "|" + String(describing: plan?.json["placement"] ?? "")
            + (draft ? "|draft" : "")

        // Made only when something below needs it: a played frame may need no light at all.
        var framedScene: [Float]?
        func scene() throws -> [Float] {
            if let framedScene { return framedScene }
            let made = try sceneFor(image, geometry: geometry, sizes: sizes, draft: draft)
            framedScene = made
            return made
        }
        var renderMilliseconds = 0.0
        // A playing movie's frame the film takes as decoded — nothing cut, turned, selected or
        // framed, in standard range — develops from the decoder's codes in one pass, as the Mac
        // app plays a movie. Its original is those codes, kept only while the page may show it:
        // like the Mac app, a movie played without the comparison leaves its original alone.
        var withoutOriginal = false
        if developed?.key != developKey, image.pace.realtime, presentation != nil, ceiling == nil,
           plan == nil, body["stage"] as? Int == nil, !hasSelection(body),
           request.cropMode != true, geometry.isIdentity, sizes.frame == sizes.output,
           let codes = image.video?.displayCodes(width: width, height: height) {
            let developStart = DispatchTime.now().uptimeNanoseconds
            let showsOriginal = body["original"] as? Bool != false
            let kept = originals.contains(where: { $0.key == frameKey })
            if let frame = try engine.developDisplay8(
                codes, width: width, height: height, contentHeadroom: image.contentHeadroom,
                edit: edit, frameIndex: image.pace.frameIndex, keepsCodes: showsOriginal && !kept) {
                renderMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - developStart) / 1e6
                developed = (developKey, width, height, .rgba8DisplayP3, frame.developed)
                if let original = frame.original {
                    remember(original: (frameKey, width, height, original))
                }
                withoutOriginal = !showsOriginal
            }
        }
        if developed?.key != developKey {
            let scene = try scene()
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            var format = HostSurfaceFormat.rgba8DisplayP3
            let developStart = DispatchTime.now().uptimeNanoseconds
            if let ceiling {
                pixels = HostPresentation.extendedLinear(
                    try developLinear(scene, width: width, height: height, image: image, edit: edit),
                    width: width, height: height, ceiling: ceiling)
                format = .rgba16FloatExtendedLinearP3
            } else if let stage = body["stage"] as? Int {
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
            developed = (developKey, frame.width, frame.height, format, frame.pixels)
        }
        let originalStart = DispatchTime.now().uptimeNanoseconds
        defer {
            if Self.logsTimings {
                FileHandle.standardError.write(Data(String(
                    format: "fotufilm develop %.1f ms, original %.1f ms\n", renderMilliseconds,
                    Double(DispatchTime.now().uptimeNanoseconds - originalStart) / 1e6).utf8))
            }
        }
        if let index = originals.firstIndex(where: { $0.key == frameKey }) {
            originals.append(originals.remove(at: index))
        } else if !withoutOriginal {
            var frame = (pixels: image.display(try scene(), width: width, height: height),
                         width: width, height: height)
            if let plan, let framed = HostFrames.frame(frame.pixels, width: width, height: height,
                                                       plan: plan) {
                frame = framed
            }
            remember(original: (frameKey, frame.width, frame.height, frame.pixels))
        }
        let developedFrame = developed!
        // A frame developed for an EDR layer is shown to the page in standard range.
        if presentation == nil, developedFrame.format != .rgba8DisplayP3 {
            throw HostEngine.Failure(description: "The develop is not in standard range.")
        }
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
        if let presentation {
            var presented: [String: Any] = [
                "width": region.width, "height": region.height, "colorSpace": "display-p3",
                "backend": engine.backendName, "renderMilliseconds": renderMilliseconds,
                "elapsed": Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6,
            ]
            if let plan { presented["framePlan"] = plan.json }
            if let subjects = subjectCount(body, cropMode: request.cropMode == true) {
                presented["subjects"] = subjects
            }
            return try present(developedFrame, original: withoutOriginal ? nil : originals.last!,
                               region: region,
                               to: presentation.presenter, request: presentation.request,
                               body: presented, headroom: ceiling, motion: image.pace.realtime)
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
        if let subjects = subjectCount(body, cropMode: request.cropMode == true) {
            answerBody["subjects"] = subjects
        }
        // The undeveloped picture changes only with the photograph, geometry and region: the
        // page names the one it holds and it crosses again only when it differs.
        let originalFrame = originals.last!
        let originalKey = "\(originalFrame.key)|\(region)"
        answerBody["originalKey"] = originalKey
        var images = ["preview": png((developedFrame.key, developedFrame.width,
                                     developedFrame.height, developedFrame.pixels))]
        if body["haveOriginal"] as? String != originalKey { images["original"] = png(originalFrame) }
        return try answer(answerBody, images: images)
    }

    /// Keeps an undeveloped picture as the newest, within the caches' limits.
    private func remember(original: (key: String, width: Int, height: Int, pixels: [UInt8])) {
        originals.append(original)
        while originals.count > Self.sceneLimit.count || originals.count > 1
            && originals.reduce(0, { $0 + $1.pixels.count }) > Self.sceneLimit.bytes / 2 {
            originals.removeFirst()
        }
    }

    /// Hands the region of a render to the host's compositor: the developed frame into the
    /// request's layer, and the undeveloped one into "<layer>.original" when it changed. The answer
    /// names the frames instead of carrying pictures; with no original it names none, and the
    /// compositor keeps the last one it has.
    private func present(_ developed: (key: String, width: Int, height: Int,
                                       format: HostSurfaceFormat, pixels: [UInt8]),
                         original: (key: String, width: Int, height: Int, pixels: [UInt8])?,
                         region: (x: Int, y: Int, width: Int, height: Int),
                         to presenter: HostPresenter, request: HostPresentation.Request,
                         body: [String: Any], headroom: Float?, motion: Bool) throws -> Answer {
        let extended = developed.format == .rgba16FloatExtendedLinearP3
        // A frame of a moving picture replaces the last at once, as the Mac app's video preview
        // does; anything else may fade in over what it replaces.
        let info: [String: Any] = ["scope": request.scope,
                                   "dynamicRange": extended ? "hdr" : "sdr",
                                   "headroom": Double(headroom ?? 1), "motion": motion]
        guard let frame = HostPresentation.present(
            developed.pixels, frameWidth: developed.width, format: developed.format,
            region: region, to: presenter, layer: request.slot, info: info) else {
            throw HostEngine.Failure(description: "The display has no room for the picture.")
        }
        let layer = request.slot + ".original"
        var originalFrame: UInt64?
        if let original {
            let originalKey = "\(original.key)|\(region)|\(request.scope)"
            originalFrame = presentedOriginals[layer].flatMap { $0.key == originalKey ? $0.id : nil }
            if originalFrame == nil {
                originalFrame = HostPresentation.present(
                    original.pixels, frameWidth: original.width, format: .rgba8DisplayP3,
                    region: region, to: presenter, layer: layer,
                    info: ["scope": request.scope, "dynamicRange": "sdr", "headroom": 1.0,
                           "motion": motion])
                presentedOriginals[layer] = originalFrame.map { (originalKey, $0) }
            }
        }
        var answerBody = body
        answerBody["presented"] = HostPresentation.Presented(
            frame: frame, original: originalFrame ?? 0, extended: extended,
            headroom: headroom ?? 1).json
        return try answer(answerBody)
    }

    /// The last develop, as the page's histogram reads a preview: 8-bit PNG no larger than
    /// 1024 pixels, and an extended-range develop clipped to SDR white.
    private func presentedImage() throws -> Answer {
        guard let frame = developed else {
            throw HostEngine.Failure(description: "Nothing has been presented yet.")
        }
        var pixels = frame.pixels
        if frame.format == .rgba16FloatExtendedLinearP3 {
            pixels = HostPresentation.standardRange(pixels, width: frame.width, height: frame.height)
        }
        let step = max(1, Int((Double(max(frame.width, frame.height)) / 1024).rounded(.up)))
        let (width, height) = ((frame.width + step - 1) / step, (frame.height + step - 1) / step)
        var reduced = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let from = ((y * step) * frame.width + x * step) * 4, to = (y * width + x) * 4
                for c in 0..<4 { reduced[to + c] = pixels[from + c] }
            }
        }
        let png = reduced.withUnsafeBytes {
            StoredPNG.encode($0.baseAddress!, width: width, height: height, rowBytes: width * 4)
        }
        return try answer(["width": width, "height": height, "previewType": "image/png"],
                          images: ["preview": png])
    }

    /// Whether the edit carries an active selective adjustment.
    private func hasSelection(_ body: [String: Any]) -> Bool {
        guard let saved = (body["edit"] as? [String: Any])?["selective"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: saved),
              let selection = try? JSONDecoder().decode(HostSelection.self, from: data)
        else { return false }
        return selection.isActive
    }

    /// How many subjects a subject selection found, for the inspector's status.
    private func subjectCount(_ body: [String: Any], cropMode: Bool) -> Int? {
        guard ((body["edit"] as? [String: Any])?["selective"] as? [String: Any])?["kind"]
                as? String == "subject", !cropMode else { return nil }
        return subjectCache?.subject?.count ?? 0
    }

    /// The photograph's develop in display-linear Display P3, before any shoulder, for a layer
    /// that shows light above display white.
    private func developLinear(_ scene: [Float], width: Int, height: Int, image: HostImage,
                               edit: WebNativeEdit) throws -> [Float] {
        var linear = [Float](repeating: 0, count: width * height * 4)
        try linear.withUnsafeMutableBytes { buffer in
            try engine.develop(scene, width: width, height: height,
                               contentHeadroom: image.contentHeadroom, edit: edit,
                               frameIndex: image.pace.frameIndex, realtime: image.pace.realtime,
                               into: .init(maxEdge: 0, format: .rgba32FloatLinearP3,
                                           pixels: buffer.baseAddress!, rowBytes: width * 16,
                                           capacity: buffer.count))
        }
        return linear
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
        let key = sceneKey.map { $0.split(separator: "|").prefix(2).joined(separator: "|") }
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

    // MARK: Measuring and exporting

    /// Exposure, highlights and shadows solved against the film's latitude from the framed
    /// scene's regional stops, as the native Mac app's Auto does.
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
        return ["filename": URL(fileURLWithPath: path).lastPathComponent, "path": path,
                "width": written.width,
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
        // The sizes the sheet offers, `{id, width, height}` of the cropped picture: those past the
        // developer's memory limit are unavailable, as the Mac app's export sheet marks them.
        let exact = parameters["photoQuality"] as? String != "fast"
        let unavailable = (parameters["sizes"] as? [[String: Any]] ?? []).compactMap { size -> String? in
            guard let id = size["id"] as? String, let width = size["width"] as? Int,
                  let height = size["height"] as? Int, width > 0, height > 0 else { return nil }
            return engine.canDevelop(width: width, height: height, edit: prepared.edit,
                                     contentHeadroom: prepared.image.contentHeadroom,
                                     exactMath: exact) ? nil : id
        }
        return [
            "metadata": HostMetadataPolicy.allCases.map(\.rawValue),
            "hdr": (HostPlatform.current.encoder?.writesHDR ?? false)
                && parameters["printFrame"] as? [String: Any] == nil
                && deliversHDR(prepared.edit),
            "unavailable": unavailable,
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
        let prepared = try prepare(JSONSerialization.data(withJSONObject: body))
        let scene = try sceneFor(prepared.image, geometry: prepared.geometry, sizes: prepared.sizes)
        return try developStill(stillJob(prepared, scene: scene, body: body), deep: deep, hdr: hdr,
                                exact: parameters["photoQuality"] as? String != "fast")
    }

    /// A still ready to develop: its framed scene, and the edit a print frame around it decides.
    struct StillJob {
        var scene: [Float]
        var width: Int
        var height: Int
        var edit: WebNativeEdit
        var plan: HostFrames.Plan?
        var contentHeadroom: Float
        var capture: [String: Any]?
    }

    func stillJob(_ prepared: Prepared, scene: [Float], body: [String: Any]) throws -> StillJob {
        var body = body
        let (width, height) = prepared.sizes.output
        let plan = try (body["printFrame"] as? [String: Any]).flatMap {
            try HostFrames.plan($0, width: width, height: height)
        }
        var edit = prepared.edit
        if let plan {
            HostFrames.settings(&body, for: plan)
            edit = try prepared.edit(body)
        }
        return StillJob(scene: scene, width: width, height: height, edit: edit, plan: plan,
                        contentHeadroom: prepared.image.contentHeadroom,
                        capture: prepared.image.captureMetadata)
    }

    /// Develops a still job. Photo Quality: exact film math unless the page asks for Fast, as the
    /// Mac app exports.
    func developStill(_ job: StillJob, deep: Bool, hdr: Bool, exact: Bool) throws -> HostStill {
        let (width, height) = (job.width, job.height)
        func develop(_ format: HostEngine.PixelFormat) throws -> [UInt8] {
            let stride = format == .rgba8DisplayP3 ? 4 : 16
            var pixels = [UInt8](repeating: 0, count: width * height * stride)
            try pixels.withUnsafeMutableBytes { buffer in
                try engine.develop(job.scene, width: width, height: height,
                                   contentHeadroom: job.contentHeadroom,
                                   edit: job.edit, exactMath: exact,
                                   into: .init(maxEdge: 0, format: format,
                                               pixels: buffer.baseAddress!,
                                               rowBytes: width * stride, capacity: buffer.count))
            }
            return pixels
        }
        let stock = engine.stock(job.edit.edit.stock)
        let knee = stock.flatMap { stock in
            try? engine.options(job.edit, stock: stock, contentHeadroom: 1)
                .sdrShoulderKnee(for: stock)
        } ?? FilmSDRDelivery.boundedShoulderKnee
        let wantsHDR = hdr && job.plan == nil && deliversHDR(job.edit)
        // One develop in linear light serves both a deep file and the HDR picture.
        let linear = deep || wantsHDR
            ? try develop(.rgba32FloatLinearP3).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            : nil
        var still = HostStill(
            pixels: deep ? .display16(HostExport.display16(linear: linear!, width: width,
                                                           height: height, knee: knee))
                         : .display8(try develop(.rgba8DisplayP3)),
            width: width, height: height, frame: job.plan?.configuration,
            capture: job.capture)
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

    /// Framed scenes, least recently used first: the preview, the detail view and the film
    /// strip's thumbnails each keep their own, so one never makes another rebuild. An entry holds
    /// its photograph weakly, so a released one never answers for a new photograph at its address.
    private var scenes: [(image: Weak<HostImage>, key: String, scene: [Float])] = []
    /// The newest framed scene's key, which subject detection reads the photograph from.
    private var sceneKey: String?
    private static let sceneLimit = (count: 4, bytes: 512 << 20)
    final class Weak<Object: AnyObject> {
        weak var object: Object?
        init(_ object: Object) { self.object = object }
    }

    /// The photograph through the edit's geometry at the frame's size, scene-linear.
    /// The prepared request's picture through its geometry, scene-linear.
    func framedScene(_ prepared: Prepared) throws -> [Float] {
        try sceneFor(prepared.image, geometry: prepared.geometry, sizes: prepared.sizes)
    }

    /// A `draft` may be reduced from a smaller copy of the photograph already made, where a
    /// settled picture is always reduced from the photograph itself.
    func sceneFor(_ image: HostImage, geometry: SceneGeometry,
                  sizes: (frame: (Int, Int), output: (Int, Int)), draft: Bool = false) throws -> [Float] {
        let key = "\(ObjectIdentifier(image))|\(image.frameKey)|\(geometry)|\(sizes.frame)|\(sizes.output)"
            + (draft ? "|draft" : "")
        scenes.removeAll { $0.image.object == nil }
        if let index = scenes.firstIndex(where: { $0.key == key && $0.image.object === image }) {
            let hit = scenes.remove(at: index)
            scenes.append(hit)
            sceneKey = key
            return hit.scene
        }
        let scene = try makeScene(image, geometry: geometry, sizes: sizes, draft: draft)
        scenes.append((Weak(image), key, scene))
        sceneKey = key
        while scenes.count > Self.sceneLimit.count || scenes.count > 1
            && scenes.reduce(0, { $0 + $1.scene.count * 4 }) > Self.sceneLimit.bytes {
            scenes.removeFirst()
        }
        return scene
    }

    /// The framed scene, made afresh and kept nowhere: safe off the engine thread, as a batch
    /// export makes the next photograph's while the current one develops.
    func makeScene(_ image: HostImage, geometry: SceneGeometry,
                   sizes: (frame: (Int, Int), output: (Int, Int)), draft: Bool = false) throws -> [Float] {
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            if Self.logsTimings {
                FileHandle.standardError.write(Data(String(
                    format: "fotufilm scene %dx%d%@ %.1f ms\n", sizes.output.0, sizes.output.1,
                    draft ? " draft" : "",
                    Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6).utf8))
            }
        }
        let swapped = geometry.rotation % 2 != 0
        let oriented = swapped ? (image.height, image.width) : (image.width, image.height)
        let table = try geometry.lens.map { try lensPlan(image, $0) }
            .flatMap { $0.identity ? nil : $0.table }
        let scene: [Float]
        if !draft, geometry.crop != SceneGeometry.fullCrop, sizes.frame != oriented {
            // A crop is cut from the whole photograph and then reduced, as the Mac app cuts it;
            // a draft is cut from a reduced copy.
            let native = geometry.sizes(width: image.width, height: image.height, maxEdge: nil)
            let cut = geometry.apply(image.scene(width: image.width, height: image.height),
                                     width: image.width, height: image.height,
                                     orientedSize: oriented, output: native.output,
                                     lensTable: table)
            let (width, height) = native.output
            scene = HostPlatform.current.resampler?.reduce(
                cut, width: width, height: height, to: sizes.output.0, sizes.output.1)
                ?? AreaResample.reduce(cut, width: width, height: height,
                                       to: sizes.output.0, sizes.output.1)
        } else {
            // Otherwise the unrotated photograph is reduced to the frame's scale first, as the
            // Mac app decodes it, so the one bilinear resample never skips pixels.
            let frameWidth = swapped ? sizes.frame.1 : sizes.frame.0
            let frameHeight = swapped ? sizes.frame.0 : sizes.frame.1
            let reduced = image.scene(width: frameWidth, height: frameHeight, draft: draft)
            scene = geometry.isIdentity && (frameWidth, frameHeight) == sizes.output
                ? reduced
                : geometry.apply(reduced, width: frameWidth, height: frameHeight,
                                 orientedSize: oriented, output: sizes.output, lensTable: table)
        }
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

extension WebNativeEdit {
    /// A gauge nobody picked follows the frame the photograph's camera exposed, the nearest film
    /// format to it, as the Mac app develops it (`EditState.resolvedFormat(sensor:)`).
    func following(_ sensor: SensorFrame?) -> WebNativeEdit {
        guard profileRequest.format == nil, let sensor else { return self }
        var edit = self
        edit.profileRequest.format = sensor.gauge.id
        return edit
    }
}
