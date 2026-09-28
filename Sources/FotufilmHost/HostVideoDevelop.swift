import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

// How a movie export develops its frames, independent of any GPU API. A platform may supply a
// pipelined develop (`HostPlatform.videoDeveloper`, the Mac's is `HostVideoDevelop+Metal.swift`);
// without one, or for an edit its road cannot carry, every frame develops on its own through
// `HostEngine.develop` (`HostFrameVideoPipeline`).

/// Which way an export's frames go through the engine, as the Mac app's exporter chooses it
/// (`VideoDecodeDepth.road`): 8-bit display-encoded frames, or scene-linear float. A deep source
/// (more than eight bits, HDR, camera log) develops in float on the engine's reference schedule;
/// a deep delivery (HLG, ProRes, 10-bit HEVC) of an 8-bit source develops in float on the
/// realtime schedule; anything else takes the 8-bit road.
struct HostVideoRoad: Equatable {
    /// Scene-linear float in and linear light out, rather than 8-bit Display P3 both ways.
    var deep: Bool
    /// The engine's realtime schedule rather than its reference one.
    var realtime: Bool

    init(deepSource: Bool, deepDelivery: Bool) {
        deep = deepSource || deepDelivery
        realtime = !deepSource
    }
}

/// Video Quality, the Mac app's `VideoDevelopQuality`: Full develops the film at the delivered
/// size; Fast develops the 8-bit road's film at no more than 1080p and prints it at the delivered
/// size.
enum HostVideoProcessing: String {
    case full, fast

    init(_ id: String?) { self = id.flatMap(Self.init(rawValue:)) ?? .full }

    /// The long edge Fast develops the film at; nil for Full. `FOTUFILM_FAST_EDGE` overrides it,
    /// as it does the Mac app's.
    var developLongEdge: Int? {
        guard self == .fast else { return nil }
        return ProcessInfo.processInfo.environment["FOTUFILM_FAST_EDGE"].flatMap(Int.init) ?? 1920
    }
}

/// Develops one frame the portable way, straight into the delivered layout: `scene` is
/// scene-linear Rec.2020 RGBA at `sceneWidth` x `sceneHeight`, `frameIndex` moves the grain.
typealias HostVideoFrameDevelop = (_ scene: [Float], _ sceneWidth: Int, _ sceneHeight: Int,
                                   _ frameIndex: UInt64,
                                   _ into: UnsafeMutableRawBufferPointer) throws -> Void

/// One export's develop: the film, the road, the sizes, and what the writer takes.
struct HostVideoDevelopment {
    var stock: FilmStock
    var options: FotufilmEngine.Options
    var road: HostVideoRoad
    /// The delivered picture.
    var width: Int
    var height: Int
    /// The rows the writer takes: the delivered picture with its last column and row repeated to
    /// even sizes.
    var paddedWidth: Int
    var paddedHeight: Int
    /// Where the film develops: the delivered size, or smaller on Fast's hybrid road, whose print
    /// is then made at the delivered size.
    var developWidth: Int
    var developHeight: Int
    /// Whether the writer takes linear Display P3 light, 16 bytes a pixel, rather than 8-bit
    /// Display P3.
    var linearOutput: Bool
    /// The SDR shoulder and dither seed linear light is quantized with for an 8-bit writer.
    var knee: Float
    var seed: UInt32
    /// The portable develop, for a frame a platform's road refuses.
    var developFrame: HostVideoFrameDevelop

    var bytesPerPixel: Int { linearOutput ? 16 : 4 }
    var deliveredBytes: Int { paddedWidth * paddedHeight * bytesPerPixel }
    /// Fast's hybrid: the film developed small, the print made at the delivered size.
    var hybrid: Bool { developWidth != width || developHeight != height }
}

/// A platform's pipelined movie develop, as the Mac app's exporter runs it: frames in buffers the
/// GPU reads and writes in place, several in flight at once.
protocol HostVideoDeveloper {
    /// A pipeline for one export, or nil when this development cannot take it; the export then
    /// develops frame by frame. `proceed` turns false on a cancel.
    func pipeline(for development: HostVideoDevelopment,
                  proceed: @escaping () -> Bool) -> HostVideoPipeline?
}

