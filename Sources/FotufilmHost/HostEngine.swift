import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif
#if canImport(FotufilmMetal)
import FotufilmMetal
#endif

/// A decoded photograph and the reduced copies previews have asked for.
public final class HostImage {
    public let width: Int
    public let height: Int
    let contentHeadroom: Float
    /// The lens the file records, for matching a correction profile.
    var lensShot: LensShot?
    /// The file's capture records (camera, exposure, lens, place) in the decoder's own form, for
    /// the encoder to carry into exports.
    var captureMetadata: [String: Any]?
    /// Scene-linear RGBA in the engine's working space, alpha flattened over black.
    private let scene: [Float]
    private let lock = NSLock()
    /// The most recent reductions, newest last: an editor asks for one or two sizes at a time.
    private var reductions: [(width: Int, height: Int, rgba: [Float])] = []

    /// What the editor's image descriptor says about the source (`web/src/backend/README.md`).
    var descriptor: [String: Any] {
        var descriptor: [String: Any] = ["naturalWidth": width, "naturalHeight": height]
        if contentHeadroom > 1 { descriptor["hdr"] = ["headroom": contentHeadroom] }
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
    }

    public func renderSize(maxEdge: Int) -> (width: Int, height: Int) {
        AreaResample.size(width: width, height: height, maxEdge: maxEdge)
    }

    func scene(width targetWidth: Int, height targetHeight: Int) -> [Float] {
        if targetWidth == width && targetHeight == height { return scene }
        lock.lock()
        defer { lock.unlock() }
        if let cached = reductions.first(where: { $0.width == targetWidth && $0.height == targetHeight }) {
            return cached.rgba
        }
        let reduced = AreaResample.reduce(scene, width: width, height: height,
                                          to: targetWidth, targetHeight)
        reductions.append((targetWidth, targetHeight, reduced))
        if reductions.count > 2 { reductions.removeFirst() }
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
    private var stocks: [String: FilmStock] = [:]

    public init() throws {
        guard FotufilmEngine.isHalideBackendAvailable || Self.metal != nil else {
            throw Failure(description: "The Halide engine is not linked into this build.")
        }
        stocks = FilmStock.presets
        guard !stocks.isEmpty else { throw Failure(description: "No film stocks are installed.") }
        warmUp()
    }

    /// Builds every film's spectral tables and compiles each distinct kernel schedule in the
    /// background, as the Mac app's `StockTableWarmup` does, so the first develop on a film costs
    /// what later ones do rather than seconds.
    private func warmUp() {
        let stocks = FilmStock.presetIDs.compactMap { id in self.stocks[id].map { (id, $0) } }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var seen = Set<Int32>()
            for (id, stock) in stocks {
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
                #if canImport(Metal)
                if let metal = Self.metal, seen.insert(invocation.featureMask).inserted {
                    metal.prepare(stock: stock, options: options, frameWidth: Self.warmWidth,
                                  frameHeight: Self.warmHeight)
                }
                #endif
            }
        }
    }

    private static let warmWidth = 192
    private static let warmHeight = 128

    #if canImport(Metal)
    static var metal: HalideMetalFilmRenderer? { HalideMetalFilmRenderer.shared }
    #else
    static var metal: Void? { nil }
    #endif

    public var backend: String { Self.metal != nil ? "metal" : "cpu" }
    /// The name the editor shows (`web/src/editor/ViewerStatus.jsx`).
    public var backendName: String { Self.metal != nil ? "Halide/Metal" : "Halide/CPU" }
    public var stockIDs: [String] { FilmStock.presetIDs.filter { stocks[$0] != nil } }

