import Foundation
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmMetal)
import FotufilmMetal
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Recording modes supported by the production 10-bit camera graph, cached after measurement.
enum RecordingCapability {
    struct Mode: Equatable, Sendable, Identifiable {
        let width: Int
        let height: Int
        let frameRate: Int

        var id: String { "\(width)x\(height)@\(frameRate)" }
        var pixels: Int { width * height }

        var label: String {
            "\(height >= 2160 ? "4K" : "\(height)p")\(frameRate)"
        }

        /// The share of a frame the develop may take.
        var developCeiling: TimeInterval { 0.66 / Double(frameRate) }
    }

    /// Richest first, so `supported.first` is the best a phone can hold.
    static let all: [Mode] = [
        Mode(width: 3840, height: 2160, frameRate: 60),
        Mode(width: 3840, height: 2160, frameRate: 30),
        Mode(width: 1920, height: 1080, frameRate: 60),
        Mode(width: 1920, height: 1080, frameRate: 30),
    ]

    /// Fallback mode when no measurement is available.
    static let floor = Mode(width: 1920, height: 1080, frameRate: 30)

    private static let measuredSizes = [(1920, 1080), (3840, 2160)]

    struct Measurement: Codable, Sendable, Equatable {
        /// Slower HDR/SDR worst sample for one complete frame, seconds, keyed "WxH".
        var seconds: [String: TimeInterval]
        /// Per-delivery worst samples retained so diagnostics can show which derivative governed.
        var hdrSeconds: [String: TimeInterval]
        var sdrSeconds: [String: TimeInterval]
        /// Thermal state the run ended in.
        var thermal: String
        var taken: Date

        func develop(_ mode: Mode) -> TimeInterval? {
            seconds["\(mode.width)x\(mode.height)"]
        }

        func supports(_ mode: Mode) -> Bool {
            guard let measured = develop(mode) else { return false }
            return measured <= mode.developCeiling
        }

        var supported: [Mode] {
            let fitting = all.filter(supports)
            return fitting.contains(floor) ? fitting : fitting + [floor]
        }
    }

    /// The best mode this phone may record at.
    static var best: Mode {
        if let override { return override }
        lock.lock(); defer { lock.unlock() }
        if let resolved { return resolved }
        let mode = stored()?.supported.first ?? floor
        resolved = mode
        return mode
    }

    static var supported: [Mode] {
        if let override { return [override] }
        return stored()?.supported ?? [floor]
    }

    /// Whether the first-launch screen has anything to do.
    static var needsMeasuring: Bool { override == nil && stored() == nil }

    /// The run behind the verdict, for the settings screen.
    static var measurement: Measurement? { stored() }

