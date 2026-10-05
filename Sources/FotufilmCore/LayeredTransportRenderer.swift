import Foundation
import FotufilmHalide

public enum TransportBackend: Int32, Sendable, Codable {
    case cpu = 0
    /// The transport pipeline on Metal; scene preparation and development keep their own road.
    case metal = 1
    public var isAvailable: Bool { fotufilm_transport_available(rawValue) == 1 }
}

/// Backend injection keeps optical preparation portable while Apple hosts use their AOT
/// scene/development kernels. The transport itself is the Halide pipeline on `backend`.
public struct TransportExecution {
    /// Renders an image, an invocation and whether to stop at the light. A record input with a
    /// fourth plane carries a donor stock's fourth record beside the three.
    public let render: (ImageBuffer, FilmEngineInvocation, Bool) throws -> ImageBuffer
    public let backend: TransportBackend
    /// The scene's light under a head invocation, written as three contiguous planes of the
    /// frame's pixel count. Optional: without it the heads go through `render`.
    public let light: ((FilmEngineInvocation, UnsafeMutablePointer<Float>) throws -> Void)?
    public init(render: @escaping (ImageBuffer, FilmEngineInvocation, Bool) throws -> ImageBuffer,
                backend: TransportBackend,
                light: ((FilmEngineInvocation, UnsafeMutablePointer<Float>) throws -> Void)? = nil) {
        self.render = render; self.backend = backend; self.light = light
    }
}

/// A frame's scene as the caller holds it, planar or interleaved RGBA (whose alpha no stage
/// reads). The other form is made only when a stage asks for it: a whole frame of it is
/// expensive at full resolution.
public final class TransportScene {
    public let width: Int, height: Int
    private var planar: ImageBuffer?
    private var rgba: [Float]?

    public init(_ image: ImageBuffer) {
        width = image.width; height = image.height; planar = image
    }

    public init(rgba: [Float], width: Int, height: Int) {
        self.width = width; self.height = height; self.rgba = rgba
    }

    var pixelCount: Int { width * height }

    func validate() throws {
        if let planar { return try planar.validate() }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard width >= 0, height >= 0, width <= Int32.max, height <= Int32.max,
              !overflow, count <= Int(Int32.max) / 3, rgba?.count == count * 4 else {
            throw TransportError.invalid("image requires width × height RGBA samples")
        }
        let bands = 64, valid = UnsafeMutableBufferPointer<Bool>.allocate(capacity: bands)
        defer { valid.deallocate() }
        rgba!.withUnsafeBufferPointer { pixels in
            ParallelWork.forEach(iterations: bands) { band in
                var finite = true
                for i in band * count / bands..<(band + 1) * count / bands {
                    finite = finite && pixels[4 * i].isFinite && pixels[4 * i + 1].isFinite
                        && pixels[4 * i + 2].isFinite
                }
                valid[band] = finite
            }
        }
        guard valid.allSatisfy({ $0 }) else { throw TransportError.invalid("image samples must be finite") }
    }

    /// The three planes.
    public var image: ImageBuffer {
        if let planar { return planar }
        let n = pixelCount
        var r = [Float](repeating: 0, count: n), g = r, b = r
        rgba!.withUnsafeBufferPointer { pixels in
            r.withUnsafeMutableBufferPointer { r in
                g.withUnsafeMutableBufferPointer { g in
                    b.withUnsafeMutableBufferPointer { b in
                        ParallelWork.forEach(iterations: 64) { band in
                            for i in band * n / 64..<(band + 1) * n / 64 {
                                r[i] = pixels[4 * i]; g[i] = pixels[4 * i + 1]; b[i] = pixels[4 * i + 2]
                            }
                        }
                    }
                }
            }
        }
        let image = ImageBuffer(width: width, height: height, planes: [r, g, b])
        planar = image
        return image
    }

    /// RGBA floats.
    var interleaved: [Float] {
        if let rgba { return rgba }
        let made = LayeredTransportRenderer.interleaved(planar!)
        rgba = made
        return made
    }

