#if canImport(Metal)
import Foundation
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The scene and print endpoints around the hand-written spatial renderer.
///
/// Preparation uploads immutable spectral and curve tables. Encoding only records work into a
/// caller-owned command buffer: it never commits or waits. The split is deliberately at physical
/// record exposure and developed density, so no nonlinear film or print operation is moved across
/// a spatial stage.
public final class HandwrittenMetalFrameEndpoints {
    public enum InputMode: Sendable, Equatable {
        /// Transfer-encoded Display P3, tightly packed as premultiplied RGBA8.
        case encodedDisplayP3RGBA8
        /// Scene-linear Rec.2020, tightly packed as RGBA16F.
        case linearRec2020RGBA16Float
    }

    /// A solved local-tone grid and whole-frame pre-emulsion glare measurement.
    ///
    /// Construct this from an invocation after its whole-frame measurement pass. Keeping the
    /// resource separate makes it impossible for preparation to mistake the invocation's identity
    /// default grid or unset glare sentinel for a completed measurement.
    public struct MeasurementResources: Sendable {
        public struct ToneGrid: Sendable {
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

        public let toneGrid: ToneGrid?
        public let flareMean: SIMD3<Float>?

        public init(toneGrid: ToneGrid? = nil, flareMean: SIMD3<Float>? = nil) {
            self.toneGrid = toneGrid
            self.flareMean = flareMean
        }

        /// Captures the solved values from a measured invocation.
        public init(measuredInvocation invocation: FilmEngineInvocation) {
            if invocation.localToneActive {
                let width = max(1, Int(invocation.configuration[
                    FilmEngineInvocation.toneGridSizeOffset]))
                let height = max(1, Int(invocation.configuration[
                    FilmEngineInvocation.toneGridSizeOffset + 1]))
                let count = width * height
                let aStart = FilmEngineInvocation.toneGridAOffset
                let bStart = FilmEngineInvocation.toneGridBOffset
                toneGrid = ToneGrid(
                    width: width, height: height,
                    a: Array(invocation.configuration[aStart..<(aStart + count)]),
                    b: Array(invocation.configuration[bStart..<(bStart + count)]))
            } else {
                toneGrid = nil
            }
            flareMean = invocation.featureMask & FilmEngineFeature.flare != 0
                ? invocation.flareMean : nil
        }
    }

    public enum PreparationError: Swift.Error, CustomStringConvertible {
        case invalidDimensions
        case invocationSizeMismatch
        case unsupportedPipelineSpan
        case missingToneMeasurement
        case invalidToneMeasurement
        case missingFlareMeasurement
        case invalidFlareMeasurement
        case malformedSpectralTable(String)
        case allocationFailed(String)
        case metalCompilation(String)

        public var description: String {
            switch self {
            case .invalidDimensions:
                return "frame dimensions must be positive"
            case .invocationSizeMismatch:
                return "the invocation and endpoint frame dimensions differ"
            case .unsupportedPipelineSpan:
                return "the handwritten endpoints require a full-frame, full-pipeline invocation"
            case .missingToneMeasurement:
                return "active local tone requires a solved whole-frame tone grid"
            case .invalidToneMeasurement:
                return "the supplied local-tone grid is malformed"
            case .missingFlareMeasurement:
                return "active veiling glare requires a whole-frame exposure mean"
            case .invalidFlareMeasurement:
                return "the supplied veiling-glare mean is not finite and nonnegative"
            case let .malformedSpectralTable(name):
                return "the \(name) spectral table is malformed"
            case let .allocationFailed(name):
                return "unable to allocate \(name)"
            case let .metalCompilation(message):
                return "Metal compilation failed: \(message)"
            }
        }
    }

    static let curveSamples = 2_048
    static let transferSamples = 1_024
    private static let fullSpanBits = FilmEngineFeature.densityOut
        | FilmEngineFeature.densityIn | FilmEngineFeature.flareMeasure
        | FilmEngineFeature.encodeOut | FilmEngineFeature.lightOut
        | FilmEngineFeature.fieldsIn | FilmEngineFeature.texture

    private struct FrameParameters {
        var width: UInt32
        var height: UInt32
        var frameWidth: UInt32
        var seed: UInt32
        var inputGain: Float
        var padding0: UInt32 = 0
        var padding1: UInt32 = 0
        var padding2: UInt32 = 0
    }

