#if canImport(Metal)
import Foundation
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// GPU-only whole-frame measurements consumed by the hand-written realtime renderer.
///
/// A resource set belongs to one in-flight frame. Encoding records into a caller-owned command
/// buffer and leaves both results in private storage, so a following head or spatial kernel can
/// bind them without a CPU round trip. Separate resource sets allow several frames in flight.
public final class HandwrittenMetalGlobalMeasurements {
    public enum InputMode: Sendable {
        /// Transfer-encoded Display P3, tightly packed as premultiplied RGBA8.
        case encodedDisplayP3RGBA8
        /// Scene-linear Rec.2020, tightly packed as RGBA16F.
        case linearRec2020RGBA16Float
        /// Scene-linear Rec.2020, tightly packed as interleaved RGBA Float32.
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

    public enum ResourceError: Swift.Error, CustomStringConvertible {
        case invalidDimensions
        case invocationSizeMismatch
        case allocationFailed(String)

        public var description: String {
            switch self {
            case .invalidDimensions:
                return "frame dimensions must be positive and fit the Metal parameter layout"
            case .invocationSizeMismatch:
                return "the invocation and measurement frame dimensions differ"
            case let .allocationFailed(name):
                return "unable to allocate \(name)"
            }
        }
    }

    /// Two contiguous float32 planes. `aOffset` and `bOffset` are byte offsets into `buffer`.
    /// The values become available to later commands after `encodeToneBase` in the same command
    /// buffer, or after command-buffer completion for a different consumer.
    public final class ToneGrid {
        public let width: Int
        public let height: Int
        public let buffer: MTLBuffer
        public let aOffset: Int
        public let bOffset: Int

        public var cellCount: Int { width * height }

        fileprivate init(width: Int, height: Int, buffer: MTLBuffer) {
            self.width = width
            self.height = height
            self.buffer = buffer
            aOffset = 0
            bOffset = width * height * MemoryLayout<Float>.stride
        }

        /// Binds the two coefficient planes as independent device-float pointers.
        public func bind(
            to encoder: MTLComputeCommandEncoder, aIndex: Int, bIndex: Int
        ) {
            encoder.setBuffer(buffer, offset: aOffset, index: aIndex)
            encoder.setBuffer(buffer, offset: bOffset, index: bIndex)
        }
    }

    /// One private float4: the RGB pre-diffusion exposure mean and a padding value of one.
    ///
    /// The buffer is a direct GPU input contract. A later encoder in the same command buffer may
    /// bind it without waiting for completion or mapping it on the CPU. Width and height identify
    /// the whole frame whose mean it contains, preventing a stale in-flight resource from being
    /// paired with a different spatial frame.
    public final class FlareMean {
        public let width: Int
        public let height: Int
        public let buffer: MTLBuffer
        public let offset: Int = 0
        public let byteCount: Int = MemoryLayout<SIMD4<Float>>.stride

        fileprivate init(width: Int, height: Int, buffer: MTLBuffer) {
            self.width = width
            self.height = height
            self.buffer = buffer
        }

        public func bind(to encoder: MTLComputeCommandEncoder, index: Int) {
            encoder.setBuffer(buffer, offset: offset, index: index)
        }

        public func isCompatible(
            with device: MTLDevice, frameWidth: Int, frameHeight: Int
        ) -> Bool {
            width == frameWidth && height == frameHeight
                && buffer.device.registryID == device.registryID
                && offset >= 0 && offset.isMultiple(of: MemoryLayout<Float>.alignment)
                && buffer.length >= offset + byteCount
        }
    }

    /// Private result and scratch storage for one in-flight frame.
    public final class Resources {
        public let width: Int
        public let height: Int
        public let mode: InputMode
        public let toneGrid: ToneGrid?
        public let flareMean: FlareMean?

        public var toneActive: Bool { toneGrid != nil }
        public var flareActive: Bool { flareMean != nil }
        public var isInactive: Bool { !toneActive && !flareActive }

        fileprivate let deviceRegistryID: UInt64
        fileprivate let toneParameters: ToneParameters
        fileprivate let toneMoments: MTLBuffer?
        fileprivate let toneModel: MTLBuffer?
        fileprivate let flarePartialsA: MTLBuffer?
        fileprivate let flarePartialsB: MTLBuffer?
        fileprivate let flarePartialCapacity: Int

