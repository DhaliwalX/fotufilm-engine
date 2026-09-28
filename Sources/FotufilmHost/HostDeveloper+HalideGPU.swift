#if os(Linux)
import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
import FotufilmHalide

/// Linux's developer: the desktop Halide graph the Mac runs on Metal, on CUDA, or on Vulkan when
/// `FOTUFILM_GPU_DEVICE=vulkan` asks for it (`GpuConfiguration.h`). It develops the whole frame at
/// once and hands it over as display-linear Display P3, as `MetalDeveloper` does; films whose
/// layered transport runs outside the graph, and scanned negatives, develop on the CPU.
struct HalideGPUDeveloper: HostDeveloper {
    private let cpu = HalideCPUDeveloper()
    private let device: String

    init?() {
        guard fotufilm_halide_cuda_available() == 1 else { return nil }
        device = ProcessInfo.processInfo.environment["FOTUFILM_GPU_DEVICE"] == "vulkan"
            ? "vulkan" : "cuda"
    }

    var kind: String { device }
    var name: String { device == "vulkan" ? "Halide/Vulkan" : "Halide/CUDA" }

    /// Compiles the film's kernels with a small develop of the same variant, so the first preview
    /// costs what later ones do.
    func prepare(stock: FilmStock, options: FotufilmEngine.Options, width: Int, height: Int) {
        let size = 64
        let scene = [Float](repeating: 0.18, count: size * size * 4)
        try? develop(scene, width: size, height: size, stock: stock, noFilm: false,
                     options: options, pace: HostDevelopPace(), encode: false, knee: nil,
                     shouldContinue: { true }, deliver: { _, _, _ in })
    }

    func develop(_ scene: [Float], width: Int, height: Int, stock: FilmStock, noFilm: Bool,
                 options: FotufilmEngine.Options, pace: HostDevelopPace, encode: Bool, knee: Float?,
                 shouldContinue: @escaping () -> Bool,
                 deliver: (UnsafeBufferPointer<Float>, Range<Int>, Bool) -> Void) throws {
        if !noFilm, options.transportConstruction(for: stock) != nil {
            return try cpu.develop(scene, width: width, height: height, stock: stock,
                                   noFilm: noFilm, options: options, pace: pace, encode: encode,
                                   knee: knee, shouldContinue: shouldContinue, deliver: deliver)
        }
        var invocation = try FilmEngineInvocation(
            validating: stock, options: options, width: width, height: height,
            frameIndex: pace.frameIndex, noFilm: noFilm)
        if pace.realtime { invocation.featureMask |= FilmEngineFeature.realtime }
        if pace.exactMath { invocation.featureMask |= FilmEngineFeature.exactMath }
        // Whole-frame measurements, as the Mac's renderer takes them before developing.
        scene.withUnsafeBufferPointer { rows in
            if invocation.featureMask & FilmEngineFeature.flare != 0 {
                invocation.flareMean = invocation.measuredAreaWeightedFlareMean(
                    linearRGBA: rows.baseAddress!, width: width, height: height)
            }
            if invocation.sceneMeteringActive {
                var measurement = invocation.toneBaseMeasurement()
                measurement.add(linearRGBA: rows.baseAddress!, rows: 0..<height)
                invocation.setToneBase(measurement)
            }
        }
        guard shouldContinue() else {
            throw HostEngine.Failure(description: "Cancelled.", cancelled: true)
        }
        let dimension = Int32(invocation.spectral.exposure.dimension)
        var output = [Float](repeating: 0, count: width * height * 4)
        var status: Int32 = -1
        invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                guard fotufilm_halide_cuda_prepare(
                    invocation.featureMask, exposure, film, paper, dimension,
                    invocation.spectralCacheID) == 0 else { return }
                scene.withUnsafeBufferPointer { input in
                    output.withUnsafeMutableBufferPointer { result in
                        status = fotufilm_halide_cuda_process_linear_float(
                            input.baseAddress, result.baseAddress, Int32(width), Int32(height),
                            0, 0, configuration.baseAddress, exposure, film, paper, dimension,
                            invocation.spectralCacheID, invocation.featureMask, invocation.seed)
                    }
                }
            }
        }
        guard status == 0 else {
            let cancelled = !shouldContinue()
            throw HostEngine.Failure(
                description: cancelled ? "Cancelled." : "The \(name) develop failed.",
                cancelled: cancelled)
        }
        // Metal and CUDA floor the light in the kernel; Vulkan leaves negative components for the
        // host's display conversion, as the browser's graph does.
        for index in output.indices { output[index] = max(output[index], 0) }
        for index in 0..<(width * height) { output[index * 4 + 3] = 1 }
        output.withUnsafeBufferPointer { deliver($0, 0..<height, false) }
    }

    func printScan(width: Int, height: Int, stock: FilmStock, options: FotufilmEngine.Options,
                   calibration: ApproximateNegativeScan, shouldContinue: @escaping () -> Bool,
                   readScan: (Range<Int>, UnsafeMutableBufferPointer<Float>) -> Void,
                   writeRows: (Range<Int>, UnsafeBufferPointer<Float>) -> Void) throws {
        try cpu.printScan(width: width, height: height, stock: stock, options: options,
                          calibration: calibration, shouldContinue: shouldContinue,
                          readScan: readScan, writeRows: writeRows)
    }
}
#endif