/// Frames developing in order. `submit` starts one; `receive` waits for the oldest still in
/// flight and hands its delivered pixels over, valid only during the call. At most `depth`
/// frames may be in flight.
protocol HostVideoPipeline: AnyObject {
    var development: HostVideoDevelopment { get }
    var depth: Int { get }
    /// What `FOTUFILM_VIDEO_TIMINGS` names this pipeline, and where it charges its stages.
    var name: String { get }
    var clock: HostVideoClock { get }
    /// Starts a frame: `scene` is at the development's develop size.
    func submit(_ scene: [Float], frameIndex: UInt64) throws
    /// Whether `submit(display8:)` develops an 8-bit decoder's Display P3 codes as they are,
    /// rather than through light.
    var takesDisplayCodes: Bool { get }
    /// Starts a frame from upright RGBA8 Display P3 codes at the develop size.
    func submit(display8: HostVideoCodes, frameIndex: UInt64) throws
    func receive(_ deliver: (UnsafeRawBufferPointer) throws -> Void) throws
    /// Waits out every frame still in flight and discards them.
    func drain()
}

extension HostVideoPipeline {
    var takesDisplayCodes: Bool { false }

    func submit(display8: HostVideoCodes, frameIndex: UInt64) throws {
        try submit(HostVideoFrame.scene(display8: display8), frameIndex: frameIndex)
    }
}

/// The portable pipeline: each frame develops as it is submitted, one at a time.
final class HostFrameVideoPipeline: HostVideoPipeline {
    let development: HostVideoDevelopment
    let depth = 1
    var name: String { "frame by frame" }
    let clock = HostVideoClock()
    private var pixels: [UInt8]
    private var ready = false

    init(_ development: HostVideoDevelopment) {
        self.development = development
        pixels = [UInt8](repeating: 0, count: development.deliveredBytes)
    }

    func submit(_ scene: [Float], frameIndex: UInt64) throws {
        precondition(!ready, "receive the last frame first")
        let d = development
        let started = clock.mark()
        try pixels.withUnsafeMutableBytes {
            try d.developFrame(scene, d.developWidth, d.developHeight, frameIndex, $0)
        }
        clock.charge("develop", since: started)
        ready = true
    }

    func receive(_ deliver: (UnsafeRawBufferPointer) throws -> Void) throws {
        precondition(ready, "nothing was submitted")
        ready = false
        try pixels.withUnsafeBytes(deliver)
    }

    func drain() { ready = false }
}

/// Pixel handling shared by the pipelines.
enum HostVideoPixels {
    /// Repeats the last column and row into the one-pixel margin an odd size leaves; rows are
    /// `paddedWidth` pixels apart.
    static func pad(_ pixels: UnsafeMutableRawPointer, width: Int, height: Int,
                    paddedWidth: Int, paddedHeight: Int, bytesPerPixel: Int) {
        let rowBytes = paddedWidth * bytesPerPixel
        if paddedWidth > width {
            for y in 0..<height {
                let row = pixels + y * rowBytes
                (row + width * bytesPerPixel).copyMemory(from: row + (width - 1) * bytesPerPixel,
                                                         byteCount: bytesPerPixel)
            }
        }
        if paddedHeight > height {
            (pixels + height * rowBytes).copyMemory(from: pixels + (height - 1) * rowBytes,
                                                    byteCount: rowBytes)
        }
    }

    /// Tightly packed rows into the delivered layout, padded.
    static func deliver(_ source: UnsafeRawPointer, width: Int, height: Int, bytesPerPixel: Int,
                        into target: UnsafeMutableRawPointer, paddedWidth: Int, paddedHeight: Int) {
        if paddedWidth == width {
            target.copyMemory(from: source, byteCount: width * height * bytesPerPixel)
        } else {
            for y in 0..<height {
                (target + y * paddedWidth * bytesPerPixel).copyMemory(
                    from: source + y * width * bytesPerPixel, byteCount: width * bytesPerPixel)
            }
        }
        pad(target, width: width, height: height, paddedWidth: paddedWidth,
            paddedHeight: paddedHeight, bytesPerPixel: bytesPerPixel)
    }