        fileprivate init(
            width: Int, height: Int, mode: InputMode, deviceRegistryID: UInt64,
            toneParameters: ToneParameters, toneGrid: ToneGrid?,
            toneMoments: MTLBuffer?, toneModel: MTLBuffer?,
            flareMean: FlareMean?, flarePartialsA: MTLBuffer?,
            flarePartialsB: MTLBuffer?, flarePartialCapacity: Int
        ) {
            self.width = width
            self.height = height
            self.mode = mode
            self.deviceRegistryID = deviceRegistryID
            self.toneParameters = toneParameters
            self.toneGrid = toneGrid
            self.toneMoments = toneMoments
            self.toneModel = toneModel
            self.flareMean = flareMean
            self.flarePartialsA = flarePartialsA
            self.flarePartialsB = flarePartialsB
            self.flarePartialCapacity = flarePartialCapacity
        }
    }

    static let reductionThreads = 256
    static let flareItemsPerThread = 8

    fileprivate struct ToneParameters {
        var width: UInt32
        var height: UInt32
        var gridWidth: UInt32
        var gridHeight: UInt32
        var weightR: Float
        var weightG: Float
        var weightB: Float
        var radius: UInt32
    }

    private struct FlareParameters {
        var width: UInt32
        var height: UInt32
        var inputCount: UInt32
        var pixelCount: UInt32
    }

    /// Matches the zero-copy spectral head's capture transform. `transform` is scene scale,
    /// chroma offset X/Y, and input gain; `source` carries transfer and SDR primaries.
    private struct CaptureToneParameters {
        var tone: ToneParameters
        var transform: SIMD4<Float>
        var source: SIMD4<UInt32>
    }

    private let device: MTLDevice
    private let toneSDR: MTLComputePipelineState
    private let toneHDR: MTLComputePipelineState
    private let toneHDRFloat: MTLComputePipelineState
    private let toneNV12: MTLComputePipelineState
    private let toneX420: MTLComputePipelineState
    private let toneModel: MTLComputePipelineState
    private let toneSmooth: MTLComputePipelineState
    private let flareFirst: MTLComputePipelineState
    private let flareReduce: MTLComputePipelineState
    private let flareFinish: MTLComputePipelineState
    private let decode: MTLTexture

    public convenience init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.init(device: device)
    }

    public init?(device: MTLDevice) {
        let options = MTLCompileOptions()
        // The reference accumulator and guided solve are explicitly float32. Do not permit the
        // compiler to replace their logarithms, divisions, or reduction arithmetic with relaxed
        // variants: the grid is a control signal reused over the full frame.
        options.fastMathEnabled = false
        do {
            let library = try HandwrittenMetalShaderLibrary.makeLibrary(
                device: device, shader: .globalMeasurements, options: options,
                preprocessorMacros: [
                    "FOTUFILM_MEASUREMENT_REDUCTION_THREADS": NSNumber(
                        value: Self.reductionThreads),
                    "FOTUFILM_MEASUREMENT_FLARE_ITEMS": NSNumber(
                        value: Self.flareItemsPerThread),
                ])
            guard let sdr = library.makeFunction(name: "fotufilm_measure_tone_sdr"),
                  let hdr = library.makeFunction(name: "fotufilm_measure_tone_hdr"),
                  let hdrFloat = library.makeFunction(
                    name: "fotufilm_measure_tone_hdr_float"),
                  let nv12 = library.makeFunction(name: "fotufilm_measure_tone_nv12"),
                  let x420 = library.makeFunction(name: "fotufilm_measure_tone_x420"),
                  let model = library.makeFunction(name: "fotufilm_measure_tone_model"),
                  let smooth = library.makeFunction(name: "fotufilm_measure_tone_smooth"),
                  let first = library.makeFunction(name: "fotufilm_measure_flare_first"),
                  let reduce = library.makeFunction(name: "fotufilm_measure_flare_reduce"),
                  let finish = library.makeFunction(name: "fotufilm_measure_flare_finish")
            else { return nil }
            toneSDR = try device.makeComputePipelineState(function: sdr)
            toneHDR = try device.makeComputePipelineState(function: hdr)
            toneHDRFloat = try device.makeComputePipelineState(function: hdrFloat)
            toneNV12 = try device.makeComputePipelineState(function: nv12)
            toneX420 = try device.makeComputePipelineState(function: x420)
            toneModel = try device.makeComputePipelineState(function: model)
            toneSmooth = try device.makeComputePipelineState(function: smooth)
            flareFirst = try device.makeComputePipelineState(function: first)
            flareReduce = try device.makeComputePipelineState(function: reduce)
            flareFinish = try device.makeComputePipelineState(function: finish)
        } catch {
            print("HandwrittenMetalGlobalMeasurements: Metal library failed (\(error))")
            return nil
        }
        guard let decode = Self.makeDecodeTexture(device: device) else { return nil }
        let reductions = [
            toneSDR, toneHDR, toneHDRFloat, toneNV12, toneX420,
            flareFirst, flareReduce,
        ]
        guard reductions.allSatisfy({
            $0.maxTotalThreadsPerThreadgroup >= Self.reductionThreads
        }) else { return nil }
        self.device = device
        self.decode = decode
    }

