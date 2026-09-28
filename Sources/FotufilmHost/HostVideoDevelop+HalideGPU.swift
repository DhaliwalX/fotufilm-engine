#if os(Linux)
import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
import FotufilmHalide

/// Linux's movie develop: the Mac exporter's roads (`HostVideoDevelop+Metal.swift`) on the CUDA
/// or Vulkan kernels. The 8-bit road takes the decoder's Display P3 codes into the fused 8-bit
/// kernel; the deep road develops light and quantizes it with the dither `HostEngine.develop` uses
/// when the writer takes 8 bits. Every frame has its own buffers and `depth` are in flight: the
/// kernels take one frame at a time, while the frames around it are measured, filled and encoded.
struct HalideGPUVideoDeveloper: HostVideoDeveloper {
    /// Frames in flight at once; `FOTUFILM_VIDEO_GPU_CONCURRENCY` sweeps it, as on the Mac.
    static var depth: Int {
        max(1, ProcessInfo.processInfo.environment["FOTUFILM_VIDEO_GPU_CONCURRENCY"]
            .flatMap(Int.init) ?? 3)
    }

    init?() {
        guard fotufilm_halide_gpu_device() != 0 else { return nil }
    }

    func pipeline(for development: HostVideoDevelopment,
                  proceed: @escaping () -> Bool) -> HostVideoPipeline? {
        // Layered transport solves the whole frame on the CPU: the portable develop does it.
        guard development.options.transportConstruction(for: development.stock) == nil else { return nil }
        // These kernels have no hybrid of a small film and a full-size print, so Fast develops
        // the film at the delivered size, as Full does.
        var full = development
        (full.developWidth, full.developHeight) = (full.width, full.height)
        return HalideGPUVideoPipeline(full, depth: Self.depth, proceed: proceed)
    }
}

final class HalideGPUVideoPipeline: HostVideoPipeline {
    let development: HostVideoDevelopment
    let depth: Int
    let clock = HostVideoClock()
    private let device = fotufilm_halide_gpu_device() == 2 ? "Vulkan" : "CUDA"
    var name: String {
        let road = development.road
        return "\(device) \(road.deep ? (road.realtime ? "deep realtime" : "deep reference") : "8-bit"), "
            + "\(depth) in flight"
    }

    /// One frame's buffers and the develop filling them.
    private final class Slot {
        /// The 8-bit road's codes in; the output is its codes or the deep road's light.
        var codes: UnsafeMutableRawBufferPointer?
        var output: UnsafeMutableRawBufferPointer
        /// The delivered layout, when the output cannot go to the writer as it is.
        var scratch: UnsafeMutableRawBufferPointer?
        var delivered = UnsafeRawBufferPointer(start: nil, count: 0)
        var result: Result<Void, Error> = .success(())
        var job: DispatchWorkItem?

        init(output bytes: Int) {
            output = .allocate(byteCount: bytes, alignment: 64)
        }

        func scratch(_ bytes: Int) -> UnsafeMutableRawBufferPointer {
            if let scratch, scratch.count >= bytes { return scratch }
            scratch?.deallocate()
            let made = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes, alignment: 64)
            scratch = made
            return made
        }

