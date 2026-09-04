// Compares CUDA and CPU frame-path performance and output accuracy on identical pixels.
//
//   .build/release/fotufilmbench [--stock id] [--iterations n] [--no-grain] [--exact]
//                               [--realtime] [--device] [--size WxH] [--skip-cpu]
//
// Defaults to a bundled example stock, so it runs against a plain checkout. Point FOTUFILM_STOCKS
// at another pack to benchmark a different emulsion.

import FotufilmCore
import FotufilmHalide
import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Just enough of the CUDA driver to put a frame in device memory and leave it there.
///
/// The benchmark needs this to time what a video pipeline actually pays. The host entry points
/// copy the frame across the bus twice, and at 4K that copy is larger than everything else in the
/// frame put together, so timing them answers a question about PCIe rather than about the engine.
/// `--device` allocates the frames here and hands their pointers to the device entry points.
///
/// Loaded with dlopen rather than linked: libcuda is the driver's own library, injected into the
/// container by the host, and the benchmark should still build and run on a machine without it.
final class CUDADriver {
    private let library: UnsafeMutableRawPointer
    private let memAlloc: @convention(c) (UnsafeMutablePointer<UInt64>, Int) -> Int32
    private let memFree: @convention(c) (UInt64) -> Int32
    private let copyToDevice: @convention(c) (UInt64, UnsafeRawPointer, Int) -> Int32
    private let copyToHost: @convention(c) (UnsafeMutableRawPointer, UInt64, Int) -> Int32
    private let synchronize: @convention(c) () -> Int32

    init?() {
        guard let library = dlopen("libcuda.so.1", RTLD_NOW) else { return nil }
        self.library = library
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let address = dlsym(library, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        // The primary context, made current before anything touches Halide: Halide's CUDA runtime
        // adopts whatever context is already current on the thread, so this is what makes the
        // pointers below the same context the pipeline runs in. Allocating in a second context
        // would hand the pipeline addresses it cannot read.
        guard let initialize = symbol("cuInit", (@convention(c) (UInt32) -> Int32).self),
              let retain = symbol("cuDevicePrimaryCtxRetain",
                                  (@convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                                                   Int32) -> Int32).self),
              let setCurrent = symbol("cuCtxSetCurrent",
                                      (@convention(c) (UnsafeMutableRawPointer?) -> Int32).self),
              let memAlloc = symbol("cuMemAlloc_v2",
                                    (@convention(c) (UnsafeMutablePointer<UInt64>, Int)
                                        -> Int32).self),
              let memFree = symbol("cuMemFree_v2", (@convention(c) (UInt64) -> Int32).self),
              let copyToDevice = symbol("cuMemcpyHtoD_v2",
                                        (@convention(c) (UInt64, UnsafeRawPointer, Int)
                                            -> Int32).self),
              let copyToHost = symbol("cuMemcpyDtoH_v2",
                                      (@convention(c) (UnsafeMutableRawPointer, UInt64, Int)
                                          -> Int32).self),
              let synchronize = symbol("cuCtxSynchronize", (@convention(c) () -> Int32).self)
        else { return nil }

        self.memAlloc = memAlloc
        self.memFree = memFree
        self.copyToDevice = copyToDevice
        self.copyToHost = copyToHost
        self.synchronize = synchronize

        var context: UnsafeMutableRawPointer?
        guard initialize(0) == 0, retain(&context, 0) == 0, setCurrent(context) == 0 else {
            return nil
        }
    }

    func allocate(bytes: Int) -> UInt64? {
        var pointer: UInt64 = 0
        return memAlloc(&pointer, bytes) == 0 ? pointer : nil
    }
    func free(_ pointer: UInt64) { _ = memFree(pointer) }
    func upload(_ source: UnsafeRawPointer, to pointer: UInt64, bytes: Int) -> Bool {
        copyToDevice(pointer, source, bytes) == 0
    }
    func download(_ pointer: UInt64, to destination: UnsafeMutableRawPointer, bytes: Int) -> Bool {
        copyToHost(destination, pointer, bytes) == 0
    }
    /// The device entry points return once the pipeline's own sync has run, but the timed loop
    /// should not trust that alone: a queue left running would be charged to the next iteration.
    func wait() { _ = synchronize() }
}

/// Wall-clock seconds, from a clock that does not jump.
func now() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_MONOTONIC, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) * 1.0e-9
}

func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