    /// Allocates one private resource set. Tone and flare allocations disappear independently
    /// when their invocation features are inactive; a wholly inactive set allocates nothing.
    public func makeResources(
        invocation: FilmEngineInvocation, mode: InputMode,
        frameWidth: Int, frameHeight: Int
    ) throws -> Resources {
        guard frameWidth > 0, frameHeight > 0,
              frameWidth <= Int(UInt32.max), frameHeight <= Int(UInt32.max),
              let pixelCount = checkedProduct(frameWidth, frameHeight),
              pixelCount <= Int(UInt32.max)
        else { throw ResourceError.invalidDimensions }
        guard Int(invocation.configuration[FilmEngineInvocation.frameSizeOffset]) == frameWidth,
              Int(invocation.configuration[FilmEngineInvocation.frameSizeOffset + 1]) == frameHeight
        else { throw ResourceError.invocationSizeMismatch }

        let long = max(frameWidth, frameHeight)
        func cells(_ side: Int) -> Int {
            min(side, max(1, (side * ToneBaseMeasurement.gridEdge + long / 2) / long))
        }
        let gridWidth = cells(frameWidth)
        let gridHeight = cells(frameHeight)
        let cellCount = gridWidth * gridHeight
        let balanceOffset = FilmEngineInvocation.whiteBalanceOffset
        let gain = invocation.configuration[FilmEngineInvocation.exposureGainOffset] / 0.18
        let luma = ColorScience.luminanceWeights
        let radius = min(12, max(gridWidth, gridHeight) - 1)
        let toneParameters = ToneParameters(
            width: UInt32(frameWidth), height: UInt32(frameHeight),
            gridWidth: UInt32(gridWidth), gridHeight: UInt32(gridHeight),
            weightR: luma.0 * invocation.configuration[balanceOffset] * gain,
            weightG: luma.1 * invocation.configuration[balanceOffset + 1] * gain,
            weightB: luma.2 * invocation.configuration[balanceOffset + 2] * gain,
            radius: UInt32(radius))

        var toneGrid: ToneGrid?
        var toneMoments: MTLBuffer?
        var model: MTLBuffer?
        if invocation.localToneActive {
            guard let coefficients = makePrivateBuffer(
                length: 2 * cellCount * MemoryLayout<Float>.stride)
            else { throw ResourceError.allocationFailed("tone coefficient planes") }
            guard let moments = makePrivateBuffer(
                length: cellCount * MemoryLayout<SIMD2<Float>>.stride)
            else { throw ResourceError.allocationFailed("tone cell moments") }
            guard let scratch = makePrivateBuffer(
                length: cellCount * MemoryLayout<SIMD2<Float>>.stride)
            else { throw ResourceError.allocationFailed("guided-filter scratch") }
            toneGrid = ToneGrid(width: gridWidth, height: gridHeight, buffer: coefficients)
            toneMoments = moments
            model = scratch
        }

        var flareMean: FlareMean?
        var partialsA: MTLBuffer?
        var partialsB: MTLBuffer?
        var partialCapacity = 0
        if invocation.featureMask & FilmEngineFeature.flare != 0 {
            partialCapacity = max(1, Self.divideRoundUp(
                pixelCount, Self.reductionThreads * Self.flareItemsPerThread))
            let partialBytes = partialCapacity * MemoryLayout<SIMD4<Float>>.stride
            guard let result = makePrivateBuffer(length: MemoryLayout<SIMD4<Float>>.stride)
            else { throw ResourceError.allocationFailed("flare mean") }
            guard let a = makePrivateBuffer(length: partialBytes),
                  let b = makePrivateBuffer(length: partialBytes)
            else { throw ResourceError.allocationFailed("flare reduction scratch") }
            flareMean = FlareMean(
                width: frameWidth, height: frameHeight, buffer: result)
            partialsA = a
            partialsB = b
        }

        return Resources(
            width: frameWidth, height: frameHeight, mode: mode,
            deviceRegistryID: device.registryID, toneParameters: toneParameters,
            toneGrid: toneGrid, toneMoments: toneMoments, toneModel: model,
            flareMean: flareMean, flarePartialsA: partialsA,
            flarePartialsB: partialsB, flarePartialCapacity: partialCapacity)
    }

