import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

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
                 options: FotufilmEngine.Options, encode: Bool, knee: Float?,
                 shouldContinue: @escaping () -> Bool,
                 deliver: (UnsafeBufferPointer<Float>, Range<Int>, Bool) -> Void) throws
}

/// The portable developer: the Halide CPU pipeline, whole frame at once.
struct HalideCPUDeveloper: HostDeveloper {
    var kind: String { "cpu" }
    var name: String { "Halide/CPU" }

    /// Building the invocation has already built the tables; there is nothing to compile.
    func prepare(stock: FilmStock, options: FotufilmEngine.Options, width: Int, height: Int) {}

    func develop(_ scene: [Float], width: Int, height: Int, stock: FilmStock, noFilm: Bool,
                 options: FotufilmEngine.Options, encode: Bool, knee: Float?,
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
}
