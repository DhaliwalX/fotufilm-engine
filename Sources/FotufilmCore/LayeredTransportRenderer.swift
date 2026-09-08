import Foundation
import FotufilmHalide

public enum TransportBackend: Int32, Sendable, Codable {
    case cpu = 0
    /// Halide Metal JIT convolution; scene preparation and development retain the CPU reference.
    case metal = 1
    public var isAvailable: Bool { fotufilm_transport_available(rawValue) == 1 }
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
        for values in [options.sceneIlluminantSpectrum, options.halationReturnGain,
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

    public static func process(image: ImageBuffer, stock: FilmStock, options: FotufilmEngine.Options,
                               model supplied: LayeredTransport) throws -> ImageBuffer {
        guard HalideBackend.isAvailable, options.transportBackend.isAvailable else {
            throw TransportError.backend("requested transport backend is unavailable")
        }
        guard stock.donorLayers.isEmpty else { throw TransportError.unsupported("donor capture layers") }
        guard image.width > 0 && image.height > 0, image.planes.count == 3,
              image.planes.allSatisfy({ $0.count == image.pixelCount && $0.allSatisfy(\.isFinite) }),
              options.halationScale.isFinite && options.halationScale >= 0,
              stock.halationLookScale.isFinite && stock.halationLookScale >= 0,
              options.frameCoverage.isFinite, options.format.frameHeightMM.isFinite,
              options.format.frameHeightMM > 0 else {
            throw TransportError.invalid("invalid image or amount")
        }
        var plain = stock; plain.layeredTransport = nil
        var settings = options; settings.layeredTransport = nil
        var model = supplied
        let texture = options.stage == .texture
        if texture && !options.textureStages.contains(.emulsionMTF) { model.coreSigmaMM = [0, 0, 0] }
        let prepared = try prepare(model: model, stock: plain, options: settings)
        let amount = texture && !options.textureStages.contains(.halation) ? 0
            : Double(options.halationScale) * Double(stock.halationLookScale)
        let t = prepared.compilation.interpolation(amount: amount)
        var invocation = FilmEngineInvocation(stock: plain, options: settings,
                                             width: image.width, height: image.height)
        if invocation.localToneActive {
            withPlanes(image.planes) { r, g, b in
                invocation.measureToneBase(planarR: r, g: g, b: b, width: image.width, height: image.height)
            }
        }
        let pitch = Double(options.format.frameHeightMM * min(max(options.frameCoverage, 0.05), 1))
            / Double(min(image.width, image.height))
        var exposure = ImageBuffer(width: image.width, height: image.height)
        for k in prepared.compilation.kernels.indices {
            let table = prepared.exposure.table(component: k, interpolation: t)
            if !table.values.contains(where: { $0 > 0 }) { continue }
            var head = invocation
            head.featureMask &= FilmEngineFeature.flare | FilmEngineFeature.diffusion
            head.featureMask |= FilmEngineFeature.lightOut
            head.spectral = SpectralPipelineTables(exposure: table, filmOutput: invocation.spectral.filmOutput,
                                                   paperOutput: invocation.spectral.paperOutput)
            let component = try run(image: image, invocation: head, developOnly: true)
            for band in try prepared.compilation.kernels[k].stencils(pixelPitchMM: pitch) {
                let filtered = try convolve(component, stencil: band.stencil, backend: options.transportBackend)
                for c in 0..<3 { for i in 0..<image.pixelCount {
                    exposure.planes[c][i] += band.weight * filtered.planes[c][i]
                } }
            }
        }
        guard exposure.planes.allSatisfy({ $0.allSatisfy { $0.isFinite && $0 >= 0 } }) else {
            throw TransportError.backend("transport produced invalid record exposure")
        }
        var continuation = invocation
        continuation.featureMask &= ~(FilmEngineFeature.flare | FilmEngineFeature.diffusion
            | FilmEngineFeature.mtf | FilmEngineFeature.mtfLuma | FilmEngineFeature.halation
            | FilmEngineFeature.annularHalation | FilmEngineFeature.texture)
        continuation.featureMask |= Int32(FOTUFILM_FRAME_RECORD_EXPOSURE_IN)
        if texture {
            continuation.featureMask |= FilmEngineFeature.densityOut
            let transported = try run(image: exposure, invocation: continuation)
            var referenceHead = invocation
            referenceHead.featureMask &= FilmEngineFeature.flare | FilmEngineFeature.diffusion
            referenceHead.featureMask |= FilmEngineFeature.lightOut
            let referenceExposure = try run(image: image, invocation: referenceHead, developOnly: true)
            var reference = continuation
            reference.featureMask &= ~(FilmEngineFeature.grain | FilmEngineFeature.adjacency
                | FilmEngineFeature.couplerDiffusion | FilmEngineFeature.printMTF)
            let baseline = try run(image: referenceExposure, invocation: reference)
            var output = image
            let sign: Float = stock.isReversal ? -1 : 1
            for c in 0..<3 { for i in 0..<image.pixelCount {
                output.planes[c][i] *= exp(sign * (transported.planes[c][i] - baseline.planes[c][i]) * log(10))
            } }
            return output
        }
        return try run(image: exposure, invocation: continuation)
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
