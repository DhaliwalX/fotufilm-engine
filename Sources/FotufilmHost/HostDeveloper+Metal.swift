#if canImport(Metal)
import Foundation
import Metal
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmMetal)
import FotufilmMetal
#endif

/// The Mac app's developer: Halide's Metal kernels, streamed in row bands, with the SDR shoulder
/// and transfer in the producing kernel when a variant carries them.
struct MetalDeveloper: HostDeveloper {
    let metal: HalideMetalFilmRenderer
    private let playback: PlaybackBuffers

    init?() {
        guard let metal = HalideMetalFilmRenderer.shared,
              let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.metal = metal
        playback = PlaybackBuffers(device: device)
    }

    /// The 8-bit road's frame in and out, kept for the next frame of the same size.
    private final class PlaybackBuffers {
        let device: MTLDevice
        var buffers: (input: MTLBuffer, output: MTLBuffer)?
        init(device: MTLDevice) { self.device = device }

        func take(bytes: Int) -> (input: MTLBuffer, output: MTLBuffer)? {
            if let buffers, buffers.input.length == bytes { return buffers }
            guard let input = device.makeBuffer(length: bytes, options: .storageModeShared),
                  let output = device.makeBuffer(length: bytes, options: .storageModeShared)
            else { return nil }
            buffers = (input, output)
            return buffers
        }
    }

    /// `processRGBA8`, the Mac app's playback and 8-bit export road.
    func developDisplay8(_ codes: HostVideoCodes, width: Int, height: Int, stock: FilmStock,
                         options: FotufilmEngine.Options, frameIndex: UInt64,
                         keepsCodes: Bool) -> (developed: [UInt8], original: [UInt8]?)? {
        let bytes = width * height * 4
        guard codes.count == bytes, let buffers = playback.take(bytes: bytes) else { return nil }
        codes.write(into: buffers.input.contents())
        guard metal.processRGBA8(input: buffers.input, output: buffers.output, width: width,
                                 height: height, stock: stock, options: options,
                                 frameIndex: frameIndex) else { return nil }
        return ([UInt8](UnsafeRawBufferPointer(start: buffers.output.contents(), count: bytes)),
                keepsCodes
                    ? [UInt8](UnsafeRawBufferPointer(start: buffers.input.contents(), count: bytes))
                    : nil)
    }

    var kind: String { "metal" }
    var name: String { "Halide/Metal" }

    func prepare(stock: FilmStock, options: FotufilmEngine.Options, width: Int, height: Int) {
        metal.prepare(stock: stock, options: options, frameWidth: width, frameHeight: height)
    }

    /// The Mac app's limit: the least the schedule needs, striped as finely as it goes, within
    /// the renderer's share of the machine.
    func canDevelop(width: Int, height: Int, stock: FilmStock, options: FotufilmEngine.Options,
                    exactMath: Bool) -> Bool {
        HalideMetalFilmRenderer.canRender(width: width, height: height, stock: stock,
                                          options: options, exactMath: exactMath)
    }

    func develop(_ scene: [Float], width: Int, height: Int, stock: FilmStock, noFilm: Bool,
                 options: FotufilmEngine.Options, pace: HostDevelopPace, encode: Bool, knee: Float?,
                 shouldContinue: @escaping () -> Bool,
                 deliver: (UnsafeBufferPointer<Float>, Range<Int>, Bool) -> Void) throws {
        let requested: FilmOutputTransform? = encode
            && metal.carriesOutputTransform(stock: stock, options: options, width: width,
                                            height: height, exactMath: pace.exactMath,
                                            noFilm: noFilm)
            ? .displayP3(shoulderKnee: knee) : nil
        func run(_ requested: FilmOutputTransform?, realtime: Bool,
                 exactMath: Bool = pace.exactMath) -> (ok: Bool, kept: Bool) {
            var transform = requested
            let encoded = requested != nil
            let ok = scene.withUnsafeBufferPointer { source in
                metal.developStreaming(
                    width: width, height: height, stock: stock, options: options,
                    outputTransform: &transform, frameIndex: pace.frameIndex, realtime: realtime,
                    exactMath: exactMath, noFilm: noFilm, shouldContinue: shouldContinue,
                    readRows: { rows, into in
                        into.baseAddress!.update(
                            from: source.baseAddress! + rows.lowerBound * width * 4,
                            count: rows.count * width * 4)
                    },
                    writeRows: { rows, from in deliver(from, rows, encoded) })
            }
            return (ok, (transform != nil) == encoded)
        }
        // An Accurate still lays its Film grain crystal by crystal over the whole frame, so a
        // magnified export shows none of the tiles' repeats; the host encodes it. A frame the
        // road cannot lay develops from the tiles below.
        if pace.exactMath, pace.frameIndex == 0, !noFilm,
           HalideMetalFilmRenderer.laysFrameGrain(stock: stock, options: options) {
            var none: FilmOutputTransform?
            let laid = scene.withUnsafeBufferPointer { source in
                metal.developWithFrameGrain(
                    width: width, height: height, stock: stock, options: options,
                    outputTransform: &none, exactMath: true, shouldContinue: shouldContinue,
                    readRows: { rows, into in
                        into.baseAddress!.update(
                            from: source.baseAddress! + rows.lowerBound * width * 4,
                            count: rows.count * width * 4)
                    },
                    writeRows: { rows, from in deliver(from, rows, false) })
            }
            if laid == true { return }
            if !shouldContinue() { throw HostEngine.Failure(description: "Cancelled.", cancelled: true) }
        }
        var result = run(requested, realtime: pace.realtime)
        // A film whose realtime schedule this build does not carry develops on the reference one.
        if !result.ok, pace.realtime, shouldContinue() { result = run(requested, realtime: false) }
        // A film whose exact variant this build does not carry develops on the approximation.
        if !result.ok, pace.exactMath, shouldContinue() {
            result = run(requested, realtime: false, exactMath: false)
        }
        // The engine refused the transform after all and handed back light: develop again,
        // encoding on the host.
        if result.ok, !result.kept { result = run(nil, realtime: false) }
        guard result.ok else {
            let cancelled = !shouldContinue()
            throw HostEngine.Failure(description: cancelled ? "Cancelled." : "The Metal develop failed.",
                                     cancelled: cancelled)
        }
    }

    func printScan(width: Int, height: Int, stock: FilmStock, options: FotufilmEngine.Options,
                   calibration: ApproximateNegativeScan, shouldContinue: @escaping () -> Bool,
                   readScan: (Range<Int>, UnsafeMutableBufferPointer<Float>) -> Void,
                   writeRows: (Range<Int>, UnsafeBufferPointer<Float>) -> Void) throws {
        guard metal.printScan(width: width, height: height, stock: stock, options: options,
                              calibration: calibration, shouldContinue: shouldContinue,
                              readScan: readScan, writeRows: writeRows) else {
            let cancelled = !shouldContinue()
            throw HostEngine.Failure(description: cancelled ? "Cancelled." : "The Metal print failed.",
                                     cancelled: cancelled)
        }
    }
}
#endif
