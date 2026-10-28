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
    /// Scene-linear RGBA in the engine's working space, alpha flattened over black: the
    /// photograph, or a working copy of it (`decodeLarger`).
    private let scene: [Float]
    /// The scene's own size: the photograph's, or its working copy's.
    private let sceneWidth: Int, sceneHeight: Int
    /// Where the scene is a working copy smaller than the photograph, as a phone holds a camera
    /// RAW and as the iPhone decodes one (`PreviewViewport.baseLongEdgeCeiling`): decodes the file
    /// again for a size the copy cannot cover, which only an export asks for.
    var decodeLarger: ((_ longEdge: Int) throws -> (rgba: [Float], width: Int, height: Int))?
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
    /// Decodes the file again no larger than needed for a long edge (twice it, for a RAW's
    /// demosaic), as the Mac app decodes an uncropped preview; nil where it reduces the full decode.
    var decodeReduced: ((_ longEdge: Int) throws -> (rgba: [Float], width: Int, height: Int))?
    /// Decodes a camera RAW again with none of the camera's corrections (RAW Corrections off):
    /// no lens distortion or vignetting correction, and where the decoder can, the whole sensor
    /// area instead of the camera's crop. Made on first use and kept with this one.
    var decodeUncorrected: (() throws -> HostImage)?
    private var uncorrectedImage: HostImage?
    private let lock = NSLock()
    /// The most recent reductions, least recently used first: the settled preview, a moving
    /// edit's drafts and the film strip's thumbnails. A draft was made from another reduction.
    private var reductions: [(width: Int, height: Int, rgba: [Float], draft: Bool)] = []

    /// The photograph without the camera's corrections, or nil where it has none to leave out.
    func uncorrected() throws -> HostImage? {
        lock.lock()
        defer { lock.unlock() }
        if let uncorrectedImage { return uncorrectedImage }
        guard let decodeUncorrected else { return nil }
        let made = try decodeUncorrected()
        uncorrectedImage = made
        return made
    }

    /// What the editor's image descriptor says about the source.
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
        sceneWidth = width
        sceneHeight = height
        self.contentHeadroom = contentHeadroom
        frames = nil
    }

    /// A photograph of `width` × `height` held as a smaller working copy, `rgba` of `workingWidth`
    /// × `workingHeight`; `decodeLarger` delivers what the copy cannot.
    init(working rgba: [Float], width workingWidth: Int, height workingHeight: Int,
         naturalWidth width: Int, naturalHeight height: Int, contentHeadroom: Float) {
        precondition(rgba.count >= workingWidth * workingHeight * 4)
        var scene = rgba
        PremultipliedAlpha.flatten(&scene, over: .zero)
        self.scene = scene
        self.width = width
        self.height = height
        sceneWidth = workingWidth
        sceneHeight = workingHeight
        self.contentHeadroom = contentHeadroom
        frames = nil
    }

    /// The longest edge developed from what is held, without decoding the file again: a working
    /// copy's, so a magnified view stops there rather than decoding the whole photograph.
    var workingLongEdge: Int? { decodeLarger == nil ? nil : max(sceneWidth, sceneHeight) }

    /// An image whose pixels are produced on demand at the size asked for, as a video's frames.
    init(width: Int, height: Int, contentHeadroom: Float,
         frames: @escaping (_ width: Int, _ height: Int) -> [Float]) {
        scene = []
        self.width = width
        self.height = height
        sceneWidth = width
        sceneHeight = height
        self.contentHeadroom = contentHeadroom
        self.frames = frames
    }

    public func renderSize(maxEdge: Int) -> (width: Int, height: Int) {
        AreaResample.size(width: width, height: height, maxEdge: maxEdge)
    }

    /// The photograph reduced to a size, kept for the next ask. A `draft` is reduced by area from
    /// the smallest reduction already made that covers it, where there is one.
    func scene(width targetWidth: Int, height targetHeight: Int, draft: Bool = false) -> [Float] {
        if let frames { return frames(targetWidth, targetHeight) }
        if targetWidth == sceneWidth && targetHeight == sceneHeight { return scene }
        // Larger than a working copy: decoded again for this ask (an export) and not kept. A pixel
        // over is the two sizes' rounding, which the copy covers.
        if let decodeLarger, targetWidth > sceneWidth + 1 || targetHeight > sceneHeight + 1 {
            let larger = (try? decodeLarger(max(targetWidth, targetHeight)))
                ?? (rgba: scene, width: sceneWidth, height: sceneHeight)
            if larger.width == targetWidth && larger.height == targetHeight { return larger.rgba }
            return AreaResample.reduce(larger.rgba, width: larger.width, height: larger.height,
                                       to: targetWidth, targetHeight)
        }
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
            ?? (scene, sceneWidth, sceneHeight)
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
    /// Each cancel scope's count of cancels, by `CancelScope.rawValue`.
    private var generations: [UInt64] = [0, 0]
    private var loadedStocks: [String: FilmStock] = [:]
    /// The kernel schedules warm-up has compiled, so films added later compile only new ones.
    private var warmedSchedules = Set<Int32>()

    /// The platform's GPU developer, or the portable Halide CPU one.
    let developer: HostDeveloper

    /// Where this person's film packs are installed; tests use their own. `reloadFilms` reads it.
    var filmPacks: HostFilmPackLibrary? = HostPlatform.current.filmPacks

    public convenience init() throws {
        if let gpu = HostPlatform.current.developer {
            try self.init(developer: gpu)
        } else if FotufilmEngine.isHalideBackendAvailable {
            try self.init(developer: HalideCPUDeveloper())
        } else {
            throw Failure(description: "The Halide engine is not linked into this build.")
        }
    }

    /// An engine that develops on `developer` whatever the platform offers, so the render
    /// baseline can develop the same requests on the CPU and on the GPU.
    init(developer: HostDeveloper) throws {
        self.developer = developer
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
    /// The name the editor shows.
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

    /// What stops a call. The editor's develops answer `cancel`, which a host calls before each
    /// newer edit; a call the host runs beside them (an export it lets go on while the person
    /// keeps editing, `"background": true`) answers only `cancelBackground`. Both still develop
    /// one at a time.
    public enum CancelScope: Int, Sendable { case foreground, background }

    /// The scope of the call running on this thread.
    @TaskLocal public static var scope: CancelScope = .foreground

    public func cancel() { cancel(.foreground) }

    public func cancelBackground() { cancel(.background) }

    private func cancel(_ scope: CancelScope) {
        stateLock.lock()
        generations[scope.rawValue] &+= 1
        stateLock.unlock()
    }

    /// The editor's develops waiting for the render lock, which a background call lets go first.
    private let turns = NSCondition()
    private var editorWaiting = 0

    /// Takes the render lock: a background call (an export) waits while the editor's develops do,
    /// so a person editing beside a long Export All waits for one photograph's develop at most.
    private func takeRenderLock() {
        if Self.scope == .background {
            turns.lock()
            while editorWaiting > 0 { turns.wait() }
            turns.unlock()
            renderLock.lock()
            return
        }
        turns.lock()
        editorWaiting += 1
        turns.unlock()
        renderLock.lock()
        turns.lock()
        editorWaiting -= 1
        turns.broadcast()
        turns.unlock()
    }

    private func generation(_ scope: CancelScope) -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generations[scope.rawValue]
    }

    /// True until the calling thread's scope is next cancelled: how a long call (an export, a
    /// video export) and a develop see a cancel, from whichever thread asks.
    func continuation() -> () -> Bool {
        let scope = Self.scope
        let started = generation(scope)
        return { self.generation(scope) == started }
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
    /// playback may ask for the engine's `realtime` schedule. `unexposedEdge` develops a piece of
    /// film larger than the aperture, the scene continued over it (`UnexposedEdge`).
    public func develop(_ scene: [Float], width: Int, height: Int, contentHeadroom: Float,
                        edit: WebNativeEdit, frameIndex: UInt64 = 0, realtime: Bool = false,
                        exactMath: Bool = false, unexposedEdge: UnexposedEdge.Develop? = nil,
                        into target: Target) throws {
        if let reading = edit.negativeReading {
            return try printNegative(scene, width: width, height: height, reading: reading,
                                     edit: edit, into: target)
        }
        let film: FilmStock?
        if let stockID = edit.edit.stock {
            guard let stock = stocks[stockID] else {
                throw Failure(description: "Film \(stockID) is not installed.")
            }
            film = stock
        } else {
            film = nil
        }
        var options = try options(edit, stock: film ?? .noFilm, contentHeadroom: contentHeadroom)
        if film != nil { options.unexposedEdge = unexposedEdge }
        try develop(scene, width: width, height: height, film: film, options: options,
                    frameIndex: frameIndex, realtime: realtime, exactMath: exactMath,
                    into: target)
    }

    /// A video frame's decoded 8-bit Display P3 codes developed in one pass, as the Mac app plays
    /// a movie, and the codes as read when `keepsCodes`; nil where the edit has no film, the film is layered, or the developer has no such
    /// road, and the frame then develops as light.
    func developDisplay8(_ codes: HostVideoCodes, width: Int, height: Int, contentHeadroom: Float,
                         edit: WebNativeEdit, frameIndex: UInt64,
                         keepsCodes: Bool) throws -> (developed: [UInt8], original: [UInt8]?)? {
        guard let film = stock(edit.edit.stock) else { return nil }
        let options = try options(edit, stock: film, contentHeadroom: contentHeadroom)
        guard options.transportConstruction(for: film) == nil,
              !options.paper(for: film).deliversCodeValues else { return nil }
        let shouldContinue = continuation()
        takeRenderLock()
        defer { renderLock.unlock() }
        guard shouldContinue() else {
            throw Failure(description: "Cancelled.", cancelled: true)
        }
        return developer.developDisplay8(codes, width: width, height: height, stock: film,
                                         options: options, frameIndex: frameIndex,
                                         keepsCodes: keepsCodes)
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

    /// The develop of a larger piece of film reaching `margins` beyond the photograph `scene`,
    /// on the photograph's own Auto Levels readings (`UnexposedEdge.Develop.metering`). Nil with
    /// no film.
    public func unexposedEdge(_ scene: [Float], width: Int, height: Int,
                              margins: UnexposedEdge.Margins, edit: WebNativeEdit,
                              contentHeadroom: Float) throws -> UnexposedEdge.Develop? {
        guard let stock = stock(edit.edit.stock) else { return nil }
        let options = try options(edit, stock: stock, contentHeadroom: contentHeadroom)
        return try scene.withUnsafeBufferPointer {
            try UnexposedEdge.Develop.metering($0, width: width, height: height, margins: margins,
                                               stock: stock, options: options)
        }
    }

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
        let shouldContinue = continuation()
        takeRenderLock()
        defer { renderLock.unlock() }
        guard shouldContinue() else { throw Failure(description: "Cancelled.", cancelled: true) }

        let knee = film.map { options.sdrShoulderKnee(for: $0) } ?? FilmSDRDelivery.boundedShoulderKnee
        let seed = UInt32(truncatingIfNeeded: options.seed)
        // Cineon Log delivers code values, not light: they are shown as the signal they are, a
        // flat scan, with no shoulder and no transfer, and a float target receives them verbatim.
        let codeValues = film.map { options.paper(for: $0).deliversCodeValues } ?? false
        try developer.develop(
            scene, width: width, height: height, stock: stock, noFilm: film == nil,
            options: options, pace: HostDevelopPace(frameIndex: frameIndex, realtime: realtime,
                                                    exactMath: exactMath),
            encode: target.format == .rgba8DisplayP3 && !codeValues,
            knee: film == nil ? nil : knee, shouldContinue: shouldContinue,
            deliver: { rows, range, encoded in
                self.deliver(rows, rows: range, width: width, encoded: encoded || codeValues,
                             knee: knee, seed: seed, target: target)
            })
    }

    /// A scanned negative's framed scan printed as the edit's film: the scan read as the film's
    /// densities, then the edit's own print, exactly the stages a develop runs after grain.
    private func printNegative(_ scan: [Float], width: Int, height: Int,
                               reading: NegativeScanPrint.Reading, edit: WebNativeEdit,
                               into target: Target) throws {
        guard let stock = stock(edit.edit.stock) else {
            throw Failure(description: "Choose the film this negative was shot on.")
        }
        let options = reading.printing(try options(edit, stock: stock, contentHeadroom: 1),
                                       stock: stock)
        let knee = options.sdrShoulderKnee(for: stock)
        let seed = UInt32(truncatingIfNeeded: options.seed)
        let codeValues = options.paper(for: stock).deliversCodeValues
        try printScan(width: width, height: height, stock: stock, options: options,
                      calibration: reading.calibration,
                      readScan: { rows, into in
                          scan.withUnsafeBufferPointer {
                              into.baseAddress!.update(from: $0.baseAddress! + rows.lowerBound * width * 4,
                                                       count: rows.count * width * 4)
                          }
                      },
                      writeRows: { range, rows in
                          self.deliver(rows, rows: range, width: width, encoded: codeValues,
                                       knee: knee, seed: seed, target: target)
                      })
    }

    /// Prints a scanned negative's rows through the developer's print stage, one print or develop
    /// at a time, stopped by `cancel` (`HostDeveloper.printScan`).
    func printScan(width: Int, height: Int, stock: FilmStock, options: FotufilmEngine.Options,
                   calibration: ApproximateNegativeScan,
                   readScan: (Range<Int>, UnsafeMutableBufferPointer<Float>) -> Void,
                   writeRows: (Range<Int>, UnsafeBufferPointer<Float>) -> Void) throws {
        let shouldContinue = continuation()
        takeRenderLock()
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
