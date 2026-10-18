#if os(Linux)
import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
import FotufilmHalide

/// Linux's developer: the desktop Halide graph the Mac runs on Metal, on CUDA or Vulkan: whichever
/// the Halide build chose (`fotufilm_halide_gpu_device`). It develops the whole frame at once,
/// or in tiles when the device cannot hold it, and hands it over as display-linear Display P3,
/// as `MetalDeveloper` does. Layered Transport runs its transport on the CPU kernels between
/// device develops, and scanned negatives print on the device.
struct HalideGPUDeveloper: HostDeveloper {
    private let device: String

    init?() {
        switch fotufilm_halide_gpu_device() {
        case 1: device = "cuda"
        case 2: device = "vulkan"
        default: return nil
        }
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
        var output: [Float]
        if !noFilm, let model = options.transportConstruction(for: stock) {
            output = try developLayered(scene, width: width, height: height, stock: stock,
                                        options: options, model: model, pace: pace)
        } else {
            output = try developFrame(scene, width: width, height: height, stock: stock,
                                      noFilm: noFilm, options: options, pace: pace,
                                      shouldContinue: shouldContinue)
        }
        guard shouldContinue() else {
            throw HostEngine.Failure(description: "Cancelled.", cancelled: true)
        }
        // Metal and CUDA floor the light in the kernel; Vulkan leaves negative components for the
        // host's display conversion, as the browser's graph does.
        for index in output.indices { output[index] = max(output[index], 0) }
        for index in 0..<(width * height) { output[index * 4 + 3] = 1 }
        output.withUnsafeBufferPointer { deliver($0, 0..<height, false) }
    }

    private func developFrame(_ scene: [Float], width: Int, height: Int, stock: FilmStock,
                              noFilm: Bool, options: FotufilmEngine.Options,
                              pace: HostDevelopPace,
                              shouldContinue: () -> Bool) throws -> [Float] {
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
        var output = [Float](repeating: 0, count: width * height * 4)
        var status = Self.run(scene, width: width, height: height, invocation, light: false,
                              into: &output)
        // A develop whose realtime schedule this build does not carry (no film has none) runs on
        // the reference one, as the Mac's developer does.
        if status == -3, pace.realtime, shouldContinue() {
            invocation.featureMask &= ~FilmEngineFeature.realtime
            status = Self.run(scene, width: width, height: height, invocation, light: false,
                              into: &output)
        }
        guard status == 0 else {
            let cancelled = !shouldContinue()
            throw HostEngine.Failure(
                description: cancelled ? "Cancelled." : "The \(name) develop failed.",
                cancelled: cancelled)
        }
        return output
    }

    /// Layered Transport: the heads' light and the records' development on the device, the
    /// transport between them on the CPU kernels.
    private func developLayered(_ scene: [Float], width: Int, height: Int, stock: FilmStock,
                                options: FotufilmEngine.Options, model: LayeredTransport,
                                pace: HostDevelopPace) throws -> [Float] {
        let n = width * height
        var image = ImageBuffer(width: width, height: height)
        for i in 0..<n {
            for c in 0..<3 {
                let value = scene[i * 4 + c]
                image.planes[c][i] = value.isFinite ? value : 0
            }
        }
        let name = name
        let execution = TransportExecution(
            render: { image, invocation, light in
                try Self.render(image, invocation, light: light, name: name)
            },
            backend: .cpu)
        let developed = try LayeredTransportRenderer.process(
            image: image, stock: stock, options: options, model: model,
            frameIndex: pace.frameIndex, execution: execution)
        var output = [Float](repeating: 1, count: n * 4)
        for i in 0..<n {
            for c in 0..<3 { output[i * 4 + c] = developed.planes[c][i] }
        }
        return output
    }

