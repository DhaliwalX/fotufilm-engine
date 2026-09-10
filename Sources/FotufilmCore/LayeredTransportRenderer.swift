import Foundation
import FotufilmHalide

public enum TransportBackend: Int32, Sendable, Codable {
    case cpu = 0
    /// Halide Metal JIT convolution; scene preparation and development retain the CPU reference.
    case metal = 1
    public var isAvailable: Bool { fotufilm_transport_available(rawValue) == 1 }
}

/// Backend injection keeps optical preparation portable while Apple hosts use their AOT
/// scene/development kernels and Metal convolution. The reference API uses the CPU implementation.
public struct TransportExecution {
    public let render: (ImageBuffer, FilmEngineInvocation, Bool) throws -> ImageBuffer
    public let convolve: (ImageBuffer, TransportStencil) throws -> ImageBuffer
    public init(render: @escaping (ImageBuffer, FilmEngineInvocation, Bool) throws -> ImageBuffer,
                convolve: @escaping (ImageBuffer, TransportStencil) throws -> ImageBuffer) {
        self.render = render; self.convolve = convolve
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
                                                                  compilation: compilation)
        let result = Prepared(compilation: compilation, exposure: exposure)
        lock.lock(); cache.insert(result, for: key); lock.unlock()
        return result
    }

    /// Solved inputs for portable AOT hosts. The browser stores these alongside its base pack.
    public static func renderPlan(stock: FilmStock, options: FotufilmEngine.Options,
                                  width: Int, height: Int) throws -> TransportRenderPlan {
        guard stock.donorLayers.isEmpty else {
            throw TransportError.unsupported("Layered Transport does not yet support donor-layer stocks; select Legacy for this stock")
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
        tail.clearTransportOptics(keepLens: false)
        tail.configuration[Int(FOTUFILM_CONFIG_RECORD_INPUT)] = 1
        let pitch = Double(options.format.frameHeightMM * min(max(options.frameCoverage, 0.05), 1)) / Double(min(width, height))
        return TransportRenderPlan(head: head, tail: tail, components: try prepared.compilation.kernels.indices.compactMap { k in
            let table = prepared.exposure.table(component: k, interpolation: t)
            guard table.values.contains(where: { $0 > 0 }) else { return nil }
            let bands = try prepared.compilation.kernels[k].stencils(pixelPitchMM: pitch)
            return .init(exposure: table.values, bands: bands.map { .init(weight: $0.weight, stencil: $0.stencil) })
        })
    }

    public static func process(image: ImageBuffer, stock: FilmStock, options: FotufilmEngine.Options,
                               model supplied: LayeredTransport, frameIndex: UInt64 = 0,
                               execution: TransportExecution? = nil,
                               invocation suppliedInvocation: FilmEngineInvocation? = nil,
                               pixelPitchMM: Double? = nil) throws -> ImageBuffer {
        guard execution != nil || (HalideBackend.isAvailable && options.transportBackend.isAvailable) else {
            throw TransportError.backend("requested transport backend is unavailable")
        }
        guard stock.donorLayers.isEmpty else {
            throw TransportError.unsupported("Layered Transport does not yet support donor-layer stocks; select Legacy for this stock")
        }
        guard image.width > 0 && image.height > 0, image.planes.count == 3,
              image.planes.allSatisfy({ $0.count == image.pixelCount && $0.allSatisfy(\.isFinite) }),
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
        if invocation.localToneActive && suppliedInvocation == nil {
            withPlanes(image.planes) { r, g, b in
                invocation.measureToneBase(planarR: r, g: g, b: b, width: image.width, height: image.height)
            }
        }
        let pitch = pixelPitchMM ?? (Double(options.format.frameHeightMM * min(max(options.frameCoverage, 0.05), 1))
            / Double(min(image.width, image.height)))
        var exposure = ImageBuffer(width: image.width, height: image.height)
        for k in prepared.compilation.kernels.indices {
            let table = prepared.exposure.table(component: k, interpolation: t)
            if !table.values.contains(where: { $0 > 0 }) { continue }
            var head = invocation
            head.featureMask &= FilmEngineFeature.flare | FilmEngineFeature.diffusion
            head.featureMask |= FilmEngineFeature.lightOut
            head.clearTransportOptics(keepLens: true)
            head.setTransportExposure(table)
            let component = try render(image, head, true)
            if let customConvolve = execution?.convolve {
                let bands = try prepared.compilation.kernels[k].stencils(pixelPitchMM: pitch)
                for band in bands {
                    let filtered = try customConvolve(component, band.stencil)
                    for c in 0..<3 { for i in 0..<image.pixelCount {
                        exposure.planes[c][i] += band.weight * filtered.planes[c][i]
                    } }
                }
            } else {
                let bands = try prepared.compilation.kernels[k].stencils(pixelPitchMM: pitch)
                try accumulate(component: component, bands: bands, into: &exposure, backend: options.transportBackend)
            }
        }
        guard exposure.planes.allSatisfy({ $0.allSatisfy { $0.isFinite && $0 >= 0 } }) else {
            throw TransportError.backend("transport produced invalid record exposure")
        }
        var continuation = invocation
        continuation.featureMask &= ~(FilmEngineFeature.flare | FilmEngineFeature.diffusion
            | FilmEngineFeature.mtf | FilmEngineFeature.mtfLuma | FilmEngineFeature.halation
            | FilmEngineFeature.annularHalation | FilmEngineFeature.texture)
        continuation.clearTransportOptics(keepLens: false)
        continuation.configuration[Int(FOTUFILM_CONFIG_RECORD_INPUT)] = 1
        if texture {
            continuation.featureMask |= FilmEngineFeature.densityOut
            let transported = try render(exposure, continuation, false)
            var referenceHead = invocation
            referenceHead.featureMask &= FilmEngineFeature.flare | FilmEngineFeature.diffusion
            referenceHead.featureMask |= FilmEngineFeature.lightOut
            referenceHead.clearTransportOptics(keepLens: true)
            let referenceExposure = try render(image, referenceHead, true)
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

    public static func convolve(_ image: ImageBuffer, stencil: TransportStencil,
                                backend: TransportBackend = .cpu) throws -> ImageBuffer {
        guard image.width > 0 && image.height > 0, image.planes.count == 3,
              image.planes.allSatisfy({ $0.count == image.pixelCount && $0.allSatisfy(\.isFinite) }),
              stencil.weights.count == (2 * stencil.radius + 1) * (2 * stencil.radius + 1) else {
            throw TransportError.invalid("invalid image or stencil")
        }
        var output = ImageBuffer(width: image.width, height: image.height)
        let status = withPlanes(image.planes) { r, g, b in
            withMutablePlanes(&output.planes) { rr, gg, bb in
                stencil.weights.withUnsafeBufferPointer { weights in
                    fotufilm_transport_convolve(r, g, b, rr, gg, bb,
                        Int32(image.width), Int32(image.height), weights.baseAddress,
                        Int32(stencil.radius), Int32(stencil.stride), backend.rawValue)
                }
            }
        }
        guard status == 0 else { throw TransportError.backend("convolution failed (\(status))") }
        return output
    }

    public static func accumulate(component: ImageBuffer, bands: [TransportWeightedStencil],
                                  into exposure: inout ImageBuffer,
                                  backend: TransportBackend = .cpu) throws {
        guard component.width > 0 && component.height > 0, component.planes.count == 3,
              component.planes.allSatisfy({ $0.count == component.pixelCount && $0.allSatisfy(\.isFinite) }),
              exposure.width == component.width && exposure.height == component.height,
              exposure.planes.count == 3,
              exposure.planes.allSatisfy({ $0.count == component.pixelCount && $0.allSatisfy(\.isFinite) }),
              bands.allSatisfy({ $0.weight.isFinite && $0.weight >= 0 }) else {
            throw TransportError.invalid("invalid image dimensions or planes")
        }
        let activeBands = bands.filter { $0.weight > 0 }
        if activeBands.isEmpty { return }

        var totalWeights = 0
        for band in activeBands {
            guard (1...128).contains(band.stencil.radius),
                  (1...4096).contains(band.stencil.stride),
                  band.stencil.stride.nonzeroBitCount == 1 else {
                throw TransportError.invalid("invalid stencil radius or stride")
            }
            let dim: Int = 2 * band.stencil.radius + 1
            let expected: Int = dim * dim
            guard band.stencil.weights.count == expected else {
                throw TransportError.invalid("invalid stencil weights size")
            }
            totalWeights += band.stencil.weights.count
        }

        var flattenedWeights = [Float]()
        flattenedWeights.reserveCapacity(totalWeights)
        var cBands = [FotufilmTransportBand]()
        cBands.reserveCapacity(activeBands.count)

        for band in activeBands {
            flattenedWeights.append(contentsOf: band.stencil.weights)
            cBands.append(FotufilmTransportBand(kernel: nil,
                                                radius: Int32(band.stencil.radius),
                                                stride: Int32(band.stencil.stride),
                                                weight: band.weight))
        }

        let status = withPlanes(component.planes) { r, g, b in
            withMutablePlanes(&exposure.planes) { er, eg, eb in
                flattenedWeights.withUnsafeBufferPointer { weightsBuf in
                    var offset = 0
                    for i in cBands.indices {
                        cBands[i].kernel = weightsBuf.baseAddress! + offset
                        offset += Int((2 * cBands[i].radius + 1) * (2 * cBands[i].radius + 1))
                    }
                    return cBands.withUnsafeBufferPointer { bandsBuf in
                        fotufilm_transport_accumulate(r, g, b, er, eg, eb,
                            Int32(component.width), Int32(component.height),
                            bandsBuf.baseAddress, Int32(activeBands.count), backend.rawValue)
                    }
                }
            }
        }
        guard status == 0 else { throw TransportError.backend("transport accumulate failed (\(status))") }
    }

    private static func run(image: ImageBuffer, invocation: FilmEngineInvocation,
                            developOnly: Bool = false) throws -> ImageBuffer {
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
            configuration[Int(FOTUFILM_CONFIG_FLARE)] = 0
            configuration[Int(FOTUFILM_CONFIG_DIFFUSION_DIRECT)] = 1
            for c in 0..<9 { configuration[Int(FOTUFILM_CONFIG_DIFFUSION_KERNEL)+c] = 0 }
            for c in 0..<3 { configuration[Int(FOTUFILM_CONFIG_DIFFUSION_RADIUS)+c] = 0 }
        }
    }
}

public struct TransportRenderPlan {
    public struct Band { public let weight: Float; public let stencil: TransportStencil }
    public struct Component { public let exposure: [Float]; public let bands: [Band] }
    public let head: FilmEngineInvocation
    public let tail: FilmEngineInvocation
    public let components: [Component]
}