    public func describe() -> String {
        let definitions = FilmStock.presetDefinitions
        let stocks = FilmStock.presetIDs.compactMap { id -> [String: Any]? in
            guard let stock = self.stocks[id] else { return nil }
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

    /// Develops `image` with a web render request into `target`; returns the delivered size.
    public func render(_ image: HostImage, request: Data, into target: Target) throws
        -> (width: Int, height: Int) {
        let edit: WebNativeEdit
        do { edit = try JSONDecoder().decode(WebNativeEdit.self, from: request) }
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

    /// Develops a scene already cut to the delivered size: scene-linear Rec.2020 RGBA.
    public func develop(_ scene: [Float], width: Int, height: Int, contentHeadroom: Float,
                        edit: WebNativeEdit, into target: Target) throws {
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
                    into: target)
    }

    /// The options an edit develops with on `stock`, the scene's recorded range included.
    public func options(_ edit: WebNativeEdit, stock: FilmStock,
                        contentHeadroom: Float) throws -> FotufilmEngine.Options {
        var options = try edit.document.options(
            for: stock,
            nativeFormatID: edit.edit.stock.flatMap { FilmStock.presetDefinitions[$0]?.nativeFormatID })
        options.sceneHeadroom = contentHeadroom
        return options
    }

    public func stock(_ id: String?) -> FilmStock? { id.flatMap { stocks[$0] } }

    /// Develops with an explicit film and options: a step of the pipeline walk, for instance.
    /// `film` nil develops with no film.
    public func develop(_ scene: [Float], width: Int, height: Int, film: FilmStock?,
                        options: FotufilmEngine.Options, into target: Target) throws {
        let stock = film ?? .noFilm
        let started = currentGeneration
        let shouldContinue = { self.currentGeneration == started }
        renderLock.lock()
        defer { renderLock.unlock() }
        guard shouldContinue() else { throw Failure(description: "Cancelled.", cancelled: true) }

        let knee = film.map { options.sdrShoulderKnee(for: $0) } ?? FilmSDRDelivery.boundedShoulderKnee
        let seed = UInt32(truncatingIfNeeded: options.seed)
        #if canImport(Metal)
        if let metal = Self.metal {
            try developOnMetal(metal, scene: scene, width: width, height: height, stock: stock,
                               noFilm: film == nil, options: options, knee: knee, seed: seed,
                               target: target, shouldContinue: shouldContinue)
            return
        }
        #endif
        guard let film else { throw Failure(description: "Developing with no film needs Metal.") }
        var linear = ImageBuffer(width: width, height: height)
        for i in 0..<(width * height) {
            for channel in 0..<3 {
                let value = scene[i * 4 + channel]
                linear.planes[channel][i] = value.isFinite ? value : 0
            }
        }
        let out = try FotufilmEngine(stock: film, options: options).processChecked(linearRGB: linear)
        guard shouldContinue() else { throw Failure(description: "Cancelled.", cancelled: true) }
        var developed = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            developed[i * 4] = out.planes[0][i]
            developed[i * 4 + 1] = out.planes[1][i]
            developed[i * 4 + 2] = out.planes[2][i]
        }
        developed.withUnsafeBufferPointer { rows in
            deliver(rows, rows: 0..<height, width: width, encoded: false, knee: knee, seed: seed,
                    target: target)
        }
    }

    #if canImport(Metal)
    private func developOnMetal(
        _ metal: HalideMetalFilmRenderer, scene: [Float], width: Int, height: Int,
        stock: FilmStock, noFilm: Bool, options: FotufilmEngine.Options, knee: Float,
        seed: UInt32, target: Target, shouldContinue: @escaping () -> Bool
    ) throws {
        // The shoulder and transfer ride in the producing kernel when a variant carries them,
        // which leaves only the quantization to the host.
        let requested: FilmOutputTransform? = target.format == .rgba8DisplayP3
            && metal.carriesOutputTransform(stock: stock, options: options, width: width,
                                            height: height, exactMath: false, noFilm: noFilm)
            ? .displayP3(shoulderKnee: noFilm ? nil : knee) : nil
        func develop(_ requested: FilmOutputTransform?) -> (ok: Bool, kept: Bool) {
            var transform = requested
            let encoded = requested != nil
            let ok = scene.withUnsafeBufferPointer { source in
                metal.developStreaming(
                    width: width, height: height, stock: stock, options: options,
                    outputTransform: &transform, noFilm: noFilm, shouldContinue: shouldContinue,
                    readRows: { rows, into in
                        into.baseAddress!.update(
                            from: source.baseAddress! + rows.lowerBound * width * 4,
                            count: rows.count * width * 4)
                    },
                    writeRows: { rows, from in
                        self.deliver(from, rows: rows, width: width, encoded: encoded, knee: knee,
                                     seed: seed, target: target)
                    })
            }
            return (ok, (transform != nil) == encoded)
        }
        var result = develop(requested)
        // The engine refused the transform after all and handed back light: develop again,
        // encoding on the host.
        if result.ok, !result.kept { result = develop(nil) }
        guard result.ok else {
            let cancelled = !shouldContinue()
            throw Failure(description: cancelled ? "Cancelled." : "The Metal develop failed.",
                          cancelled: cancelled)
        }
    }
    #endif

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