    func measureToneBase(_ invocation: inout FilmEngineInvocation) {
        if let rgba {
            rgba.withUnsafeBufferPointer {
                invocation.measureToneBase(linearRGBA: $0.baseAddress!, width: width, height: height)
            }
        } else {
            LayeredTransportRenderer.withPlanes(planar!.planes) { r, g, b in
                invocation.measureToneBase(planarR: r, g: g, b: b, width: width, height: height)
            }
        }
    }
}

/// Planar reference integration. Optical components are streamed, never all materialized as images.
public enum LayeredTransportRenderer {
    private final class Prepared: @unchecked Sendable {
        let compilation: TransportCompilation
        let exposure: TransportExposureTables
        /// Every component's stencil table at the last pixel pitch asked for.
        private var tables: (pitch: Double, values: [[Float]])?
        private let lock = NSLock()
        init(compilation: TransportCompilation, exposure: TransportExposureTables) {
            self.compilation = compilation; self.exposure = exposure
        }
        func transportTables(pixelPitchMM pitch: Double) throws -> [[Float]] {
            lock.lock(); defer { lock.unlock() }
            if let tables, tables.pitch == pitch { return tables.values }
            let kernels = compilation.kernels
            var results = [Result<[Float], Error>?](repeating: nil, count: kernels.count)
            results.withUnsafeMutableBufferPointer { results in
                ParallelWork.forEach(iterations: kernels.count) { k in
                    results[k] = Result { try kernels[k].transportTable(pixelPitchMM: pitch) }
                }
            }
            let values = try results.map { try $0!.get() }
            tables = (pitch, values)
            return values
        }
    }
    private static let lock = NSLock()
    /// Kernels by construction and halation edits; exposure tables also by the scene's light, so
    /// a white balance or a lens filter moving builds tables without compiling kernels again.
    nonisolated(unsafe) private static var compilations = BoundedCache<UInt64, TransportCompilation>(limit: 4)
    nonisolated(unsafe) private static var cache = BoundedCache<UInt64, Prepared>(limit: 4)

    private static func prepare(model film: LayeredTransport, stock: FilmStock,
                                options: FotufilmEngine.Options) throws -> Prepared {
        let model = try HalationReturn.applying(options.halationReturnRatio, to: film)
        let haze = options.halationHazeMM ?? stock.halationHazeMM
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var compiled: UInt64 = 0xcbf29ce484222325
        for byte in try encoder.encode(film) { compiled = (compiled ^ UInt64(byte)) &* 0x100000001b3 }
        compiled = (compiled ^ UInt64((options.halationReturnRatio ?? -1).bitPattern)) &* 0x100000001b3
        compiled ^= SpectralRuntime.cacheIdentifier(for: stock)
        for values in [options.halationReturnGain, [options.halationSourceColour, haze],
                       [options.antiHalationScale, options.baseThicknessScale, options.pressurePlateReflectance]] {
            compiled = (compiled ^ UInt64(values.count)) &* 0x100000001b3
            for value in values { compiled = (compiled ^ UInt64(value.bitPattern)) &* 0x100000001b3 }
        }
        var key = compiled ^ options.lensFilters.signature
        for values in [options.resolvedSceneSpectrum(referenceKelvin: stock.referenceIlluminantKelvin),
                       [options.sceneIlluminantKelvin ?? 0]] {
            key = (key ^ UInt64(values.count)) &* 0x100000001b3
            for value in values { key = (key ^ UInt64(value.bitPattern)) &* 0x100000001b3 }
        }
        lock.lock(); let found = cache.value(for: key), kernels = compilations.value(for: compiled); lock.unlock()
        if let found { return found }
        let compilation = try kernels ?? {
            // A donor's fourth record is solved at its own depth; one without a depth sits at green's.
            let donorDepth = stock.donorLayers.first.map { $0.depthUM.map { Double($0) / 1000 } ?? model.recordDepthMM[1] }
            let adjusted = try model.adjusted(antiHalation: options.antiHalationScale,
                                              baseThickness: options.baseThicknessScale,
                                              pressurePlate: options.pressurePlateReflectance)
            func compile(edgeTolerance: Double) throws -> TransportCompilation {
                try TransportKernelCompiler.compile(adjusted, returnGain: options.halationReturnGain,
                    sourceColour: options.halationSourceColour, hazeMM: Double(haze),
                    donorDepthMM: donorDepth, reference: adjusted == model ? nil : film,
                    edgeTolerance: edgeTolerance)
            }
            // Every film's own construction fits the renderer's components within 0.005. A strongly
            // adjusted one may not, and takes the compiler's widest tolerance rather than failing.
            let compilation: TransportCompilation
            do { compilation = try compile(edgeTolerance: 0.005) }
            catch TransportError.convergence where adjusted != model {
                compilation = try compile(edgeTolerance: 0.02)
            }
            lock.lock(); compilations.insert(compilation, for: compiled); lock.unlock()
            return compilation
        }()
        let exposure = try SpectralRuntime.transportExposureTables(stock: stock, options: options,
            compilation: compilation)
        let result = Prepared(compilation: compilation, exposure: exposure)
        lock.lock(); cache.insert(result, for: key); lock.unlock()
        return result
    }

