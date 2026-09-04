#if canImport(Metal)
import Foundation
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Fast scene-to-record endpoint for the hand-written realtime frame graph.
///
/// Both input roads finish at the same physical seam: RGBA16F contains the three image-forming
/// record exposures and the optional donor-layer exposure in W. The spectral LUT is restricted to
/// its three upper faces because recovery normalizes every non-black physical colour by its largest
/// component. This preserves the canonical tetrahedral walk as a three-read triangular lookup and
/// keeps the complete table in the texture cache.
public final class HandwrittenMetalSpectralHead {
    public enum InputMode: Sendable, Equatable {
        /// Transfer-encoded Display P3, tightly packed as premultiplied RGBA8.
        case encodedDisplayP3RGBA8
        /// Scene-linear Rec.2020, tightly packed as RGBA16F.
        case linearRec2020RGBA16Float
        /// Scene-linear Rec.2020, tightly packed as interleaved RGBA Float32.
        /// This is the maximum-precision still-image seam before spectral exposure.
        case linearRec2020RGBA32Float
    }

    /// Code range of a native 8-bit bi-planar camera buffer.
    public enum SDRCaptureRange: UInt32, Sendable {
        case video = 0
        case full = 1
    }

    /// RGB primaries declared by an SDR camera buffer. Both use the IEC sRGB transfer curve.
    public enum SDRCaptureGamut: UInt32, Sendable {
        case displayP3 = 0
        case sRGB = 1
    }

    /// Transfer carried by a 10-bit bi-planar BT.2020 camera buffer.
    public enum HDRCaptureTransfer: UInt32, Sendable {
        case hlg = 0
        case appleLog = 1
    }

    /// A whole-frame local-tone solve held on the CPU at preparation time.
    public struct SolvedToneGrid: Sendable {
        public let width: Int
        public let height: Int
        public let a: [Float]
        public let b: [Float]

        public init(width: Int, height: Int, a: [Float], b: [Float]) {
            self.width = width
            self.height = height
            self.a = a
            self.b = b
        }
    }

    /// Where an active local-tone solve will come from.
    public enum ToneGridSource: Sendable {
        /// Upload an already-solved grid during preparation.
        case cpu(SolvedToneGrid)
        /// Require a `HandwrittenMetalGlobalMeasurements.ToneGrid` on every encode. Its private
        /// buffer may be produced by an earlier encoder in the same command buffer.
        case gpu
    }

    public enum PreparationError: Swift.Error, CustomStringConvertible {
        case invalidDimensions
        case invocationSizeMismatch
        case unsupportedPipelineSpan
        case missingToneGrid
        case unexpectedToneGrid
        case invalidToneGrid
        case invalidSceneConfiguration
        case malformedSpectralTable
        case allocationFailed(String)
        case metalCompilation(String)

        public var description: String {
            switch self {
            case .invalidDimensions:
                return "frame dimensions must be positive and fit the Metal parameter layout"
            case .invocationSizeMismatch:
                return "the invocation and spectral-head frame dimensions differ"
            case .unsupportedPipelineSpan:
                return "the spectral head requires a full-frame scene-input invocation"
            case .missingToneGrid:
                return "active local tone requires an explicit CPU or GPU solved grid"
            case .unexpectedToneGrid:
                return "a tone grid was supplied when local tone is inactive"
            case .invalidToneGrid:
                return "the supplied local-tone grid is malformed or has the wrong extent"
            case .invalidSceneConfiguration:
                return "scene exposure, white balance, or creative controls are invalid"
            case .malformedSpectralTable:
                return "the exposure spectral table is malformed or cannot be represented in half"
            case let .allocationFailed(name):
                return "unable to allocate \(name)"
            case let .metalCompilation(message):
                return "Metal compilation failed: \(message)"
            }
        }
    }

    public static let outputPixelFormat: MTLPixelFormat = .rgba16Float

    static let decodeSamples = 256
    private static let fullSpanBits = FilmEngineFeature.densityOut
        | FilmEngineFeature.densityIn | FilmEngineFeature.flareMeasure
        | FilmEngineFeature.encodeOut | FilmEngineFeature.lightOut
        | FilmEngineFeature.fieldsIn | FilmEngineFeature.texture

