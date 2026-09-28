import Foundation

import FotufilmHalide

// The engine the bridge develops through, one per platform, answering the calls
// `FotufilmBridge.swift` makes: on the Mac the Metal renderer the app uses, on Linux the same
// desktop graph ahead-of-time compiled for CUDA and Vulkan.

#if !os(Linux)
typealias BridgeRenderer = HalideMetalFilmRenderer
typealias BridgeStaging = FilmFrameStaging

extension HalideMetalFilmRenderer {
    static let missingDevice = "no Metal device the Halide engine can use"
    /// Metal decodes and encodes the host's colour in its kernels.
    static let transformsOnDevice = true
}

/// One effect instance's Metal arguments, bound around each call that renders.
final class BridgeDevice {
    private let context: UnsafeMutableRawPointer

    init?() {
        guard let context = fotufilm_halide_metal_context_create() else { return nil }
        self.context = context
    }

    func run<Result>(_ body: () -> Result) -> Result {
        let previous = fotufilm_halide_metal_context_bind(context)
        defer { fotufilm_halide_metal_context_restore(previous) }
        return body()
    }

    deinit { fotufilm_halide_metal_context_destroy(context) }
}
#else
/// Linux keeps its device state process-wide (`FotufilmHalideLinux.cpp`), so an instance has
/// nothing of its own to bind.
final class BridgeDevice {
    init?() {}
    func run<Result>(_ body: () -> Result) -> Result { body() }
}

/// A frame's pair of host buffers, as the Metal staging is a pair of shared ones: the host decodes
/// into `scenePixels` and encodes out of `developedPixels`, and the kernels read and write them in
/// place.
final class BridgeStaging {
    let capacityPixels: Int
    let scenePixels: UnsafeMutablePointer<Float>
    let developedPixels: UnsafeMutablePointer<Float>

    init(pixels: Int) {
        capacityPixels = pixels
        scenePixels = .allocate(capacity: pixels * 4)
        developedPixels = .allocate(capacity: pixels * 4)
    }

    deinit {
        scenePixels.deallocate()
        developedPixels.deallocate()
    }
}

/// The develop on CUDA or Vulkan, whichever `fotufilm_halide_gpu_device` chose, measured on the
/// host as `HalideGPUDeveloper` measures a still. A film whose layered transport runs outside the
/// graph, or a machine with neither device, develops through the CPU engine; a frame the kernels
/// have no variant for fails, as it does on the Mac, so the controls the host dims agree. The host
/// decodes and encodes: no output transform is carried in the kernel.
final class BridgeRenderer {
    static let shared: BridgeRenderer? = BridgeRenderer()
    static let missingDevice = "no GPU the Halide engine can use"
    static let transformsOnDevice = false

    private let onDevice = fotufilm_halide_gpu_device() != 0
    private let poolLock = NSLock()
    private var idle: BridgeStaging?

    /// What a pixel costs in flight: the staging pair, and the graph's light chain and develop
    /// as the Mac measured them (`HalideMetalFilmRenderer.stripBytesPerRow`); the graph is the same.
    private static let bytesPerPixel = 32 + 48 + 144