    /// Scene-linear Rec.2020 as 8-bit Display P3 with the sRGB transfer: the 8-bit road's input,
    /// what the Mac app's decoder hands its exporter. An 8-bit source's codes come back exactly.
    static func encodeDisplay8(_ scene: UnsafePointer<Float>, width: Int, height: Int,
                               into target: UnsafeMutableRawPointer) {
        let thresholds = display8Thresholds
        SceneGeometry.concurrent(height) { y in
            let row = (target + y * width * 4).assumingMemoryBound(to: UInt8.self)
            thresholds.withUnsafeBufferPointer { thresholds in
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let p3 = ColorScience.linearRec2020ToDisplayP3(
                        SIMD3(scene[i], scene[i + 1], scene[i + 2]))
                    for c in 0..<3 { row[x * 4 + c] = code8(p3[c], thresholds) }
                    row[x * 4 + 3] = 255
                }
            }
        }
    }

    /// The linear light at which each 8-bit sRGB code rounds up to the next: code `c` covers
    /// light from `thresholds[c - 1]` to `thresholds[c]`. Rounding `linearToSrgb(v) * 255` for a
    /// frame's worth of channels is a transcendental each; this is eight comparisons.
    private static let display8Thresholds: [Float] = (0..<255).map {
        ColorScience.srgbToLinear((Float($0) + 0.5) / 255)
    }

    @inline(__always)
    private static func code8(_ value: Float, _ thresholds: UnsafeBufferPointer<Float>) -> UInt8 {
        guard value >= thresholds[0] else { return 0 }   // NaN too
        var low = 0, high = 255
        while high - low > 1 {
            let middle = (low + high) / 2
            if value >= thresholds[middle] { low = middle } else { high = middle }
        }
        return UInt8(high)
    }

    /// Bilinear resampling of RGBA floats, pixel centres aligned: how a frame developed small is
    /// brought to the delivered size when it has to take the portable road.
    static func resample(_ rgba: [Float], width: Int, height: Int,
                         to targetWidth: Int, _ targetHeight: Int) -> [Float] {
        if width == targetWidth && height == targetHeight { return rgba }
        var out = [Float](repeating: 0, count: targetWidth * targetHeight * 4)
        let sx = Double(width) / Double(targetWidth), sy = Double(height) / Double(targetHeight)
        out.withUnsafeMutableBufferPointer { out in
            let out = out
            SceneGeometry.concurrent(targetHeight) { y in
                let fy = min(max((Double(y) + 0.5) * sy - 0.5, 0), Double(height - 1))
                let y0 = Int(fy), y1 = min(y0 + 1, height - 1), ty = Float(fy - Double(y0))
                for x in 0..<targetWidth {
                    let fx = min(max((Double(x) + 0.5) * sx - 0.5, 0), Double(width - 1))
                    let x0 = Int(fx), x1 = min(x0 + 1, width - 1), tx = Float(fx - Double(x0))
                    for c in 0..<4 {
                        let top = rgba[(y0 * width + x0) * 4 + c] * (1 - tx)
                            + rgba[(y0 * width + x1) * 4 + c] * tx
                        let bottom = rgba[(y1 * width + x0) * 4 + c] * (1 - tx)
                            + rgba[(y1 * width + x1) * 4 + c] * tx
                        out[(y * targetWidth + x) * 4 + c] = top * (1 - ty) + bottom * ty
                    }
                }
            }
        }
        return out
    }
}

/// Where an export's wall time went, stage by stage, printed to standard error when
/// `FOTUFILM_VIDEO_TIMINGS=1`. The stages overlap once frames are in flight together, so the
/// columns can sum to more than the run.
final class HostVideoClock: @unchecked Sendable {
    static let isEnabled = ProcessInfo.processInfo.environment["FOTUFILM_VIDEO_TIMINGS"] == "1"
    private let lock = NSLock()
    private var seconds: [(String, Double)] = []

    func mark() -> UInt64 { Self.isEnabled ? DispatchTime.now().uptimeNanoseconds : 0 }

    func charge(_ stage: String, since start: UInt64) {
        guard Self.isEnabled else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        lock.lock()
        if let index = seconds.firstIndex(where: { $0.0 == stage }) {
            seconds[index].1 += elapsed
        } else {
            seconds.append((stage, elapsed))
        }
        lock.unlock()
    }

    func report(_ title: String, frames: Int, wall: Double) {
        guard Self.isEnabled, frames > 0 else { return }
        lock.lock()
        let stages = seconds.map { String(format: "%@ %.2f", $0.0, $0.1 * 1000 / Double(frames)) }
        lock.unlock()
        let line = String(format: "fotufilm video: %@, %d frames, %.2f s (%.2f ms/frame) | ",
                          title, frames, wall, wall * 1000 / Double(frames))
            + stages.joined(separator: " · ") + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
