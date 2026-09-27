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
    /// Scene-linear RGBA in the engine's working space, alpha flattened over black.
    private let scene: [Float]
    private let lock = NSLock()
    /// The most recent reductions, newest last: an editor asks for one or two sizes at a time.
    private var reductions: [(width: Int, height: Int, rgba: [Float])] = []

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
    }

    #if canImport(FotufilmMetal)
    static var metal: HalideMetalFilmRenderer? { HalideMetalFilmRenderer.shared }
    #else
    static var metal: Void? { nil }
    #endif

    public var backend: String { Self.metal != nil ? "metal" : "cpu" }

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
        guard let stockID = edit.edit.stock, let stock = stocks[stockID] else {
            throw Failure(description: "Film \(edit.edit.stock ?? "(none)") is not installed.")
        }
        var options = try edit.document.options(
            for: stock, nativeFormatID: FilmStock.presetDefinitions[stockID]?.nativeFormatID)
        options.sceneHeadroom = image.contentHeadroom

        let (width, height) = image.renderSize(maxEdge: target.maxEdge)
        let bytesPerPixel = target.format == .rgba8DisplayP3 ? 4 : 16
        guard target.rowBytes >= width * bytesPerPixel,
              target.capacity >= target.rowBytes * (height - 1) + width * bytesPerPixel else {
            throw Failure(description: "The target holds less than \(width)x\(height).")
        }

        let started = currentGeneration
        let shouldContinue = { self.currentGeneration == started }
        renderLock.lock()
        defer { renderLock.unlock() }
        guard shouldContinue() else { throw Failure(description: "Cancelled.", cancelled: true) }

        let scene = image.scene(width: width, height: height)
        let knee = options.sdrShoulderKnee(for: stock)
        let seed = UInt32(truncatingIfNeeded: options.seed)
        #if canImport(FotufilmMetal)
        if let metal = Self.metal {
            try developOnMetal(metal, scene: scene, width: width, height: height, stock: stock,
                               options: options, knee: knee, seed: seed, target: target,
                               shouldContinue: shouldContinue)
            return (width, height)
        }
        #endif
        var linear = ImageBuffer(width: width, height: height)
        for i in 0..<(width * height) {
            for channel in 0..<3 {
                let value = scene[i * 4 + channel]
                linear.planes[channel][i] = value.isFinite ? value : 0
            }
        }
        let out = try FotufilmEngine(stock: stock, options: options).processChecked(linearRGB: linear)
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
        return (width, height)
    }

    #if canImport(FotufilmMetal)
    private func developOnMetal(
        _ metal: HalideMetalFilmRenderer, scene: [Float], width: Int, height: Int,
        stock: FilmStock, options: FotufilmEngine.Options, knee: Float, seed: UInt32,
        target: Target, shouldContinue: @escaping () -> Bool
    ) throws {
        // The shoulder and transfer ride in the producing kernel when a variant carries them,
        // which leaves only the quantization to the host.
        let requested: FilmOutputTransform? = target.format == .rgba8DisplayP3
            && metal.carriesOutputTransform(stock: stock, options: options, width: width,
                                            height: height, exactMath: false)
            ? .displayP3(shoulderKnee: knee) : nil
        func develop(_ requested: FilmOutputTransform?) -> (ok: Bool, kept: Bool) {
            var transform = requested
            let encoded = requested != nil
            let ok = scene.withUnsafeBufferPointer { source in
                metal.developStreaming(
                    width: width, height: height, stock: stock, options: options,
                    outputTransform: &transform, shouldContinue: shouldContinue,
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