    private struct HeadPipelineKey: Hashable {
        let mode: UInt8
        let tone: Bool
        let chroma: Bool
    }

    private struct TailPipelineKey: Hashable {
        let mode: UInt8
        let reversal: Bool
        let monochrome: Bool
        let grade: Bool
        let encodedGrade: Bool
    }

    private struct Prepared {
        let mode: InputMode
        let width: Int
        let height: Int
        let baseSeed: UInt32
        let flareMean: SIMD3<Float>?
        let configuration: MTLBuffer
        let exposureFaces: MTLTexture
        let film: MTLTexture
        let paper: MTLTexture
        let paperCurve: MTLTexture
        let headPipeline: MTLComputePipelineState
        let tailPipeline: MTLComputePipelineState
    }

    private let device: MTLDevice
    private let library: MTLLibrary
    private let decode: MTLTexture
    private let transfer: MTLTexture
    private let lock = NSLock()
    private var prepared: [String: Prepared] = [:]
    private var headPipelines: [HeadPipelineKey: MTLComputePipelineState] = [:]
    private var tailPipelines: [TailPipelineKey: MTLComputePipelineState] = [:]

    public convenience init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.init(device: device)
    }

    public init?(device: MTLDevice) {
        let options = MTLCompileOptions()
        // Runtime tables retain their explicit float/half storage contracts. Fast Metal
        // arithmetic materially improves the per-pixel spectral head on Apple GPUs; the focused
        // endpoint parity suite bounds the resulting error against the canonical schedule.
        options.fastMathEnabled = true
        do {
            library = try HandwrittenMetalShaderLibrary.makeLibrary(
                device: device, shader: .frameEndpoints, options: options,
                preprocessorMacros: [
                    "FOTUFILM_ENDPOINT_CURVE_SAMPLES": NSNumber(value: Self.curveSamples),
                    "FOTUFILM_ENDPOINT_TRANSFER_SAMPLES": NSNumber(
                        value: Self.transferSamples),
                ])
        } catch {
            print("HandwrittenMetalFrameEndpoints: Metal library failed (\(error))")
            return nil
        }
        guard let decode = Self.makeDecodeTexture(device: device),
              let transfer = Self.makeTransferTexture(device: device) else { return nil }
        self.device = device
        self.decode = decode
        self.transfer = transfer
    }

    /// Intermediate storage required by a prepared mode.
    public static func intermediatePixelFormat(for mode: InputMode) -> MTLPixelFormat {
        switch mode {
        case .encodedDisplayP3RGBA8: return .rgba16Float
        case .linearRec2020RGBA16Float: return .rgba32Float
        }
    }