    /// The stages the continuation leaves off: the heads already ran the optics, and the
    /// transport took the place of the halation and the emulsion's MTF.
    public static let continuationClears = FilmEngineFeature.flare | FilmEngineFeature.diffusion
        | FilmEngineFeature.mtf | FilmEngineFeature.mtfLuma | FilmEngineFeature.halation
        | FilmEngineFeature.annularHalation | FilmEngineFeature.texture

    /// Solved inputs for portable AOT hosts. The browser stores these alongside its base pack.
    /// A donor stock's components carry its fourth record in each exposure table's fourth lane.
    public static func renderPlan(stock: FilmStock, options: FotufilmEngine.Options,
                                  width: Int, height: Int) throws -> TransportRenderPlan {
        guard let model = options.transportConstruction(for: stock),
              options.stage == .full, !options.localTone else {
            throw TransportError.unsupported("transport pack requires full stage without image-dependent local tone")
        }
        let settings = options.withoutLayeredTransport
        let prepared = try prepare(model: model, stock: stock, options: settings)
        let t = prepared.compilation.interpolation(amount: Double(options.halationScale * stock.halationLookScale))
        var head = try FilmEngineInvocation(validating: stock, options: settings, width: width, height: height)
        var tail = head
        head.clearTransportOptics(keepLens: true)
        head.featureMask &= FilmEngineFeature.flare | FilmEngineFeature.diffusion
        head.featureMask |= FilmEngineFeature.lightOut
        tail.featureMask &= ~continuationClears
        tail.clearTransportOptics(keepLens: false)
        tail.configuration[Int(FOTUFILM_CONFIG_RECORD_INPUT)] = 1
        let pitch = options.pixelPitchMM(width: width, height: height)
        let components: [TransportRenderPlan.Component] = try prepared.compilation.kernels.indices.compactMap { k in
            let table = prepared.exposure.table(component: k, interpolation: t)
            guard table.values.contains(where: { $0 > 0 }) else { return nil }
            let bands = try prepared.compilation.kernels[k].stencils(pixelPitchMM: pitch)
            return try .init(exposure: table.values, bands: bands.map { .init(weight: $0.weight, stencil: $0.stencil) })
        }
        head.sharePreflash(among: components.count)
        return TransportRenderPlan(head: head, tail: tail, components: components)
    }

    /// A frame's transported exposure: the records summed over every component, planar
    /// width * height * channels (a donor stock's fourth record last), the invocation the heads
    /// were made from, and the one that develops the records.
    public struct Exposure {
        public let sum: [Float]
        public let channels: Int
        public let invocation: FilmEngineInvocation
        public let continuation: FilmEngineInvocation
    }

