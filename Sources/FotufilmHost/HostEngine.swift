import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// A decoded photograph and the reduced copies previews have asked for.
public final class HostImage {
    public let width: Int
    public let height: Int
    /// The range above diffuse white the source records. A video's follows the interpretation
    /// its edit chooses.
    var contentHeadroom: Float
    /// The lens the file records, for matching a correction profile.
    var lensShot: LensShot?
    /// The file's capture records (camera, exposure, lens, place) in the decoder's own form, for
    /// the encoder to carry into exports.
    var captureMetadata: [String: Any]?
    /// Scene-linear RGBA in the engine's working space, alpha flattened over black.
    private let scene: [Float]
    /// A video's pixels: the frame the current request selected, decoded at the size asked for.
    private let frames: ((_ width: Int, _ height: Int) -> [Float])?
    /// Names the pixels `frames` delivers now, so caches keyed on the image see a new frame.
    var frameKey = ""
    /// How the selected frame develops: its number, which moves the grain, and whether
    /// interactive playback asked for the realtime schedule.
    var pace: (frameIndex: UInt64, realtime: Bool) = (0, false)
    /// The movie a video's image shows, kept alive by it.
    var video: HostVideo?
    /// Whether the source is camera RAW, and the file it was read from in place: what Export
    /// Original copies, as the Mac app's does.
    var isRAW = false
    var originalFile: URL?
    /// The frame the file says its camera exposed, which a gauge nobody picked follows.
    var sensorFrame: SensorFrame?
    /// Decodes the file again as the Standard Range source interpretation reads it: the
    /// platform's SDR rendition, nothing above white. Nil where it reads the same (camera RAW, a
    /// video, a converted scan).
    var decodeStandardRange: (() throws -> HostImage)?
    private var standardRangeImage: HostImage?
    /// Decodes the file again no larger than needed for a long edge (twice it, for a RAW's
    /// demosaic), as the Mac app decodes an uncropped preview; nil where it reduces the full decode.
    var decodeReduced: ((_ longEdge: Int) throws -> (rgba: [Float], width: Int, height: Int))?
    private let lock = NSLock()
    /// The most recent reductions, least recently used first: the settled preview, a moving
    /// edit's drafts and the film strip's thumbnails. A draft was made from another reduction.
    private var reductions: [(width: Int, height: Int, rgba: [Float], draft: Bool)] = []

    /// What the editor's image descriptor says about the source (`web/src/backend/README.md`).
    var descriptor: [String: Any] {
        var descriptor: [String: Any] = ["naturalWidth": width, "naturalHeight": height]
        if contentHeadroom > 1 { descriptor["hdr"] = ["headroom": contentHeadroom] }
        if let video { descriptor["video"] = video.descriptor }
        if let originalFile { descriptor["original"] = ["name": originalFile.lastPathComponent] }
        // The editor's format picker says what an unpicked gauge follows, as the Mac app's does.
        if let sensorFrame {
            descriptor["sensor"] = ["gauge": sensorFrame.gauge.id, "frameSize": sensorFrame.frameSize]
        }
        return descriptor
    }

