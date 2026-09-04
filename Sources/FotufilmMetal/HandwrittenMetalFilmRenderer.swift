#if canImport(Metal)
import Foundation
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif

private func retainHandwrittenMetalResources(
    _ resources: [AnyObject], untilCompletedBy commandBuffer: MTLCommandBuffer
) {
    commandBuffer.addCompletedHandler { _ in
        withExtendedLifetime(resources) {}
    }
}

/// A parity-first handwritten Metal frame renderer.
///
/// Preparation evaluates the data-driven spectral tables directly; neither preparation nor a
/// frame enters a Halide schedule. The seam between the cubes deliberately leaves film development
/// exposed, so spatial stages can be inserted in their physical domains without moving optical
/// operations across development.
///
/// This initial road implements the complete pointwise chemistry, including nonlinear DIR
/// release and its neutral-axis warp. Spatial kernels are added to this executor independently;
/// until then it is a differential-test target, not a production replacement.
public final class HandwrittenMetalFilmRenderer {
    public static let shared = HandwrittenMetalFilmRenderer()

    private static let printCubeEdge = 65
    private static let curveSamples = 2_048
    static let transferSamples = 1_024
    static let decodeSamples = 256

    private struct FrameParameters {
        var width: UInt32
        var height: UInt32
        var frameWidth: UInt32
        var originX: UInt32
        var originY: UInt32
        var seed: UInt32
        var reversal: UInt32
        var nonlinearWarp: UInt32
        var donor: UInt32
        var toneAdjust: UInt32
        var chromaAdjust: UInt32
        var ditherSalt0: UInt32
        var ditherSalt1: UInt32
        var ditherSalt2: UInt32
    }

    private struct HDRFrameParameters {
        var frame: FrameParameters
        var inputGain: Float
        var padding: SIMD3<Float> = .zero
    }

    private struct Prepared {
        let exposure: MTLTexture
        let print: MTLTexture
        let curves: MTLTexture
        let configuration: MTLBuffer
        let seed: UInt32
        let frameWidth: Int
        let frameHeight: Int
        let hdrInput: Bool
        let reversal: Bool
        let nonlinearWarp: Bool
        let donor: Bool
        let toneAdjust: Bool
        let chromaAdjust: Bool
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let sdrPipeline: MTLComputePipelineState
    private let hdrPipeline: MTLComputePipelineState
    private let temporalSDRPipeline: MTLComputePipelineState
    private let temporalHDRPipeline: MTLComputePipelineState
    private let transfer: MTLTexture
    private let decode: MTLTexture
    private let lock = NSLock()
    private var prepared: [String: Prepared] = [:]

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let transfer = Self.makeTransferTexture(device: device),
              let decode = Self.makeDecodeTexture(device: device)
        else { return nil }
        do {
            let compileOptions = MTLCompileOptions()
            compileOptions.fastMathEnabled = true
            let library = try HandwrittenMetalShaderLibrary.makeLibrary(
                device: device, shader: .pointwise, options: compileOptions,
                preprocessorMacros: [
                    "FOTUFILM_POINTWISE_TRANSFER_SAMPLES": NSNumber(
                        value: Self.transferSamples),
                    "FOTUFILM_POINTWISE_DECODE_SAMPLES": NSNumber(
                        value: Self.decodeSamples),
                ])
            func makePipeline(
                _ name: String, temporalPrint: Bool
            ) throws -> MTLComputePipelineState {
                let constants = MTLFunctionConstantValues()
                var temporalPrint = temporalPrint
                constants.setConstantValue(
                    &temporalPrint, type: .bool, index: 0)
                let function = try library.makeFunction(
                    name: name, constantValues: constants)
                return try device.makeComputePipelineState(function: function)
            }
            sdrPipeline = try makePipeline(
                "fotufilm_handwritten_pointwise_sdr", temporalPrint: false)
            hdrPipeline = try makePipeline(
                "fotufilm_handwritten_pointwise_hdr", temporalPrint: false)
            temporalSDRPipeline = try makePipeline(
                "fotufilm_handwritten_pointwise_sdr", temporalPrint: true)
            temporalHDRPipeline = try makePipeline(
                "fotufilm_handwritten_pointwise_hdr", temporalPrint: true)
        } catch {
            print("HandwrittenMetalFilmRenderer: Metal library failed (\(error))")
            return nil
        }
        self.device = device
        self.queue = queue
        self.transfer = transfer
        self.decode = decode
    }

