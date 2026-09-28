#if canImport(Metal)
import Foundation
import Metal
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmMetal)
import FotufilmMetal
#endif

/// The Mac app's video exporter (`VideoPipeline.export`) for the host: every frame in its own
/// shared buffers, which the CPU fills and reads in place and Halide's Metal kernels develop in
/// place, with `depth` frames in flight at once.
///
/// The 8-bit road is the Mac's (`processRGBA8`, or Fast's `processRGBA8Head` and `Tail`). The
/// deep road runs the Mac's float kernel on its road's schedule through `developStaged`, which is
/// `processLinearFloat` with the SDR shoulder and transfer in the producing kernel when an 8-bit
/// writer takes the frame: the same develop `HostEngine.develop` makes of a still.
struct MetalVideoDeveloper: HostVideoDeveloper {
    let metal: HalideMetalFilmRenderer
    let device: MTLDevice

    init?() {
        guard let metal = HalideMetalFilmRenderer.shared,
              let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.metal = metal
        self.device = device
    }

    /// Frames in flight at once. Two, where the Mac app's measurements stopped paying: a frame is
    /// a chain of full-frame passes, and a second frame's host work and passes fill the gaps in
    /// the first's. `FOTUFILM_VIDEO_GPU_CONCURRENCY` re-opens the sweep, as on the Mac.
    static var depth: Int {
        max(1, ProcessInfo.processInfo.environment["FOTUFILM_VIDEO_GPU_CONCURRENCY"]
            .flatMap(Int.init) ?? 2)
    }

    func pipeline(for development: HostVideoDevelopment,
                  proceed: @escaping () -> Bool) -> HostVideoPipeline? {
        // Layered transport solves the whole frame on the CPU, and a deep frame too large to
        // develop in one pass is cut into tiles: the portable develop does both.
        guard development.options.transportConstruction(for: development.stock) == nil,
              !development.road.deep
                || HalideMetalFilmRenderer.developsInOnePass(width: development.width,
                                                             height: development.height)
        else { return nil }
        return MetalVideoPipeline(metal: metal, device: device, development: development,
                                  depth: Self.depth, proceed: proceed)
    }
}

final class MetalVideoPipeline: HostVideoPipeline {
    let development: HostVideoDevelopment
    let depth: Int
    let clock = HostVideoClock()
    var name: String {
        let d = development
        let road = d.road.deep ? (d.road.realtime ? "deep realtime" : "deep reference")
            : (d.hybrid ? "8-bit hybrid from \(d.developWidth)x\(d.developHeight)" : "8-bit")
        return "Metal \(road), \(depth) in flight"
    }

    /// One frame's buffers and the develop filling them.
    private final class Slot {
        /// The 8-bit road's frame in and out, and Fast's film density at the develop size.
        var input: MTLBuffer?
        var sceneInput: MTLBuffer?
        var output: MTLBuffer?
        var density: MTLBuffer?
        /// The deep road's scene-linear frame in and developed frame out.
        var staging: FilmFrameStaging?
        /// The delivered layout, when the output cannot be handed to the writer as it is: an odd
        /// size, light for an 8-bit writer, or a frame the portable develop took.
        private var scratch: UnsafeMutableRawBufferPointer?
        var delivered = UnsafeRawBufferPointer(start: nil, count: 0)
        var result: Result<Void, Error> = .success(())
        var job: DispatchWorkItem?

        func scratch(_ bytes: Int) -> UnsafeMutableRawBufferPointer {
            if let scratch, scratch.count >= bytes { return scratch }
            scratch?.deallocate()
            let made = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes, alignment: 64)
            scratch = made
            return made
        }

