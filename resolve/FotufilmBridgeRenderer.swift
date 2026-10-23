import Foundation
#if !os(Linux)
import Metal
#endif

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

/// A host's frames when it hands them over as Metal buffers (the OFX GPU render extension): moved
/// between the host's buffers and the engine's staging on the GPU, on the host's own queue, so
/// the frame never visits CPU memory and the copies are ordered after the work that drew it.
final class BridgeHostFrames {
    private var mirrors: [MTLBuffer?] = [nil, nil]

    static func object<T>(_ pointer: UnsafeMutableRawPointer?) -> T? {
        guard let pointer else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }

    static func handle(_ object: AnyObject) -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(object).toOpaque()
    }

    /// Whether the queue and every buffer are on the device the engine develops on: a copy
    /// between devices is not a copy the GPU can make.
    static func usable(queue: UnsafeMutableRawPointer?,
                       buffers: [UnsafeMutableRawPointer?]) -> Bool {
        guard let queue: MTLCommandQueue = object(queue),
              let device = MTLCreateSystemDefaultDevice(), queue.device === device
        else { return false }
        return buffers.allSatisfy { pointer in
            (object(pointer) as MTLBuffer?).map { $0.device === device } ?? false
        }
    }

    static func staging(_ staging: BridgeStaging?)
        -> (scene: UnsafeMutableRawPointer, developed: UnsafeMutableRawPointer)? {
        guard let staging else { return nil }
        return (handle(staging.sceneBuffer), handle(staging.developedBuffer))
    }

    /// A shared buffer of at least `bytes` this context keeps for the frames that still need the
    /// CPU, and its CPU view.
    func mirror(slot: Int, bytes: Int)
        -> (buffer: UnsafeMutableRawPointer, contents: UnsafeMutableRawPointer)? {
        guard mirrors.indices.contains(slot), bytes > 0 else { return nil }
        if mirrors[slot].map({ $0.length < bytes }) ?? true {
            mirrors[slot] = nil
            mirrors[slot] = MTLCreateSystemDefaultDevice()?
                .makeBuffer(length: bytes, options: .storageModeShared)
        }
        guard let buffer = mirrors[slot] else { return nil }
        return (Self.handle(buffer), buffer.contents())
    }

    private static let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Rows { int sourceBase; int sourceStep; int destinationBase; int destinationStep;
                      uint width; uint rows; };
        kernel void fotufilm_copy_rows(device const float4 *source [[buffer(0)]],
                                       device float4 *destination [[buffer(1)]],
                                       constant Rows &rows [[buffer(2)]],
                                       uint2 at [[thread_position_in_grid]]) {
            if (at.x >= rows.width || at.y >= rows.rows) return;
            destination[rows.destinationBase + rows.destinationStep * int(at.y) + int(at.x)] =
                source[rows.sourceBase + rows.sourceStep * int(at.y) + int(at.x)];
        }
        """
    private static let pipelineLock = NSLock()
    nonisolated(unsafe) private static var pipelines: [ObjectIdentifier: MTLComputePipelineState] = [:]

    private static func pipeline(_ device: MTLDevice) -> MTLComputePipelineState? {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        if let built = pipelines[ObjectIdentifier(device)] { return built }
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "fotufilm_copy_rows"),
              let built = try? device.makeComputePipelineState(function: function)
        else { return nil }
        pipelines[ObjectIdentifier(device)] = built
        return built
    }

    /// Whether pixels `base + step * row + x` for every row and x stay inside a buffer.
    private static func fits(_ buffer: MTLBuffer, base: Int, step: Int, width: Int,
                             rows: Int) -> Bool {
        let first = base + min(0, step * (rows - 1))
        let last = base + max(0, step * (rows - 1)) + width - 1
        return first >= 0 && (last + 1) * 16 <= buffer.length && last < Int(Int32.max)
    }

    /// Copies `rows` rows of `width` RGBA-float pixels, pixel (x, row) of each side at
    /// `base + step * row + x`; a negative step walks the rows the other way. Encoded on the host's
    /// queue — after whatever drew the source, before whatever reads the destination — and waited
    /// for, so the engine's own queue may read what landed. 1 when copied, 0 when it could not be,
    /// -1 when the host's queue did not reach it within `timeout` seconds.
    static func copy(queue queuePointer: UnsafeMutableRawPointer?,
                     source sourcePointer: UnsafeMutableRawPointer?, sourceBase: Int,
                     sourceStep: Int, destination destinationPointer: UnsafeMutableRawPointer?,
                     destinationBase: Int, destinationStep: Int, width: Int, rows: Int,
                     timeout: Double = 4) -> Int32 {
        guard width > 0, rows > 0,
              let queue: MTLCommandQueue = object(queuePointer),
              let source: MTLBuffer = object(sourcePointer),
              let destination: MTLBuffer = object(destinationPointer),
              fits(source, base: sourceBase, step: sourceStep, width: width, rows: rows),
              fits(destination, base: destinationBase, step: destinationStep, width: width,
                   rows: rows),
              let pipeline = pipeline(queue.device),
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder()
        else { return 0 }
        var arguments = (Int32(sourceBase), Int32(sourceStep), Int32(destinationBase),
                         Int32(destinationStep), UInt32(width), UInt32(rows))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(destination, offset: 0, index: 1)
        encoder.setBytes(&arguments, length: MemoryLayout.size(ofValue: arguments), index: 2)
        let across = min(width, pipeline.threadExecutionWidth)
        encoder.dispatchThreads(
            MTLSize(width: width, height: rows, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: across,
                height: max(1, min(rows, pipeline.maxTotalThreadsPerThreadgroup / across)),
                depth: 1))
        encoder.endEncoding()
        commands.label = "Fotufilm host frame copy"
        let done = DispatchSemaphore(value: 0)
        commands.addCompletedHandler { _ in done.signal() }
        commands.commit()
        if done.wait(timeout: .now() + timeout) == .timedOut { return -1 }
        return commands.status == .completed ? 1 : 0
    }
}
#else
/// Linux keeps its device state process-wide (`FotufilmHalideLinux.cpp`), so an instance has
/// nothing of its own to bind.
final class BridgeDevice {
    init?() {}
    func run<Result>(_ body: () -> Result) -> Result { body() }
}

/// No host hands a Linux build Metal buffers: the plugin advertises the extension only on the Mac.
final class BridgeHostFrames {
    static func usable(queue: UnsafeMutableRawPointer?,
                       buffers: [UnsafeMutableRawPointer?]) -> Bool { false }
    static func staging(_ staging: BridgeStaging?)
        -> (scene: UnsafeMutableRawPointer, developed: UnsafeMutableRawPointer)? { nil }
    func mirror(slot: Int, bytes: Int)
        -> (buffer: UnsafeMutableRawPointer, contents: UnsafeMutableRawPointer)? { nil }
    static func copy(queue: UnsafeMutableRawPointer?, source: UnsafeMutableRawPointer?,
                     sourceBase: Int, sourceStep: Int,
                     destination: UnsafeMutableRawPointer?, destinationBase: Int,
                     destinationStep: Int, width: Int, rows: Int,
                     timeout: Double = 4) -> Int32 { 0 }
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