    public static func process(image: ImageBuffer, stock: FilmStock, options: FotufilmEngine.Options,
                               model: LayeredTransport, frameIndex: UInt64 = 0,
                               execution: TransportExecution? = nil,
                               invocation: FilmEngineInvocation? = nil,
                               pixelPitchMM: Double? = nil) throws -> ImageBuffer {
        let exposed = try expose(scene: TransportScene(image), stock: stock, options: options, model: model,
                                 frameIndex: frameIndex, execution: execution, invocation: invocation,
                                 pixelPitchMM: pixelPitchMM)
        let render = execution?.render ?? { image, invocation, developOnly in
            try run(image: image, invocation: invocation, developOnly: developOnly)
        }
        let n = image.pixelCount
        var exposure = ImageBuffer(width: image.width, height: image.height)
        exposure.planes = (0..<exposed.channels).map { Array(exposed.sum[$0 * n..<($0 + 1) * n]) }
        guard options.stage == .texture else { return try render(exposure, exposed.continuation, false) }
        var continuation = exposed.continuation
        continuation.featureMask |= FilmEngineFeature.densityOut
        let transported = try render(exposure, continuation, false)
        var referenceHead = exposed.invocation
        referenceHead.featureMask &= FilmEngineFeature.flare | FilmEngineFeature.diffusion
        referenceHead.featureMask |= FilmEngineFeature.lightOut
        referenceHead.clearTransportOptics(keepLens: true)
        var referenceExposure = try render(image, referenceHead, true)
        if exposed.channels == 4 {
            var donorHead = referenceHead
            donorHead.setTransportExposure(exposed.invocation.spectral.exposure)
            referenceExposure.planes.append(try render(image, Self.fourthRecordHead(donorHead), true).planes[0])
        }
        var reference = continuation
        reference.featureMask &= ~(FilmEngineFeature.grain | FilmEngineFeature.adjacency
            | FilmEngineFeature.couplerDiffusion | FilmEngineFeature.printMTF)
        reference.configuration[Int(FOTUFILM_CONFIG_CHROMATIC_FRINGE_AMOUNT)] = 0
        reference.configuration[Int(FOTUFILM_CONFIG_PRINT_MTF_RADIUS)] = 0
        reference.configuration[Int(FOTUFILM_CONFIG_GRAIN_RADIUS)] = 0
        reference.configuration[Int(FOTUFILM_CONFIG_ADJACENCY_STRENGTH)] = 0
        reference.configuration[Int(FOTUFILM_CONFIG_COUPLER_RADIUS)] = 0
        for c in 0..<3 { reference.configuration[FilmEngineInvocation.grainOffset+c] = 0 }
        let baseline = try render(referenceExposure, reference, false)
        var output = image
        let sign: Float = stock.isReversal ? -1 : 1
        for c in 0..<3 { for i in 0..<n {
            output.planes[c][i] *= exp(sign * (transported.planes[c][i] - baseline.planes[c][i]) * log(10))
        } }
        return output
    }