    /// Three compact float4 values. Keeping the scene controls out of the large packed engine
    /// configuration saves a cache line walk at every pixel.
    private struct SceneParameters {
        var whiteBalance: SIMD4<Float>
        var adjustment: SIMD4<Float>
        var exposureAndPadding: SIMD4<Float>
    }

    private struct FrameParameters {
        var extentAndTone: SIMD4<UInt32>
        var inputGainAndPadding: SIMD4<Float>
    }

    private struct CaptureParameters {
        var frame: FrameParameters
        /// Scene scale, chroma offset X/Y, padding.
        var transform: SIMD4<Float>
        /// HDR transfer or SDR range, SDR gamut, padding.
        var sourceAndPadding: SIMD4<UInt32>
    }

    private struct PipelineKey: Hashable {
        let mode: UInt8
        let tone: Bool
        let localTone: Bool
        let chroma: Bool
    }

    private enum PreparedTone {
        /// No regional grid. This covers both an inactive tone stage and the global one-tap tone
        /// stage, whose canonical base is simply the pixel's own metered stops.
        case none
        case cpu(buffer: MTLBuffer, width: Int, height: Int, bOffset: Int)
        case gpu(width: Int, height: Int)
    }

    private struct Prepared {
        let mode: InputMode
        let width: Int
        let height: Int
        let inputByteCount: Int
        let scene: MTLBuffer
        let exposureFaces: MTLTexture
        let bufferPipeline: MTLComputePipelineState
        let texturePipeline: MTLComputePipelineState
        let tone: PreparedTone
    }

    private struct ToneBinding {
        let buffer: MTLBuffer
        let aOffset: Int
        let bOffset: Int
        let width: Int
        let height: Int
        let retained: AnyObject?
    }

    private let device: MTLDevice
    private let library: MTLLibrary
    private let decode: MTLTexture
    private let identityTone: MTLBuffer
    private let lock = NSLock()
    private var pipelines: [PipelineKey: MTLComputePipelineState] = [:]
    private var prepared: [String: Prepared] = [:]

