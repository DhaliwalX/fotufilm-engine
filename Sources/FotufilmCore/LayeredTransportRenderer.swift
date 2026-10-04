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
    public init(render: @escaping (ImageBuffer, FilmEngineInvocation, Bool) throws -> ImageBuffer,
                backend: TransportBackend) {
        self.render = render; self.backend = backend
    }
}

/// Planar reference integration. Optical components are streamed, never all materialized as images.
public enum LayeredTransportRenderer {
    private struct Prepared: Sendable {
        let compilation: TransportCompilation
        let exposure: TransportExposureTables
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache = BoundedCache<UInt64, Prepared>(limit: 4)

    private static func prepare(model: LayeredTransport, stock: FilmStock,
                                options: FotufilmEngine.Options) throws -> Prepared {
        let model = try HalationReturn.applying(options.halationReturnRatio, to: model)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var key: UInt64 = 0xcbf29ce484222325
        for byte in try encoder.encode(model) { key = (key ^ UInt64(byte)) &* 0x100000001b3 }
        key ^= SpectralRuntime.cacheIdentifier(for: stock)
        key ^= options.lensFilters.signature
        for values in [options.resolvedSceneSpectrum(referenceKelvin: stock.referenceIlluminantKelvin), options.halationReturnGain,
                       [options.sceneIlluminantKelvin ?? 0, options.halationSourceColour, options.halationHazeMM ?? 0]] {
            key = (key ^ UInt64(values.count)) &* 0x100000001b3
            for value in values { key = (key ^ UInt64(value.bitPattern)) &* 0x100000001b3 }
        }
        lock.lock(); let found = cache.value(for: key); lock.unlock()
        if let found { return found }
        let compilation = try TransportKernelCompiler.compile(model, returnGain: options.halationReturnGain,
            sourceColour: options.halationSourceColour, hazeMM: Double(options.halationHazeMM ?? 0))
        let exposure = try SpectralRuntime.transportExposureTables(stock: stock, options: options,
            compilation: compilation, donorReceivers: donorReceivers(model: model, stock: stock))
        let result = Prepared(compilation: compilation, exposure: exposure)
        lock.lock(); cache.insert(result, for: key); lock.unlock()
        return result
    }

    /// How a donor stock's fourth record takes the three receivers' transport: by its depth in
    /// the coating, interpolated between the receivers either side of it and held beyond the
    /// outermost. The construction solves three receivers; the fourth lies among them.
    static func donorReceivers(model: LayeredTransport, stock: FilmStock) -> [Float]? {
        guard let layer = stock.donorLayers.first else { return nil }
        let depths = model.recordDepthMM
        let order = depths.indices.sorted { depths[$0] < depths[$1] }
        let depth = layer.depthUM.map { Double($0) / 1000 } ?? depths[1]
        var weights: [Float] = [0, 0, 0]
        if depth <= depths[order[0]] { weights[order[0]] = 1; return weights }
        if depth >= depths[order[2]] { weights[order[2]] = 1; return weights }
        let upper = depth < depths[order[1]] ? 1 : 2
        let a = order[upper - 1], b = order[upper]
        let t = depths[b] > depths[a] ? (depth - depths[a]) / (depths[b] - depths[a]) : 0
        weights[a] = Float(1 - t); weights[b] = Float(t)
        return weights
    }

    /// Solved inputs for portable AOT hosts. The browser stores these alongside its base pack.
    /// The stages the continuation leaves off: the heads already ran the optics, and the
    /// transport took the place of the halation and the emulsion's MTF.
    public static let continuationClears = FilmEngineFeature.flare | FilmEngineFeature.diffusion
        | FilmEngineFeature.mtf | FilmEngineFeature.mtfLuma | FilmEngineFeature.halation
        | FilmEngineFeature.annularHalation | FilmEngineFeature.texture