    /// Scene light as the screen shows the photograph before any film: Display P3, clipped.
    func display(_ scene: [Float], width: Int, height: Int) -> [UInt8] {
        var display = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            let p3 = ColorScience.linearRec2020ToDisplayP3(
                SIMD3(scene[i * 4], scene[i * 4 + 1], scene[i * 4 + 2]))
            display[i * 4] = p3.x
            display[i * 4 + 1] = p3.y
            display[i * 4 + 2] = p3.z
        }
        return DisplayEncoding.encode8(display, width: width, height: height, knee: 1, seed: 0)
    }

    public init(rgba: [Float], width: Int, height: Int, contentHeadroom: Float) {
        precondition(rgba.count >= width * height * 4)
        var scene = rgba
        PremultipliedAlpha.flatten(&scene, over: .zero)
        self.scene = scene
        self.width = width
        self.height = height
        self.contentHeadroom = contentHeadroom
        frames = nil
    }

    /// An image whose pixels are produced on demand at the size asked for, as a video's frames.
    init(width: Int, height: Int, contentHeadroom: Float,
         frames: @escaping (_ width: Int, _ height: Int) -> [Float]) {
        scene = []
        self.width = width
        self.height = height
        self.contentHeadroom = contentHeadroom
        self.frames = frames
    }

    /// The photograph as an edit with this source interpretation develops it, decoded once and
    /// kept: the Mac app tone-maps a processed photograph to SDR for Standard Range.
    func interpreted(standardRange: Bool) throws -> HostImage {
        guard standardRange, let decodeStandardRange else { return self }
        lock.lock()
        defer { lock.unlock() }
        if let standardRangeImage { return standardRangeImage }
        let image = try decodeStandardRange()
        image.lensShot = lensShot
        image.captureMetadata = captureMetadata
        image.sensorFrame = sensorFrame
        image.isRAW = isRAW
        image.originalFile = originalFile
        standardRangeImage = image
        return image
    }

    public func renderSize(maxEdge: Int) -> (width: Int, height: Int) {
        AreaResample.size(width: width, height: height, maxEdge: maxEdge)
    }

    /// The photograph reduced to a size, kept for the next ask. A `draft` is reduced by area from
    /// the smallest reduction already made that covers it, where there is one.
    func scene(width targetWidth: Int, height targetHeight: Int, draft: Bool = false) -> [Float] {
        if let frames { return frames(targetWidth, targetHeight) }
        if targetWidth == width && targetHeight == height { return scene }
        lock.lock()
        defer { lock.unlock() }
        if let index = reductions.firstIndex(where: {
            $0.width == targetWidth && $0.height == targetHeight && (draft || !$0.draft)
        }) {
            let cached = reductions.remove(at: index)
            reductions.append(cached)
            return cached.rgba
        }
        let covering = draft
            ? reductions.filter { $0.width >= targetWidth && $0.height >= targetHeight && !$0.draft }
                .min { $0.width < $1.width }
            : nil
        let source: (rgba: [Float], width: Int, height: Int) = covering.map { ($0.rgba, $0.width, $0.height) }
            ?? (try? decodeReduced?(max(targetWidth, targetHeight)))
            ?? (scene, width, height)
        // A draft takes the plain area reduction: the platform's resampler may build a filter for
        // every new ratio, and a moving edit asks for a new size at every step.
        let reduced = source.width == targetWidth && source.height == targetHeight
            ? source.rgba
            : (draft ? nil : HostPlatform.current.resampler)?.reduce(
                source.rgba, width: source.width, height: source.height,
                to: targetWidth, targetHeight)
            ?? AreaResample.reduce(source.rgba, width: source.width, height: source.height,
                                   to: targetWidth, targetHeight)
        reductions.append((targetWidth, targetHeight, reduced, covering != nil))
        if reductions.count > 4 { reductions.removeFirst() }
        return reduced
    }
}

/// What the C interface's engine handle holds: the loaded films and one develop at a time.
public final class HostEngine {
    public enum PixelFormat: Int32 {
        case rgba8DisplayP3 = 0
        case rgba32FloatLinearP3 = 1
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
        public var cancelled = false
    }

    public struct Target {
        public var maxEdge: Int
        public var format: PixelFormat
        public var pixels: UnsafeMutableRawPointer
        public var rowBytes: Int
        public var capacity: Int
    }

    /// The web editor's backend calls, answered against this engine.
    public private(set) lazy var service = HostService(engine: self)

    private let renderLock = NSLock()
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var loadedStocks: [String: FilmStock] = [:]
    /// The kernel schedules warm-up has compiled, so films added later compile only new ones.
    private var warmedSchedules = Set<Int32>()

    /// The platform's GPU developer, or the portable Halide CPU one.
    let developer: HostDeveloper

    /// Where this person's film packs are installed; tests use their own. `reloadFilms` reads it.
    var filmPacks: HostFilmPackLibrary? = HostPlatform.current.filmPacks

    public init() throws {
        if let gpu = HostPlatform.current.developer {
            developer = gpu
        } else if FotufilmEngine.isHalideBackendAvailable {
            developer = HalideCPUDeveloper()
        } else {
            throw Failure(description: "The Halide engine is not linked into this build.")
        }
        HostFilmPacks.publish(filmPacks)
        loadedStocks = FilmStock.presets
        guard !loadedStocks.isEmpty else {
            throw Failure(description: "No film stocks are installed.")
        }
        warmUp(FilmStock.presetIDs)
    }