    /// Prepares tables and compile-time-specialized endpoint pipelines for one immutable edit.
    public func prepareChecked(
        key: String, invocation source: FilmEngineInvocation,
        mode: InputMode, frameWidth: Int, frameHeight: Int,
        measurements: MeasurementResources? = nil
    ) throws {
        guard frameWidth > 0, frameHeight > 0 else {
            throw PreparationError.invalidDimensions
        }
        guard Int(source.configuration[FilmEngineInvocation.frameSizeOffset]) == frameWidth,
              Int(source.configuration[FilmEngineInvocation.frameSizeOffset + 1]) == frameHeight
        else { throw PreparationError.invocationSizeMismatch }
        guard source.featureMask & Self.fullSpanBits == 0 else {
            throw PreparationError.unsupportedPipelineSpan
        }

        var configuration = source.configuration
        if source.localToneActive {
            guard let tone = measurements?.toneGrid else {
                throw PreparationError.missingToneMeasurement
            }
            let count = tone.width * tone.height
            guard tone.width > 0, tone.height > 0,
                  count <= FilmEngineInvocation.toneGridCells,
                  tone.a.count == count, tone.b.count == count,
                  tone.a.allSatisfy(\.isFinite), tone.b.allSatisfy(\.isFinite)
            else { throw PreparationError.invalidToneMeasurement }
            configuration[FilmEngineInvocation.toneGridSizeOffset] = Float(tone.width)
            configuration[FilmEngineInvocation.toneGridSizeOffset + 1] = Float(tone.height)
            for index in 0..<count {
                configuration[FilmEngineInvocation.toneGridAOffset + index] = tone.a[index]
                configuration[FilmEngineInvocation.toneGridBOffset + index] = tone.b[index]
            }
        }

        var flareMean: SIMD3<Float>?
        if source.featureMask & FilmEngineFeature.flare != 0 {
            guard let supplied = measurements?.flareMean else {
                throw PreparationError.missingFlareMeasurement
            }
            guard Self.validFlareMean(supplied) else {
                throw PreparationError.invalidFlareMeasurement
            }
            flareMean = supplied
            configuration[FilmEngineInvocation.flareMeanOffset] = supplied.x
            configuration[FilmEngineInvocation.flareMeanOffset + 1] = supplied.y
            configuration[FilmEngineInvocation.flareMeanOffset + 2] = supplied.z
        }

        let reversal = source.featureMask & FilmEngineFeature.reversal != 0
        let monochrome = source.featureMask & FilmEngineFeature.monochrome != 0
        let gradeBase = FilmEngineInvocation.gradeOffset
        let grade = (0..<3).contains { configuration[gradeBase + $0] != 0 }
            || (0..<3).contains { configuration[gradeBase + 3 + $0] != 1 }
            || (0..<3).contains { configuration[gradeBase + 6 + $0] != 1 }
        let encodedGrade = configuration[FilmEngineInvocation.gradeSpaceOffset] != 0
        let tone = configuration[FilmEngineInvocation.sceneAdjustOffset] != 0
            || configuration[FilmEngineInvocation.sceneAdjustOffset + 1] != 0
        let chroma = configuration[FilmEngineInvocation.sceneAdjustOffset + 2] != 1
            || configuration[FilmEngineInvocation.sceneAdjustOffset + 3] != 0

        guard let configurationBuffer = makeBuffer(configuration) else {
            throw PreparationError.allocationFailed("configuration buffer")
        }
        guard let exposure = makeExposureFaces(source.spectral.exposure) else {
            throw PreparationError.malformedSpectralTable("exposure")
        }
        guard let film = makeCube(source.spectral.filmOutput) else {
            throw PreparationError.malformedSpectralTable("film-output")
        }
        let paper: MTLTexture
        if reversal {
            // A specialized reversal kernel never reads paper. Metal still requires a valid
            // binding for the statically-declared argument, so reuse the film cube without a
            // second allocation.
            paper = film
        } else {
            guard let table = source.spectral.paperOutput,
                  let uploaded = makeCube(table) else {
                throw PreparationError.malformedSpectralTable("paper-output")
            }
            paper = uploaded
        }
        guard let paperCurve = makePaperCurve(configuration) else {
            throw PreparationError.allocationFailed("paper curve texture")
        }

        let modeValue: UInt8 = mode == .encodedDisplayP3RGBA8 ? 0 : 1
        let headKey = HeadPipelineKey(mode: modeValue, tone: tone, chroma: chroma)
        let tailKey = TailPipelineKey(
            mode: modeValue, reversal: reversal, monochrome: monochrome,
            grade: grade, encodedGrade: encodedGrade)
        let headPipeline = try pipeline(for: headKey)
        let tailPipeline = try pipeline(for: tailKey)
        let value = Prepared(
            mode: mode, width: frameWidth, height: frameHeight,
            baseSeed: source.seed, flareMean: flareMean,
            configuration: configurationBuffer, exposureFaces: exposure,
            film: film, paper: paper, paperCurve: paperCurve,
            headPipeline: headPipeline, tailPipeline: tailPipeline)
        lock.lock()
        prepared[key] = value
        lock.unlock()
    }

    /// Compatibility convenience for callers that select another renderer on failure.
    @discardableResult
    public func prepare(
        key: String, invocation: FilmEngineInvocation,
        mode: InputMode, frameWidth: Int, frameHeight: Int,
        measurements: MeasurementResources? = nil
    ) -> Bool {
        do {
            try prepareChecked(
                key: key, invocation: invocation, mode: mode,
                frameWidth: frameWidth, frameHeight: frameHeight,
                measurements: measurements)
            return true
        } catch {
            return false
        }
    }

