#if canImport(Metal)
import Foundation
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Texture-resident HDR camera renderer composed from the hand-written Metal stages.
///
/// Encoding records native 8-bit or 10-bit bi-planar camera decode, or a scene-linear Float32
/// still, followed by GPU measurements, spectral recovery, spatial development, and Digital
/// Reference HDR delivery into one caller-owned command buffer. No stage commits, waits, or maps a
/// GPU result on the CPU.
/// Writable per-frame state is leased from a bounded private ring so tone, flare, record-exposure,
/// and developed-density storage cannot alias across in-flight frames.
public final class HandwrittenMetalFullFrameRenderer {
    public typealias HDRCaptureTransfer = HandwrittenMetalSpectralHead.HDRCaptureTransfer
    public typealias SDRCaptureRange = HandwrittenMetalSpectralHead.SDRCaptureRange
    public typealias SDRCaptureGamut = HandwrittenMetalSpectralHead.SDRCaptureGamut

    public enum PreparationError: Swift.Error, CustomStringConvertible {
        case invalidDimensions
        case unsupportedPipelineStage
        case measurementPreparation(String)
        case spectralHeadPreparation(String)
        case spatialPreparation(String)
        case compositeTailPreparation(String)
        case allocationFailed(String)

        public var description: String {
            switch self {
            case .invalidDimensions:
                return "frame dimensions must be positive and fit the Metal parameter layout"
            case .unsupportedPipelineStage:
                return "the HDR full-frame renderer requires the full pipeline stage"
            case let .measurementPreparation(message):
                return "global-measurement preparation failed: \(message)"
            case let .spectralHeadPreparation(message):
                return "spectral-head preparation failed: \(message)"
            case let .spatialPreparation(message):
                return "spatial preparation failed: \(message)"
            case let .compositeTailPreparation(message):
                return "composite-tail preparation failed: \(message)"
            case let .allocationFailed(resource):
                return "unable to allocate \(resource)"
            }
        }
    }

    public static let outputPixelFormat: MTLPixelFormat = .rgba16Float

    private struct Prepared {
        let internalKey: String
        let sdrHeadKey: String
        let x420HeadKey: String
        let floatHeadKey: String
        let revision: UInt64
        let width: Int
        let height: Int
        let floatInputByteCount: Int
        let invocation: FilmEngineInvocation
        let toneActive: Bool
        let flareActive: Bool

        var intermediateKey: IntermediateKey {
            IntermediateKey(revision: revision, width: width, height: height)
        }
    }

    private struct IntermediateKey: Equatable {
        let revision: UInt64
        let width: Int
        let height: Int
    }

    private final class IntermediateFrame {
        let key: IntermediateKey
        let recordExposure: MTLTexture
        let developedDensity: MTLTexture
        let sdrToneResources: HandwrittenMetalGlobalMeasurements.Resources?
        let x420ToneResources: HandwrittenMetalGlobalMeasurements.Resources?
        let floatToneResources: HandwrittenMetalGlobalMeasurements.Resources?
        let flareResources: HandwrittenMetalGlobalMeasurements.Resources?
        var leased = false

        init(
            key: IntermediateKey,
            recordExposure: MTLTexture,
            developedDensity: MTLTexture,
            sdrToneResources: HandwrittenMetalGlobalMeasurements.Resources?,
            x420ToneResources: HandwrittenMetalGlobalMeasurements.Resources?,
            floatToneResources: HandwrittenMetalGlobalMeasurements.Resources?,
            flareResources: HandwrittenMetalGlobalMeasurements.Resources?
        ) {
            self.key = key
            self.recordExposure = recordExposure
            self.developedDensity = developedDensity
            self.sdrToneResources = sdrToneResources
            self.x420ToneResources = x420ToneResources
            self.floatToneResources = floatToneResources
            self.flareResources = flareResources
        }
    }

    private let device: MTLDevice
    private let measurements: HandwrittenMetalGlobalMeasurements
    private let spectralHead: HandwrittenMetalSpectralHead
    private let spatial: HandwrittenMetalSpatialExecutor
    private let compositeTail: HandwrittenMetalCompositeTail
    private let maximumInFlightFrames: Int

    private let lock = NSLock()
    private var prepared: [String: Prepared] = [:]
    private var intermediates: [IntermediateFrame] = []
    private var preparationRevision: UInt64 = 0