    private static var override: Mode? {
        guard let wanted = ProcessInfo.processInfo
            .environment["FOTUFILM_RECORDING"], !wanted.isEmpty else { return nil }
        return all.first { $0.label.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// Each derivative gets its own warm frames. The camera records one derivative, never both.
    private static let warmupFrames = 2

    private static let timedFrames = 8

    private struct DeliveryTiming {
        let hdr: TimeInterval
        let sdr: TimeInterval

        var slower: TimeInterval { max(hdr, sdr) }
    }

    @discardableResult
    static func measure(
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> Measurement? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        var options = FotufilmEngine.Options()
        // The 60 fps camera contract has grain off. Every other stock-authored spatial stage stays
        // enabled, and the full-frame renderer forces the optical output to Digital Reference.
        options.grainScale = 0
        options.paper = .screen
        options.sceneHeadroom = HLGSceneTransfer.headroom
        let installed = FilmStock.presetIDs.compactMap(FilmStock.named)
        guard let stock = installed.first(where: { !$0.isMonochrome })
                ?? installed.first else { return nil }

        let perDelivery = warmupFrames + timedFrames
        let perSize = 2 * perDelivery
        let totalFrames = Double(measuredSizes.count * perSize)
        var done = 0.0
        var seconds: [String: TimeInterval] = [:]
        var hdrSeconds: [String: TimeInterval] = [:]
        var sdrSeconds: [String: TimeInterval] = [:]

        for (width, height) in measuredSizes {
            var sizeFrames = 0
            defer {
                done += Double(perSize)
                progress?(min(done / totalFrames, 1))
            }
            let tick: () -> Void = {
                sizeFrames += 1
                progress?(min((done + Double(sizeFrames)) / totalFrames, 1))
            }
            let timing = autoreleasepool {
                timeHandwritten(
                    device: device, stock: stock, options: options,
                    width: width, height: height, tick: tick)
            }
            guard let timing else { continue }
            let size = "\(width)x\(height)"
            seconds[size] = timing.slower
            hdrSeconds[size] = timing.hdr
            sdrSeconds[size] = timing.sdr
        }

        guard !seconds.isEmpty else { return nil }
        let measurement = Measurement(
            seconds: seconds, hdrSeconds: hdrSeconds, sdrSeconds: sdrSeconds,
            thermal: describe(ProcessInfo.processInfo.thermalState),
            taken: Date())
        remember(measurement)
        print("RecordingCapability: "
              + measuredSizes.map { width, height in
                  let key = "\(width)x\(height)"
                  return String(
                    format: "%@ HDR %.1f ms, SDR %.1f ms, governing %.1f ms",
                    key, (hdrSeconds[key] ?? .nan) * 1000,
                    (sdrSeconds[key] ?? .nan) * 1000,
                    (seconds[key] ?? .nan) * 1000)
              }.joined(separator: ", ")
              + ", thermal \(measurement.thermal)"
              + ", records \(measurement.supported.first?.label ?? floor.label)")
        return measurement
    }

    /// Times HLG and Rec.709 as separate production frames. The maximum is the capability value;
    /// encoding both derivatives into one command buffer would price work the camera never does.
    private static func timeHandwritten(
        device: MTLDevice,
        stock: FilmStock, options: FotufilmEngine.Options,
        width: Int, height: Int, tick: () -> Void
    ) -> DeliveryTiming? {
        guard width.isMultiple(of: 2), height.isMultiple(of: 2),
              let queue = device.makeCommandQueue(),
              let renderer = HandwrittenMetalFullFrameRenderer(
                device: device, maximumInFlightFrames: 1,
                spatialOptimizationVariant: .exactSpecialized),
              let delivery = try? HandwrittenMetalDigitalDelivery(device: device),
              let luma = texture(
                device: device, format: .r16Unorm,
                width: width, height: height, storage: .shared,
                usage: .shaderRead),
              let chroma = texture(
                device: device, format: .rg16Unorm,
                width: width / 2, height: height / 2, storage: .shared,
                usage: .shaderRead),
              let master = texture(
                device: device, format: .rgba16Float,
                width: width, height: height, storage: .private,
                usage: [.shaderRead, .shaderWrite]),
              let outputLuma = texture(
                device: device, format: .r16Unorm,
                width: width, height: height, storage: .private,
                usage: .shaderWrite),
              let outputChroma = texture(
                device: device, format: .rg16Unorm,
                width: width / 2, height: height / 2, storage: .private,
                usage: .shaderWrite)
        else { return nil }

        luma.label = "Fotufilm capability 10-bit HLG luma"
        chroma.label = "Fotufilm capability 10-bit HLG chroma"
        master.label = "Fotufilm capability linear Digital Reference HDR master"
        outputLuma.label = "Fotufilm capability 10-bit delivery luma"
        outputChroma.label = "Fotufilm capability 10-bit delivery chroma"
        fill(luma: luma, chroma: chroma)

        let key = "recording-capability|x420-hlg|\(width)x\(height)"
        guard renderer.prepare(
            key: key, stock: stock, options: options,
            frameWidth: width, frameHeight: height)
        else { return nil }

        func measure(_ output: HandwrittenMetalDigitalDelivery.Output) -> TimeInterval? {
            time({ frame in
                guard let commands = queue.makeCommandBuffer(),
                      renderer.encodeCapturedHDR(
                        luma: luma, chroma: chroma, output: master,
                        width: width, height: height, key: key,
                        transfer: .hlg, sceneScale: HLGSceneTransfer.headroom,
                        inputGain: HLGTransfer.videoExposureTrim,
                        frameIndex: frame, commandBuffer: commands)
                else { return false }
                do {
                    try delivery.encode(
                        master: master, luma: outputLuma, chroma: outputChroma,
                        output: output, commandBuffer: commands)
                } catch {
                    return false
                }
                commands.commit()
                commands.waitUntilCompleted()
                return commands.status == .completed
            }, tick: tick)
        }

        guard let hdr = measure(.hdrHLGRec2020),
              let sdr = measure(.sdrRec709)
        else { return nil }
        return DeliveryTiming(hdr: hdr, sdr: sdr)
    }

    private static func time(_ develop: (UInt64) -> Bool,
                             tick: () -> Void) -> TimeInterval? {
        var timed: [TimeInterval] = []
        timed.reserveCapacity(timedFrames)
        for frame in 0..<(warmupFrames + timedFrames) {
            let start = ProcessInfo.processInfo.systemUptime
            guard develop(UInt64(frame)) else { return nil }
            if frame >= warmupFrames {
                timed.append(ProcessInfo.processInfo.systemUptime - start)
            }
            tick()
        }
        guard !timed.isEmpty else { return nil }
        // Eight frames keep first-launch measurement bounded. At that sample count a nominal p95
        // is the maximum, so make the conservative governing rule explicit instead of reporting a
        // percentile the run cannot estimate.
        let worst = timed.max() ?? .nan
        return worst.isFinite ? worst : nil
    }

    private static func texture(
        device: MTLDevice, format: MTLPixelFormat,
        width: Int, height: Int, storage: MTLStorageMode,
        usage: MTLTextureUsage
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = storage
        descriptor.usage = usage
        return device.makeTexture(descriptor: descriptor)
    }

    /// A deterministic 10-bit video-range signal with enough local variation to exercise every
    /// data-dependent part of the graph. x420 stores each code left-justified in a UInt16 lane.
    private static func fill(luma: MTLTexture, chroma: MTLTexture) {
        let width = luma.width
        let height = luma.height
        var lumaCodes = [UInt16](repeating: 0, count: width * height)
        var random: UInt32 = 0x243f_6a88
        for index in lumaCodes.indices {
            random = random &* 747_796_405 &+ 2_891_336_453
            lumaCodes[index] = UInt16(64 + random % 877) << 6
        }
        lumaCodes.withUnsafeBytes { bytes in
            luma.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: width * MemoryLayout<UInt16>.stride)
        }

        var chromaCodes = [UInt16](
            repeating: 0, count: chroma.width * chroma.height * 2)
        for index in stride(from: 0, to: chromaCodes.count, by: 2) {
            random = random &* 747_796_405 &+ 2_891_336_453
            chromaCodes[index] = UInt16(288 + random % 449) << 6
            chromaCodes[index + 1] = UInt16(288 + (random >> 10) % 449) << 6
        }
        chromaCodes.withUnsafeBytes { bytes in
            chroma.replace(
                region: MTLRegionMake2D(0, 0, chroma.width, chroma.height),
                mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: chroma.width * 2 * MemoryLayout<UInt16>.stride)
        }
    }

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static let lock = NSLock()
    private static var resolved: Mode?

    private static let method = 4

    private static var buildFlavor: String {
        #if DEBUG
        "debug"
        #else
        "optimized"
        #endif
    }

    private static var key: String {
        let build = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "fotufilm.recording-capability.v\(method).\(build).\(buildFlavor)."
            + ProcessInfo.processInfo.operatingSystemVersionString
    }

    private static func stored() -> Measurement? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Measurement.self, from: data)
    }

    private static func remember(_ measurement: Measurement) {
        guard let data = try? JSONEncoder().encode(measurement) else { return }
        UserDefaults.standard.set(data, forKey: key)
        lock.lock()
        resolved = measurement.supported.first ?? floor
        lock.unlock()
    }
}