    public static func renderPlan(stock: FilmStock, options: FotufilmEngine.Options,
                                  width: Int, height: Int) throws -> TransportRenderPlan {
        guard stock.donorLayers.isEmpty else {
            throw TransportError.unsupported("transport packs do not yet carry a donor stock's fourth record")
        }
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

    public static func process(image: ImageBuffer, stock: FilmStock, options: FotufilmEngine.Options,
                               model supplied: LayeredTransport, frameIndex: UInt64 = 0,
                               execution: TransportExecution? = nil,
                               invocation suppliedInvocation: FilmEngineInvocation? = nil,
                               pixelPitchMM: Double? = nil) throws -> ImageBuffer {
        try image.validate()
        let backend = execution?.backend ?? options.transportBackend
        guard backend.isAvailable, execution != nil || HalideBackend.isAvailable else {
            throw TransportError.backend("requested transport backend is unavailable")
        }
        guard image.width > 0 && image.height > 0,
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
                                             width: image.width, height: image.height, frameIndex: frameIndex)
        if invocation.sceneMeteringActive && suppliedInvocation == nil {
            withPlanes(image.planes) { r, g, b in
                invocation.measureToneBase(planarR: r, g: g, b: b, width: image.width, height: image.height)
            }
        }
        let pitch = pixelPitchMM ?? options.pixelPitchMM(width: image.width, height: image.height)
        let donated = !plain.donorLayers.isEmpty
        // The running sum; a donor stock's fourth record accumulates beside the three.
        var exposure = ImageBuffer(width: image.width, height: image.height)
        if donated { exposure.planes.append(Array(repeating: 0, count: image.pixelCount)) }
        let tables = prepared.compilation.kernels.indices.map { k -> SpectralLUT? in
            let table = prepared.exposure.table(component: k, interpolation: t)
            return table.values.contains(where: { $0 > 0 }) ? table : nil
        }
        let active = tables.compactMap { $0 }.count
        for k in prepared.compilation.kernels.indices {
            guard let table = tables[k] else { continue }
            var head = invocation
            head.featureMask &= FilmEngineFeature.flare | FilmEngineFeature.diffusion
            head.featureMask |= FilmEngineFeature.lightOut
            head.clearTransportOptics(keepLens: true)
            head.sharePreflash(among: active)
            head.setTransportExposure(table)
            var component = try render(image, head, true)
            component.planes = Array(component.planes.prefix(3))
            if donated {
                head.setTransportExposure(Self.fourthRecord(of: table))
                component.planes.append(try render(image, head, true).planes[0])
            }
            try transport(component, stencils: prepared.compilation.kernels[k].transportTable(pixelPitchMM: pitch),
                          into: &exposure, backend: backend)
        }
        guard exposure.planes.allSatisfy({ $0.allSatisfy { $0.isFinite && $0 >= 0 } }) else {
            throw TransportError.backend("transport produced invalid record exposure")
        }
        var continuation = invocation
        continuation.featureMask &= ~continuationClears
        continuation.clearTransportOptics(keepLens: false)
        continuation.configuration[Int(FOTUFILM_CONFIG_RECORD_INPUT)] = 1
        if texture {
            continuation.featureMask |= FilmEngineFeature.densityOut
            let transported = try render(exposure, continuation, false)
            var referenceHead = invocation
            referenceHead.featureMask &= FilmEngineFeature.flare | FilmEngineFeature.diffusion
            referenceHead.featureMask |= FilmEngineFeature.lightOut
            referenceHead.clearTransportOptics(keepLens: true)
            var referenceExposure = try render(image, referenceHead, true)
            if donated {
                var donorHead = referenceHead
                donorHead.setTransportExposure(Self.fourthRecord(of: invocation.spectral.exposure))
                referenceExposure.planes.append(try render(image, donorHead, true).planes[0])
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
            for c in 0..<3 { for i in 0..<image.pixelCount {
                output.planes[c][i] *= exp(sign * (transported.planes[c][i] - baseline.planes[c][i]) * log(10))
            } }
            return output
        }
        return try render(exposure, continuation, false)
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
        let status = accumulated.withUnsafeMutableBufferPointer {
            fotufilm_transport_component(input, $0.baseAddress!, Int32(sum.width), Int32(sum.height),
                                         Int32(sum.planes.count), stencils, backend.rawValue)
        }
        guard status == 0 else { throw TransportError.backend("transport failed (\(status))") }
        let count = sum.pixelCount
        for c in sum.planes.indices { sum.planes[c] = Array(accumulated[c * count..<(c + 1) * count]) }
    }

    /// A table exposing its fourth record, a donor stock's, in each of the three it renders.
    private static func fourthRecord(of table: SpectralLUT) -> SpectralLUT {
        var values = table.values
        for i in stride(from: 0, to: values.count, by: 4) {
            values[i] = values[i + 3]; values[i + 1] = values[i + 3]; values[i + 2] = values[i + 3]
        }
        return SpectralLUT(dimension: table.dimension, values: values)
    }

    private static func run(image: ImageBuffer, invocation: FilmEngineInvocation,
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

    private static func withPlanes<T>(_ planes: [[Float]], _ body: (UnsafePointer<Float>, UnsafePointer<Float>, UnsafePointer<Float>) -> T) -> T {
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