    /// Prepares immutable tables for one stock/options/frame-size tuple.
    ///
    /// The caller owns `key`; replace it whenever an edit changes. Local tone is intentionally
    /// rejected for now because its value depends on frame coordinates and therefore cannot be
    /// represented by a colour cube. The production executor will run that creative stage before
    /// the exposure cube.
    @discardableResult
    public func prepare(
        key: String, stock: FilmStock, options: FotufilmEngine.Options,
        frameWidth: Int, frameHeight: Int
    ) -> Bool {
        prepare(
            key: key, stock: stock, options: options,
            frameWidth: frameWidth, frameHeight: frameHeight, hdrInput: false)
    }

    /// Prepares the same chemistry for linear Rec.2020 half-float input and linear Display P3
    /// output, matching the engine's float full-frame contract.
    @discardableResult
    public func prepareLinearHDR(
        key: String, stock: FilmStock, options: FotufilmEngine.Options,
        frameWidth: Int, frameHeight: Int
    ) -> Bool {
        prepare(
            key: key, stock: stock, options: options,
            frameWidth: frameWidth, frameHeight: frameHeight, hdrInput: true)
    }

    private func prepare(
        key: String, stock: FilmStock, options: FotufilmEngine.Options,
        frameWidth: Int, frameHeight: Int, hdrInput: Bool
    ) -> Bool {
        guard frameWidth > 0, frameHeight > 0,
              options.stage == .full else { return false }
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: frameWidth, height: frameHeight)
        let originalMask = invocation.featureMask
        guard !invocation.localToneActive,
              originalMask & FilmEngineFeature.flare == 0 else { return false }
        let reversal = originalMask & FilmEngineFeature.reversal != 0
        let donor = originalMask & FilmEngineFeature.donorLayer != 0
        let nonlinearWarp = (0..<3).contains {
            invocation.configuration[
                FilmEngineInvocation.couplerReleaseGammaOffset + $0] != 1
        } || invocation.configuration[
            FilmEngineInvocation.donorReleaseGammaOffset] != 1
        let toneAdjust = invocation.configuration[
            FilmEngineInvocation.sceneAdjustOffset] != 0
            || invocation.configuration[
                FilmEngineInvocation.sceneAdjustOffset + 1] != 0
        let chromaAdjust = invocation.configuration[
            FilmEngineInvocation.sceneAdjustOffset + 2] != 1
            || invocation.configuration[
                FilmEngineInvocation.sceneAdjustOffset + 3] != 0

        guard let exposure = makeExposureTexture(invocation: invocation),
              let print = bakePrintCube(invocation: invocation),
              let curves = makeCurveTexture(
                configuration: invocation.configuration),
              let configuration = device.makeBuffer(
                bytes: invocation.configuration,
                length: invocation.configuration.count * MemoryLayout<Float>.stride,
                options: .storageModeShared)
        else { return false }