    /// Runs every component of the frame's transport, up to the records' development.
    public static func expose(scene: TransportScene, stock: FilmStock, options: FotufilmEngine.Options,
                              model supplied: LayeredTransport, frameIndex: UInt64 = 0,
                              execution: TransportExecution? = nil,
                              invocation suppliedInvocation: FilmEngineInvocation? = nil,
                              pixelPitchMM: Double? = nil) throws -> Exposure {
        try scene.validate()
        let backend = execution?.backend ?? options.transportBackend
        guard backend.isAvailable, execution != nil || HalideBackend.isAvailable else {
            throw TransportError.backend("requested transport backend is unavailable")
        }
        guard scene.width > 0 && scene.height > 0,
              options.halationScale.isFinite && options.halationScale >= 0,
              stock.halationLookScale.isFinite && stock.halationLookScale >= 0,
              options.frameCoverage.isFinite, options.format.frameHeightMM.isFinite,
              options.format.frameHeightMM > 0 else {
            throw TransportError.invalid("invalid image or amount")
        }
        var plain = stock; plain.layeredTransport = nil
        let settings = options.withoutLayeredTransport
        let render = execution?.render ?? { image, invocation, developOnly in
            try run(image: image, invocation: invocation, developOnly: developOnly)
        }
        var model = supplied
        let texture = options.stage == .texture
        if texture && !options.textureStages.contains(.emulsionMTF) { model.coreSigmaMM = [0, 0, 0] }
        let prepared = try prepare(model: model, stock: plain, options: settings)
        let amount = texture && !options.textureStages.contains(.halation) ? 0
            : Double(options.halationScale) * Double(stock.halationLookScale)
        let t = prepared.compilation.interpolation(amount: amount)
        var invocation = try suppliedInvocation ?? FilmEngineInvocation(validating: plain, options: settings,
                                             width: scene.width, height: scene.height, frameIndex: frameIndex)
        if invocation.sceneMeteringActive && suppliedInvocation == nil { scene.measureToneBase(&invocation) }
        let pitch = pixelPitchMM ?? options.pixelPitchMM(width: scene.width, height: scene.height)
        let donated = !plain.donorLayers.isEmpty
        let n = scene.pixelCount, channels = donated ? 4 : 3
        // The running sum and each component, planar and contiguous as the transport takes
        // them; a donor stock's fourth record accumulates beside the three.
        var sum = [Float](repeating: 0, count: n * channels)
        lazy var component = [Float](repeating: 0, count: n * channels)
        lazy var fourth = [Float](repeating: 0, count: donated ? n * 3 : 0)
        func light(_ head: FilmEngineInvocation, into destination: UnsafeMutablePointer<Float>) throws {
            if let light = execution?.light { return try light(head, destination) }
            let planes = try render(scene.image, head, true).planes
            for c in 0..<3 {
                planes[c].withUnsafeBufferPointer { destination.advanced(by: c * n).update(from: $0.baseAddress!, count: n) }
            }
        }
        let tables = prepared.compilation.kernels.indices.map { k -> SpectralLUT? in
            let table = prepared.exposure.table(component: k, interpolation: t)
            return table.values.contains(where: { $0 > 0 }) ? table : nil
        }
        let active = tables.compactMap { $0 }.count
        func head(_ table: SpectralLUT) -> FilmEngineInvocation {
            var head = invocation
            head.featureMask &= FilmEngineFeature.flare | FilmEngineFeature.diffusion
            head.featureMask |= FilmEngineFeature.lightOut
            head.clearTransportOptics(keepLens: true)
            head.sharePreflash(among: active)
            head.setTransportExposure(table)
            return head
        }
        let stencils = try prepared.transportTables(pixelPitchMM: pitch)
        if invocation.featureMask & (FilmEngineFeature.flare | FilmEngineFeature.diffusion) == 0 {
            // Every head is the scene through its table and the gate, which the transport
            // exposes itself: the frame's components never leave the device.
            try exposeFrame(scene.interleaved, width: scene.width, height: scene.height, channels: channels,
                            components: prepared.compilation.kernels.indices.compactMap { k in
                                tables[k].map { (head($0), stencils[k]) } },
                            backend: backend, into: &sum)
        } else {
            try component.withUnsafeMutableBufferPointer { component in
                try sum.withUnsafeMutableBufferPointer { sum in
                    for k in prepared.compilation.kernels.indices {
                        guard let table = tables[k] else { continue }
                        var head = head(table)
                        try light(head, into: component.baseAddress!)
                        if donated {
                            head = Self.fourthRecordHead(head)
                            try fourth.withUnsafeMutableBufferPointer {
                                try light(head, into: $0.baseAddress!)
                                component.baseAddress!.advanced(by: 3 * n).update(from: $0.baseAddress!, count: n)
                            }
                        }
                        try transport(component.baseAddress!, into: sum.baseAddress!, width: scene.width,
                                      height: scene.height, channels: channels, stencils: stencils[k],
                                      backend: backend)
                    }
                }
            }
        }
        let bands = 64, valid = UnsafeMutableBufferPointer<Bool>.allocate(capacity: bands)
        defer { valid.deallocate() }
        sum.withUnsafeBufferPointer { sum in
            ParallelWork.forEach(iterations: bands) { band in
                valid[band] = sum[band * sum.count / bands..<(band + 1) * sum.count / bands]
                    .allSatisfy { $0.isFinite && $0 >= 0 }
            }
        }
        guard valid.allSatisfy({ $0 }) else {
            throw TransportError.backend("transport produced invalid record exposure")
        }
        var continuation = invocation
        continuation.featureMask &= ~continuationClears
        continuation.clearTransportOptics(keepLens: false)
        continuation.configuration[Int(FOTUFILM_CONFIG_RECORD_INPUT)] = 1
        return Exposure(sum: sum, channels: channels, invocation: invocation, continuation: continuation)
    }