        deinit {
            codes?.deallocate()
            output.deallocate()
            scratch?.deallocate()
        }
    }

    private let slots: [Slot]
    private var nextSlot = 0
    private var inFlight: [Slot] = []
    private let queue: DispatchQueue
    private let proceed: () -> Bool

    init(_ d: HostVideoDevelopment, depth: Int, proceed: @escaping () -> Bool) {
        development = d
        self.depth = depth
        self.proceed = proceed
        let pixels = d.width * d.height
        slots = (0..<depth).map { _ in
            let slot = Slot(output: pixels * (d.road.deep ? 16 : 4))
            if !d.road.deep { slot.codes = .allocate(byteCount: pixels * 4, alignment: 64) }
            return slot
        }
        // Frames are independent — their own buffers and frame index — so overlapping them changes
        // when a pixel is computed and never what it is.
        queue = DispatchQueue(label: "fotufilm.video.develop", qos: .userInitiated,
                              attributes: depth > 1 ? .concurrent : [])
    }

    deinit { drain() }

    /// The 8-bit road reads display codes, as the Mac's 8-bit road takes its decoder's frames.
    var takesDisplayCodes: Bool { !development.road.deep }

    func submit(_ scene: [Float], frameIndex: UInt64) throws {
        precondition(scene.count >= development.width * development.height * 4)
        start(scene: scene, codes: nil, frameIndex: frameIndex)
    }

    func submit(display8: HostVideoCodes, frameIndex: UInt64) throws {
        guard takesDisplayCodes, display8.count == development.width * development.height * 4 else {
            return try submit(HostVideoFrame.scene(display8: display8), frameIndex: frameIndex)
        }
        start(scene: nil, codes: display8, frameIndex: frameIndex)
    }

    private func start(scene: [Float]?, codes: HostVideoCodes?, frameIndex: UInt64) {
        precondition(inFlight.count < depth, "receive a frame first")
        let slot = slots[nextSlot]
        nextSlot = (nextSlot + 1) % depth
        let (d, clock, proceed) = (development, clock, proceed)
        let job = DispatchWorkItem {
            slot.result = Result {
                try Self.develop(scene: scene, codes: codes, frameIndex: frameIndex, in: slot,
                                 d, clock: clock, proceed: proceed)
            }
        }
        slot.job = job
        inFlight.append(slot)
        queue.async(execute: job)
    }

    func receive(_ deliver: (UnsafeRawBufferPointer) throws -> Void) throws {
        precondition(!inFlight.isEmpty, "nothing was submitted")
        let slot = inFlight.removeFirst()
        let waited = clock.mark()
        slot.job?.wait()
        slot.job = nil
        clock.charge("develop wait", since: waited)
        try slot.result.get()
        try deliver(slot.delivered)
    }

    func drain() {
        for slot in inFlight {
            slot.job?.wait()
            slot.job = nil
        }
        inFlight.removeAll()
    }

    // MARK: One frame

    private static func develop(scene: [Float]?, codes: HostVideoCodes?, frameIndex: UInt64,
                                in slot: Slot, _ d: HostVideoDevelopment, clock: HostVideoClock,
                                proceed: () -> Bool) throws {
        let cancelled = HostEngine.Failure(description: "Cancelled.", cancelled: true)
        guard proceed() else { throw cancelled }
        var started = clock.mark()
        if let codes, let input = slot.codes {
            codes.write(into: input.baseAddress!)
        } else if let scene, !d.road.deep, let input = slot.codes {
            HostVideoPixels.encodeDisplay8(scene, width: d.width, height: d.height,
                                           into: input.baseAddress!)
        }
        clock.charge("fill", since: started)

        started = clock.mark()
        let ok = d.road.deep
            ? developLight(scene ?? [], into: slot.output, d, frameIndex: frameIndex)
            : developCodes(slot.codes!, into: slot.output, d, frameIndex: frameIndex)
        clock.charge("kernel", since: started)
        guard proceed() else { throw cancelled }

        started = clock.mark()
        defer { clock.charge("deliver", since: started) }
        guard ok else {
            // A frame these kernels refuse develops the portable way, so the movie never loses it.
            let scratch = slot.scratch(d.deliveredBytes)
            try d.developFrame(scene ?? HostVideoFrame.scene(display8: codes!), d.width, d.height,
                               frameIndex, scratch)
            slot.delivered = UnsafeRawBufferPointer(scratch)
            return
        }
        let developed = UnsafeRawPointer(slot.output.baseAddress!)
        if d.road.deep {
            // Vulkan's graph leaves negative light for a host's display conversion; the writers
            // take it floored and opaque, as `HalideGPUDeveloper` hands a still over.
            let light = slot.output.baseAddress!.assumingMemoryBound(to: Float.self)
            let width = d.width
            SceneGeometry.concurrent(d.height) { y in
                for i in (y * width * 4)..<((y + 1) * width * 4) {
                    light[i] = i & 3 == 3 ? 1 : max(light[i], 0)
                }
            }
            if !d.linearOutput {
                // Deep light for an 8-bit writer: the dither `HostEngine.develop` quantizes with.
                let scratch = slot.scratch(d.deliveredBytes)
                DisplayEncoding.quantize8(
                    linear: UnsafeBufferPointer(start: light, count: d.width * d.height * 4),
                    rows: 0..<d.height, width: d.width, knee: d.knee,
                    into: scratch.baseAddress!, rowBytes: d.paddedWidth * 4, seed: d.seed)
                HostVideoPixels.pad(scratch.baseAddress!, width: d.width, height: d.height,
                                    paddedWidth: d.paddedWidth, paddedHeight: d.paddedHeight,
                                    bytesPerPixel: 4)
                slot.delivered = UnsafeRawBufferPointer(start: scratch.baseAddress!,
                                                        count: d.deliveredBytes)
                return
            }
        }
        if d.paddedWidth != d.width || d.paddedHeight != d.height {
            let scratch = slot.scratch(d.deliveredBytes)
            HostVideoPixels.deliver(developed, width: d.width, height: d.height,
                                    bytesPerPixel: d.bytesPerPixel, into: scratch.baseAddress!,
                                    paddedWidth: d.paddedWidth, paddedHeight: d.paddedHeight)
            slot.delivered = UnsafeRawBufferPointer(start: scratch.baseAddress!, count: d.deliveredBytes)
        } else {
            slot.delivered = UnsafeRawBufferPointer(start: developed, count: d.deliveredBytes)
        }
    }

    /// The Mac's `processRGBA8`: Display P3 codes in and out through the fused 8-bit kernel, the
    /// tone base measured from the codes and the glare averaged by the kernel.
    private static func developCodes(_ input: UnsafeMutableRawBufferPointer,
                                     into output: UnsafeMutableRawBufferPointer,
                                     _ d: HostVideoDevelopment, frameIndex: UInt64) -> Bool {
        guard var invocation = try? FilmEngineInvocation(
            validating: d.stock, options: d.options, width: d.width, height: d.height,
            frameIndex: frameIndex) else { return false }
        let codes = input.baseAddress!.assumingMemoryBound(to: UInt8.self)
        if invocation.sceneMeteringActive {
            invocation.measureToneBase(encodedDisplayP3RGBA: codes, width: d.width, height: d.height)
        }
        if invocation.featureMask & FilmEngineFeature.flare != 0 {
            invocation.featureMask |= FilmEngineFeature.flareMeasure
        }
        return run(invocation) { configuration, exposure, film, paper, dimension in
            fotufilm_halide_cuda_process_srgb8(
                codes, output.baseAddress!.assumingMemoryBound(to: UInt8.self),
                Int32(d.width), Int32(d.height), configuration, exposure, film, paper, dimension,
                invocation.spectralCacheID, invocation.featureMask, invocation.seed)
        }
    }

    /// The deep road: scene light in, linear Display P3 out, measured as `HalideGPUDeveloper`
    /// measures a still.
    private static func developLight(_ scene: [Float], into output: UnsafeMutableRawBufferPointer,
                                     _ d: HostVideoDevelopment, frameIndex: UInt64) -> Bool {
        guard var invocation = try? FilmEngineInvocation(
            validating: d.stock, options: d.options, width: d.width, height: d.height,
            frameIndex: frameIndex) else { return false }
        if d.road.realtime { invocation.featureMask |= FilmEngineFeature.realtime }
        scene.withUnsafeBufferPointer { rows in
            if invocation.featureMask & FilmEngineFeature.flare != 0 {
                invocation.flareMean = invocation.measuredAreaWeightedFlareMean(
                    linearRGBA: rows.baseAddress!, width: d.width, height: d.height)
            }
            if invocation.sceneMeteringActive {
                var measurement = invocation.toneBaseMeasurement()
                measurement.add(linearRGBA: rows.baseAddress!, rows: 0..<d.height)
                invocation.setToneBase(measurement)
            }
        }
        return scene.withUnsafeBufferPointer { input in
            run(invocation) { configuration, exposure, film, paper, dimension in
                fotufilm_halide_cuda_process_linear_float(
                    input.baseAddress, output.baseAddress!.assumingMemoryBound(to: Float.self),
                    Int32(d.width), Int32(d.height), 0, 0, configuration, exposure, film, paper,
                    dimension, invocation.spectralCacheID, invocation.featureMask, invocation.seed)
            }
        }
    }

    /// Uploads the film's tables where they changed and runs one kernel: whether it developed.
    private static func run(
        _ invocation: FilmEngineInvocation,
        _ kernel: (UnsafePointer<Float>, UnsafePointer<Float>?, UnsafePointer<Float>?,
                   UnsafePointer<Float>?, Int32) -> Int32
    ) -> Bool {
        let dimension = Int32(invocation.spectral.exposure.dimension)
        return invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                fotufilm_halide_cuda_prepare(invocation.featureMask, exposure, film, paper,
                                             dimension, invocation.spectralCacheID) == 0
                    && kernel(configuration.baseAddress!, exposure, film, paper, dimension) == 0
            }
        }
    }
}
#endif