/// Grain is drawn per pixel, so CUDA and the CPU disagree on it by construction even when both
/// are right. Pass --no-grain to silence it and see whether anything *else* disagrees: that run
/// is the one whose diff column is a correctness claim.
let noGrain = CommandLine.arguments.contains("--no-grain")
/// The GPU schedule uses fast_* polynomials unless asked otherwise, while the CPU pipeline always
/// evaluates the exact transcendentals. Pass --exact to put both on the same footing; the gap that
/// survives *that* is the one that would mean a real defect.
let exactMath = CommandLine.arguments.contains("--exact")
/// Float IO alone selects the stills path: the pipeline reads `realtime_` as `!float_io_` unless
/// the caller asks for the realtime bit as well. A video frame wants the realtime schedule — the
/// coarser diffusion, the fused develop, the packed intermediates — so without this flag the
/// benchmark reports the stills cost for a frame no video pipeline would ever pay it on.
let realtime = CommandLine.arguments.contains("--realtime")
/// Skips the CPU reference and the diff. The CPU pass is two orders of magnitude slower than the
/// frame it is checking, so a run that is only asking "how fast is the GPU now" spends all its
/// time in the reference; correctness runs still want it.
let skipCPU = CommandLine.arguments.contains("--skip-cpu")
/// Times the device entry points on frames that never leave the GPU, which is what a pipeline
/// decoding and encoding on the device pays. Without it the frame time is mostly PCIe.
let deviceResident = CommandLine.arguments.contains("--device")
let stockID = argument("--stock") ?? "example-negative-400"
let iterations = Int(argument("--iterations") ?? "") ?? 5
/// Frame sizes: a 1080p-ish frame, 4K, and a 61 MP stills frame. `--size WxH` replaces the list
/// with one frame, which is what an optimisation loop aimed at a single resolution wants.
let sizes: [(Int, Int)] = {
    guard let requested = argument("--size") else {
        return [(1920, 1080), (3840, 2160), (9504, 6336)]
    }
    let parts = requested.lowercased().split(separator: "x")
    guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
          width > 0, height > 0 else {
        FileHandle.standardError.write(Data("--size wants WxH, e.g. 3840x2160\n".utf8))
        exit(1)
    }
    return [(width, height)]
}()

/// Built before the first call into Halide, so the context it makes current is the one Halide
/// adopts. Constructing it later would leave the pipeline in a context of its own, and the
/// pointers below would not be addresses it could read.
let driver: CUDADriver? = deviceResident ? CUDADriver() : nil
if deviceResident && driver == nil {
    FileHandle.standardError.write(Data("--device needs libcuda.so.1 and a usable device\n".utf8))
    exit(1)
}

guard let stock = FilmStock.named(stockID) ?? FilmStock.default else {
    FileHandle.standardError.write(Data(
        "no stocks found: \(String(describing: FilmStockPack.loadError))\n".utf8))
    exit(1)
}

print("stock:      \(stockID)\(noGrain ? " (grain off)" : "")\(exactMath ? " (exact math)" : "")"
      + "\(realtime ? " (realtime)" : " (stills road)")"
      + "\(deviceResident ? " (device resident)" : " (host buffers)")")
print("cuda:       \(fotufilm_halide_cuda_available() == 1 ? "available" : "UNAVAILABLE")")
print("cpu halide: \(fotufilm_halide_available() == 1 ? "available" : "UNAVAILABLE")")
guard fotufilm_halide_cuda_available() == 1 else {
    FileHandle.standardError.write(Data("CUDA target unavailable on this host\n".utf8))
    exit(1)
}