        deinit { scratch?.deallocate() }
    }

    /// What a develop job reads; captured by value so no job holds the pipeline.
    private struct Context {
        let metal: HalideMetalFilmRenderer
        let development: HostVideoDevelopment
        let proceed: () -> Bool
        let clock: HostVideoClock
        let displayEncoder: MetalVideoDisplayEncoder?
    }

    private let context: Context
    private var slots: [Slot] = []
    private var nextSlot = 0
    private var inFlight: [Slot] = []
    private let queue: DispatchQueue

    init?(metal: HalideMetalFilmRenderer, device: MTLDevice, development d: HostVideoDevelopment,
          depth: Int, proceed: @escaping () -> Bool) {
        let cpuInput = ProcessInfo.processInfo.environment["FOTUFILM_VIDEO_CPU_INPUT"] == "1"
        let displayEncoder = d.road.deep || cpuInput ? nil : MetalVideoDisplayEncoder(device: device)
        for _ in 0..<depth {
            let slot = Slot()
            if d.road.deep {
                guard !d.hybrid,
                      let staging = metal.makeFrameStaging(pixels: d.width * d.height)
                else { return nil }
                slot.staging = staging
            } else {
                guard let input = device.makeBuffer(length: d.developWidth * d.developHeight * 4,
                                                    options: .storageModeShared),
                      let output = device.makeBuffer(length: d.width * d.height * 4,
                                                     options: .storageModeShared)
                else { return nil }
                slot.input = input
                slot.output = output
                if displayEncoder != nil {
                    slot.sceneInput = device.makeBuffer(length: d.developWidth * d.developHeight * 16,
                                                        options: .storageModeShared)
                }
                if d.hybrid {
                    guard let density = device.makeBuffer(
                        length: d.developWidth * d.developHeight * 8, options: .storageModeShared)
                    else { return nil }
                    slot.density = density
                }
            }
            slots.append(slot)
        }
        development = d
        self.depth = depth
        context = Context(metal: metal, development: d, proceed: proceed, clock: clock,
                          displayEncoder: displayEncoder)
        // Frames are independent — their own buffers and frame index, and the engine keeps its
        // execution state per thread — so overlapping them changes when a pixel is computed and
        // never what it is.
        queue = depth > 1
            ? DispatchQueue(label: "fotufilm.video.develop", qos: .userInitiated,
                            attributes: .concurrent)
            : DispatchQueue(label: "fotufilm.video.develop", qos: .userInitiated)
        metal.prepare(stock: d.stock, options: d.options, frameWidth: d.developWidth,
                      frameHeight: d.developHeight)
        if d.hybrid {
            metal.prepare(stock: d.stock, options: d.options, frameWidth: d.width,
                          frameHeight: d.height)
        }
    }

    deinit { drain() }

    /// A frame arrives as light, or as the 8-bit decoder's Display P3 codes.
    private enum Input {
        case scene([Float])
        case display8(HostVideoCodes)

        var scene: [Float] {
            switch self {
            case .scene(let scene): return scene
            case .display8(let codes): return HostVideoFrame.scene(display8: codes)
            }
        }
    }

    /// The 8-bit road reads display codes, and the display encoder proves the codes it would
    /// rebuild from their light are the decoder's own (`MetalVideoDisplayEncoder`): so they go
    /// in as they are, as the Mac app's 8-bit road takes its decoder's frames.
    var takesDisplayCodes: Bool {
        !development.road.deep && !development.hybrid && context.displayEncoder != nil
    }

    func submit(_ scene: [Float], frameIndex: UInt64) throws {
        precondition(scene.count >= development.developWidth * development.developHeight * 4)
        start(.scene(scene), frameIndex: frameIndex)
    }

    func submit(display8: HostVideoCodes, frameIndex: UInt64) throws {
        guard takesDisplayCodes,
              display8.count == development.developWidth * development.developHeight * 4 else {
            return try submit(HostVideoFrame.scene(display8: display8), frameIndex: frameIndex)
        }
        start(.display8(display8), frameIndex: frameIndex)
    }

    private func start(_ input: Input, frameIndex: UInt64) {
        precondition(inFlight.count < depth, "receive a frame first")
        let slot = slots[nextSlot]
        nextSlot = (nextSlot + 1) % depth
        let context = self.context
        let job = DispatchWorkItem {
            slot.result = Result { try Self.develop(input, frameIndex: frameIndex, in: slot,
                                                    context) }
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

    /// One frame: the scene into the slot, the develop, and the result into the layout the
    /// writer takes.
    private static func develop(_ input: Input, frameIndex: UInt64, in slot: Slot,
                                _ context: Context) throws {
        let (metal, d, clock) = (context.metal, context.development, context.clock)
        let cancelled = HostEngine.Failure(description: "Cancelled.", cancelled: true)
        guard context.proceed() else { throw cancelled }
        var started = clock.mark()
        if case .display8(let codes) = input, let buffer = slot.input {
            codes.write(into: buffer.contents())
        } else {
            fill(input.scene, slot: slot, context)
        }
        clock.charge("fill", since: started)
        try finish(input, frameIndex: frameIndex, in: slot, context)
    }

    /// The scene into the slot: the deep road's staging, or display codes for the 8-bit road.
    private static func fill(_ scene: [Float], slot: Slot, _ context: Context) {
        let d = context.development
        scene.withUnsafeBufferPointer { scene in
            if let staging = slot.staging {
                staging.scenePixels.update(from: scene.baseAddress!, count: d.width * d.height * 4)
            } else if let input = slot.input {
                let encoded = slot.sceneInput.map { staging in
                    context.displayEncoder?.encode(scene, staging: staging, output: input,
                        pixels: d.developWidth * d.developHeight) == true
                } ?? false
                if !encoded {
                    HostVideoPixels.encodeDisplay8(scene.baseAddress!, width: d.developWidth,
                                                   height: d.developHeight, into: input.contents())
                }
            }
        }
    }

    /// The develop, and the result into the layout the writer takes.
    private static func finish(_ input: Input, frameIndex: UInt64, in slot: Slot,
                               _ context: Context) throws {
        let (metal, d, clock) = (context.metal, context.development, context.clock)
        let cancelled = HostEngine.Failure(description: "Cancelled.", cancelled: true)
        var started = clock.mark()
        var ok = false
        // Light for an 8-bit writer leaves the kernel shouldered and encoded where this build
        // carries that variant; nil after the develop means it came back as light.
        var transform: FilmOutputTransform?
        if let staging = slot.staging {
            func run(realtime: Bool) -> Bool {
                transform = d.linearOutput ? nil : .displayP3(shoulderKnee: d.knee)
                return metal.developStaged(
                    staging, width: d.width, height: d.height, stock: d.stock,
                    options: d.options, outputTransform: &transform, frameIndex: frameIndex,
                    realtime: realtime, shouldContinue: context.proceed)
            }
            ok = run(realtime: d.road.realtime)
            // A film whose realtime schedule this build does not carry develops on the reference.
            if !ok, d.road.realtime, context.proceed() { ok = run(realtime: false) }
        } else if let input = slot.input, let output = slot.output {
            if let density = slot.density {
                ok = metal.processRGBA8Hybrid(
                    input: input, density: density, output: output,
                    width: d.width, height: d.height,
                    densityWidth: d.developWidth, densityHeight: d.developHeight,
                    stock: d.stock, options: d.options, frameIndex: frameIndex)
            } else {
                ok = metal.processRGBA8(
                    input: input, output: output, width: d.width, height: d.height,
                    stock: d.stock, options: d.options, frameIndex: frameIndex)
            }
        }
        clock.charge("kernel", since: started)
        guard context.proceed() else { throw cancelled }

        started = clock.mark()
        defer { clock.charge("deliver", since: started) }
        guard ok else {
            // A frame this build's road refuses develops the portable way, so the movie never
            // loses it.
            let scratch = slot.scratch(d.deliveredBytes)
            try d.developFrame(input.scene, d.developWidth, d.developHeight, frameIndex, scratch)
            slot.delivered = UnsafeRawBufferPointer(scratch)
            return
        }
        let developed: UnsafeRawPointer = slot.staging.map { UnsafeRawPointer($0.developedPixels) }
            ?? UnsafeRawPointer(slot.output!.contents())
        if d.road.deep && !d.linearOutput {
            // Deep light for an 8-bit writer: the dither `HostEngine.develop` quantizes with.
            let scratch = slot.scratch(d.deliveredBytes)
            let rows = UnsafeBufferPointer(start: developed.assumingMemoryBound(to: Float.self),
                                           count: d.width * d.height * 4)
            if transform != nil {
                DisplayEncoding.quantize8(encoded: rows, rows: 0..<d.height, width: d.width,
                                          into: scratch.baseAddress!, rowBytes: d.paddedWidth * 4,
                                          seed: d.seed)
            } else {
                DisplayEncoding.quantize8(linear: rows, rows: 0..<d.height, width: d.width,
                                          knee: d.knee, into: scratch.baseAddress!,
                                          rowBytes: d.paddedWidth * 4, seed: d.seed)
            }
            HostVideoPixels.pad(scratch.baseAddress!, width: d.width, height: d.height,
                                paddedWidth: d.paddedWidth, paddedHeight: d.paddedHeight,
                                bytesPerPixel: 4)
            slot.delivered = UnsafeRawBufferPointer(start: scratch.baseAddress!,
                                                    count: d.deliveredBytes)
        } else if d.paddedWidth != d.width || d.paddedHeight != d.height {
            let scratch = slot.scratch(d.deliveredBytes)
            HostVideoPixels.deliver(developed, width: d.width, height: d.height,
                                    bytesPerPixel: d.bytesPerPixel, into: scratch.baseAddress!,
                                    paddedWidth: d.paddedWidth, paddedHeight: d.paddedHeight)
            slot.delivered = UnsafeRawBufferPointer(start: scratch.baseAddress!,
                                                    count: d.deliveredBytes)
        } else {
            slot.delivered = UnsafeRawBufferPointer(start: developed, count: d.deliveredBytes)
        }
    }
}
#endif
