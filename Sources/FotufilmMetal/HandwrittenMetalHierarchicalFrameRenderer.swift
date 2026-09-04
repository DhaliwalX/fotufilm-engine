#if canImport(Metal)
import Foundation
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// A native-detail camera schedule with a physically scaled spatial residual lattice.
///
/// Pointwise spectral/film/print response is evaluated at every camera pixel through a composed
/// scene cube. Halation, diffused couplers, adjacency, flare, and the other smooth spatial fields
/// are evaluated by the exact handwritten graph on a smaller lattice, then transported back as a
/// linear-light residual. The source is never resized for presentation: native detail always comes
/// from the full-resolution composed result.
public final class HandwrittenMetalHierarchicalFrameRenderer {
    public typealias HDRCaptureTransfer = HandwrittenMetalFullFrameRenderer.HDRCaptureTransfer
    public typealias SDRCaptureRange = HandwrittenMetalFullFrameRenderer.SDRCaptureRange
    public typealias SDRCaptureGamut = HandwrittenMetalFullFrameRenderer.SDRCaptureGamut

    public enum PreparationError: Swift.Error, CustomStringConvertible {
        case invalidDimensions
        case grainRequiresThirtyFPSPath
        case componentUnavailable(String)
        case measurementPreparation(String)
        case fullFramePreparation(String)
        case cubePreparation(String)
        case allocationFailed(String)

        public var description: String {
            switch self {
            case .invalidDimensions:
                return "the hierarchical camera frame must have positive even dimensions"
            case .grainRequiresThirtyFPSPath:
                return "the 60 fps hierarchical schedule requires grain to be disabled"
            case let .componentUnavailable(name):
                return "the handwritten \(name) component is unavailable"
            case let .measurementPreparation(message):
                return "hierarchical tone preparation failed: \(message)"
            case let .fullFramePreparation(message):
                return "reduced spatial preparation failed: \(message)"
            case let .cubePreparation(message):
                return "composed pointwise preparation failed: \(message)"
            case let .allocationFailed(name):
                return "unable to allocate \(name)"
            }
        }
    }

    public static let spatialReduction = 2
    public static let outputPixelFormat: MTLPixelFormat = .rgba16Float
    static let decodeSamples = 256

    private struct SceneParameters {
        var whiteBalance: SIMD4<Float>
        var adjustment: SIMD4<Float>
        var exposureAndCube: SIMD4<Float>
    }

    private struct CameraParameters {
        var outputAndTone: SIMD4<UInt32>
        var source: SIMD4<UInt32>
        var transform: SIMD4<Float>
    }

    private struct PipelineSet {
        let sdrBase: MTLComputePipelineState
        let hdrBase: MTLComputePipelineState
        let sdrFinish: MTLComputePipelineState
        let hdrFinish: MTLComputePipelineState
    }

    private struct Prepared {
        let revision: UInt64
        let lowKey: String
        let cubeKey: String
        let width: Int
        let height: Int
        let lowWidth: Int
        let lowHeight: Int
        let invocation: FilmEngineInvocation
        let scene: MTLBuffer
        let pipelines: PipelineSet
        let toneActive: Bool

        var frameKey: FrameKey {
            FrameKey(revision: revision, width: lowWidth, height: lowHeight)
        }
    }

    private struct FrameKey: Equatable {
        let revision: UInt64
        let width: Int
        let height: Int
    }

    private final class Frame {
        let key: FrameKey
        let lowFull: MTLTexture
        let lowBase: MTLTexture
        let sdrMeasurements: HandwrittenMetalGlobalMeasurements.Resources
        let hdrMeasurements: HandwrittenMetalGlobalMeasurements.Resources
        var leased = false

        init(
            key: FrameKey, lowFull: MTLTexture, lowBase: MTLTexture,
            sdrMeasurements: HandwrittenMetalGlobalMeasurements.Resources,
            hdrMeasurements: HandwrittenMetalGlobalMeasurements.Resources
        ) {
            self.key = key
            self.lowFull = lowFull
            self.lowBase = lowBase
            self.sdrMeasurements = sdrMeasurements
            self.hdrMeasurements = hdrMeasurements
        }
    }