/// A deterministic scene with gradients and edges, so the spatial stages (MTF, halation, grain)
/// have real structure to work on rather than flat field.
func syntheticFrame(width: Int, height: Int) -> (r: [Float], g: [Float], b: [Float]) {
    let count = width * height
    var r = [Float](repeating: 0, count: count)
    var g = [Float](repeating: 0, count: count)
    var b = [Float](repeating: 0, count: count)
    for y in 0..<height {
        let v = Float(y) / Float(height - 1)
        for x in 0..<width {
            let u = Float(x) / Float(width - 1)
            let index = y * width + x
            // A bright square, so highlights reach the shoulder and halation has something to bloom.
            let square = (u > 0.35 && u < 0.5 && v > 0.35 && v < 0.5) ? Float(6.0) : Float(0.0)
            r[index] = u * 1.2 + square
            g[index] = v * 1.1 + square
            b[index] = (1.0 - u) * 0.9 + square
        }
    }
    return (r, g, b)
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}
func padRight(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

print("")
print(padRight("frame", 13) + pad("cuda ms", 10) + pad("cuda fps", 10) + pad("cpu ms", 11)
      + pad("speedup", 9) + pad("max diff", 11) + pad("mean diff", 11))

for (width, height) in sizes {
    let count = width * height
    let scene = syntheticFrame(width: width, height: height)
    var options = FotufilmEngine.Options()
    if noGrain { options.grainScale = 0 }
    var invocation = FilmEngineInvocation(
        stock: stock, options: options, width: width, height: height)
    if exactMath { invocation.featureMask |= FilmEngineFeature.exactMath }
    if realtime { invocation.featureMask |= FilmEngineFeature.realtime }
    let dimension = Int32(invocation.spectral.exposure.dimension)

    // Interleaved RGBA for the GPU entry point; alpha is carried through untouched.
    var interleaved = [Float](repeating: 1.0, count: count * 4)
    for index in 0..<count {
        interleaved[index * 4 + 0] = scene.r[index]
        interleaved[index * 4 + 1] = scene.g[index]
        interleaved[index * 4 + 2] = scene.b[index]
    }
    var gpuOut = [Float](repeating: 0, count: count * 4)

    // Veiling glare requires a whole-frame measurement. The configuration uses -1 until measured,
    // and the engine rejects that sentinel. Measure outside the timed loop to match renderer setup.
    if invocation.featureMask & FilmEngineFeature.flare != 0 {
        interleaved.withUnsafeBufferPointer { pixels in
            invocation.flareMean = invocation.measuredAreaWeightedFlareMean(
                linearRGBA: pixels.baseAddress!, width: width, height: height)
        }
    }
    if invocation.localToneActive {
        var measurement = invocation.toneBaseMeasurement()
        interleaved.withUnsafeBufferPointer { pixels in
            measurement.add(linearRGBA: pixels.baseAddress!, rows: 0..<height)
        }
        invocation.setToneBase(measurement)
    }

    var status: Int32 = 0
    invocation.configuration.withUnsafeBufferPointer { configuration in
        invocation.withSpectralPointers { exposure, film, paper in
            status = fotufilm_halide_cuda_prepare(
                invocation.featureMask, exposure, film, paper, dimension,
                invocation.spectralCacheID)
        }
    }
    guard status == 0 else {
        FileHandle.standardError.write(Data("cuda prepare failed: \(status)\n".utf8))
        exit(1)
    }

    // The frame's two device allocations in `--device` mode. They are filled once, outside the
    // timed loop, because a video pipeline's frames arrive on the device already: the decoder
    // wrote them there and the encoder reads them from there.
    let frameBytes = count * 4 * MemoryLayout<Float>.size
    var deviceInput: UInt64 = 0
    var deviceOutput: UInt64 = 0
    if let driver {
        guard let input = driver.allocate(bytes: frameBytes),
              let output = driver.allocate(bytes: frameBytes) else {
            FileHandle.standardError.write(Data("cuMemAlloc failed at \(width)x\(height)\n".utf8))
            exit(1)
        }
        deviceInput = input
        deviceOutput = output
        let uploaded = interleaved.withUnsafeBufferPointer { pixels in
            driver.upload(pixels.baseAddress!, to: input, bytes: frameBytes)
        }
        guard uploaded else {
            FileHandle.standardError.write(Data("upload to device failed\n".utf8))
            exit(1)
        }
    }

    // One untimed pass first: it pays for JIT compilation and the LUT upload, which are not
    // per-frame costs and would otherwise land entirely on the first measurement.
    func runCUDA() -> Int32 {
        var result: Int32 = 0
        if let driver {
            invocation.configuration.withUnsafeBufferPointer { configuration in
                invocation.withSpectralPointers { exposure, film, paper in
                    result = fotufilm_halide_cuda_process_device_linear_float(
                        deviceInput, deviceOutput,
                        Int32(width), Int32(height), 0, 0,
                        configuration.baseAddress, exposure, film, paper,
                        dimension, invocation.spectralCacheID,
                        invocation.featureMask, invocation.seed)
                }
            }
            driver.wait()
            return result
        }
        interleaved.withUnsafeBufferPointer { input in
            gpuOut.withUnsafeMutableBufferPointer { output in
                invocation.configuration.withUnsafeBufferPointer { configuration in
                    invocation.withSpectralPointers { exposure, film, paper in
                        result = fotufilm_halide_cuda_process_linear_float(
                            input.baseAddress, output.baseAddress,
                            Int32(width), Int32(height), 0, 0,
                            configuration.baseAddress, exposure, film, paper,
                            dimension, invocation.spectralCacheID,
                            invocation.featureMask, invocation.seed)
                    }
                }
            }
        }
        return result
    }

    status = runCUDA()
    guard status == 0 else {
        FileHandle.standardError.write(Data("cuda frame failed: \(status)\n".utf8))
        exit(1)
    }
    var cudaBest = Double.greatestFiniteMagnitude
    for _ in 0..<iterations {
        let start = now()
        _ = runCUDA()
        cudaBest = min(cudaBest, now() - start)
    }

    // Bring the device frame back for the comparison below. This is untimed on purpose: it is the
    // copy the device entry points exist to avoid, and the benchmark only does it because it has
    // to read the pixels to check them. The diff is also what proves the two entry points agree —
    // a device pointer allocated in the wrong context would show up here rather than as a number.
    if let driver {
        let downloaded = gpuOut.withUnsafeMutableBufferPointer { pixels in
            driver.download(deviceOutput, to: pixels.baseAddress!, bytes: frameBytes)
        }
        guard downloaded else {
            FileHandle.standardError.write(Data("download from device failed\n".utf8))
            exit(1)
        }
        driver.free(deviceInput)
        driver.free(deviceOutput)

        // The 8-bit pair, checked against each other on the same configuration. A decoder hands
        // over 8-bit frames, so this is the likelier of the two entry points in a video pipeline;
        // it is also the one the float timing above would never touch. The two paths run the same
        // schedule on the same pixels, so anything but an exact match is a defect in the wrapping
        // rather than a tolerance to argue about.
        var byteInput = [UInt8](repeating: 255, count: count * 4)
        for index in 0..<(count * 4) where index % 4 != 3 {
            byteInput[index] = UInt8(max(0, min(255, Int(interleaved[index] * 255.0))))
        }
        var hostBytes = [UInt8](repeating: 0, count: count * 4)
        var deviceBytes = [UInt8](repeating: 0, count: count * 4)
        let byteCount = count * 4
        var byteStatus: Int32 = 0
        byteInput.withUnsafeBufferPointer { input in
            hostBytes.withUnsafeMutableBufferPointer { output in
                invocation.configuration.withUnsafeBufferPointer { configuration in
                    invocation.withSpectralPointers { exposure, film, paper in
                        byteStatus = fotufilm_halide_cuda_process_srgb8(
                            input.baseAddress, output.baseAddress,
                            Int32(width), Int32(height),
                            configuration.baseAddress, exposure, film, paper,
                            dimension, invocation.spectralCacheID,
                            invocation.featureMask, invocation.seed)
                    }
                }
            }
        }
        guard byteStatus == 0,
              let byteIn = driver.allocate(bytes: byteCount),
              let byteOut = driver.allocate(bytes: byteCount) else {
            FileHandle.standardError.write(Data("srgb8 host frame failed: \(byteStatus)\n".utf8))
            exit(1)
        }
        let byteUploaded = byteInput.withUnsafeBufferPointer { pixels in
            driver.upload(pixels.baseAddress!, to: byteIn, bytes: byteCount)
        }
        invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                byteStatus = fotufilm_halide_cuda_process_device_srgb8(
                    byteIn, byteOut, Int32(width), Int32(height),
                    configuration.baseAddress, exposure, film, paper,
                    dimension, invocation.spectralCacheID,
                    invocation.featureMask, invocation.seed)
            }
        }
        driver.wait()
        let byteDownloaded = deviceBytes.withUnsafeMutableBufferPointer { pixels in
            driver.download(byteOut, to: pixels.baseAddress!, bytes: byteCount)
        }
        driver.free(byteIn)
        driver.free(byteOut)
        guard byteUploaded, byteDownloaded, byteStatus == 0 else {
            FileHandle.standardError.write(Data("srgb8 device frame failed: \(byteStatus)\n".utf8))
            exit(1)
        }
        let mismatches = zip(hostBytes, deviceBytes).reduce(into: 0) { $0 += $1.0 == $1.1 ? 0 : 1 }
        print("    srgb8 device vs host: \(mismatches) of \(byteCount) bytes differ")
    }

    // The CPU reference, on the same pixels and the same configuration.
    var cpuR = [Float](repeating: 0, count: count)
    var cpuG = [Float](repeating: 0, count: count)
    var cpuB = [Float](repeating: 0, count: count)
    func runCPU() -> Int32 {
        var result: Int32 = 0
        scene.r.withUnsafeBufferPointer { inputR in
            scene.g.withUnsafeBufferPointer { inputG in
                scene.b.withUnsafeBufferPointer { inputB in
                    cpuR.withUnsafeMutableBufferPointer { outputR in
                        cpuG.withUnsafeMutableBufferPointer { outputG in
                            cpuB.withUnsafeMutableBufferPointer { outputB in
                                invocation.configuration.withUnsafeBufferPointer { configuration in
                                    invocation.withSpectralPointers { exposure, film, paper in
                                        result = fotufilm_halide_process(
                                            inputR.baseAddress, inputG.baseAddress,
                                            inputB.baseAddress,
                                            outputR.baseAddress, outputG.baseAddress,
                                            outputB.baseAddress,
                                            Int32(width), Int32(height),
                                            configuration.baseAddress,
                                            exposure, film, paper, dimension,
                                            invocation.featureMask, invocation.seed)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    var cpuBest = Double.nan
    if fotufilm_halide_available() == 1 && !skipCPU {
        status = runCPU()
        if status == 0 {
            cpuBest = Double.greatestFiniteMagnitude
            // Use one CPU iteration above 20 MP to keep benchmark duration practical.
            let cpuIterations = count > 20_000_000 ? 1 : iterations
            for _ in 0..<cpuIterations {
                let start = now()
                _ = runCPU()
                cpuBest = min(cpuBest, now() - start)
            }
        }
    }

    var maxDiff: Float = 0
    var sumDiff: Double = 0
    // Where the worst pixel is and what the two paths actually said there, plus the tail of the
    // distribution. A single max number cannot distinguish "one clamped pixel" from "the whole
    // frame is off", and those call for very different responses.
    var worstIndex = 0, worstChannel = 0
    var differences: [Float] = []
    // The distribution is only collected for the smallest frame: sorting 183M floats at 61 MP
    // would cost more than the benchmark it is describing, and the diff behaviour does not
    // depend on frame size here.
    let collectDistribution = count <= 2_100_000
    if cpuBest.isFinite {
        if collectDistribution { differences.reserveCapacity(count * 3) }
        for index in 0..<count {
            // The GPU float output ends in max(value, 0): below-black values are clamped there
            // and not on the CPU, so the reference gets the same clamp before comparison.
            // Without it the diff measures that one deliberate difference and nothing else.
            let planes = [max(cpuR[index], 0), max(cpuG[index], 0), max(cpuB[index], 0)]
            for channel in 0..<3 {
                let difference = abs(gpuOut[index * 4 + channel] - planes[channel])
                if difference > maxDiff {
                    maxDiff = difference
                    worstIndex = index
                    worstChannel = channel
                }
                sumDiff += Double(difference)
                if collectDistribution { differences.append(difference) }
            }
        }
    }
    let meanDiff = cpuBest.isFinite ? sumDiff / Double(count * 3) : Double.nan
    let label = "\(width)x\(height)"
    let speedup = cpuBest.isFinite ? cpuBest / cudaBest : Double.nan
    func number(_ value: Double, _ places: Int, _ width: Int) -> String {
        pad(value.isFinite ? String(format: "%.\(places)f", value) : "n/a", width)
    }
    print(padRight(label, 13) + number(cudaBest * 1000, 2, 10)
          + number(1.0 / cudaBest, 1, 10)
          + number(cpuBest * 1000, 2, 11) + number(speedup, 2, 8) + "x"
          + number(Double(maxDiff), 6, 11) + number(meanDiff, 6, 11))
    if !differences.isEmpty {
        differences.sort()
        func percentile(_ fraction: Double) -> Float {
            differences[min(differences.count - 1,
                            Int(fraction * Double(differences.count)))]
        }
        let x = worstIndex % width, y = worstIndex / width
        let channelName = ["R", "G", "B"][worstChannel]
        let cpuValue = [cpuR, cpuG, cpuB][worstChannel][worstIndex]
        let gpuValue = gpuOut[worstIndex * 4 + worstChannel]
        let overTenth = differences.reduce(into: 0) { $0 += $1 > 0.001 ? 1 : 0 }
        print("    worst \(channelName) at (\(x),\(y)) of \(width)x\(height): "
              + "cpu \(cpuValue) vs cuda \(gpuValue)")
        print("    |diff| p50 \(percentile(0.5)) p99 \(percentile(0.99)) "
              + "p99.9 \(percentile(0.999)); "
              + "\(overTenth) of \(differences.count) samples over 0.001 "
              + String(format: "(%.3f%%)",
                       100.0 * Double(overTenth) / Double(differences.count)))
    }
}
