import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Where a develop sits in a movie: the frame number, which moves the grain from frame to frame,
/// and whether interactive playback asked for the engine's realtime schedule.
struct HostDevelopPace {
    var frameIndex: UInt64 = 0
    var realtime = false
    /// The film's transcendentals evaluated exactly rather than approximated: the Mac app's
    /// Accurate photo quality, which its exports use by default.
    var exactMath = false
}

/// Develops scene light through a film. The platform may supply a GPU developer
/// (`HostPlatform.developer`); every build has the portable Halide CPU one.
protocol HostDeveloper {
    /// "metal", "cpu", …: what `fotufilm_engine_describe` reports.
    var kind: String { get }
    /// The name the editor shows (`web/src/editor/ViewerStatus.jsx`).
    var name: String { get }

    /// Builds what a film's first develop would otherwise build (kernel schedules, tables), so
    /// the first develop costs what later ones do.
    func prepare(stock: FilmStock, options: FotufilmEngine.Options, width: Int, height: Int)

    /// Develops scene-linear Rec. 2020 RGBA and hands the rows over as they finish:
    /// display-linear Display P3, or already shouldered and sRGB-encoded (the `Bool`) when
    /// `encode` was asked for and the developer does it in its kernel. `knee` is the SDR
    /// shoulder, nil with no film.
    func develop(_ scene: [Float], width: Int, height: Int, stock: FilmStock, noFilm: Bool,
                 options: FotufilmEngine.Options, pace: HostDevelopPace, encode: Bool, knee: Float?,
                 shouldContinue: @escaping () -> Bool,
                 deliver: (UnsafeBufferPointer<Float>, Range<Int>, Bool) -> Void) throws

    /// Develops upright RGBA8 Display P3 codes, as an 8-bit video decoder delivers them, straight
    /// to 8-bit Display P3 in one pass, as the Mac app's playback does, with the codes as read
    /// for the undeveloped picture; nil where this developer has no such road, and the frame then
    /// develops as light.
    func developDisplay8(_ codes: HostVideoCodes, width: Int, height: Int, stock: FilmStock,
                         options: FotufilmEngine.Options, frameIndex: UInt64) -> (developed: [UInt8], original: [UInt8])?

    /// Whether a frame this large develops with enough memory left for the rest of the app: the
    /// export sheet offers only the sizes that do.
    func canDevelop(width: Int, height: Int, stock: FilmStock, options: FotufilmEngine.Options,
                    exactMath: Bool) -> Bool

    /// Prints a scanned negative through the print stage: `readScan` fills rows of linear scan
    /// RGBA, the border calibration reads them as the film's record densities, and `writeRows`
    /// receives display-linear Display P3. Samples outside the film's densities print black.
    func printScan(width: Int, height: Int, stock: FilmStock, options: FotufilmEngine.Options,
                   calibration: ApproximateNegativeScan, shouldContinue: @escaping () -> Bool,
                   readScan: (Range<Int>, UnsafeMutableBufferPointer<Float>) -> Void,
                   writeRows: (Range<Int>, UnsafeBufferPointer<Float>) -> Void) throws
}

extension HostDeveloper {
    /// A developer that states no limit develops every size.
    func canDevelop(width: Int, height: Int, stock: FilmStock, options: FotufilmEngine.Options,
                    exactMath: Bool) -> Bool { true }

    func developDisplay8(_ codes: HostVideoCodes, width: Int, height: Int, stock: FilmStock,
                         options: FotufilmEngine.Options, frameIndex: UInt64) -> (developed: [UInt8], original: [UInt8])? {
        nil
    }
}

/// The portable developer: the Halide CPU pipeline, whole frame at once.
struct HalideCPUDeveloper: HostDeveloper {
    var kind: String { "cpu" }
    var name: String { "Halide/CPU" }

    /// Building the invocation has already built the tables; there is nothing to compile.
    func prepare(stock: FilmStock, options: FotufilmEngine.Options, width: Int, height: Int) {}

    func develop(_ scene: [Float], width: Int, height: Int, stock: FilmStock, noFilm: Bool,
                 options: FotufilmEngine.Options, pace: HostDevelopPace, encode: Bool, knee: Float?,
                 shouldContinue: @escaping () -> Bool,
                 deliver: (UnsafeBufferPointer<Float>, Range<Int>, Bool) -> Void) throws {
        guard !noFilm else {
            throw HostEngine.Failure(description: "Developing with no film needs a GPU developer.")
        }
        var linear = ImageBuffer(width: width, height: height)
        for i in 0..<(width * height) {
            for channel in 0..<3 {
                let value = scene[i * 4 + channel]
                linear.planes[channel][i] = value.isFinite ? value : 0
            }
        }
        // The CPU pipeline has no frame index; a movie's grain moves with the seed instead.
        var options = options
        options.seed &+= pace.frameIndex
        let out = try FotufilmEngine(stock: stock, options: options).processChecked(linearRGB: linear)
        guard shouldContinue() else { throw HostEngine.Failure(description: "Cancelled.", cancelled: true) }
        var developed = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            developed[i * 4] = out.planes[0][i]
            developed[i * 4 + 1] = out.planes[1][i]
            developed[i * 4 + 2] = out.planes[2][i]
        }
        developed.withUnsafeBufferPointer { deliver($0, 0..<height, false) }
    }

    /// The whole frame at once through the CPU print stage, as the GPU's banded print does it.
    func printScan(width: Int, height: Int, stock: FilmStock, options: FotufilmEngine.Options,
                   calibration: ApproximateNegativeScan, shouldContinue: @escaping () -> Bool,
                   readScan: (Range<Int>, UnsafeMutableBufferPointer<Float>) -> Void,
                   writeRows: (Range<Int>, UnsafeBufferPointer<Float>) -> Void) throws {
        var film = stock
        film.layeredTransport = nil
        var options = options
        options.stage = .print
        let count = width * height
        var rgba = [Float](repeating: 0, count: count * 4)
        rgba.withUnsafeMutableBufferPointer { readScan(0..<height, $0) }
        let base = SIMD3(calibration.baseDensity[0], calibration.baseDensity[1],
                         calibration.baseDensity[2])
        var density = ImageBuffer(width: width, height: height)
        var invalid = [Bool](repeating: false, count: count)
        for i in 0..<count {
            let sample = SIMD3(rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2])
            let d = calibration.density(of: sample)
            invalid[i] = d == nil
            for c in 0..<3 { density.planes[c][i] = (d ?? base)[c] }
        }
        let positive = try FotufilmEngine(stock: film, options: options)
            .printPositiveChecked(negativeDensity: density)
        guard shouldContinue() else {
            throw HostEngine.Failure(description: "Cancelled.", cancelled: true)
        }
        for i in 0..<count {
            for c in 0..<3 { rgba[i * 4 + c] = invalid[i] ? 0 : positive.planes[c][i] }
            rgba[i * 4 + 3] = 1
        }
        rgba.withUnsafeBufferPointer { writeRows(0..<height, $0) }
    }
}