        let value = Prepared(
            exposure: exposure, print: print, curves: curves,
            configuration: configuration, seed: invocation.seed,
            frameWidth: frameWidth, frameHeight: frameHeight,
            hdrInput: hdrInput,
            reversal: reversal,
            nonlinearWarp: nonlinearWarp, donor: donor,
            toneAdjust: toneAdjust, chromaAdjust: chromaAdjust)
        lock.lock()
        prepared[key] = value
        lock.unlock()
        return true
    }

    /// Encodes a pointwise reference frame into a caller-owned command buffer. It neither commits
    /// nor waits, so it can share one frame graph with capture decode, spatial stages, presentation,
    /// and recording.
    @discardableResult
    public func encodeRGBA8(
        input: MTLBuffer, output: MTLBuffer,
        width: Int, height: Int, originX: Int = 0, originY: Int = 0,
        key: String, frameIndex: UInt64, temporalPrint: Bool = false,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        let bytes = width * height * 4
        guard width > 0, height > 0, originX >= 0, originY >= 0,
              input.length >= bytes, output.length >= bytes,
              commandBuffer.device === device,
              commandBuffer.status == .notEnqueued else { return false }
        lock.lock()
        let tables = prepared[key]
        lock.unlock()
        guard let tables, !tables.hdrInput,
              originX + width <= tables.frameWidth,
              originY + height <= tables.frameHeight,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        let animatedSeed = tables.seed &+ UInt32(truncatingIfNeeded:
            frameIndex &* 0x9E3779B97F4A7C15)
        let ditherBase = animatedSeed &* 0x9E3779B9
        retainHandwrittenMetalResources(
            [self, input, output, tables.exposure, tables.print,
             tables.curves, transfer, decode, tables.configuration],
            untilCompletedBy: commandBuffer)
        var parameters = FrameParameters(
            width: UInt32(width), height: UInt32(height),
            frameWidth: UInt32(tables.frameWidth),
            originX: UInt32(originX), originY: UInt32(originY),
            seed: animatedSeed,
            reversal: tables.reversal ? 1 : 0,
            nonlinearWarp: tables.nonlinearWarp ? 1 : 0,
            donor: tables.donor ? 1 : 0,
            toneAdjust: tables.toneAdjust ? 1 : 0,
            chromaAdjust: tables.chromaAdjust ? 1 : 0,
            ditherSalt0: Self.pcg(ditherBase),
            ditherSalt1: Self.pcg(1 &+ ditherBase),
            ditherSalt2: Self.pcg(2 &+ ditherBase))
        encoder.setComputePipelineState(
            temporalPrint ? temporalSDRPipeline : sdrPipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBuffer(tables.configuration, offset: 0, index: 2)
        encoder.setBytes(&parameters,
                         length: MemoryLayout<FrameParameters>.stride, index: 3)
        encoder.setTexture(tables.exposure, index: 0)
        encoder.setTexture(tables.print, index: 1)
        encoder.setTexture(tables.curves, index: 2)
        encoder.setTexture(transfer, index: 3)
        encoder.setTexture(decode, index: 4)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 32, height: 2, depth: 1))
        encoder.endEncoding()
        return true
    }

    /// Encodes a linear Rec.2020 half-float HDR frame into a caller-owned command buffer.
    @discardableResult
    public func encodeLinearHalf(
        input: MTLBuffer, output: MTLBuffer,
        width: Int, height: Int, originX: Int = 0, originY: Int = 0,
        key: String, frameIndex: UInt64, inputGain: Float = 1,
        temporalPrint: Bool = false,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        let bytes = width * height * 4 * MemoryLayout<Float16>.stride
        guard width > 0, height > 0, originX >= 0, originY >= 0,
              inputGain.isFinite, inputGain >= 0,
              input.length >= bytes, output.length >= bytes,
              commandBuffer.device === device,
              commandBuffer.status == .notEnqueued else { return false }
        lock.lock()
        let tables = prepared[key]
        lock.unlock()
        guard let tables, tables.hdrInput,
              originX + width <= tables.frameWidth,
              originY + height <= tables.frameHeight,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        let animatedSeed = tables.seed &+ UInt32(truncatingIfNeeded:
            frameIndex &* 0x9E3779B97F4A7C15)
        let ditherBase = animatedSeed &* 0x9E3779B9
        retainHandwrittenMetalResources(
            [self, input, output, tables.exposure, tables.print,
             tables.curves, tables.configuration],
            untilCompletedBy: commandBuffer)
        let common = FrameParameters(
            width: UInt32(width), height: UInt32(height),
            frameWidth: UInt32(tables.frameWidth),
            originX: UInt32(originX), originY: UInt32(originY),
            seed: animatedSeed, reversal: tables.reversal ? 1 : 0,
            nonlinearWarp: tables.nonlinearWarp ? 1 : 0,
            donor: tables.donor ? 1 : 0,
            toneAdjust: tables.toneAdjust ? 1 : 0,
            chromaAdjust: tables.chromaAdjust ? 1 : 0,
            ditherSalt0: Self.pcg(ditherBase),
            ditherSalt1: Self.pcg(1 &+ ditherBase),
            ditherSalt2: Self.pcg(2 &+ ditherBase))
        var parameters = HDRFrameParameters(
            frame: common, inputGain: inputGain)
        encoder.setComputePipelineState(
            temporalPrint ? temporalHDRPipeline : hdrPipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBuffer(tables.configuration, offset: 0, index: 2)
        encoder.setBytes(&parameters,
                         length: MemoryLayout<HDRFrameParameters>.stride, index: 3)
        encoder.setTexture(tables.exposure, index: 0)
        encoder.setTexture(tables.print, index: 1)
        encoder.setTexture(tables.curves, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 32, height: 2, depth: 1))
        encoder.endEncoding()
        return true
    }

    @discardableResult
    public func processRGBA8(
        input: MTLBuffer, output: MTLBuffer,
        width: Int, height: Int, originX: Int = 0, originY: Int = 0,
        key: String, frameIndex: UInt64, temporalPrint: Bool = false
    ) -> Bool {
        guard let commandBuffer = queue.makeCommandBuffer(),
              encodeRGBA8(
                input: input, output: output, width: width, height: height,
                originX: originX, originY: originY, key: key,
                frameIndex: frameIndex, temporalPrint: temporalPrint,
                commandBuffer: commandBuffer)
        else { return false }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    @discardableResult
    public func processLinearHalf(
        input: MTLBuffer, output: MTLBuffer,
        width: Int, height: Int, originX: Int = 0, originY: Int = 0,
        key: String, frameIndex: UInt64, inputGain: Float = 1,
        temporalPrint: Bool = false
    ) -> Bool {
        guard let commandBuffer = queue.makeCommandBuffer(),
              encodeLinearHalf(
                input: input, output: output, width: width, height: height,
                originX: originX, originY: originY, key: key,
                frameIndex: frameIndex, inputGain: inputGain,
                temporalPrint: temporalPrint,
                commandBuffer: commandBuffer)
        else { return false }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    public func removeAll() {
        lock.lock()
        prepared.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func makeExposureTexture(
        invocation: FilmEngineInvocation
    ) -> MTLTexture? {
        let table = invocation.spectral.exposure
        let edge = table.dimension
        guard edge >= 2, table.values.count == edge * edge * edge * 4 else {
            return nil
        }
        // Recovery divides physical light by its largest component before this lookup. Except at
        // exact black, every coordinate therefore lies on one of the cube's three upper faces.
        // Store only those faces: the restriction of tetrahedral interpolation to a face is the
        // same three-vertex triangular interpolation, while the whole working set fits in the
        // texture cache (about 26 KiB instead of 281 KiB at the canonical 33-node edge).
        var faces = [Float16](repeating: 0, count: 3 * edge * edge * 4)
        @inline(__always)
        func sourceIndex(_ x: Int, _ y: Int, _ z: Int) -> Int {
            ((z * edge + y) * edge + x) * 4
        }
        for face in 0..<3 {
            for v in 0..<edge {
                for u in 0..<edge {
                    let coordinate: (x: Int, y: Int, z: Int)
                    switch face {
                    case 0: coordinate = (edge - 1, u, v)
                    case 1: coordinate = (u, edge - 1, v)
                    default: coordinate = (u, v, edge - 1)
                    }
                    let source = sourceIndex(
                        coordinate.x, coordinate.y, coordinate.z)
                    let destination = ((face * edge + v) * edge + u) * 4
                    for channel in 0..<4 {
                        let value = table.values[source + channel]
                        faces[destination + channel] = Float16(
                            value.isFinite ? value : 0)
                    }
                }
            }
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = edge
        descriptor.height = edge
        descriptor.arrayLength = 3
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let bytesPerRow = edge * 4 * MemoryLayout<Float16>.stride
        let bytesPerFace = edge * bytesPerRow
        faces.withUnsafeBytes { bytes in
            for face in 0..<3 {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, edge, edge),
                    mipmapLevel: 0, slice: face,
                    withBytes: bytes.baseAddress!.advanced(by: face * bytesPerFace),
                    bytesPerRow: bytesPerRow, bytesPerImage: bytesPerFace)
            }
        }
        return texture
    }

    private func bakePrintCube(invocation source: FilmEngineInvocation) -> MTLTexture? {
        guard let values = HandwrittenPrintResponseBaker.linearCubeValues(
            invocation: source, edge: Self.printCubeEdge)
        else { return nil }
        return makeCubeTexture(fromFloatValues: values)
    }

    private func makeCubeTexture(fromFloatValues values: [Float]) -> MTLTexture? {
        let count = Self.printCubeEdge * Self.printCubeEdge
            * Self.printCubeEdge * 4
        guard values.count == count else { return nil }
        var half = [Float16](repeating: 0, count: count)
        for index in 0..<count {
            let value = values[index]
            half[index] = Float16(value.isFinite ? value : 0)
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = Self.printCubeEdge
        descriptor.height = Self.printCubeEdge
        descriptor.depth = Self.printCubeEdge
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        half.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake3D(
                    0, 0, 0, Self.printCubeEdge,
                    Self.printCubeEdge, Self.printCubeEdge),
                mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: Self.printCubeEdge * 4 * MemoryLayout<Float16>.stride,
                bytesPerImage: Self.printCubeEdge * Self.printCubeEdge * 4
                    * MemoryLayout<Float16>.stride)
        }
        return texture
    }

    private func makeCurveTexture(configuration: [Float]) -> MTLTexture? {
        // Row 0 is the released inhibitor activation for the three image-forming layers and the
        // optional donor. Row 1 folds the stock's neutral-axis warp into the final film curve.
        // Both are edit-time tables: keeping the Hill powers and cubic warp out of the 4K frame
        // kernel saves several transcendental operations per pixel without moving a physical seam.
        let rows = 2
        var values = [Float16](
            repeating: 0, count: Self.curveSamples * rows * 4)
        let minima = (0..<3).map { configuration[$0 * 6] }
        let ranges = (0..<3).map {
            Self.filmCurveRange(configuration: configuration, channel: $0)
        }
        // A genuine reversal stock develops to a direct positive, so its row-1 coordinate is the
        // complement; a negative shown on a light box or scanner is not complemented, however it
        // is routed. See FOTUFILM_CONFIG_DEVELOP_COMPLEMENT.
        let complement =
            configuration[FilmEngineInvocation.developComplementOffset] != 0
        let donorMinimum = configuration[FilmEngineInvocation.donorCurveOffset]
        let donorRange = configuration[FilmEngineInvocation.donorCurveOffset + 1]
            * (configuration[FilmEngineInvocation.donorCurveOffset + 4]
               - configuration[FilmEngineInvocation.donorCurveOffset + 2])
        let nonlinearWarp = (0..<3).contains {
            configuration[FilmEngineInvocation.couplerReleaseGammaOffset + $0] != 1
        } || configuration[FilmEngineInvocation.donorReleaseGammaOffset] != 1
        for sample in 0..<Self.curveSamples {
            let x = -8 + 16 * Float(sample) / Float(Self.curveSamples - 1)
            for channel in 0..<3 {
                let density = Self.filmDensity(
                    configuration: configuration, channel: channel,
                    logExposure: x)
                let activation = (density - minima[channel])
                    / max(ranges[channel], 1e-6)
                values[sample * 4 + channel] = Float16(Self.inhibitorRelease(
                    activation: activation,
                    gamma: configuration[
                        FilmEngineInvocation.couplerReleaseGammaOffset + channel]))
                let effective = x + Self.couplerWarp(
                    configuration: configuration, channel: channel,
                    value: x, nonlinear: nonlinearWarp)
                let formed = Self.filmDensity(
                    configuration: configuration, channel: channel,
                    logExposure: effective)
                let coordinate = (formed - minima[channel])
                    / max(ranges[channel], 1e-6)
                values[(Self.curveSamples + sample) * 4 + channel] = Float16(
                    complement ? 1 - coordinate : coordinate)
            }
            let donorDensity = Self.curveDensity(
                configuration: configuration,
                base: FilmEngineInvocation.donorCurveOffset,
                logExposure: x)
            values[sample * 4 + 3] = Float16(Self.inhibitorRelease(
                activation: (donorDensity - donorMinimum) / max(donorRange, 1e-6),
                gamma: configuration[FilmEngineInvocation.donorReleaseGammaOffset]))
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: Self.curveSamples,
            height: rows, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, Self.curveSamples, rows),
                mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: Self.curveSamples * 4 * MemoryLayout<Float16>.stride)
        }
        return texture
    }

    private static func makeTransferTexture(device: MTLDevice) -> MTLTexture? {
        var values = [Float16](repeating: 0, count: transferSamples)
        for index in values.indices {
            let root = Float(index) / Float(transferSamples - 1)
            values[index] = Float16(ColorScience.linearToSrgb(root * root))
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.pixelFormat = .r16Float
        descriptor.width = transferSamples
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake1D(0, transferSamples), mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: transferSamples * MemoryLayout<Float16>.stride)
        }
        return texture
    }

    private static func makeDecodeTexture(device: MTLDevice) -> MTLTexture? {
        var values = [Float16](repeating: 0, count: decodeSamples)
        for index in values.indices {
            values[index] = Float16(ColorScience.srgbToLinear(
                Float(index) / Float(decodeSamples - 1)))
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.pixelFormat = .r16Float
        descriptor.width = decodeSamples
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake1D(0, decodeSamples), mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: decodeSamples * MemoryLayout<Float16>.stride)
        }
        return texture
    }

    private static func softplus(_ value: Float) -> Float {
        if value > 20 { return value }
        if value < -20 { return exp(value) }
        return log1p(exp(value))
    }

    private static func pcg(_ value: UInt32) -> UInt32 {
        let state = value &* 747_796_405 &+ 2_891_336_453
        let word = ((state >> ((state >> 28) + 4)) ^ state) &* 277_803_737
        return (word >> 22) ^ word
    }

    private static func curveDensity(
        configuration: [Float], base: Int, logExposure: Float
    ) -> Float {
        let dMin = configuration[base]
        let gamma = configuration[base + 1]
        let toe = configuration[base + 2]
        let toeWidth = max(configuration[base + 3], 1e-6)
        let shoulder = configuration[base + 4]
        let shoulderWidth = max(configuration[base + 5], 1e-6)
        let toeTerm = toeWidth * softplus((logExposure - toe) / toeWidth)
        let shoulderTerm = shoulderWidth
            * softplus((logExposure - shoulder) / shoulderWidth)
        return dMin + gamma * min(max(toeTerm - shoulderTerm, 0), shoulder - toe)
    }

    private static func filmDensity(
        configuration: [Float], channel: Int, logExposure: Float
    ) -> Float {
        let primary = curveDensity(
            configuration: configuration, base: channel * 6,
            logExposure: logExposure)
        let base = FilmEngineInvocation.curveSecondaryOffset + channel * 5
        let gamma = configuration[base]
        guard gamma != 0 else { return primary }
        let toe = configuration[base + 1]
        let toeWidth = max(configuration[base + 2], 1e-6)
        let shoulder = configuration[base + 3]
        let shoulderWidth = max(configuration[base + 4], 1e-6)
        let toeTerm = toeWidth * softplus((logExposure - toe) / toeWidth)
        let shoulderTerm = shoulderWidth
            * softplus((logExposure - shoulder) / shoulderWidth)
        return primary + gamma
            * min(max(toeTerm - shoulderTerm, 0), shoulder - toe)
    }

    private static func filmCurveRange(
        configuration: [Float], channel: Int
    ) -> Float {
        let primary = channel * 6
        let secondary = FilmEngineInvocation.curveSecondaryOffset + channel * 5
        return configuration[primary + 1]
            * (configuration[primary + 4] - configuration[primary + 2])
            + configuration[secondary]
            * (configuration[secondary + 3] - configuration[secondary + 1])
    }

    private static func inhibitorRelease(activation: Float, gamma: Float) -> Float {
        let value = min(max(activation, 0), 1)
        guard gamma != 1 else { return value }
        let released = pow(value, gamma)
        let retained = pow(1 - value, gamma)
        return released / max(released + retained, 1e-8)
    }

    private static func couplerWarp(
        configuration: [Float], channel: Int, value: Float, nonlinear: Bool
    ) -> Float {
        let samples = FilmEngineInvocation.couplerWarpSamples
        let low = FilmEngineInvocation.couplerWarpMin
        let high = FilmEngineInvocation.couplerWarpMax
        let q = min(max((value - low) * Float(samples - 1) / (high - low), 0),
                    Float(samples - 1))
        let index = min(Int(q), samples - 2)
        let fraction = q - Float(index)
        let base = FilmEngineInvocation.couplerWarpOffset + channel * samples
        let lowValue = configuration[base + index]
        let highValue = configuration[base + index + 1]
        guard nonlinear else { return lowValue + fraction * (highValue - lowValue) }
        let previous = configuration[base + max(index - 1, 0)]
        let following = configuration[base + min(index + 2, samples - 1)]
        let delta = max(highValue - lowValue, 0)
        let lowSlope = min(max(0.5 * (highValue - previous), 0), 3 * delta)
        let highSlope = min(max(0.5 * (following - lowValue), 0), 3 * delta)
        let f2 = fraction * fraction
        let f3 = f2 * fraction
        return (2 * f3 - 3 * f2 + 1) * lowValue
            + (f3 - 2 * f2 + fraction) * lowSlope
            + (-2 * f3 + 3 * f2) * highValue
            + (f3 - f2) * highSlope
    }

}
#endif