    /// Sums components the transport exposes from `scene`, RGBA floats, each through its head's
    /// configuration and exposure table, into the planar `sum`.
    static func exposeFrame(_ scene: [Float], width: Int, height: Int, channels: Int,
                            components: [(head: FilmEngineInvocation, stencils: [Float])],
                            backend: TransportBackend, into sum: inout [Float]) throws {
        let count = FilmEngineInvocation.configurationCount, d = SpectralRuntime.lutDimension
        guard scene.count == width * height * 4, sum.count == width * height * channels,
              components.allSatisfy({ $0.head.configuration.count == count
                  && $0.head.spectral.exposure.values.count == d * d * d * 4 }) else {
            throw TransportError.invalid("invalid transport frame")
        }
        guard let first = components.first?.head else { return }
        let status = sum.withUnsafeMutableBufferPointer { sum -> Int32 in
            guard let frame = scene.withUnsafeBufferPointer({ scene in
                first.configuration.withUnsafeBufferPointer {
                    fotufilm_transport_frame_begin(scene.baseAddress, $0.baseAddress, sum.baseAddress,
                                                   Int32(width), Int32(height), Int32(channels),
                                                   backend.rawValue)
                }
            }) else { return -3 }
            var status: Int32 = 0
            for (head, stencils) in components where status == 0 {
                status = head.configuration.withUnsafeBufferPointer { configuration in
                    head.spectral.exposure.values.withUnsafeBufferPointer { lut in
                        stencils.withUnsafeBufferPointer {
                            fotufilm_transport_frame_add(frame, configuration.baseAddress, lut.baseAddress,
                                                         $0.baseAddress)
                        }
                    }
                }
            }
            let finished = fotufilm_transport_frame_finish(frame, status == 0 ? 1 : 0)
            return status == 0 ? finished : status
        }
        guard status == 0 else { throw TransportError.backend("transport frame failed (\(status))") }
    }

    /// The image's three planes as RGBA floats.
    static func interleaved(_ image: ImageBuffer) -> [Float] {
        let n = image.pixelCount
        var scene = [Float](repeating: 1, count: n * 4)
        withPlanes(image.planes) { r, g, b in
            scene.withUnsafeMutableBufferPointer { scene in
                ParallelWork.forEach(iterations: 64) { band in
                    for i in band * n / 64..<(band + 1) * n / 64 {
                        scene[4 * i] = r[i]; scene[4 * i + 1] = g[i]; scene[4 * i + 2] = b[i]
                    }
                }
            }
        }
        return scene
    }

    /// Adds one component, spread by its kernel's `TransportRadialKernel.transportTable`, to
    /// `sum`. Both carry three planes, or four with a donor record.
    public static func transport(_ component: ImageBuffer, stencils: [Float], into sum: inout ImageBuffer,
                                 backend: TransportBackend = .cpu) throws {
        guard component.width == sum.width, component.height == sum.height,
              component.planes.count == sum.planes.count, stencils.count == TransportRadialKernel.transportTableCount,
              (component.planes + sum.planes).allSatisfy({ $0.count == component.pixelCount }) else {
            throw TransportError.invalid("invalid transport component or sum")
        }
        let input = component.planes.flatMap { $0 }
        var accumulated = sum.planes.flatMap { $0 }
        try input.withUnsafeBufferPointer { input in
            try accumulated.withUnsafeMutableBufferPointer {
                try transport(input.baseAddress!, into: $0.baseAddress!, width: sum.width, height: sum.height,
                              channels: sum.planes.count, stencils: stencils, backend: backend)
            }
        }
        let count = sum.pixelCount
        for c in sum.planes.indices { sum.planes[c] = Array(accumulated[c * count..<(c + 1) * count]) }
    }