    /// Encodes scene input to physical record exposure. Donor exposure is retained in W.
    @discardableResult
    public func encodeHead(
        input: MTLBuffer, recordExposure: MTLTexture,
        key: String, frameIndex: UInt64 = 0, inputGain: Float = 1,
        originX: Int = 0, originY: Int = 0,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard originX == 0, originY == 0,
              inputGain.isFinite, inputGain >= 0,
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              validIntermediate(recordExposure, requiresWrite: true)
        else { return false }
        lock.lock()
        let state = prepared[key]
        lock.unlock()
        guard let state,
              recordExposure.pixelFormat == Self.intermediatePixelFormat(for: state.mode),
              recordExposure.width == state.width, recordExposure.height == state.height,
              input.length >= inputByteCount(mode: state.mode,
                                             width: state.width, height: state.height),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        var parameters = FrameParameters(
            width: UInt32(state.width), height: UInt32(state.height),
            frameWidth: UInt32(state.width),
            seed: animatedSeed(base: state.baseSeed, frameIndex: frameIndex),
            inputGain: inputGain)
        retain(
            [self, input, recordExposure, state.configuration,
             state.exposureFaces, decode, state.headPipeline],
            untilCompletedBy: commandBuffer)
        encoder.label = "Fotufilm handwritten scene-to-record endpoint"
        encoder.setComputePipelineState(state.headPipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(state.configuration, offset: 0, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<FrameParameters>.stride, index: 2)
        encoder.setTexture(state.exposureFaces, index: 0)
        encoder.setTexture(recordExposure, index: 1)
        if state.mode == .encodedDisplayP3RGBA8 { encoder.setTexture(decode, index: 2) }
        dispatch(encoder, pipeline: state.headPipeline,
                 width: state.width, height: state.height)
        encoder.endEncoding()
        return true
    }

    /// Encodes developed density to the delivery buffer, taking alpha from the original input.
    @discardableResult
    public func encodeTail(
        developedDensity: MTLTexture, originalInput: MTLBuffer,
        output: MTLBuffer, key: String, frameIndex: UInt64 = 0,
        originX: Int = 0, originY: Int = 0,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard originX == 0, originY == 0,
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              validIntermediate(developedDensity, requiresWrite: false)
        else { return false }
        lock.lock()
        let state = prepared[key]
        lock.unlock()
        let bytes = state.map {
            inputByteCount(mode: $0.mode, width: $0.width, height: $0.height)
        } ?? 0
        guard let state,
              developedDensity.pixelFormat == Self.intermediatePixelFormat(for: state.mode),
              developedDensity.width == state.width,
              developedDensity.height == state.height,
              originalInput.length >= bytes, output.length >= bytes,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        var parameters = FrameParameters(
            width: UInt32(state.width), height: UInt32(state.height),
            frameWidth: UInt32(state.width),
            seed: animatedSeed(base: state.baseSeed, frameIndex: frameIndex),
            inputGain: 1)
        retain(
            [self, developedDensity, originalInput, output, state.configuration,
             state.film, state.paper, state.paperCurve, transfer,
             state.tailPipeline], untilCompletedBy: commandBuffer)
        encoder.label = "Fotufilm handwritten density-to-print endpoint"
        encoder.setComputePipelineState(state.tailPipeline)
        encoder.setBuffer(originalInput, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBuffer(state.configuration, offset: 0, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<FrameParameters>.stride, index: 3)
        encoder.setTexture(developedDensity, index: 0)
        encoder.setTexture(state.film, index: 1)
        encoder.setTexture(state.paperCurve, index: 2)
        encoder.setTexture(state.paper, index: 3)
        if state.mode == .encodedDisplayP3RGBA8 { encoder.setTexture(transfer, index: 4) }
        dispatch(encoder, pipeline: state.tailPipeline,
                 width: state.width, height: state.height)
        encoder.endEncoding()
        return true
    }

    /// The measured pre-emulsion exposure mean to pass to the spatial executor.
    public func preparedFlareMean(forKey key: String) -> SIMD3<Float>? {
        lock.lock()
        defer { lock.unlock() }
        return prepared[key]?.flareMean
    }

    public func removeAll() {
        lock.lock()
        prepared.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func pipeline(for key: HeadPipelineKey) throws -> MTLComputePipelineState {
        lock.lock()
        if let existing = headPipelines[key] {
            lock.unlock()
            return existing
        }
        lock.unlock()
        let constants = MTLFunctionConstantValues()
        var tone = key.tone
        var chroma = key.chroma
        constants.setConstantValue(&tone, type: .bool, index: 4)
        constants.setConstantValue(&chroma, type: .bool, index: 5)
        let name = key.mode == 0 ? "fotufilm_endpoint_head_sdr" : "fotufilm_endpoint_head_hdr"
        do {
            let function = try library.makeFunction(name: name, constantValues: constants)
            let pipeline = try device.makeComputePipelineState(function: function)
            lock.lock()
            headPipelines[key] = pipeline
            lock.unlock()
            return pipeline
        } catch {
            throw PreparationError.metalCompilation(error.localizedDescription)
        }
    }

    private func pipeline(for key: TailPipelineKey) throws -> MTLComputePipelineState {
        lock.lock()
        if let existing = tailPipelines[key] {
            lock.unlock()
            return existing
        }
        lock.unlock()
        let constants = MTLFunctionConstantValues()
        var reversal = key.reversal
        var monochrome = key.monochrome
        var grade = key.grade
        var encoded = key.encodedGrade
        constants.setConstantValue(&reversal, type: .bool, index: 0)
        constants.setConstantValue(&monochrome, type: .bool, index: 1)
        constants.setConstantValue(&grade, type: .bool, index: 2)
        constants.setConstantValue(&encoded, type: .bool, index: 3)
        let name = key.mode == 0 ? "fotufilm_endpoint_tail_sdr" : "fotufilm_endpoint_tail_hdr"
        do {
            let function = try library.makeFunction(name: name, constantValues: constants)
            let pipeline = try device.makeComputePipelineState(function: function)
            lock.lock()
            tailPipelines[key] = pipeline
            lock.unlock()
            return pipeline
        } catch {
            throw PreparationError.metalCompilation(error.localizedDescription)
        }
    }

    private func makeBuffer(_ values: [Float]) -> MTLBuffer? {
        values.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }
    }

    private func makeExposureFaces(_ table: SpectralLUT) -> MTLTexture? {
        let edge = table.dimension
        guard edge >= 2, table.values.count == edge * edge * edge * 4 else { return nil }
        var faces = [Float](repeating: 0, count: 3 * edge * edge * 4)
        @inline(__always)
        func sourceIndex(_ x: Int, _ y: Int, _ z: Int) -> Int {
            ((z * edge + y) * edge + x) * 4
        }
        for face in 0..<3 {
            for v in 0..<edge {
                for u in 0..<edge {
                    let coordinate: (Int, Int, Int)
                    switch face {
                    case 0: coordinate = (edge - 1, u, v)
                    case 1: coordinate = (u, edge - 1, v)
                    default: coordinate = (u, v, edge - 1)
                    }
                    let source = sourceIndex(coordinate.0, coordinate.1, coordinate.2)
                    let destination = ((face * edge + v) * edge + u) * 4
                    for channel in 0..<4 {
                        let value = table.values[source + channel]
                        guard value.isFinite else { return nil }
                        faces[destination + channel] = value
                    }
                }
            }
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = edge
        descriptor.height = edge
        descriptor.arrayLength = 3
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let rowBytes = edge * 4 * MemoryLayout<Float>.stride
        let faceBytes = edge * rowBytes
        faces.withUnsafeBytes { bytes in
            for face in 0..<3 {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, edge, edge),
                    mipmapLevel: 0, slice: face,
                    withBytes: bytes.baseAddress!.advanced(by: face * faceBytes),
                    bytesPerRow: rowBytes, bytesPerImage: faceBytes)
            }
        }
        return texture
    }

    private func makeCube(_ table: SpectralLUT) -> MTLTexture? {
        let edge = table.dimension
        guard edge >= 2, table.values.count == edge * edge * edge * 4,
              table.values.allSatisfy(\.isFinite) else { return nil }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = edge
        descriptor.height = edge
        descriptor.depth = edge
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        table.values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, edge, edge, edge),
                mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: edge * 4 * MemoryLayout<Float>.stride,
                bytesPerImage: edge * edge * 4 * MemoryLayout<Float>.stride)
        }
        return texture
    }

    private func makePaperCurve(_ configuration: [Float]) -> MTLTexture? {
        let bases = [FilmEngineInvocation.paperRedOffset, 33,
                     FilmEngineInvocation.paperBlueOffset]
        var values = [Float](repeating: 0, count: Self.curveSamples * 3)
        for channel in 0..<3 {
            for sample in 0..<Self.curveSamples {
                let exposure = -8 + 16 * Float(sample) / Float(Self.curveSamples - 1)
                let value = Self.curveDensity(
                    configuration, base: bases[channel], exposure: exposure)
                guard value.isFinite else { return nil }
                values[channel * Self.curveSamples + sample] = value
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: Self.curveSamples, height: 3,
            mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, Self.curveSamples, 3),
                mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: Self.curveSamples * MemoryLayout<Float>.stride)
        }
        return texture
    }

    private static func curveDensity(
        _ configuration: [Float], base: Int, exposure: Float
    ) -> Float {
        let dMin = configuration[base]
        let gamma = configuration[base + 1]
        let toe = configuration[base + 2]
        let toeWidth = max(configuration[base + 3], 1e-6)
        let shoulder = configuration[base + 4]
        let shoulderWidth = max(configuration[base + 5], 1e-6)
        let toeTerm = toeWidth * softplus((exposure - toe) / toeWidth)
        let shoulderTerm = shoulderWidth
            * softplus((exposure - shoulder) / shoulderWidth)
        return dMin + gamma * min(max(toeTerm - shoulderTerm, 0), shoulder - toe)
    }

    private static func softplus(_ value: Float) -> Float {
        if value > 20 { return value }
        if value < -20 { return exp(value) }
        return log1p(exp(value))
    }

    private static func makeDecodeTexture(device: MTLDevice) -> MTLTexture? {
        var values = [Float](repeating: 0, count: transferSamples)
        for index in values.indices {
            values[index] = ColorScience.srgbToLinear(
                Float(index) / Float(transferSamples - 1))
        }
        return make1DTexture(device: device, values: values)
    }

    private static func makeTransferTexture(device: MTLDevice) -> MTLTexture? {
        var values = [Float](repeating: 0, count: transferSamples)
        for index in values.indices {
            let root = Float(index) / Float(transferSamples - 1)
            values[index] = ColorScience.linearToSrgb(root * root)
        }
        return make1DTexture(device: device, values: values)
    }

    private static func make1DTexture(device: MTLDevice, values: [Float]) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.pixelFormat = .r32Float
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

    private func validIntermediate(_ texture: MTLTexture, requiresWrite: Bool) -> Bool {
        texture.device.registryID == device.registryID
            && texture.textureType == .type2D
            && texture.sampleCount == 1
            && texture.mipmapLevelCount == 1
            && texture.arrayLength == 1
            && texture.depth == 1
            && texture.usage.contains(.shaderRead)
            && (!requiresWrite || texture.usage.contains(.shaderWrite))
    }

    private func inputByteCount(mode: InputMode, width: Int, height: Int) -> Int {
        let bytesPerPixel = mode == .encodedDisplayP3RGBA8
            ? 4 : 4 * MemoryLayout<Float16>.stride
        return width * height * bytesPerPixel
    }

    private func animatedSeed(base: UInt32, frameIndex: UInt64) -> UInt32 {
        base &+ UInt32(truncatingIfNeeded: frameIndex &* 0x9E3779B97F4A7C15)
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
        width: Int, height: Int
    ) {
        let groupWidth = min(pipeline.threadExecutionWidth, 32)
        let groupHeight = max(1, min(8,
            pipeline.maxTotalThreadsPerThreadgroup / max(groupWidth, 1)))
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: groupWidth, height: groupHeight, depth: 1))
    }

    private func retain(_ resources: [AnyObject], untilCompletedBy buffer: MTLCommandBuffer) {
        buffer.addCompletedHandler { _ in withExtendedLifetime(resources) {} }
    }

    private static func validFlareMean(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
            && value.x >= 0 && value.y >= 0 && value.z >= 0
    }

}
#endif
