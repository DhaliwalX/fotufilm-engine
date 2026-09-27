#if canImport(Metal)
import Foundation
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

    init?() {
        guard let metal = HalideMetalFilmRenderer.shared else { return nil }
        self.metal = metal
    }

    var kind: String { "metal" }
    var name: String { "Halide/Metal" }

    func prepare(stock: FilmStock, options: FotufilmEngine.Options, width: Int, height: Int) {
        metal.prepare(stock: stock, options: options, frameWidth: width, frameHeight: height)
    }

    func develop(_ scene: [Float], width: Int, height: Int, stock: FilmStock, noFilm: Bool,
                 options: FotufilmEngine.Options, pace: HostDevelopPace, encode: Bool, knee: Float?,
                 shouldContinue: @escaping () -> Bool,
                 deliver: (UnsafeBufferPointer<Float>, Range<Int>, Bool) -> Void) throws {
        let requested: FilmOutputTransform? = encode
            && metal.carriesOutputTransform(stock: stock, options: options, width: width,
                                            height: height, exactMath: false, noFilm: noFilm)
            ? .displayP3(shoulderKnee: knee) : nil
        func run(_ requested: FilmOutputTransform?, realtime: Bool) -> (ok: Bool, kept: Bool) {
            var transform = requested
            let encoded = requested != nil
            let ok = scene.withUnsafeBufferPointer { source in
                metal.developStreaming(
                    width: width, height: height, stock: stock, options: options,
                    outputTransform: &transform, frameIndex: pace.frameIndex, realtime: realtime,
                    noFilm: noFilm, shouldContinue: shouldContinue,
                    readRows: { rows, into in
                        into.baseAddress!.update(
                            from: source.baseAddress! + rows.lowerBound * width * 4,
                            count: rows.count * width * 4)
                    },
                    writeRows: { rows, from in deliver(from, rows, encoded) })
            }
            return (ok, (transform != nil) == encoded)
        }
        var result = run(requested, realtime: pace.realtime)
        // A film whose realtime schedule this build does not carry develops on the reference one.
        if !result.ok, pace.realtime, shouldContinue() { result = run(requested, realtime: false) }
        // The engine refused the transform after all and handed back light: develop again,
        // encoding on the host.
        if result.ok, !result.kept { result = run(nil, realtime: false) }
        guard result.ok else {
            let cancelled = !shouldContinue()
            throw HostEngine.Failure(description: cancelled ? "Cancelled." : "The Metal develop failed.",
                                     cancelled: cancelled)
        }
    }
}
#endif