    /// `transport(_:stencils:into:backend:)` on planar, contiguous records.
    static func transport(_ component: UnsafePointer<Float>, into sum: UnsafeMutablePointer<Float>,
                          width: Int, height: Int, channels: Int, stencils: [Float],
                          backend: TransportBackend) throws {
        guard stencils.count == TransportRadialKernel.transportTableCount else {
            throw TransportError.invalid("invalid transport stencils")
        }
        let status = fotufilm_transport_component(component, sum, Int32(width), Int32(height),
                                                  Int32(channels), stencils, backend.rawValue)
        guard status == 0 else { throw TransportError.backend("transport failed (\(status))") }
    }

    /// A head exposing its table's fourth record, a donor stock's, in each of the three it renders,
    /// through the lens diffusion the donor's own record takes.
    public static func fourthRecordHead(_ head: FilmEngineInvocation) -> FilmEngineInvocation {
        var donor = head
        donor.setTransportExposure(fourthRecord(of: head.spectral.exposure))
        let from = Int(FOTUFILM_CONFIG_DONOR_DIFFUSION_KERNEL), to = Int(FOTUFILM_CONFIG_DIFFUSION_KERNEL)
        for c in 0..<3 { for k in 0..<3 { donor.configuration[to + 3 * c + k] = head.configuration[from + k] } }
        return donor
    }

    /// A table exposing its fourth record, a donor stock's, in each of the three it renders.
    static func fourthRecord(of table: SpectralLUT) -> SpectralLUT {
        var values = table.values
        for i in stride(from: 0, to: values.count, by: 4) {
            values[i] = values[i + 3]; values[i + 1] = values[i + 3]; values[i + 2] = values[i + 3]
        }
        return SpectralLUT(dimension: table.dimension, values: values)
    }

    static func run(image: ImageBuffer, invocation: FilmEngineInvocation,
                            developOnly: Bool = false) throws -> ImageBuffer {
        if image.planes.count == 4 && !developOnly { return try runWithDonor(image: image, invocation: invocation) }
        var output = ImageBuffer(width: image.width, height: image.height)
        let status = withPlanes(image.planes) { r, g, b in
            withMutablePlanes(&output.planes) { rr, gg, bb in
                invocation.configuration.withUnsafeBufferPointer { config in
                    invocation.withSpectralPointers { exposure, film, paper in
                        if developOnly {
                            return fotufilm_halide_develop(r, g, b, rr, gg, bb,
                                Int32(image.width), Int32(image.height), config.baseAddress,
                                exposure, Int32(invocation.spectral.exposure.dimension), invocation.featureMask, invocation.seed)
                        }
                        return fotufilm_halide_process(r, g, b, rr, gg, bb,
                            Int32(image.width), Int32(image.height), config.baseAddress,
                            exposure, film, paper, Int32(invocation.spectral.exposure.dimension),
                            invocation.featureMask, invocation.seed)
                    }
                }
            }
        }
        guard status == 0 else { throw TransportError.backend("exposure/development failed (\(status))") }
        return output
    }

    /// Develops three records with a donor stock's fourth beside them. The planar input has no
    /// fourth channel, so the donor arrives as additional record exposure.
    private static func runWithDonor(image: ImageBuffer, invocation: FilmEngineInvocation) throws -> ImageBuffer {
        var output = ImageBuffer(width: image.width, height: image.height)
        var donor = [Float](repeating: 0, count: image.pixelCount * 4)
        for i in 0..<image.pixelCount { donor[4 * i + 3] = image.planes[3][i] }
        let w = Int32(image.width), h = Int32(image.height)
        let status = withPlanes(image.planes) { r, g, b in
            withMutablePlanes(&output.planes) { rr, gg, bb in
                invocation.configuration.withUnsafeBufferPointer { config in
                    donor.withUnsafeBufferPointer { donor in
                        invocation.withSpectralPointers { exposure, film, paper in
                            fotufilm_halide_process_tile_with_exposure(r, g, b, rr, gg, bb,
                                w, h, w, h, 0, 0, 0, 0, w, h, config.baseAddress,
                                exposure, film, paper, Int32(invocation.spectral.exposure.dimension),
                                invocation.featureMask, invocation.seed, donor.baseAddress)
                        }
                    }
                }
            }
        }
        guard status == 0 else { throw TransportError.backend("exposure/development failed (\(status))") }
        return output
    }