    private let device: MTLDevice
    private let measurements: HandwrittenMetalGlobalMeasurements
    private let lowRenderer: HandwrittenMetalFullFrameRenderer
    private let composed: HandwrittenMetalComposedPointwise
    private let library: MTLLibrary
    private let decode: MTLTexture
    private let identityTone: MTLBuffer
    private let maximumInFlightFrames: Int
    private let lock = NSLock()
    private var prepared: [String: Prepared] = [:]
    private var frames: [Frame] = []
    private var pipelineCache: [Bool: PipelineSet] = [:]
    private var revision: UInt64 = 0

    public convenience init?(
        maximumInFlightFrames: Int = 2, cubeEdge: Int = 65,
        cubeInputKnee: Float = 0.01
    ) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.init(
            device: device, maximumInFlightFrames: maximumInFlightFrames,
            cubeEdge: cubeEdge, cubeInputKnee: cubeInputKnee)
    }

    public init?(
        device: MTLDevice, maximumInFlightFrames: Int = 2,
        cubeEdge: Int = 65, cubeInputKnee: Float = 0.01
    ) {
        guard maximumInFlightFrames > 0,
              let measurements = HandwrittenMetalGlobalMeasurements(device: device),
              let lowRenderer = HandwrittenMetalFullFrameRenderer(
                device: device, maximumInFlightFrames: maximumInFlightFrames,
                spatialOptimizationVariant: .exactSpecialized),
              let composed = HandwrittenMetalComposedPointwise(
                device: device, cubeEdge: cubeEdge,
                inputKnee: cubeInputKnee),
              let decode = Self.makeDecodeTexture(device: device)
        else { return nil }
        do {
            let options = MTLCompileOptions()
            options.fastMathEnabled = true
            library = try HandwrittenMetalShaderLibrary.makeLibrary(
                device: device, shader: .hierarchicalCamera, options: options,
                preprocessorMacros: [
                    "FOTUFILM_HIERARCHICAL_DECODE_SAMPLES": NSNumber(value: Self.decodeSamples),
                ])
        } catch {
            print("HandwrittenMetalHierarchicalFrameRenderer: Metal library failed (\(error))")
            return nil
        }
        let identity: [Float] = [1, 0]
        guard let identityTone = identity.withUnsafeBytes({ bytes in
            device.makeBuffer(
                bytes: bytes.baseAddress!, length: bytes.count,
                options: .storageModeShared)
        })
        else { return nil }
        self.device = device
        self.measurements = measurements
        self.lowRenderer = lowRenderer
        self.composed = composed
        self.decode = decode
        self.identityTone = identityTone
        self.maximumInFlightFrames = maximumInFlightFrames
    }

    public func prepareChecked(
        key: String, stock: FilmStock, options: FotufilmEngine.Options,
        frameWidth: Int, frameHeight: Int, sceneCeiling: Float
    ) throws {
        guard frameWidth > 0, frameHeight > 0,
              frameWidth.isMultiple(of: Self.spatialReduction),
              frameHeight.isMultiple(of: Self.spatialReduction),
              frameWidth <= Int(UInt32.max), frameHeight <= Int(UInt32.max)
        else { throw PreparationError.invalidDimensions }
        guard options.grainScale == 0 else {
            throw PreparationError.grainRequiresThirtyFPSPath
        }
        let lowWidth = frameWidth / Self.spatialReduction
        let lowHeight = frameHeight / Self.spatialReduction
        var hdrOptions = options
        hdrOptions.paper = .screen
        let lowInvocation = FilmEngineInvocation(
            stock: stock, options: hdrOptions,
            width: lowWidth, height: lowHeight)
        let fullInvocation = FilmEngineInvocation(
            stock: stock, options: hdrOptions,
            width: frameWidth, height: frameHeight)
        let pipelines = try pipelines(localTone: fullInvocation.localToneActive)

        lock.lock()
        revision &+= 1
        let currentRevision = revision
        lock.unlock()
        let lowKey = "\(key)#hierarchical-low-\(currentRevision)"
        let cubeKey = "\(key)#hierarchical-cube-\(currentRevision)"
        do {
            try lowRenderer.prepareChecked(
                key: lowKey, stock: stock, options: hdrOptions,
                frameWidth: lowWidth, frameHeight: lowHeight)
        } catch {
            throw PreparationError.fullFramePreparation(String(describing: error))
        }

        var cubeOptions = hdrOptions
        cubeOptions.sceneHeadroom = 1
        cubeOptions.whiteBalance = .neutral
        cubeOptions.highlights = 0
        cubeOptions.shadows = 0
        cubeOptions.localTone = false
        cubeOptions.saturation = 1
        cubeOptions.vibrance = 0
        cubeOptions.flareScale = 0
        do {
            try composed.prepareChecked(
                key: cubeKey, stock: stock, options: cubeOptions,
                frameWidth: frameWidth, frameHeight: frameHeight,
                sceneCeiling: sceneCeiling)
        } catch {
            throw PreparationError.cubePreparation(String(describing: error))
        }
        guard let binding = composed.binding(forKey: cubeKey) else {
            throw PreparationError.componentUnavailable("composed-cube binding")
        }

        let balance = FilmEngineInvocation.whiteBalanceOffset
        let adjust = FilmEngineInvocation.sceneAdjustOffset
        var sceneParameters = SceneParameters(
            whiteBalance: SIMD4(
                fullInvocation.configuration[balance],
                fullInvocation.configuration[balance + 1],
                fullInvocation.configuration[balance + 2], 0),
            adjustment: SIMD4(
                fullInvocation.configuration[adjust],
                fullInvocation.configuration[adjust + 1],
                fullInvocation.configuration[adjust + 2],
                fullInvocation.configuration[adjust + 3]),
            exposureAndCube: SIMD4(
                fullInvocation.configuration[FilmEngineInvocation.exposureGainOffset] / 0.18,
                binding.inputKnee, binding.shaperScale, 0))
        guard let scene = device.makeBuffer(
            bytes: &sceneParameters, length: MemoryLayout<SceneParameters>.stride,
            options: .storageModeShared)
        else { throw PreparationError.allocationFailed("scene controls") }

        let value = Prepared(
            revision: currentRevision, lowKey: lowKey, cubeKey: cubeKey,
            width: frameWidth, height: frameHeight,
            lowWidth: lowWidth, lowHeight: lowHeight,
            invocation: lowInvocation, scene: scene, pipelines: pipelines,
            toneActive: lowInvocation.localToneActive)
        try primeFrames(for: value)
        lock.lock()
        prepared[key] = value
        lock.unlock()
    }

    @discardableResult
    public func prepare(
        key: String, stock: FilmStock, options: FotufilmEngine.Options,
        frameWidth: Int, frameHeight: Int, sceneCeiling: Float
    ) -> Bool {
        do {
            try prepareChecked(
                key: key, stock: stock, options: options,
                frameWidth: frameWidth, frameHeight: frameHeight,
                sceneCeiling: sceneCeiling)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func encodeCapturedSDR(
        luma: MTLTexture, chroma: MTLTexture, output: MTLTexture,
        width: Int, height: Int, key: String,
        range: SDRCaptureRange, gamut: SDRCaptureGamut,
        chromaOffset: SIMD2<Float> = .zero, inputGain: Float = 1,
        frameIndex: UInt64 = 0, commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard let state = state(
            key: key, width: width, height: height,
            luma: luma, chroma: chroma, output: output,
            lumaFormat: .r8Unorm, chromaFormat: .rg8Unorm,
            commandBuffer: commandBuffer),
              let frame = acquireFrame(for: state),
              let binding = composed.binding(forKey: state.cubeKey)
        else { return false }
        func fail() -> Bool { release(frame); return false }

        let tone = frame.sdrMeasurements.toneGrid
        if state.toneActive {
            guard tone != nil,
                  measurements.encodeToneBase(
                    luma: luma, chroma: chroma,
                    range: measurementRange(range), gamut: measurementGamut(gamut),
                    chromaOffset: chromaOffset, inputGain: inputGain,
                    resources: frame.sdrMeasurements,
                    commandBuffer: commandBuffer)
            else { return fail() }
        }
        guard lowRenderer.encodeCapturedSDR(
            luma: luma, chroma: chroma, output: frame.lowFull,
            width: state.lowWidth, height: state.lowHeight, key: state.lowKey,
            range: range, gamut: gamut, chromaOffset: chromaOffset,
            inputGain: inputGain, externalToneGrid: tone,
            frameIndex: frameIndex, commandBuffer: commandBuffer),
              encodeBase(
                hdr: false, luma: luma, chroma: chroma,
                destination: frame.lowBase, state: state, binding: binding,
                tone: tone, source0: range.rawValue, source1: gamut.rawValue,
                transform: SIMD4(inputGain, chromaOffset.x, chromaOffset.y, 1),
                commandBuffer: commandBuffer),
              encodeFinish(
                hdr: false, luma: luma, chroma: chroma,
                output: output, frame: frame, state: state, binding: binding,
                tone: tone, source0: range.rawValue, source1: gamut.rawValue,
                transform: SIMD4(inputGain, chromaOffset.x, chromaOffset.y, 1),
                commandBuffer: commandBuffer)
        else { return fail() }
        finish(frame: frame, state: state, binding: binding,
               commandBuffer: commandBuffer)
        return true
    }

    @discardableResult
    public func encodeCapturedHDR(
        luma: MTLTexture, chroma: MTLTexture, output: MTLTexture,
        width: Int, height: Int, key: String,
        transfer: HDRCaptureTransfer, sceneScale: Float,
        chromaOffset: SIMD2<Float> = .zero, inputGain: Float = 1,
        frameIndex: UInt64 = 0, commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard sceneScale.isFinite, sceneScale >= 0,
              let state = state(
                key: key, width: width, height: height,
                luma: luma, chroma: chroma, output: output,
                lumaFormat: .r16Unorm, chromaFormat: .rg16Unorm,
                commandBuffer: commandBuffer),
              let frame = acquireFrame(for: state),
              let binding = composed.binding(forKey: state.cubeKey)
        else { return false }
        func fail() -> Bool { release(frame); return false }

        let tone = frame.hdrMeasurements.toneGrid
        if state.toneActive {
            guard tone != nil,
                  measurements.encodeToneBase(
                    luma: luma, chroma: chroma,
                    transfer: measurementTransfer(transfer),
                    sceneScale: sceneScale, chromaOffset: chromaOffset,
                    inputGain: inputGain, resources: frame.hdrMeasurements,
                    commandBuffer: commandBuffer)
            else { return fail() }
        }
        let transform = SIMD4(
            inputGain, chromaOffset.x, chromaOffset.y, sceneScale)
        guard lowRenderer.encodeCapturedHDR(
            luma: luma, chroma: chroma, output: frame.lowFull,
            width: state.lowWidth, height: state.lowHeight, key: state.lowKey,
            transfer: transfer, sceneScale: sceneScale,
            chromaOffset: chromaOffset, inputGain: inputGain,
            externalToneGrid: tone, frameIndex: frameIndex,
            commandBuffer: commandBuffer),
              encodeBase(
                hdr: true, luma: luma, chroma: chroma,
                destination: frame.lowBase, state: state, binding: binding,
                tone: tone, source0: transfer.rawValue, source1: 0,
                transform: transform, commandBuffer: commandBuffer),
              encodeFinish(
                hdr: true, luma: luma, chroma: chroma,
                output: output, frame: frame, state: state, binding: binding,
                tone: tone, source0: transfer.rawValue, source1: 0,
                transform: transform, commandBuffer: commandBuffer)
        else { return fail() }
        finish(frame: frame, state: state, binding: binding,
               commandBuffer: commandBuffer)
        return true
    }

    public func removeAll() {
        lowRenderer.removeAll()
        composed.removeAll()
        lock.lock()
        prepared.removeAll(keepingCapacity: false)
        frames.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func encodeBase(
        hdr: Bool, luma: MTLTexture, chroma: MTLTexture,
        destination: MTLTexture, state: Prepared,
        binding: HandwrittenMetalComposedPointwise.Binding,
        tone: HandwrittenMetalGlobalMeasurements.ToneGrid?,
        source0: UInt32, source1: UInt32, transform: SIMD4<Float>,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        var parameters = cameraParameters(
            width: state.lowWidth, height: state.lowHeight,
            tone: tone, source0: source0, source1: source1,
            transform: transform)
        encoder.label = "Fotufilm hierarchical reduced pointwise base"
        encoder.setComputePipelineState(
            hdr ? state.pipelines.hdrBase : state.pipelines.sdrBase)
        bindCommon(
            encoder: encoder, luma: luma, chroma: chroma,
            binding: binding, state: state, tone: tone,
            parameters: &parameters)
        if !hdr { encoder.setTexture(decode, index: 3) }
        encoder.setTexture(destination, index: 4)
        dispatch(encoder, width: state.lowWidth, height: state.lowHeight)
        encoder.endEncoding()
        return true
    }

    private func encodeFinish(
        hdr: Bool, luma: MTLTexture, chroma: MTLTexture,
        output: MTLTexture, frame: Frame, state: Prepared,
        binding: HandwrittenMetalComposedPointwise.Binding,
        tone: HandwrittenMetalGlobalMeasurements.ToneGrid?,
        source0: UInt32, source1: UInt32, transform: SIMD4<Float>,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        var parameters = cameraParameters(
            width: state.width, height: state.height,
            tone: tone, source0: source0, source1: source1,
            transform: transform)
        encoder.label = "Fotufilm hierarchical native-detail residual finish"
        encoder.setComputePipelineState(
            hdr ? state.pipelines.hdrFinish : state.pipelines.sdrFinish)
        bindCommon(
            encoder: encoder, luma: luma, chroma: chroma,
            binding: binding, state: state, tone: tone,
            parameters: &parameters)
        if !hdr { encoder.setTexture(decode, index: 3) }
        encoder.setTexture(frame.lowFull, index: 4)
        encoder.setTexture(frame.lowBase, index: 5)
        encoder.setTexture(output, index: 6)
        dispatch(encoder, width: state.width, height: state.height)
        encoder.endEncoding()
        return true
    }

    private func bindCommon(
        encoder: MTLComputeCommandEncoder,
        luma: MTLTexture, chroma: MTLTexture,
        binding: HandwrittenMetalComposedPointwise.Binding,
        state: Prepared, tone: HandwrittenMetalGlobalMeasurements.ToneGrid?,
        parameters: inout CameraParameters
    ) {
        encoder.setBuffer(state.scene, offset: 0, index: 0)
        encoder.setBytes(
            &parameters, length: MemoryLayout<CameraParameters>.stride, index: 1)
        if let tone {
            tone.bind(to: encoder, aIndex: 2, bIndex: 3)
        } else {
            encoder.setBuffer(identityTone, offset: 0, index: 2)
            encoder.setBuffer(
                identityTone, offset: MemoryLayout<Float>.stride, index: 3)
        }
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(binding.cube, index: 2)
    }

    private func cameraParameters(
        width: Int, height: Int,
        tone: HandwrittenMetalGlobalMeasurements.ToneGrid?,
        source0: UInt32, source1: UInt32, transform: SIMD4<Float>
    ) -> CameraParameters {
        CameraParameters(
            outputAndTone: SIMD4(
                UInt32(width), UInt32(height),
                UInt32(tone?.width ?? 1), UInt32(tone?.height ?? 1)),
            source: SIMD4(source0, source1, 0, 0), transform: transform)
    }

    private func state(
        key: String, width: Int, height: Int,
        luma: MTLTexture, chroma: MTLTexture, output: MTLTexture,
        lumaFormat: MTLPixelFormat, chromaFormat: MTLPixelFormat,
        commandBuffer: MTLCommandBuffer
    ) -> Prepared? {
        guard width > 0, height > 0,
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              validPlane(luma, format: lumaFormat),
              validPlane(chroma, format: chromaFormat),
              chroma.width == (luma.width + 1) / 2,
              chroma.height == (luma.height + 1) / 2,
              luma.width == width, luma.height == height,
              validOutput(output, width: width, height: height)
        else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let state = prepared[key],
              state.width == width, state.height == height else { return nil }
        return state
    }

    private func pipelines(localTone: Bool) throws -> PipelineSet {
        lock.lock()
        if let cached = pipelineCache[localTone] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let constants = MTLFunctionConstantValues()
        var localTone = localTone
        constants.setConstantValue(&localTone, type: .bool, index: 0)
        func make(_ name: String) throws -> MTLComputePipelineState {
            let function = try library.makeFunction(name: name, constantValues: constants)
            return try device.makeComputePipelineState(function: function)
        }
        do {
            let value = PipelineSet(
                sdrBase: try make("fotufilm_hierarchical_sdr_base"),
                hdrBase: try make("fotufilm_hierarchical_hdr_base"),
                sdrFinish: try make("fotufilm_hierarchical_sdr_finish"),
                hdrFinish: try make("fotufilm_hierarchical_hdr_finish"))
            lock.lock()
            pipelineCache[localTone] = value
            lock.unlock()
            return value
        } catch {
            throw PreparationError.componentUnavailable(
                "hierarchical Metal pipeline: \(error)")
        }
    }

    private func primeFrames(for state: Prepared) throws {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll { !$0.leased }
        do {
            while frames.count < maximumInFlightFrames {
                frames.append(try makeFrame(for: state))
            }
        } catch {
            frames.removeAll { $0.key == state.frameKey && !$0.leased }
            throw error
        }
    }

    private func makeFrame(for state: Prepared) throws -> Frame {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: state.lowWidth, height: state.lowHeight, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let lowFull = device.makeTexture(descriptor: descriptor),
              let lowBase = device.makeTexture(descriptor: descriptor)
        else { throw PreparationError.allocationFailed("reduced RGBA16F frame") }
        let sdr: HandwrittenMetalGlobalMeasurements.Resources
        let hdr: HandwrittenMetalGlobalMeasurements.Resources
        do {
            sdr = try measurements.makeResources(
                invocation: state.invocation, mode: .encodedDisplayP3RGBA8,
                frameWidth: state.lowWidth, frameHeight: state.lowHeight)
            hdr = try measurements.makeResources(
                invocation: state.invocation, mode: .linearRec2020RGBA16Float,
                frameWidth: state.lowWidth, frameHeight: state.lowHeight)
        } catch {
            throw PreparationError.measurementPreparation(String(describing: error))
        }
        return Frame(
            key: state.frameKey, lowFull: lowFull, lowBase: lowBase,
            sdrMeasurements: sdr, hdrMeasurements: hdr)
    }

    private func acquireFrame(for state: Prepared) -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        if let frame = frames.first(where: {
            $0.key == state.frameKey && !$0.leased
        }) {
            frame.leased = true
            return frame
        }
        if let idle = frames.firstIndex(where: { !$0.leased }) {
            frames.remove(at: idle)
        }
        guard frames.count < maximumInFlightFrames,
              let frame = try? makeFrame(for: state) else { return nil }
        frame.leased = true
        frames.append(frame)
        return frame
    }

    private func release(_ frame: Frame) {
        lock.lock()
        frame.leased = false
        lock.unlock()
    }

    private func finish(
        frame: Frame, state: Prepared,
        binding: HandwrittenMetalComposedPointwise.Binding,
        commandBuffer: MTLCommandBuffer
    ) {
        commandBuffer.addCompletedHandler { [weak self, frame, state, binding] _ in
            self?.release(frame)
            withExtendedLifetime((state, binding)) {}
        }
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder, width: Int, height: Int
    ) {
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 32, height: 2, depth: 1))
    }

    private func validPlane(_ texture: MTLTexture, format: MTLPixelFormat) -> Bool {
        texture.device.registryID == device.registryID
            && texture.textureType == .type2D
            && texture.pixelFormat == format
            && texture.depth == 1 && texture.arrayLength == 1
            && texture.mipmapLevelCount == 1 && texture.sampleCount == 1
            && texture.usage.contains(.shaderRead)
    }

    private func validOutput(_ texture: MTLTexture, width: Int, height: Int) -> Bool {
        texture.device.registryID == device.registryID
            && texture.textureType == .type2D
            && texture.pixelFormat == Self.outputPixelFormat
            && texture.width == width && texture.height == height
            && texture.depth == 1 && texture.arrayLength == 1
            && texture.mipmapLevelCount == 1 && texture.sampleCount == 1
            && texture.usage.contains(.shaderWrite)
    }

    private static func makeDecodeTexture(device: MTLDevice) -> MTLTexture? {
        var values = [Float16](repeating: 0, count: 256)
        for index in values.indices {
            values[index] = Float16(ColorScience.srgbToLinear(Float(index) / 255))
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.pixelFormat = .r16Float
        descriptor.width = values.count
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake1D(0, values.count), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: bytes.count)
        }
        return texture
    }

    private func measurementTransfer(
        _ value: HDRCaptureTransfer
    ) -> HandwrittenMetalGlobalMeasurements.HDRCaptureTransfer {
        switch value {
        case .hlg: return .hlg
        case .appleLog: return .appleLog
        }
    }

    private func measurementRange(
        _ value: SDRCaptureRange
    ) -> HandwrittenMetalGlobalMeasurements.SDRCaptureRange {
        switch value {
        case .video: return .video
        case .full: return .full
        }
    }

    private func measurementGamut(
        _ value: SDRCaptureGamut
    ) -> HandwrittenMetalGlobalMeasurements.SDRCaptureGamut {
        switch value {
        case .displayP3: return .displayP3
        case .sRGB: return .sRGB
        }
    }
}
#endif