    /// One of Layered Transport's develops, as `LayeredMetalTransport` runs it: a head's light,
    /// or records developed, a donor stock's fourth riding in the alpha.
    private static func render(_ image: ImageBuffer, _ supplied: FilmEngineInvocation,
                               light: Bool, name: String) throws -> ImageBuffer {
        let width = image.width, height = image.height, n = image.pixelCount
        var input = [Float](repeating: 1, count: n * 4)
        for (c, plane) in image.planes.prefix(4).enumerated() {
            for i in 0..<n { input[i * 4 + c] = plane[i] }
        }
        var invocation = supplied
        if invocation.featureMask & FilmEngineFeature.flare != 0 {
            input.withUnsafeBufferPointer {
                invocation.flareMean = invocation.measuredAreaWeightedFlareMean(
                    linearRGBA: $0.baseAddress!, width: width, height: height)
            }
        }
        let channels = light ? 3 : 4
        var output = [Float](repeating: 0, count: n * channels)
        let status = run(input, width: width, height: height, invocation, light: light,
                         into: &output)
        guard status == 0 else {
            throw TransportError.backend("The \(name) transport stage failed (\(status)).")
        }
        var result = ImageBuffer(width: width, height: height)
        for c in 0..<3 {
            for i in 0..<n { result.planes[c][i] = output[i * channels + c] }
        }
        return result
    }

    func printScan(width: Int, height: Int, stock: FilmStock, options: FotufilmEngine.Options,
                   calibration: ApproximateNegativeScan, shouldContinue: @escaping () -> Bool,
                   readScan: (Range<Int>, UnsafeMutableBufferPointer<Float>) -> Void,
                   writeRows: (Range<Int>, UnsafeBufferPointer<Float>) -> Void) throws {
        // The print stage reads the scan as the film's record densities: exposure and
        // development already happened to the scanned film.
        var options = options
        options.stage = .print
        options.scanReading = calibration
        var film = stock
        film.layeredTransport = nil
        var scan = [Float](repeating: 0, count: width * height * 4)
        scan.withUnsafeMutableBufferPointer { readScan(0..<height, $0) }
        // A sample that is not a number reads as one the film cannot place, and prints black.
        for index in scan.indices where !scan[index].isFinite { scan[index] = 0 }
        try develop(scan, width: width, height: height, stock: film, noFilm: false,
                    options: options, pace: HostDevelopPace(), encode: false, knee: nil,
                    shouldContinue: shouldContinue,
                    deliver: { rows, range, _ in writeRows(range, rows) })
    }

    // MARK: The device

    /// The fewest pixels a develop has failed on for want of device memory, as the frame or a
    /// tile with its apron: later frames start below it rather than fail again.
    private static let refused = Refused()
    private final class Refused: @unchecked Sendable {
        private let lock = NSLock()
        private var pixels = Int.max
        var value: Int { lock.withLock { pixels } }
        func record(_ value: Int) { lock.withLock { pixels = min(pixels, value) } }
    }

    /// Develops interleaved RGBA under `invocation` into `output`: RGBA, or the light as three
    /// floats a pixel when `light`, in tiles when the device cannot hold the frame
    /// (`HostDeviceTiles`), whose apron is the film's reach, the light chain's alone for a light.
    /// The whole-frame measurements are the caller's, already in the invocation.
    /// `FOTUFILM_GPU_TILE_PIXELS` caps what a develop reads, for the parity checks.
    private static func run(_ input: [Float], width: Int, height: Int,
                            _ invocation: FilmEngineInvocation, light: Bool,
                            into output: inout [Float]) -> Int32 {
        let entry = light ? fotufilm_halide_cuda_process_light_grid
            : fotufilm_halide_cuda_process_linear_float_tile
        let dimension = Int32(invocation.spectral.exposure.dimension)
        let forced = ProcessInfo.processInfo.environment["FOTUFILM_GPU_TILE_PIXELS"]
            .flatMap(Int.init)
        return invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper -> Int32 in
                guard fotufilm_halide_cuda_prepare(
                    invocation.featureMask, exposure, film, paper, dimension,
                    invocation.spectralCacheID) == 0 else { return -1 }
                return HostDeviceTiles.develop(
                    input, width: width, height: height, channels: light ? 3 : 4,
                    apron: max(1, light ? invocation.lightSupport : invocation.spatialSupport),
                    budget: min(forced ?? Int.max, refused.value - 1),
                    isOutOfMemory: { $0 == -11 || $0 == -16 }, refused: refused.record,
                    into: &output) { input, output, columns, rows, window, origin in
                        entry(input, output, Int32(columns), Int32(rows),
                              Int32(window.x), Int32(window.columns),
                              Int32(window.y), Int32(window.rows),
                              Int32(origin.x), Int32(origin.y), configuration.baseAddress,
                              exposure, film, paper, dimension, invocation.spectralCacheID,
                              invocation.featureMask, invocation.seed)
                    }
            }
        }
    }
}
#endif