    public convenience init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.init(device: device)
    }

    public init?(device: MTLDevice) {
        let options = MTLCompileOptions()
        if #available(macOS 15.0, iOS 18.0, *) {
            options.mathMode = .fast
        } else {
            options.fastMathEnabled = true
        }
        do {
            library = try HandwrittenMetalShaderLibrary.makeLibrary(
                device: device, shader: .spectralHead, options: options,
                preprocessorMacros: [
                    "FOTUFILM_HEAD_DECODE_SAMPLES": NSNumber(value: Self.decodeSamples),
                ])
        } catch {
            print("HandwrittenMetalSpectralHead: Metal library failed (\(error))")
            return nil
        }
        guard let decode = Self.makeDecodeTexture(device: device) else { return nil }
        let identity: [Float] = [1, 0]
        guard let identityTone = identity.withUnsafeBytes({ bytes -> MTLBuffer? in
            guard let base = bytes.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: base, length: bytes.count, options: .storageModeShared)
        })
        else { return nil }
        self.device = device
        self.decode = decode
        self.identityTone = identityTone
    }

    /// Prepares immutable tables and a compile-time-specialized head for one edit.
    ///
    /// `toneGrid` must be non-nil exactly when `invocation.localToneActive` is true. Choosing
    /// `.gpu` defers the actual resource binding to `encode`; it does not install an identity grid.
    public func prepareChecked(
        key: String, invocation: FilmEngineInvocation,
        mode: InputMode, frameWidth: Int, frameHeight: Int,
        toneGrid: ToneGridSource? = nil
    ) throws {
        guard frameWidth > 0, frameHeight > 0,
              frameWidth <= Int(UInt32.max), frameHeight <= Int(UInt32.max),
              let inputByteCount = Self.inputByteCount(
                mode: mode, width: frameWidth, height: frameHeight)
        else { throw PreparationError.invalidDimensions }
        guard Int(invocation.configuration[FilmEngineInvocation.frameSizeOffset]) == frameWidth,
              Int(invocation.configuration[FilmEngineInvocation.frameSizeOffset + 1]) == frameHeight
        else { throw PreparationError.invocationSizeMismatch }
        guard invocation.featureMask & Self.fullSpanBits == 0 else {
            throw PreparationError.unsupportedPipelineSpan
        }

        let adjustmentOffset = FilmEngineInvocation.sceneAdjustOffset
        let balanceOffset = FilmEngineInvocation.whiteBalanceOffset
        let exposureGain = invocation.configuration[FilmEngineInvocation.exposureGainOffset]
        let balance = SIMD3<Float>(
            invocation.configuration[balanceOffset],
            invocation.configuration[balanceOffset + 1],
            invocation.configuration[balanceOffset + 2])
        let adjustment = SIMD4<Float>(
            invocation.configuration[adjustmentOffset],
            invocation.configuration[adjustmentOffset + 1],
            invocation.configuration[adjustmentOffset + 2],
            invocation.configuration[adjustmentOffset + 3])
        guard exposureGain.isFinite, exposureGain >= 0,
              balance.x.isFinite, balance.y.isFinite, balance.z.isFinite,
              balance.x >= 0, balance.y >= 0, balance.z >= 0,
              adjustment.x.isFinite, adjustment.y.isFinite,
              adjustment.z.isFinite, adjustment.w.isFinite
        else { throw PreparationError.invalidSceneConfiguration }

        let toneControls = adjustment.x != 0 || adjustment.y != 0
        let chromaControls = adjustment.z != 1 || adjustment.w != 0
        let localTone = invocation.localToneActive
        let expectedGrid = invocation.toneBaseMeasurement()
        let preparedTone: PreparedTone
        if localTone {
            guard let toneGrid else { throw PreparationError.missingToneGrid }
            switch toneGrid {
            case let .cpu(grid):
                guard grid.width == expectedGrid.gridWidth,
                      grid.height == expectedGrid.gridHeight,
                      let count = Self.checkedProduct(grid.width, grid.height),
                      count <= FilmEngineInvocation.toneGridCells,
                      grid.a.count == count, grid.b.count == count,
                      grid.a.allSatisfy(\.isFinite), grid.b.allSatisfy(\.isFinite)
                else { throw PreparationError.invalidToneGrid }
                let values = grid.a + grid.b
                guard let buffer = values.withUnsafeBytes({ bytes -> MTLBuffer? in
                    guard let base = bytes.baseAddress else { return nil }
                    return device.makeBuffer(
                        bytes: base, length: bytes.count, options: .storageModeShared)
                }) else { throw PreparationError.allocationFailed("CPU tone-grid buffer") }
                preparedTone = .cpu(
                    buffer: buffer, width: grid.width, height: grid.height,
                    bOffset: count * MemoryLayout<Float>.stride)
            case .gpu:
                preparedTone = .gpu(
                    width: expectedGrid.gridWidth, height: expectedGrid.gridHeight)
            }
        } else {
            guard case nil = toneGrid else { throw PreparationError.unexpectedToneGrid }
            preparedTone = .none
        }

        var sceneParameters = SceneParameters(
            whiteBalance: SIMD4(balance, 0), adjustment: adjustment,
            exposureAndPadding: SIMD4(exposureGain / 0.18, 0, 0, 0))
        guard let scene = device.makeBuffer(
            bytes: &sceneParameters,
            length: MemoryLayout<SceneParameters>.stride,
            options: .storageModeShared)
        else { throw PreparationError.allocationFailed("scene parameter buffer") }
        guard let exposureFaces = makeExposureFaces(invocation.spectral.exposure) else {
            throw PreparationError.malformedSpectralTable
        }
        let modeValue: UInt8
        let textureModeValue: UInt8
        switch mode {
        case .encodedDisplayP3RGBA8:
            modeValue = 0
            textureModeValue = 2
        case .linearRec2020RGBA16Float:
            modeValue = 1
            textureModeValue = 3
        case .linearRec2020RGBA32Float:
            modeValue = 4
            // Float32 is a packed-buffer seam. The texture pipeline is retained only to keep the
            // prepared representation uniform and is rejected by both texture entry points.
            textureModeValue = 3
        }
        let bufferPipeline = try pipeline(for: PipelineKey(
            mode: modeValue, tone: toneControls,
            localTone: localTone, chroma: chromaControls))
        let texturePipeline = try pipeline(for: PipelineKey(
            mode: textureModeValue, tone: toneControls,
            localTone: localTone, chroma: chromaControls))
        let value = Prepared(
            mode: mode, width: frameWidth, height: frameHeight,
            inputByteCount: inputByteCount, scene: scene,
            exposureFaces: exposureFaces,
            bufferPipeline: bufferPipeline, texturePipeline: texturePipeline,
            tone: preparedTone)
        lock.lock()
        prepared[key] = value
        lock.unlock()
    }

    /// Compatibility convenience for callers that select another renderer on failure.
    @discardableResult
    public func prepare(
        key: String, invocation: FilmEngineInvocation,
        mode: InputMode, frameWidth: Int, frameHeight: Int,
        toneGrid: ToneGridSource? = nil
    ) -> Bool {
        do {
            try prepareChecked(
                key: key, invocation: invocation, mode: mode,
                frameWidth: frameWidth, frameHeight: frameHeight,
                toneGrid: toneGrid)
            return true
        } catch {
            return false
        }
    }

    /// Records one full-frame spectral recovery into a caller-owned command buffer.
    ///
    /// The method neither commits nor waits. `gpuToneGrid` is required only for keys prepared
    /// with `.gpu`; because it is bound directly, a preceding measurement encoder in this same
    /// command buffer can produce it without a CPU synchronization point.
    @discardableResult
    public func encode(
        input: MTLBuffer, recordExposure: MTLTexture,
        key: String, inputGain: Float = 1,
        gpuToneGrid: HandwrittenMetalGlobalMeasurements.ToneGrid? = nil,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard inputGain.isFinite, inputGain >= 0,
              input.device.registryID == device.registryID,
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              validOutput(recordExposure)
        else { return false }
        lock.lock()
        let state = prepared[key]
        lock.unlock()
        guard let state,
              input.length >= state.inputByteCount,
              recordExposure.width == state.width,
              recordExposure.height == state.height,
              let tone = toneBinding(for: state, gpuToneGrid: gpuToneGrid),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        var frame = FrameParameters(
            extentAndTone: SIMD4(
                UInt32(state.width), UInt32(state.height),
                UInt32(tone.width), UInt32(tone.height)),
            inputGainAndPadding: SIMD4(inputGain, 0, 0, 0))
        var resources: [AnyObject] = [
            self, input, recordExposure, state.scene, state.exposureFaces,
            state.bufferPipeline, decode, tone.buffer,
        ]
        if let retained = tone.retained { resources.append(retained) }
        retain(resources, untilCompletedBy: commandBuffer)
        encoder.label = "Fotufilm fast handwritten spectral head"
        encoder.setComputePipelineState(state.bufferPipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(state.scene, offset: 0, index: 1)
        encoder.setBytes(&frame, length: MemoryLayout<FrameParameters>.stride, index: 2)
        encoder.setBuffer(tone.buffer, offset: tone.aOffset, index: 3)
        encoder.setBuffer(tone.buffer, offset: tone.bOffset, index: 4)
        encoder.setTexture(state.exposureFaces, index: 0)
        encoder.setTexture(recordExposure, index: 1)
        if state.mode == .encodedDisplayP3RGBA8 {
            encoder.setTexture(decode, index: 2)
        }
        dispatch(
            encoder, pipeline: state.bufferPipeline,
            width: state.width, height: state.height)
        encoder.endEncoding()
        return true
    }

    /// Fuses native 420f/420v camera decode and spectral recovery without an RGB intermediate.
    /// The `r8Unorm`/`rg8Unorm` plane views are decoded with the BT.709 YCbCr matrix, the selected
    /// code range, and the IEC sRGB curve. `gamut` then maps the scene-linear RGB to Rec.2020 at
    /// the same seam used by HDR and maximum-precision still capture.
    @discardableResult
    public func encodeCapturedSDR(
        luma: MTLTexture, chroma: MTLTexture,
        recordExposure: MTLTexture, key: String,
        range: SDRCaptureRange, gamut: SDRCaptureGamut,
        chromaOffset: SIMD2<Float> = .zero, inputGain: Float = 1,
        gpuToneGrid: HandwrittenMetalGlobalMeasurements.ToneGrid? = nil,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard chromaOffset.x.isFinite, chromaOffset.y.isFinite,
              inputGain.isFinite, inputGain >= 0,
              validTextureInput(luma, format: .r8Unorm),
              validTextureInput(chroma, format: .rg8Unorm),
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              validOutput(recordExposure)
        else { return false }
        lock.lock()
        let state = prepared[key]
        lock.unlock()
        guard let state, state.mode == .encodedDisplayP3RGBA8,
              validCaptureTextures(
                luma: luma, chroma: chroma,
                outputWidth: state.width, outputHeight: state.height),
              recordExposure.width == state.width,
              recordExposure.height == state.height,
              let tone = toneBinding(for: state, gpuToneGrid: gpuToneGrid),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        var parameters = CaptureParameters(
            frame: FrameParameters(
                extentAndTone: SIMD4(
                    UInt32(state.width), UInt32(state.height),
                    UInt32(tone.width), UInt32(tone.height)),
                inputGainAndPadding: SIMD4(inputGain, 0, 0, 0)),
            transform: SIMD4(1, chromaOffset.x, chromaOffset.y, 0),
            sourceAndPadding: SIMD4(range.rawValue, gamut.rawValue, 0, 0))
        var resources: [AnyObject] = [
            self, luma, chroma, recordExposure, state.scene, state.exposureFaces,
            state.texturePipeline, decode, tone.buffer,
        ]
        if let retained = tone.retained { resources.append(retained) }
        retain(resources, untilCompletedBy: commandBuffer)
        encoder.label = "Fotufilm native 8-bit YCbCr spectral head"
        encoder.setComputePipelineState(state.texturePipeline)
        encoder.setBuffer(state.scene, offset: 0, index: 0)
        encoder.setBytes(
            &parameters, length: MemoryLayout<CaptureParameters>.stride, index: 1)
        encoder.setBuffer(tone.buffer, offset: tone.aOffset, index: 2)
        encoder.setBuffer(tone.buffer, offset: tone.bOffset, index: 3)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(state.exposureFaces, index: 2)
        encoder.setTexture(recordExposure, index: 3)
        encoder.setTexture(decode, index: 4)
        dispatch(
            encoder, pipeline: state.texturePipeline,
            width: state.width, height: state.height)
        encoder.endEncoding()
        return true
    }

    /// Fuses x420 camera decode and spectral recovery. The luma/chroma textures are the
    /// `r16Unorm`/`rg16Unorm` views of a 10-bit video-range CVPixelBuffer. HLG and Apple Log both
    /// carry BT.2020 primaries, so the curve decode lands directly in the film working space.
    @discardableResult
    public func encodeCapturedHDR(
        luma: MTLTexture, chroma: MTLTexture,
        recordExposure: MTLTexture, key: String,
        transfer: HDRCaptureTransfer, sceneScale: Float,
        chromaOffset: SIMD2<Float> = .zero, inputGain: Float = 1,
        gpuToneGrid: HandwrittenMetalGlobalMeasurements.ToneGrid? = nil,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard sceneScale.isFinite, sceneScale >= 0,
              chromaOffset.x.isFinite, chromaOffset.y.isFinite,
              inputGain.isFinite, inputGain >= 0,
              validTextureInput(luma, format: .r16Unorm),
              validTextureInput(chroma, format: .rg16Unorm),
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              validOutput(recordExposure)
        else { return false }
        lock.lock()
        let state = prepared[key]
        lock.unlock()
        guard let state, state.mode == .linearRec2020RGBA16Float,
              validCaptureTextures(
                luma: luma, chroma: chroma,
                outputWidth: state.width, outputHeight: state.height),
              recordExposure.width == state.width,
              recordExposure.height == state.height,
              let tone = toneBinding(for: state, gpuToneGrid: gpuToneGrid),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        var parameters = CaptureParameters(
            frame: FrameParameters(
                extentAndTone: SIMD4(
                    UInt32(state.width), UInt32(state.height),
                    UInt32(tone.width), UInt32(tone.height)),
                inputGainAndPadding: SIMD4(inputGain, 0, 0, 0)),
            transform: SIMD4(sceneScale, chromaOffset.x, chromaOffset.y, 0),
            sourceAndPadding: SIMD4(transfer.rawValue, 0, 0, 0))
        var resources: [AnyObject] = [
            self, luma, chroma, recordExposure, state.scene,
            state.exposureFaces, state.texturePipeline, tone.buffer,
        ]
        if let retained = tone.retained { resources.append(retained) }
        retain(resources, untilCompletedBy: commandBuffer)
        encoder.label = "Fotufilm zero-intermediate HDR capture spectral head"
        encoder.setComputePipelineState(state.texturePipeline)
        encoder.setBuffer(state.scene, offset: 0, index: 0)
        encoder.setBytes(
            &parameters, length: MemoryLayout<CaptureParameters>.stride, index: 1)
        encoder.setBuffer(tone.buffer, offset: tone.aOffset, index: 2)
        encoder.setBuffer(tone.buffer, offset: tone.bOffset, index: 3)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(state.exposureFaces, index: 2)
        encoder.setTexture(recordExposure, index: 3)
        dispatch(
            encoder, pipeline: state.texturePipeline,
            width: state.width, height: state.height)
        encoder.endEncoding()
        return true
    }

    public func removeAll() {
        lock.lock()
        prepared.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func pipeline(for key: PipelineKey) throws -> MTLComputePipelineState {
        lock.lock()
        if let pipeline = pipelines[key] {
            lock.unlock()
            return pipeline
        }
        lock.unlock()
        let constants = MTLFunctionConstantValues()
        var tone = key.tone
        var localTone = key.localTone
        var chroma = key.chroma
        constants.setConstantValue(&tone, type: .bool, index: 0)
        constants.setConstantValue(&localTone, type: .bool, index: 1)
        constants.setConstantValue(&chroma, type: .bool, index: 2)
        let name: String
        switch key.mode {
        case 0: name = "fotufilm_fast_spectral_head_sdr"
        case 1: name = "fotufilm_fast_spectral_head_hdr"
        case 2: name = "fotufilm_fast_spectral_head_nv12"
        case 3: name = "fotufilm_fast_spectral_head_x420"
        default: name = "fotufilm_fast_spectral_head_hdr_float"
        }
        do {
            let function = try library.makeFunction(name: name, constantValues: constants)
            let pipeline = try device.makeComputePipelineState(function: function)
            lock.lock()
            pipelines[key] = pipeline
            lock.unlock()
            return pipeline
        } catch {
            throw PreparationError.metalCompilation(error.localizedDescription)
        }
    }

    private func makeExposureFaces(_ table: SpectralLUT) -> MTLTexture? {
        let edge = table.dimension
        guard edge >= 2, edge <= Int(UInt32.max),
              let voxelCount = Self.checkedProduct(edge, edge),
              let cubeCount = Self.checkedProduct(voxelCount, edge),
              let valueCount = Self.checkedProduct(cubeCount, 4),
              table.values.count == valueCount,
              let facePixels = Self.checkedProduct(3, voxelCount),
              let faceValues = Self.checkedProduct(facePixels, 4)
        else { return nil }
        var faces = [Float16](repeating: 0, count: faceValues)
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
                    let source = sourceIndex(coordinate.x, coordinate.y, coordinate.z)
                    let destination = ((face * edge + v) * edge + u) * 4
                    for channel in 0..<4 {
                        let value = table.values[source + channel]
                        let half = Float16(value)
                        guard value.isFinite, half.isFinite else { return nil }
                        faces[destination + channel] = half
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

    private static func makeDecodeTexture(device: MTLDevice) -> MTLTexture? {
        var values = [Float16](repeating: 0, count: decodeSamples)
        for index in values.indices {
            let value = ColorScience.srgbToLinear(
                Float(index) / Float(decodeSamples - 1))
            let half = Float16(value)
            guard value.isFinite, half.isFinite else { return nil }
            values[index] = half
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

    private func validOutput(_ texture: MTLTexture) -> Bool {
        texture.device.registryID == device.registryID
            && texture.pixelFormat == Self.outputPixelFormat
            && texture.textureType == .type2D
            && texture.sampleCount == 1
            && texture.mipmapLevelCount == 1
            && texture.arrayLength == 1
            && texture.depth == 1
            && texture.usage.contains(.shaderRead)
            && texture.usage.contains(.shaderWrite)
    }

    private func validTextureInput(
        _ texture: MTLTexture, format: MTLPixelFormat
    ) -> Bool {
        texture.device.registryID == device.registryID
            && texture.pixelFormat == format
            && texture.textureType == .type2D
            && texture.sampleCount == 1
            && texture.mipmapLevelCount == 1
            && texture.arrayLength == 1
            && texture.depth == 1
            && texture.usage.contains(.shaderRead)
    }

    private func validCaptureTextures(
        luma: MTLTexture, chroma: MTLTexture,
        outputWidth: Int, outputHeight: Int
    ) -> Bool {
        validTextureInput(luma, format: luma.pixelFormat)
            && validTextureInput(chroma, format: chroma.pixelFormat)
            && chroma.width == (luma.width + 1) / 2
            && chroma.height == (luma.height + 1) / 2
            && luma.width >= outputWidth && luma.height >= outputHeight
            && luma.width * outputHeight == luma.height * outputWidth
    }

    private func toneBinding(
        for state: Prepared,
        gpuToneGrid: HandwrittenMetalGlobalMeasurements.ToneGrid?
    ) -> ToneBinding? {
        switch state.tone {
        case .none:
            guard gpuToneGrid == nil else { return nil }
            return ToneBinding(
                buffer: identityTone, aOffset: 0,
                bOffset: MemoryLayout<Float>.stride,
                width: 1, height: 1, retained: nil)
        case let .cpu(buffer, width, height, bOffset):
            guard gpuToneGrid == nil else { return nil }
            return ToneBinding(
                buffer: buffer, aOffset: 0, bOffset: bOffset,
                width: width, height: height, retained: nil)
        case let .gpu(width, height):
            guard let grid = gpuToneGrid,
                  grid.width == width, grid.height == height,
                  grid.buffer.device.registryID == device.registryID,
                  grid.aOffset >= 0, grid.bOffset >= 0,
                  grid.buffer.length >= grid.aOffset
                    + grid.cellCount * MemoryLayout<Float>.stride,
                  grid.buffer.length >= grid.bOffset
                    + grid.cellCount * MemoryLayout<Float>.stride
            else { return nil }
            return ToneBinding(
                buffer: grid.buffer, aOffset: grid.aOffset,
                bOffset: grid.bOffset, width: width, height: height,
                retained: grid)
        }
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
        width: Int, height: Int
    ) {
        let groupWidth = min(pipeline.threadExecutionWidth, 32)
        let groupHeight = max(1, min(
            8, pipeline.maxTotalThreadsPerThreadgroup / max(groupWidth, 1)))
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: groupWidth, height: groupHeight, depth: 1))
    }

    private func retain(_ resources: [AnyObject], untilCompletedBy buffer: MTLCommandBuffer) {
        buffer.addCompletedHandler { _ in withExtendedLifetime(resources) {} }
    }

    private static func inputByteCount(
        mode: InputMode, width: Int, height: Int
    ) -> Int? {
        guard let pixels = checkedProduct(width, height) else { return nil }
        let bytesPerPixel: Int
        switch mode {
        case .encodedDisplayP3RGBA8:
            bytesPerPixel = 4
        case .linearRec2020RGBA16Float:
            bytesPerPixel = 4 * MemoryLayout<Float16>.stride
        case .linearRec2020RGBA32Float:
            bytesPerPixel = 4 * MemoryLayout<Float>.stride
        }
        return checkedProduct(pixels, bytesPerPixel)
    }

    private static func checkedProduct(_ lhs: Int, _ rhs: Int) -> Int? {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : value
    }

}
#endif