    /// Records the Display-P3/Rec.2020 metering reduction and complete guided-filter solve.
    /// Returns immediately without creating an encoder when local tone is inactive.
    @discardableResult
    public func encodeToneBase(
        input: MTLBuffer?, inputGain: Float = 1, resources: Resources,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard resources.toneActive else { return true }
        guard inputGain.isFinite, inputGain >= 0,
              resources.deviceRegistryID == device.registryID,
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              let input, input.device.registryID == device.registryID,
              let moments = resources.toneMoments,
              let model = resources.toneModel,
              let grid = resources.toneGrid,
              input.length >= inputByteCount(
                mode: resources.mode, width: resources.width, height: resources.height),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        var parameters = resources.toneParameters
        if resources.mode != .encodedDisplayP3RGBA8 {
            parameters.weightR *= inputGain
            parameters.weightG *= inputGain
            parameters.weightB *= inputGain
        }
        var retained: [AnyObject] = [self, resources, input]
        if resources.mode == .encodedDisplayP3RGBA8 { retained.append(decode) }
        retain(retained, untilCompletedBy: commandBuffer)
        encoder.label = "Fotufilm handwritten global tone measurement"
        let first: MTLComputePipelineState
        switch resources.mode {
        case .encodedDisplayP3RGBA8: first = toneSDR
        case .linearRec2020RGBA16Float: first = toneHDR
        case .linearRec2020RGBA32Float: first = toneHDRFloat
        }
        encoder.setComputePipelineState(first)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(moments, offset: 0, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<ToneParameters>.stride, index: 2)
        if resources.mode == .encodedDisplayP3RGBA8 {
            encoder.setTexture(decode, index: 0)
        }
        encoder.dispatchThreadgroups(
            MTLSize(width: grid.width, height: grid.height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: Self.reductionThreads, height: 1, depth: 1))

        finishToneSolve(
            encoder: encoder,
            parameters: &parameters, moments: moments, model: model, grid: grid)
        return true
    }

    /// Records the tone solve directly from native 420f/420v camera planes. Its decode is shared
    /// with `HandwrittenMetalSpectralHead.encodeCapturedSDR`, keeping metering and exposure on the
    /// identical linear Rec.2020 scene.
    @discardableResult
    public func encodeToneBase(
        luma: MTLTexture?, chroma: MTLTexture?,
        range: SDRCaptureRange, gamut: SDRCaptureGamut,
        chromaOffset: SIMD2<Float> = .zero, inputGain: Float = 1,
        resources: Resources, commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard resources.toneActive else { return true }
        guard resources.mode == .encodedDisplayP3RGBA8,
              chromaOffset.x.isFinite, chromaOffset.y.isFinite,
              inputGain.isFinite, inputGain >= 0,
              resources.deviceRegistryID == device.registryID,
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              let luma, let chroma,
              validCaptureTextures(
                luma: luma, chroma: chroma,
                lumaFormat: .r8Unorm, chromaFormat: .rg8Unorm,
                outputWidth: resources.width, outputHeight: resources.height),
              let moments = resources.toneMoments,
              let model = resources.toneModel,
              let grid = resources.toneGrid,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        var parameters = CaptureToneParameters(
            tone: resources.toneParameters,
            transform: SIMD4(1, chromaOffset.x, chromaOffset.y, inputGain),
            source: SIMD4(range.rawValue, gamut.rawValue, 0, 0))
        retain([self, resources, luma, chroma, decode], untilCompletedBy: commandBuffer)
        encoder.label = "Fotufilm native 8-bit YCbCr global tone measurement"
        encoder.setComputePipelineState(toneNV12)
        encoder.setBuffer(moments, offset: 0, index: 0)
        encoder.setBytes(
            &parameters, length: MemoryLayout<CaptureToneParameters>.stride, index: 1)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(decode, index: 2)
        encoder.dispatchThreadgroups(
            MTLSize(width: grid.width, height: grid.height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: Self.reductionThreads, height: 1, depth: 1))

        var toneParameters = resources.toneParameters
        finishToneSolve(
            encoder: encoder,
            parameters: &toneParameters, moments: moments, model: model, grid: grid)
        return true
    }