    private var stocks: [String: FilmStock] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return loadedStocks
    }

    /// Reads the installed films again, after a film pack was added or removed, and warms the
    /// ones that arrived.
    func reloadFilms() {
        HostFilmPacks.publish(filmPacks)
        let presets = FilmStock.presets
        stateLock.lock()
        let previous = loadedStocks
        loadedStocks = presets
        stateLock.unlock()
        // A pack's films are warmed whenever it arrives: an updated pack may keep its ids.
        warmUp(FilmStock.presetIDs.filter {
            previous[$0] == nil || FilmStock.origin(of: $0)?.packID != nil
        })
    }

    /// Builds each film's spectral tables and compiles each distinct kernel schedule in the
    /// background, as the Mac app's `StockTableWarmup` does, so the first develop on a film costs
    /// what later ones do rather than seconds.
    private func warmUp(_ ids: [String]) {
        let current = stocks
        let films = ids.compactMap { id in current[id].map { (id, $0) } }
        guard !films.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for (id, stock) in films {
                guard let self,
                      let request = try? JSONSerialization.data(withJSONObject: [
                        "edit": ["stock": id], "profileRequest": ["controls": [String: Any]()],
                      ]),
                      let edit = try? JSONDecoder().decode(WebNativeEdit.self, from: request),
                      let options = try? self.options(edit, stock: stock, contentHeadroom: 1),
                      let invocation = try? FilmEngineInvocation(
                        validating: stock, options: options, width: Self.warmWidth,
                        height: Self.warmHeight)
                else { continue }
                self.stateLock.lock()
                let fresh = self.warmedSchedules.insert(invocation.featureMask).inserted
                self.stateLock.unlock()
                if fresh {
                    self.developer.prepare(stock: stock, options: options, width: Self.warmWidth,
                                           height: Self.warmHeight)
                }
            }
        }
    }

    private static let warmWidth = 192
    private static let warmHeight = 128

    public var backend: String { developer.kind }
    /// The name the editor shows (`web/src/editor/ViewerStatus.jsx`).
    public var backendName: String { developer.name }
    public var stockIDs: [String] {
        let stocks = self.stocks
        return FilmStock.presetIDs.filter { stocks[$0] != nil }
    }

    public func describe() -> String {
        let definitions = FilmStock.presetDefinitions
        let loaded = self.stocks
        let stocks = FilmStock.presetIDs.compactMap { id -> [String: Any]? in
            guard let stock = loaded[id] else { return nil }
            var row: [String: Any] = ["id": id, "name": stock.name]
            if let format = definitions[id]?.nativeFormatID { row["nativeFormat"] = format }
            return row
        }
        let body: [String: Any] = ["apiVersion": 1, "backend": backend, "stocks": stocks]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public func cancel() {
        stateLock.lock()
        generation &+= 1
        stateLock.unlock()
    }

    private var currentGeneration: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation
    }

    /// True until `cancel` is next called: how a long call, a video export, sees a cancel
    /// between its develops.
    func continuation() -> () -> Bool {
        let started = currentGeneration
        return { self.currentGeneration == started }
    }

    /// Develops `image` with a web render request into `target`; returns the delivered size.
    public func render(_ image: HostImage, request: Data, into target: Target) throws
        -> (width: Int, height: Int) {
        let edit: WebNativeEdit
        do { edit = try JSONDecoder().decode(WebNativeEdit.self, from: request).following(image.sensorFrame) }
        catch { throw Failure(description: "Unreadable render request: \(error)") }
        let (width, height) = image.renderSize(maxEdge: target.maxEdge)
        let bytesPerPixel = target.format == .rgba8DisplayP3 ? 4 : 16
        guard target.rowBytes >= width * bytesPerPixel,
              target.capacity >= target.rowBytes * (height - 1) + width * bytesPerPixel else {
            throw Failure(description: "The target holds less than \(width)x\(height).")
        }
        try develop(image.scene(width: width, height: height), width: width, height: height,
                    contentHeadroom: image.contentHeadroom, edit: edit, into: target)
        return (width, height)
    }

    /// Develops a scene already cut to the delivered size: scene-linear Rec.2020 RGBA. A video
    /// frame names its `frameIndex`, which moves the grain from frame to frame, and interactive
    /// playback may ask for the engine's `realtime` schedule.
    public func develop(_ scene: [Float], width: Int, height: Int, contentHeadroom: Float,
                        edit: WebNativeEdit, frameIndex: UInt64 = 0, realtime: Bool = false,
                        exactMath: Bool = false, into target: Target) throws {
        let film: FilmStock?
        if let stockID = edit.edit.stock {
            guard let stock = stocks[stockID] else {
                throw Failure(description: "Film \(stockID) is not installed.")
            }
            film = stock
        } else {
            film = nil
        }
        try develop(scene, width: width, height: height, film: film,
                    options: options(edit, stock: film ?? .noFilm, contentHeadroom: contentHeadroom),
                    frameIndex: frameIndex, realtime: realtime, exactMath: exactMath,
                    into: target)
    }

    /// A video frame's decoded 8-bit Display P3 codes developed in one pass, as the Mac app plays
    /// a movie, and the codes as read; nil where the edit has no film, the film is layered, or the developer has no such
    /// road, and the frame then develops as light.
    func developDisplay8(_ codes: HostVideoCodes, width: Int, height: Int, contentHeadroom: Float,
                         edit: WebNativeEdit, frameIndex: UInt64) throws -> (developed: [UInt8], original: [UInt8])? {
        guard let film = stock(edit.edit.stock) else { return nil }
        let options = try options(edit, stock: film, contentHeadroom: contentHeadroom)
        guard options.transportConstruction(for: film) == nil else { return nil }
        let started = currentGeneration
        renderLock.lock()
        defer { renderLock.unlock() }
        guard currentGeneration == started else {
            throw Failure(description: "Cancelled.", cancelled: true)
        }
        return developer.developDisplay8(codes, width: width, height: height, stock: film,
                                         options: options, frameIndex: frameIndex)
    }

    /// The options an edit develops with on `stock`, the scene's recorded range included.
    public func options(_ edit: WebNativeEdit, stock: FilmStock,
                        contentHeadroom: Float) throws -> FotufilmEngine.Options {
        var options = try edit.options(
            for: stock,
            nativeFormatID: edit.edit.stock.flatMap { FilmStock.presetDefinitions[$0]?.nativeFormatID })
        options.sceneHeadroom = contentHeadroom
        return options
    }

    public func stock(_ id: String?) -> FilmStock? { id.flatMap { stocks[$0] } }

    /// Whether the edit's film develops a frame this large within the developer's memory limit.
    /// No film streams in bands and has no limit.
    public func canDevelop(width: Int, height: Int, edit: WebNativeEdit, contentHeadroom: Float,
                           exactMath: Bool) -> Bool {
        guard let stock = stock(edit.edit.stock),
              let options = try? options(edit, stock: stock, contentHeadroom: contentHeadroom)
        else { return true }
        return developer.canDevelop(width: width, height: height, stock: stock, options: options,
                                    exactMath: exactMath)
    }

    /// Develops with an explicit film and options: a step of the pipeline walk, for instance.
    /// `film` nil develops with no film.
    public func develop(_ scene: [Float], width: Int, height: Int, film: FilmStock?,
                        options: FotufilmEngine.Options, frameIndex: UInt64 = 0,
                        realtime: Bool = false, exactMath: Bool = false,
                        into target: Target) throws {
        let stock = film ?? .noFilm
        let started = currentGeneration
        let shouldContinue = { self.currentGeneration == started }
        renderLock.lock()
        defer { renderLock.unlock() }
        guard shouldContinue() else { throw Failure(description: "Cancelled.", cancelled: true) }

        let knee = film.map { options.sdrShoulderKnee(for: $0) } ?? FilmSDRDelivery.boundedShoulderKnee
        let seed = UInt32(truncatingIfNeeded: options.seed)
        try developer.develop(
            scene, width: width, height: height, stock: stock, noFilm: film == nil,
            options: options, pace: HostDevelopPace(frameIndex: frameIndex, realtime: realtime,
                                                    exactMath: exactMath),
            encode: target.format == .rgba8DisplayP3,
            knee: film == nil ? nil : knee, shouldContinue: shouldContinue,
            deliver: { rows, range, encoded in
                self.deliver(rows, rows: range, width: width, encoded: encoded, knee: knee,
                             seed: seed, target: target)
            })
    }

    /// Prints a scanned negative's rows through the developer's print stage, one print or develop
    /// at a time, stopped by `cancel` (`HostDeveloper.printScan`).
    func printScan(width: Int, height: Int, stock: FilmStock, options: FotufilmEngine.Options,
                   calibration: ApproximateNegativeScan,
                   readScan: (Range<Int>, UnsafeMutableBufferPointer<Float>) -> Void,
                   writeRows: (Range<Int>, UnsafeBufferPointer<Float>) -> Void) throws {
        let started = currentGeneration
        let shouldContinue = { self.currentGeneration == started }
        renderLock.lock()
        defer { renderLock.unlock() }
        guard shouldContinue() else { throw Failure(description: "Cancelled.", cancelled: true) }
        try developer.printScan(width: width, height: height, stock: stock, options: options,
                                calibration: calibration, shouldContinue: shouldContinue,
                                readScan: readScan, writeRows: writeRows)
    }

    private func deliver(_ rows: UnsafeBufferPointer<Float>, rows range: Range<Int>, width: Int,
                         encoded: Bool, knee: Float, seed: UInt32, target: Target) {
        switch target.format {
        case .rgba8DisplayP3:
            if encoded {
                DisplayEncoding.quantize8(encoded: rows, rows: range, width: width,
                                          into: target.pixels, rowBytes: target.rowBytes, seed: seed)
            } else {
                DisplayEncoding.quantize8(linear: rows, rows: range, width: width, knee: knee,
                                          into: target.pixels, rowBytes: target.rowBytes, seed: seed)
            }
        case .rgba32FloatLinearP3:
            for (local, y) in range.enumerated() {
                target.pixels.advanced(by: y * target.rowBytes)
                    .copyMemory(from: rows.baseAddress! + local * width * 4, byteCount: width * 16)
            }
        }
    }
}