    public convenience init?(
        maximumInFlightFrames: Int = 2,
        spatialOptimizationVariant: HandwrittenMetalSpatialExecutor.OptimizationVariant =
            .exactSpecialized
    ) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.init(
            device: device, maximumInFlightFrames: maximumInFlightFrames,
            spatialOptimizationVariant: spatialOptimizationVariant)
    }

    public init?(
        device: MTLDevice, maximumInFlightFrames: Int = 2,
        spatialOptimizationVariant: HandwrittenMetalSpatialExecutor.OptimizationVariant =
            .exactSpecialized
    ) {
        guard maximumInFlightFrames > 0,
              let measurements = HandwrittenMetalGlobalMeasurements(device: device),
              let spectralHead = HandwrittenMetalSpectralHead(device: device),
              let spatial = HandwrittenMetalSpatialExecutor(
                device: device, maximumInFlightFrames: maximumInFlightFrames,
                optimizationVariant: spatialOptimizationVariant),
              let compositeTail = HandwrittenMetalCompositeTail(
                device: device, lookupLayout: .baseline3D)
        else { return nil }
        self.device = device
        self.measurements = measurements
        self.spectralHead = spectralHead
        self.spatial = spatial
        self.compositeTail = compositeTail
        self.maximumInFlightFrames = maximumInFlightFrames
    }

    /// Prepares an HDR-master edit. The requested output medium is intentionally replaced with
    /// `PrintPaper.screen`; physical paper, scan, telecine, and negative outputs are not part of
    /// the production camera graph.
    public func prepareChecked(
        key: String, stock: FilmStock, options: FotufilmEngine.Options,
        frameWidth: Int, frameHeight: Int
    ) throws {
        guard frameWidth > 0, frameHeight > 0,
              frameWidth <= Int(UInt32.max), frameHeight <= Int(UInt32.max),
              let floatInputByteCount = Self.rgba32FloatByteCount(
                width: frameWidth, height: frameHeight)
        else { throw PreparationError.invalidDimensions }
        guard options.stage == .full else {
            throw PreparationError.unsupportedPipelineStage
        }

        var hdrOptions = options
        hdrOptions.paper = .screen
        let invocation = FilmEngineInvocation(
            stock: stock, options: hdrOptions,
            width: frameWidth, height: frameHeight)
        let toneActive = invocation.localToneActive
        let flareActive = invocation.featureMask & FilmEngineFeature.flare != 0

        lock.lock()
        preparationRevision &+= 1
        let revision = preparationRevision
        lock.unlock()
        // Component dictionaries overwrite a stable key on re-preparation. The revision belongs
        // only to writable intermediate leases; putting it in component keys retained every
        // superseded set of frame-sized immutable state for the renderer's lifetime.
        let internalKey = "\(key)#handwritten-hdr-master"
        let sdrHeadKey = "\(internalKey)#nv12"
        let x420HeadKey = "\(internalKey)#x420"
        let floatHeadKey = "\(internalKey)#rgba32-float"

        do {
            try spectralHead.prepareChecked(
                key: sdrHeadKey, invocation: invocation,
                mode: .encodedDisplayP3RGBA8,
                frameWidth: frameWidth, frameHeight: frameHeight,
                toneGrid: toneActive ? .gpu : nil)
            try spectralHead.prepareChecked(
                key: x420HeadKey, invocation: invocation,
                mode: .linearRec2020RGBA16Float,
                frameWidth: frameWidth, frameHeight: frameHeight,
                toneGrid: toneActive ? .gpu : nil)
            try spectralHead.prepareChecked(
                key: floatHeadKey, invocation: invocation,
                mode: .linearRec2020RGBA32Float,
                frameWidth: frameWidth, frameHeight: frameHeight,
                toneGrid: toneActive ? .gpu : nil)
        } catch {
            throw PreparationError.spectralHeadPreparation(String(describing: error))
        }
        do {
            try spatial.prepareChecked(
                key: internalKey, stock: stock, options: hdrOptions,
                frameWidth: frameWidth, frameHeight: frameHeight)
        } catch {
            throw PreparationError.spatialPreparation(String(describing: error))
        }
        do {
            try compositeTail.prepareChecked(
                key: internalKey, invocation: invocation,
                mode: .linearRec2020RGBA16Float,
                frameWidth: frameWidth, frameHeight: frameHeight)
        } catch {
            throw PreparationError.compositeTailPreparation(String(describing: error))
        }

        let value = Prepared(
            internalKey: internalKey,
            sdrHeadKey: sdrHeadKey, x420HeadKey: x420HeadKey,
            floatHeadKey: floatHeadKey,
            revision: revision,
            width: frameWidth, height: frameHeight,
            floatInputByteCount: floatInputByteCount,
            invocation: invocation, toneActive: toneActive,
            flareActive: flareActive)
        do {
            try primeIntermediateRing(for: value)
        } catch let error as PreparationError {
            throw error
        } catch {
            throw PreparationError.measurementPreparation(String(describing: error))
        }

        lock.lock()
        prepared[key] = value
        lock.unlock()
    }

    /// Compatibility convenience for callers that select another renderer on preparation error.
    @discardableResult
    public func prepare(
        key: String, stock: FilmStock, options: FotufilmEngine.Options,
        frameWidth: Int, frameHeight: Int
    ) -> Bool {
        do {
            try prepareChecked(
                key: key, stock: stock, options: options,
                frameWidth: frameWidth, frameHeight: frameHeight)
            return true
        } catch {
            return false
        }
    }

    /// Records a native 420f/420v fallback frame into the same RGBA16F Digital Reference HDR
    /// master used by 10-bit capture. The planes stay bi-planar until the measurement and spectral
    /// kernels decode them directly to scene-linear Rec.2020; no BGRA or preview-only graph exists.
    @discardableResult
    public func encodeCapturedSDR(
        luma: MTLTexture, chroma: MTLTexture,
        output: MTLTexture, width: Int, height: Int, key: String,
        range: SDRCaptureRange, gamut: SDRCaptureGamut,
        chromaOffset: SIMD2<Float> = .zero, inputGain: Float = 1,
        externalToneGrid: HandwrittenMetalGlobalMeasurements.ToneGrid? = nil,
        frameIndex: UInt64 = 0, commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard width > 0, height > 0,
              chromaOffset.x.isFinite, chromaOffset.y.isFinite,
              inputGain.isFinite, inputGain >= 0,
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              validCaptureInputs(
                luma: luma, chroma: chroma,
                lumaFormat: .r8Unorm, chromaFormat: .rg8Unorm,
                outputWidth: width, outputHeight: height),
              validOutput(output, width: width, height: height)
        else { return false }

        lock.lock()
        let state = prepared[key]
        lock.unlock()
        guard let state, state.width == width, state.height == height,
              let frame = acquireIntermediate(for: state)
        else { return false }

        func fail() -> Bool {
            releaseIntermediate(frame)
            return false
        }

        let gpuToneGrid: HandwrittenMetalGlobalMeasurements.ToneGrid?
        if state.toneActive {
            if let externalToneGrid {
                gpuToneGrid = externalToneGrid
            } else {
                guard let resources = frame.sdrToneResources,
                      let grid = resources.toneGrid,
                      measurements.encodeToneBase(
                        luma: luma, chroma: chroma,
                        range: Self.measurementRange(range),
                        gamut: Self.measurementGamut(gamut),
                        chromaOffset: chromaOffset, inputGain: inputGain,
                        resources: resources, commandBuffer: commandBuffer)
                else { return fail() }
                gpuToneGrid = grid
            }
        } else {
            guard externalToneGrid == nil else { return fail() }
            gpuToneGrid = nil
        }

        guard spectralHead.encodeCapturedSDR(
            luma: luma, chroma: chroma,
            recordExposure: frame.recordExposure, key: state.sdrHeadKey,
            range: range, gamut: gamut, chromaOffset: chromaOffset,
            inputGain: inputGain, gpuToneGrid: gpuToneGrid,
            commandBuffer: commandBuffer)
        else { return fail() }

        return finishEncoding(
            frame: frame, state: state, output: output,
            frameIndex: frameIndex, commandBuffer: commandBuffer)
    }

    /// Records a complete x420 camera frame into the caller's RGBA16F HDR-master texture.
    ///
    /// `luma` and `chroma` are `r16Unorm`/`rg16Unorm` views of a video-range 10-bit bi-planar
    /// buffer. A successful call only records commands: it never commits, waits, or reads a GPU
    /// result. A false result means the caller must discard this command buffer because an earlier
    /// stage may already have encoded work. `frameIndex` is forwarded unchanged to every seeded
    /// stage, making repeated renders deterministic.
    @discardableResult
    public func encodeCapturedHDR(
        luma: MTLTexture, chroma: MTLTexture,
        output: MTLTexture, width: Int, height: Int, key: String,
        transfer: HDRCaptureTransfer, sceneScale: Float,
        chromaOffset: SIMD2<Float> = .zero, inputGain: Float = 1,
        externalToneGrid: HandwrittenMetalGlobalMeasurements.ToneGrid? = nil,
        frameIndex: UInt64 = 0, commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard width > 0, height > 0,
              sceneScale.isFinite, sceneScale >= 0,
              chromaOffset.x.isFinite, chromaOffset.y.isFinite,
              inputGain.isFinite, inputGain >= 0,
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              validCaptureInputs(
                luma: luma, chroma: chroma,
                lumaFormat: .r16Unorm, chromaFormat: .rg16Unorm,
                outputWidth: width, outputHeight: height),
              validOutput(output, width: width, height: height)
        else { return false }

        lock.lock()
        let state = prepared[key]
        lock.unlock()
        guard let state, state.width == width, state.height == height,
              let frame = acquireIntermediate(for: state)
        else { return false }

        func fail() -> Bool {
            releaseIntermediate(frame)
            return false
        }

        let gpuToneGrid: HandwrittenMetalGlobalMeasurements.ToneGrid?
        if state.toneActive {
            if let externalToneGrid {
                gpuToneGrid = externalToneGrid
            } else {
                guard let resources = frame.x420ToneResources,
                      let grid = resources.toneGrid,
                      measurements.encodeToneBase(
                        luma: luma, chroma: chroma,
                        transfer: Self.measurementTransfer(transfer),
                        sceneScale: sceneScale, chromaOffset: chromaOffset,
                        inputGain: inputGain, resources: resources,
                        commandBuffer: commandBuffer)
                else { return fail() }
                gpuToneGrid = grid
            }
        } else {
            guard externalToneGrid == nil else { return fail() }
            gpuToneGrid = nil
        }

        guard spectralHead.encodeCapturedHDR(
            luma: luma, chroma: chroma,
            recordExposure: frame.recordExposure, key: state.x420HeadKey,
            transfer: transfer, sceneScale: sceneScale,
            chromaOffset: chromaOffset, inputGain: inputGain,
            gpuToneGrid: gpuToneGrid, commandBuffer: commandBuffer)
        else { return fail() }

        return finishEncoding(
            frame: frame, state: state, output: output,
            frameIndex: frameIndex, commandBuffer: commandBuffer)
    }

    /// Records a maximum-precision still-image source into the same RGBA16F HDR master as x420.
    ///
    /// `sceneLinearRec2020RGBAFloat` is tightly packed interleaved RGBA Float32 (16 bytes per
    /// pixel). Tone metering and spectral exposure read the RGB Float32 values directly;
    /// the first half-precision seam is the private record-exposure texture after spectral recovery.
    /// This method only records into `commandBuffer` and never commits, waits, or reads back.
    @discardableResult
    public func encodeSceneLinearRec2020RGBAFloat(
        sceneLinearRec2020RGBAFloat input: MTLBuffer,
        output: MTLTexture, width: Int, height: Int, key: String,
        inputGain: Float = 1, frameIndex: UInt64 = 0,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard width > 0, height > 0,
              inputGain.isFinite, inputGain >= 0,
              input.device.registryID == device.registryID,
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              validOutput(output, width: width, height: height)
        else { return false }

        lock.lock()
        let state = prepared[key]
        lock.unlock()
        guard let state, state.width == width, state.height == height,
              input.length >= state.floatInputByteCount,
              let frame = acquireIntermediate(for: state)
        else { return false }

        func fail() -> Bool {
            releaseIntermediate(frame)
            return false
        }

        let gpuToneGrid: HandwrittenMetalGlobalMeasurements.ToneGrid?
        if state.toneActive {
            guard let resources = frame.floatToneResources,
                  let grid = resources.toneGrid,
                  measurements.encodeToneBase(
                    input: input, inputGain: inputGain, resources: resources,
                    commandBuffer: commandBuffer)
            else { return fail() }
            gpuToneGrid = grid
        } else {
            gpuToneGrid = nil
        }
        guard spectralHead.encode(
            input: input, recordExposure: frame.recordExposure,
            key: state.floatHeadKey, inputGain: inputGain,
            gpuToneGrid: gpuToneGrid, commandBuffer: commandBuffer)
        else { return fail() }

        return finishEncoding(
            frame: frame, state: state, output: output,
            frameIndex: frameIndex, commandBuffer: commandBuffer)
    }

    private func finishEncoding(
        frame: IntermediateFrame, state: Prepared,
        output: MTLTexture, frameIndex: UInt64,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        let fusedTail = compositeTail.linearHDRBinding(forKey: state.internalKey)
        var encodedFusedTail = false
        let spatialEncoded: Bool
        if state.flareActive {
            guard let resources = frame.flareResources,
                  let flareMean = resources.flareMean,
                  measurements.encodeFlareMean(
                    recordExposure: frame.recordExposure,
                    resources: resources, commandBuffer: commandBuffer)
            else {
                releaseIntermediate(frame)
                return false
            }
            if let fusedTail,
               spatial.encodeLinearHDR(
                    recordExposure: frame.recordExposure,
                    workingTexture: frame.developedDensity,
                    output: output, tail: fusedTail,
                    key: state.internalKey, frameIndex: frameIndex,
                    flareMean: flareMean, commandBuffer: commandBuffer) {
                encodedFusedTail = true
                spatialEncoded = true
            } else {
                spatialEncoded = spatial.encodeDevelopedDensity(
                    recordExposure: frame.recordExposure,
                    densityOutput: frame.developedDensity,
                    key: state.internalKey, frameIndex: frameIndex,
                    flareMean: flareMean, commandBuffer: commandBuffer)
            }
        } else {
            if let fusedTail,
               spatial.encodeLinearHDR(
                    recordExposure: frame.recordExposure,
                    workingTexture: frame.developedDensity,
                    output: output, tail: fusedTail,
                    key: state.internalKey, frameIndex: frameIndex,
                    commandBuffer: commandBuffer) {
                encodedFusedTail = true
                spatialEncoded = true
            } else {
                spatialEncoded = spatial.encodeDevelopedDensity(
                    recordExposure: frame.recordExposure,
                    densityOutput: frame.developedDensity,
                    key: state.internalKey, frameIndex: frameIndex,
                    commandBuffer: commandBuffer)
            }
        }
        guard spatialEncoded else {
            releaseIntermediate(frame)
            return false
        }
        if !encodedFusedTail,
           !compositeTail.encodeTail(
                developedDensity: frame.developedDensity, output: output,
                key: state.internalKey, frameIndex: frameIndex,
                commandBuffer: commandBuffer) {
            releaseIntermediate(frame)
            return false
        }

        commandBuffer.addCompletedHandler { [weak self, frame, state] _ in
            self?.releaseIntermediate(frame)
            withExtendedLifetime(state) {}
        }
        return true
    }

    /// Drops prepared edits and idle pooled resources. Already-encoded command buffers retain all
    /// resources they use and complete safely after this call.
    public func removeAll() {
        spectralHead.removeAll()
        spatial.removeAll()
        compositeTail.removeAll()
        lock.lock()
        prepared.removeAll(keepingCapacity: false)
        intermediates.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// Preallocates every currently available ring slot during edit preparation. If an old edit
    /// still occupies slots, its completion makes those slots replaceable without ever aliasing
    /// their resources.
    private func primeIntermediateRing(for state: Prepared) throws {
        lock.lock()
        defer { lock.unlock() }
        intermediates.removeAll { !$0.leased }
        do {
            while intermediates.count < maximumInFlightFrames {
                intermediates.append(try makeIntermediate(for: state))
            }
        } catch {
            intermediates.removeAll { $0.key == state.intermediateKey && !$0.leased }
            if let preparation = error as? PreparationError { throw preparation }
            throw PreparationError.measurementPreparation(String(describing: error))
        }
    }

    private func acquireIntermediate(for state: Prepared) -> IntermediateFrame? {
        lock.lock()
        defer { lock.unlock() }
        if let frame = intermediates.first(where: {
            $0.key == state.intermediateKey && !$0.leased
        }) {
            frame.leased = true
            return frame
        }
        if let idle = intermediates.firstIndex(where: { !$0.leased }) {
            intermediates.remove(at: idle)
        }
        guard intermediates.count < maximumInFlightFrames,
              let frame = try? makeIntermediate(for: state)
        else { return nil }
        frame.leased = true
        intermediates.append(frame)
        return frame
    }

    private func releaseIntermediate(_ frame: IntermediateFrame) {
        lock.lock()
        frame.leased = false
        lock.unlock()
    }

    private func makeIntermediate(for state: Prepared) throws -> IntermediateFrame {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: state.width, height: state.height,
            mipmapped: false)
        descriptor.textureType = .type2D
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let record = device.makeTexture(descriptor: descriptor),
              let density = device.makeTexture(descriptor: descriptor)
        else {
            throw PreparationError.allocationFailed("private RGBA16F intermediate ring")
        }
        record.label = "Fotufilm HDR-master record exposure"
        density.label = "Fotufilm HDR-master developed density"

        let sdrToneResources: HandwrittenMetalGlobalMeasurements.Resources?
        let x420ToneResources: HandwrittenMetalGlobalMeasurements.Resources?
        let floatToneResources: HandwrittenMetalGlobalMeasurements.Resources?
        let flareResources: HandwrittenMetalGlobalMeasurements.Resources?
        do {
            sdrToneResources = state.toneActive ? try measurements.makeResources(
                invocation: state.invocation, mode: .encodedDisplayP3RGBA8,
                frameWidth: state.width, frameHeight: state.height) : nil
            x420ToneResources = state.toneActive ? try measurements.makeResources(
                invocation: state.invocation, mode: .linearRec2020RGBA16Float,
                frameWidth: state.width, frameHeight: state.height) : nil
            floatToneResources = state.toneActive ? try measurements.makeResources(
                invocation: state.invocation, mode: .linearRec2020RGBA32Float,
                frameWidth: state.width, frameHeight: state.height) : nil
            // The flare reducer's current RGBA16F seam is selected by its SDR resource tag. Tone
            // metering uses separate per-source sets, so simultaneous tone and flare never share
            // writable reduction storage and still remain in the same command buffer.
            flareResources = state.flareActive ? try measurements.makeResources(
                invocation: state.invocation, mode: .encodedDisplayP3RGBA8,
                frameWidth: state.width, frameHeight: state.height) : nil
        } catch {
            throw PreparationError.measurementPreparation(String(describing: error))
        }
        guard !state.toneActive || sdrToneResources?.toneGrid != nil,
              !state.toneActive || x420ToneResources?.toneGrid != nil,
              !state.toneActive || floatToneResources?.toneGrid != nil,
              !state.flareActive || flareResources?.flareMean != nil
        else {
            throw PreparationError.allocationFailed("per-frame GPU measurement resources")
        }
        return IntermediateFrame(
            key: state.intermediateKey,
            recordExposure: record, developedDensity: density,
            sdrToneResources: sdrToneResources,
            x420ToneResources: x420ToneResources,
            floatToneResources: floatToneResources,
            flareResources: flareResources)
    }

    private func validInput(
        _ texture: MTLTexture, format: MTLPixelFormat,
        width: Int, height: Int
    ) -> Bool {
        texture.device.registryID == device.registryID
            && texture.textureType == .type2D
            && texture.pixelFormat == format
            && texture.width == width && texture.height == height
            && texture.depth == 1 && texture.arrayLength == 1
            && texture.mipmapLevelCount == 1 && texture.sampleCount == 1
            && texture.usage.contains(.shaderRead)
    }

    private func validCaptureInputs(
        luma: MTLTexture, chroma: MTLTexture,
        lumaFormat: MTLPixelFormat, chromaFormat: MTLPixelFormat,
        outputWidth: Int, outputHeight: Int
    ) -> Bool {
        validInput(luma, format: lumaFormat, width: luma.width, height: luma.height)
            && validInput(
                chroma, format: chromaFormat,
                width: (luma.width + 1) / 2, height: (luma.height + 1) / 2)
            && luma.width >= outputWidth && luma.height >= outputHeight
            && luma.width * outputHeight == luma.height * outputWidth
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

    private static func measurementTransfer(
        _ transfer: HDRCaptureTransfer
    ) -> HandwrittenMetalGlobalMeasurements.HDRCaptureTransfer {
        switch transfer {
        case .hlg: return .hlg
        case .appleLog: return .appleLog
        }
    }

    private static func measurementRange(
        _ range: SDRCaptureRange
    ) -> HandwrittenMetalGlobalMeasurements.SDRCaptureRange {
        switch range {
        case .video: return .video
        case .full: return .full
        }
    }

    private static func measurementGamut(
        _ gamut: SDRCaptureGamut
    ) -> HandwrittenMetalGlobalMeasurements.SDRCaptureGamut {
        switch gamut {
        case .displayP3: return .displayP3
        case .sRGB: return .sRGB
        }
    }

    private static func rgba32FloatByteCount(width: Int, height: Int) -> Int? {
        let (pixels, pixelsOverflow) = width.multipliedReportingOverflow(by: height)
        let (values, valuesOverflow) = pixels.multipliedReportingOverflow(by: 4)
        let (bytes, bytesOverflow) = values.multipliedReportingOverflow(
            by: MemoryLayout<Float>.stride)
        return pixelsOverflow || valuesOverflow || bytesOverflow ? nil : bytes
    }
}
#endif