    /// Records the tone solve directly from `r16Unorm`/`rg16Unorm` views of a 10-bit video-range
    /// x420 camera buffer. The YCbCr matrix, bilinear chroma siting, transfer curve, scene scale,
    /// and input gain match `HandwrittenMetalSpectralHead.encodeCapturedHDR`.
    @discardableResult
    public func encodeToneBase(
        luma: MTLTexture?, chroma: MTLTexture?,
        transfer: HDRCaptureTransfer, sceneScale: Float,
        chromaOffset: SIMD2<Float> = .zero, inputGain: Float = 1,
        resources: Resources, commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard resources.toneActive else { return true }
        guard resources.mode == .linearRec2020RGBA16Float,
              sceneScale.isFinite, sceneScale >= 0,
              chromaOffset.x.isFinite, chromaOffset.y.isFinite,
              inputGain.isFinite, inputGain >= 0,
              resources.deviceRegistryID == device.registryID,
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              let luma, let chroma,
              validCaptureTextures(
                luma: luma, chroma: chroma,
                lumaFormat: .r16Unorm, chromaFormat: .rg16Unorm,
                outputWidth: resources.width, outputHeight: resources.height),
              let moments = resources.toneMoments,
              let model = resources.toneModel,
              let grid = resources.toneGrid,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        var parameters = CaptureToneParameters(
            tone: resources.toneParameters,
            transform: SIMD4(
                sceneScale, chromaOffset.x, chromaOffset.y, inputGain),
            source: SIMD4(transfer.rawValue, 0, 0, 0))
        retain([self, resources, luma, chroma], untilCompletedBy: commandBuffer)
        encoder.label = "Fotufilm zero-copy x420 global tone measurement"
        encoder.setComputePipelineState(toneX420)
        encoder.setBuffer(moments, offset: 0, index: 0)
        encoder.setBytes(
            &parameters, length: MemoryLayout<CaptureToneParameters>.stride, index: 1)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: grid.width, height: grid.height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: Self.reductionThreads, height: 1, depth: 1))

        var toneParameters = resources.toneParameters
        finishToneSolve(
            encoder: encoder,
            parameters: &toneParameters, moments: moments, model: model, grid: grid)
        return true
    }

    private func finishToneSolve(
        encoder: MTLComputeCommandEncoder,
        parameters: inout ToneParameters, moments: MTLBuffer,
        model: MTLBuffer, grid: ToneGrid
    ) {

        encoder.memoryBarrier(scope: .buffers)
        encoder.setComputePipelineState(toneModel)
        encoder.setBuffer(moments, offset: 0, index: 0)
        encoder.setBuffer(model, offset: 0, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<ToneParameters>.stride, index: 2)
        dispatchCells(encoder, pipeline: toneModel, count: grid.cellCount)

        encoder.memoryBarrier(scope: .buffers)
        encoder.setComputePipelineState(toneSmooth)
        encoder.setBuffer(model, offset: 0, index: 0)
        encoder.setBuffer(grid.buffer, offset: 0, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<ToneParameters>.stride, index: 2)
        dispatchCells(encoder, pipeline: toneSmooth, count: grid.cellCount)
        encoder.endEncoding()
    }

    /// Records a deterministic hierarchy over the pre-diffusion record-exposure texture.
    /// Returns immediately without creating an encoder when veiling glare is inactive.
    @discardableResult
    public func encodeFlareMean(
        recordExposure: MTLTexture?, resources: Resources,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard resources.flareActive else { return true }
        guard resources.deviceRegistryID == device.registryID,
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              let texture = recordExposure,
              validRecordExposure(texture, resources: resources),
              let partialsA = resources.flarePartialsA,
              let partialsB = resources.flarePartialsB,
              let result = resources.flareMean?.buffer,
              let pixelCount = checkedProduct(resources.width, resources.height),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        var partialCount = Self.divideRoundUp(
            pixelCount, Self.reductionThreads * Self.flareItemsPerThread)
        guard partialCount > 0, partialCount <= resources.flarePartialCapacity else {
            encoder.endEncoding()
            return false
        }
        retain([self, resources, texture], untilCompletedBy: commandBuffer)
        encoder.label = "Fotufilm handwritten pre-diffusion flare measurement"
        var parameters = FlareParameters(
            width: UInt32(resources.width), height: UInt32(resources.height),
            inputCount: UInt32(pixelCount), pixelCount: UInt32(pixelCount))
        encoder.setComputePipelineState(flareFirst)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(partialsA, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<FlareParameters>.stride, index: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: partialCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: Self.reductionThreads, height: 1, depth: 1))

        var source = partialsA
        var destination = partialsB
        while partialCount > 1 {
            encoder.memoryBarrier(scope: .buffers)
            let nextCount = Self.divideRoundUp(
                partialCount, Self.reductionThreads * Self.flareItemsPerThread)
            parameters.inputCount = UInt32(partialCount)
            encoder.setComputePipelineState(flareReduce)
            encoder.setBuffer(source, offset: 0, index: 0)
            encoder.setBuffer(destination, offset: 0, index: 1)
            encoder.setBytes(
                &parameters, length: MemoryLayout<FlareParameters>.stride, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: nextCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: Self.reductionThreads, height: 1, depth: 1))
            partialCount = nextCount
            swap(&source, &destination)
        }

        encoder.memoryBarrier(scope: .buffers)
        encoder.setComputePipelineState(flareFinish)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(result, offset: 0, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<FlareParameters>.stride, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        return true
    }

    private func makePrivateBuffer(length: Int) -> MTLBuffer? {
        guard length > 0 else { return nil }
        return device.makeBuffer(length: length, options: .storageModePrivate)
    }

    private static func makeDecodeTexture(device: MTLDevice) -> MTLTexture? {
        var values = [Float16](repeating: 0, count: 256)
        for index in values.indices {
            let value = ColorScience.srgbToLinear(Float(index) / 255)
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

    private func inputByteCount(mode: InputMode, width: Int, height: Int) -> Int {
        let bytesPerPixel: Int
        switch mode {
        case .encodedDisplayP3RGBA8:
            bytesPerPixel = 4
        case .linearRec2020RGBA16Float:
            bytesPerPixel = 4 * MemoryLayout<Float16>.stride
        case .linearRec2020RGBA32Float:
            bytesPerPixel = 4 * MemoryLayout<Float>.stride
        }
        return width * height * bytesPerPixel
    }

    private func validRecordExposure(_ texture: MTLTexture, resources: Resources) -> Bool {
        let format: MTLPixelFormat = resources.mode == .encodedDisplayP3RGBA8
            ? .rgba16Float : .rgba32Float
        return texture.device.registryID == device.registryID
            && texture.textureType == .type2D
            && texture.pixelFormat == format
            && texture.width == resources.width && texture.height == resources.height
            && texture.depth == 1 && texture.arrayLength == 1
            && texture.mipmapLevelCount == 1 && texture.sampleCount == 1
            && texture.usage.contains(.shaderRead)
    }

    private func validInputTexture(
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

    /// Camera-plane kernels use normalized coordinates, so a smaller measurement lattice can
    /// sample the complete native source without materializing a resized YCbCr frame. Requiring
    /// the same aspect ratio prevents an accidental crop or stretch from changing metering.
    private func validCaptureTextures(
        luma: MTLTexture, chroma: MTLTexture,
        lumaFormat: MTLPixelFormat, chromaFormat: MTLPixelFormat,
        outputWidth: Int, outputHeight: Int
    ) -> Bool {
        validInputTexture(
            luma, format: lumaFormat, width: luma.width, height: luma.height)
            && validInputTexture(
                chroma, format: chromaFormat,
                width: (luma.width + 1) / 2, height: (luma.height + 1) / 2)
            && luma.width >= outputWidth && luma.height >= outputHeight
            && luma.width * outputHeight == luma.height * outputWidth
    }

    private func dispatchCells(
        _ encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState, count: Int
    ) {
        let width = min(pipeline.threadExecutionWidth,
                        pipeline.maxTotalThreadsPerThreadgroup)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: max(1, width), height: 1, depth: 1))
    }

    private func retain(_ values: [AnyObject], untilCompletedBy buffer: MTLCommandBuffer) {
        buffer.addCompletedHandler { _ in withExtendedLifetime(values) {} }
    }

    private func checkedProduct(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? nil : result.partialValue
    }

    private static func divideRoundUp(_ value: Int, _ divisor: Int) -> Int {
        value / divisor + (value % divisor == 0 ? 0 : 1)
    }

}
#endif