    static func withPlanes<T>(_ planes: [[Float]], _ body: (UnsafePointer<Float>, UnsafePointer<Float>, UnsafePointer<Float>) -> T) -> T {
        planes[0].withUnsafeBufferPointer { r in planes[1].withUnsafeBufferPointer { g in
            planes[2].withUnsafeBufferPointer { b in body(r.baseAddress!, g.baseAddress!, b.baseAddress!) }
        } }
    }
    private static func withMutablePlanes<T>(_ planes: inout [[Float]], _ body: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> T) -> T {
        var r = planes[0], g = planes[1], b = planes[2]
        let result = r.withUnsafeMutableBufferPointer { rr in g.withUnsafeMutableBufferPointer { gg in
            b.withUnsafeMutableBufferPointer { bb in body(rr.baseAddress!, gg.baseAddress!, bb.baseAddress!) }
        } }
        planes = [r, g, b]
        return result
    }
}

public extension FilmEngineInvocation {
    mutating func setTransportExposure(_ table: SpectralLUT) {
        spectral = SpectralPipelineTables(exposure: table, filmOutput: spectral.filmOutput,
                                         paperOutput: spectral.paperOutput)
        // Apple AOT uploads are keyed by this ID. Each component and amount must upload its
        // own table even though development and print tables are shared.
        for value in table.values { spectralCacheID = (spectralCacheID ^ UInt64(value.bitPattern)) &* 0x100000001b3 }
    }

    /// Each component head exposes its share of a uniform preflash. Every kernel is normalized,
    /// so the transported shares add back to one flash.
    mutating func sharePreflash(among components: Int) {
        configuration[Int(FOTUFILM_CONFIG_CAMERA_PREFLASH)] /= Float(max(components, 1))
    }

    mutating func clearTransportOptics(keepLens: Bool) {
        for c in 0..<3 {
            configuration[Int(FOTUFILM_CONFIG_MTF_RADIUS)+c] = 0
            configuration[Int(FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS)+c] = 0
            configuration[Int(FOTUFILM_CONFIG_HALATION_RADIUS)+c] = 0
        }
        configuration[Int(FOTUFILM_CONFIG_MTF_LUMA_RADIUS)] = 0
        configuration[Int(FOTUFILM_CONFIG_MTF_LUMA_SHARE)] = 0
        for c in 0..<9 { configuration[Int(FOTUFILM_CONFIG_HALATION_MATRIX)+c] = 0 }
        if !keepLens {
            // The transported exposure passed the camera gate in the head and carries its
            // preflash; gating it again would square the penumbra and cut off the light
            // scattered past the aperture, and flashing it again would double the flash.
            configuration[Int(FOTUFILM_CONFIG_GATE) + 4] = -1
            configuration[Int(FOTUFILM_CONFIG_CAMERA_PREFLASH)] = 0
            configuration[Int(FOTUFILM_CONFIG_FLARE)] = 0
            configuration[Int(FOTUFILM_CONFIG_DIFFUSION_DIRECT)] = 1
            for c in 0..<9 { configuration[Int(FOTUFILM_CONFIG_DIFFUSION_KERNEL)+c] = 0 }
            for c in 0..<3 { configuration[Int(FOTUFILM_CONFIG_DIFFUSION_RADIUS)+c] = 0 }
        }
    }
}

public struct TransportRenderPlan {
    public struct Band { public let weight: Float; public let stencil: TransportStencil }
    public struct Component {
        public let exposure: [Float]
        public let bands: [Band]
        /// The bands as the transport pipeline takes them (`TransportRadialKernel.transportTable`).
        public let stencils: [Float]

        public init(exposure: [Float], bands: [Band]) throws {
            self.exposure = exposure; self.bands = bands
            stencils = try TransportRadialKernel.transportTable(
                bands: bands.map { TransportWeightedStencil(weight: $0.weight, stencil: $0.stencil) })
        }
    }
    public let head: FilmEngineInvocation
    public let tail: FilmEngineInvocation
    public let components: [Component]
}