    /// Frames up to 16384 on a side develop whole: the staging is host memory. The Mac's
    /// `FOTUFILM_STRIP_BUDGET` bounds a frame here too, so a host can test its striped road.
    static func developsInOnePass(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return false }
        return fitsBudget(pixels: width * height)
    }

    private static func fitsBudget(pixels: Int) -> Bool {
        guard let raw = getenv("FOTUFILM_STRIP_BUDGET"), let budget = Int(String(cString: raw)),
              budget > 0 else { return true }
        return pixels * bytesPerPixel <= budget
    }

    func borrowFrameStaging(pixels: Int) -> BridgeStaging? {
        Self.fitsBudget(pixels: pixels) ? pooledStaging(pixels: pixels) : nil
    }

    private func pooledStaging(pixels: Int) -> BridgeStaging? {
        poolLock.lock()
        defer { poolLock.unlock() }
        if let staging = idle, staging.capacityPixels >= pixels {
            idle = nil
            return staging
        }
        return BridgeStaging(pixels: pixels)
    }

    /// Keeps one idle pair, the largest, for the next frame.
    func recycleFrameStaging(_ staging: BridgeStaging) {
        poolLock.lock()
        defer { poolLock.unlock() }
        if idle.map({ $0.capacityPixels < staging.capacityPixels }) ?? true { idle = staging }
    }

    /// Uploads the film's tables, so the first frame costs what later ones do.
    @discardableResult
    func prepare(stock: FilmStock, options: FotufilmEngine.Options,
                 frameWidth: Int, frameHeight: Int) -> Bool {
        guard onDevice, options.transportConstruction(for: stock) == nil,
              let invocation = try? FilmEngineInvocation(
                validating: stock, options: options, width: frameWidth, height: frameHeight)
        else { return true }
        return invocation.withSpectralPointers { exposure, film, paper in
            fotufilm_halide_cuda_prepare(invocation.featureMask, exposure, film, paper,
                                         Int32(invocation.spectral.exposure.dimension),
                                         invocation.spectralCacheID) == 0
        }
    }

    func carriesOutputTransform(stock: FilmStock, options: FotufilmEngine.Options,
                                width: Int, height: Int, realtime: Bool,
                                measuresGlareOnDevice: Bool) -> Bool { false }

    func decodeStaged(_ staging: BridgeStaging, width: Int, height: Int,
                      transform: FilmInputTransform, realtime: Bool) -> FilmDecodeReport? { nil }

    func decodeRows(_ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>,
                    width: Int, rows: Int, transform: FilmInputTransform,
                    realtime: Bool) -> FilmDecodeReport? { nil }

    func developStaged(_ staging: BridgeStaging, width: Int, height: Int, stock: FilmStock,
                       options: FotufilmEngine.Options, outputTransform: inout FilmOutputTransform?,
                       frameIndex: UInt64, realtime: Bool, measuresGlareOnDevice: Bool,
                       shouldContinue: (() -> Bool)?) -> Bool {
        outputTransform = nil
        guard staging.capacityPixels >= width * height else { return false }
        return develop(staging.scenePixels, into: staging.developedPixels, width: width,
                       height: height, stock: stock, options: options, frameIndex: frameIndex,
                       realtime: realtime, shouldContinue: shouldContinue ?? { true })
    }

    /// The whole frame read, developed and written back at once: the staging is host memory, so
    /// there is nothing a strip would save, and a budget too small for a staged frame still takes
    /// this road.
    func developStreaming(width: Int, height: Int, stock: FilmStock,
                          options: FotufilmEngine.Options,
                          outputTransform: inout FilmOutputTransform?, frameIndex: UInt64,
                          realtime: Bool, shouldContinue: (() -> Bool)?,
                          readRows: (Range<Int>, UnsafeMutableBufferPointer<Float>) -> Void,
                          writeRows: (Range<Int>, UnsafeBufferPointer<Float>) -> Void) -> Bool {
        outputTransform = nil
        guard let staging = pooledStaging(pixels: width * height) else { return false }
        defer { recycleFrameStaging(staging) }
        let count = width * height * 4
        readRows(0..<height, UnsafeMutableBufferPointer(start: staging.scenePixels, count: count))
        guard develop(staging.scenePixels, into: staging.developedPixels, width: width,
                      height: height, stock: stock, options: options, frameIndex: frameIndex,
                      realtime: realtime, shouldContinue: shouldContinue ?? { true })
        else { return false }
        writeRows(0..<height, UnsafeBufferPointer(start: staging.developedPixels, count: count))
        return true
    }

    private func develop(_ scene: UnsafeMutablePointer<Float>,
                         into output: UnsafeMutablePointer<Float>, width: Int, height: Int,
                         stock: FilmStock, options: FotufilmEngine.Options, frameIndex: UInt64,
                         realtime: Bool, shouldContinue: () -> Bool) -> Bool {
        guard shouldContinue() else { return false }
        let layered = options.transportConstruction(for: stock) != nil
        if onDevice, !layered {
            return developOnDevice(scene, into: output, width: width, height: height, stock: stock,
                                   options: options, frameIndex: frameIndex, realtime: realtime)
                && shouldContinue()
        }
        if developOnCPU(scene, into: output, width: width, height: height, stock: stock,
                        options: options, frameIndex: frameIndex) {
            return shouldContinue()
        }
        // The layered transport needs a Halide backend this build does not carry; the frame
        // develops with the film's own halation rather than not at all.
        guard onDevice, layered, shouldContinue() else { return false }
        return developOnDevice(scene, into: output, width: width, height: height, stock: stock,
                               options: options.withoutLayeredTransport, frameIndex: frameIndex,
                               realtime: realtime) && shouldContinue()
    }

    private func developOnDevice(_ scene: UnsafeMutablePointer<Float>,
                                 into output: UnsafeMutablePointer<Float>, width: Int,
                                 height: Int, stock: FilmStock, options: FotufilmEngine.Options,
                                 frameIndex: UInt64, realtime: Bool) -> Bool {
        guard var invocation = try? FilmEngineInvocation(
            validating: stock, options: options, width: width, height: height,
            frameIndex: frameIndex) else { return false }
        if realtime { invocation.featureMask |= FilmEngineFeature.realtime }
        // Whole-frame measurements, as the Mac's renderer takes them before developing.
        if invocation.featureMask & FilmEngineFeature.flare != 0 {
            invocation.flareMean = invocation.measuredAreaWeightedFlareMean(
                linearRGBA: scene, width: width, height: height)
        }
        if invocation.sceneMeteringActive {
            var measurement = invocation.toneBaseMeasurement()
            measurement.add(linearRGBA: scene, rows: 0..<height)
            invocation.setToneBase(measurement)
        }
        let dimension = Int32(invocation.spectral.exposure.dimension)
        let developed = invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                fotufilm_halide_cuda_prepare(invocation.featureMask, exposure, film, paper,
                                             dimension, invocation.spectralCacheID) == 0
                    && fotufilm_halide_cuda_process_linear_float(
                        scene, output, Int32(width), Int32(height), 0, 0,
                        configuration.baseAddress, exposure, film, paper, dimension,
                        invocation.spectralCacheID, invocation.featureMask,
                        invocation.seed) == 0
            }
        }
        guard developed else { return false }
        // Vulkan's graph leaves negative light in a finished print for a host's display
        // conversion; Metal and CUDA floor it in the kernel. The other spans hand back what they
        // were given, out-of-gamut values included, on every device.
        if fotufilm_halide_gpu_device() == 2, options.stage == .full || options.stage == .print {
            let count = width * height * 4
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for i in (y * width * 4)..<min(count, (y + 1) * width * 4) where i & 3 != 3 {
                    if !(output[i] > 0) { output[i] = 0 }
                }
            }
        }
        return true
    }

    /// The CPU engine, the frame's alpha carried across as the kernels carry it.
    private func developOnCPU(_ scene: UnsafeMutablePointer<Float>,
                              into output: UnsafeMutablePointer<Float>, width: Int, height: Int,
                              stock: FilmStock, options: FotufilmEngine.Options,
                              frameIndex: UInt64) -> Bool {
        var linear = ImageBuffer(width: width, height: height)
        for i in 0..<(width * height) {
            for channel in 0..<3 {
                let value = scene[i * 4 + channel]
                linear.planes[channel][i] = value.isFinite ? value : 0
            }
        }
        // The CPU pipeline has no frame index; the grain moves with the seed instead.
        var options = options
        options.seed &+= frameIndex
        guard let developed = try? FotufilmEngine(stock: stock, options: options)
            .processChecked(linearRGB: linear) else { return false }
        for i in 0..<(width * height) {
            output[i * 4] = developed.planes[0][i]
            output[i * 4 + 1] = developed.planes[1][i]
            output[i * 4 + 2] = developed.planes[2][i]
            output[i * 4 + 3] = scene[i * 4 + 3]
        }
        return true
    }
}
#endif
