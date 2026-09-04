#if canImport(Metal)
import Foundation
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// A compact post-spatial density-to-delivery endpoint.
///
/// The spectral film LUT, paper curves, spectral paper LUT, monochrome conversion, and colour
/// grade are immutable for an edit. Preparation evaluates that complete mapping directly from the
/// invocation's data-driven spectral tables into one cube for HDR. SDR keeps the final spectral
/// paper LUT exact and bakes everything before it into a compact paper-activation cube. A fully
/// composed output cube smears narrow, piecewise-spectral near-black transitions between lattice
/// points; retaining the final 33-cube preserves those transitions while still removing the film
/// LUT and all three paper-curve reads from the frame loop. The physical seam remains developed
/// density, so spatial stages stay on the correct side of printing.
public final class HandwrittenMetalCompositeTail {
    public typealias OutputMode = HandwrittenMetalFrameEndpoints.InputMode

    /// `baseline3D` is retained for accuracy and device A/B measurements. The oriented layout
    /// duplicates each cube in X-, Y-, and Z-edge order so a tetrahedron needs two cache-friendly
    /// bilinear samples instead of filtered 3D reads or four scattered loads.
    public enum LookupLayout: Sendable {
        case baseline3D
        case oriented2DArray
        case composed129WarpedTetrahedral
        case composed129WarpedTrilinear
    }

    public enum PreparationError: Swift.Error, CustomStringConvertible {
        case invalidDimensions
        case invocationSizeMismatch
        case unsupportedPipelineSpan
        case unsupportedOutputMode
        case allocationFailed(String)
        case bakeFailed

        public var description: String {
            switch self {
            case .invalidDimensions:
                return "frame dimensions must be positive"
            case .invocationSizeMismatch:
                return "the invocation and tail frame dimensions differ"
            case .unsupportedPipelineSpan:
                return "the composite tail requires a full-pipeline invocation"
            case .unsupportedOutputMode:
                return "composed response layouts are available only for the linear HDR master"
            case let .allocationFailed(resource):
                return "unable to allocate \(resource)"
            case .bakeFailed:
                return "the native density-to-print cube bake failed"
            }
        }
    }

    private static let cubeEdge = 65
    private static let composedCubeEdge = 129
    private static let warpSegments = 16
    private static let curveSamples = 2_048
    private static let transferSamples = 1_024
    private static let transferValues: [Float16] = (0..<transferSamples).map { index in
        let root = Float(index) / Float(transferSamples - 1)
        return Float16(ColorScience.linearToSrgb(root * root))
    }
    private static let identityWarpKnots: [Float] = (0..<3).flatMap { _ in
        (0...warpSegments).map { Float($0) / Float(warpSegments) }
    }
    private static let fullSpanBits = FilmEngineFeature.densityOut
        | FilmEngineFeature.densityIn | FilmEngineFeature.flareMeasure
        | FilmEngineFeature.encodeOut | FilmEngineFeature.lightOut
        | FilmEngineFeature.fieldsIn | FilmEngineFeature.texture

    private struct FrameParameters {
        var width: UInt32
        var height: UInt32
        var frameWidth: UInt32
        var seed: UInt32
        var minimum: SIMD4<Float>
        var inverseRange: SIMD4<Float>
        var gradeLift: SIMD4<Float>
        var gradeGain: SIMD4<Float>
        var gradeExponent: SIMD4<Float>
        var flags: SIMD4<UInt32>
    }

    private struct Prepared {
        let mode: OutputMode
        let width: Int
        let height: Int
        let baseSeed: UInt32
        let minimum: SIMD4<Float>
        let inverseRange: SIMD4<Float>
        let printCube: MTLTexture
        let paperCube: MTLTexture
        let gradeLift: SIMD4<Float>
        let gradeGain: SIMD4<Float>
        let gradeExponent: SIMD4<Float>
        let flags: SIMD4<UInt32>
        let warpKnots: [Float]
    }

    /// Immutable subset consumed by the spatial executor's exact camera endpoint. Keeping this
    /// binding package-owned prevents the fused kernel from becoming a second print-cube baker.
    struct LinearHDRBinding {
        let width: Int
        let height: Int
        let minimum: SIMD4<Float>
        let inverseRange: SIMD4<Float>
        let printCube: MTLTexture
    }

    private struct WarpedCube {
        let texture: MTLTexture
        let warpKnots: [Float]
    }

    private let device: MTLDevice
    private let lookupLayout: LookupLayout
    private let uploadQueue: MTLCommandQueue
    private let sdrPipeline: MTLComputePipelineState
    private let hdrPipeline: MTLComputePipelineState
    private let hdrTexturePipeline: MTLComputePipelineState
    private let transfer: MTLTexture
    private let lock = NSLock()
    private var prepared: [String: Prepared] = [:]

    public convenience init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.init(device: device)
    }

    public convenience init?(device: MTLDevice) {
        self.init(device: device, lookupLayout: .oriented2DArray)
    }

    public init?(device: MTLDevice, lookupLayout: LookupLayout) {
        guard let uploadQueue = device.makeCommandQueue(),
              let transfer = Self.makeTransferTexture(device: device)
        else { return nil }
        let options = MTLCompileOptions()
        options.fastMathEnabled = true
        do {
            let library = try HandwrittenMetalShaderLibrary.makeLibrary(
                device: device, shader: .compositeTail, options: options)
            let suffix: String
            switch lookupLayout {
            case .baseline3D:
                suffix = "baseline"
            case .oriented2DArray:
                suffix = "oriented"
            case .composed129WarpedTetrahedral:
                suffix = "composed_tetrahedral"
            case .composed129WarpedTrilinear:
                suffix = "composed_trilinear"
            }
            guard let sdr = library.makeFunction(
                    name: "fotufilm_composite_tail_sdr_\(suffix)"),
                  let hdr = library.makeFunction(
                    name: "fotufilm_composite_tail_hdr_\(suffix)"),
                  let hdrTexture = library.makeFunction(
                    name: "fotufilm_composite_tail_hdr_texture_\(suffix)")
            else { return nil }
            sdrPipeline = try device.makeComputePipelineState(function: sdr)
            hdrPipeline = try device.makeComputePipelineState(function: hdr)
            hdrTexturePipeline = try device.makeComputePipelineState(function: hdrTexture)
        } catch {
            print("HandwrittenMetalCompositeTail: Metal library failed (\(error))")
            return nil
        }
        self.device = device
        self.lookupLayout = lookupLayout
        self.uploadQueue = uploadQueue
        self.transfer = transfer
    }

    /// Bakes immutable print chemistry for one edit. The bake is preparation-time work only.
    public func prepareChecked(
        key: String, invocation source: FilmEngineInvocation,
        mode: OutputMode, frameWidth: Int, frameHeight: Int
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
        guard !usesComposedCube || mode == .linearRec2020RGBA16Float else {
            throw PreparationError.unsupportedOutputMode
        }

        let minimum = SIMD4<Float>(
            source.configuration[0], source.configuration[6],
            source.configuration[12], 0)
        let ranges = SIMD4<Float>(
            Self.filmCurveRange(configuration: source.configuration, channel: 0),
            Self.filmCurveRange(configuration: source.configuration, channel: 1),
            Self.filmCurveRange(configuration: source.configuration, channel: 2), 1)
        guard minimum.x.isFinite, minimum.y.isFinite, minimum.z.isFinite,
              ranges.x.isFinite, ranges.y.isFinite, ranges.z.isFinite,
              ranges.x > 0, ranges.y > 0, ranges.z > 0
        else { throw PreparationError.bakeFailed }
        let cube: MTLTexture
        let warpKnots: [Float]
        if usesComposedCube {
            guard let composed = makeWarpedComposedCube(
                invocation: source, mode: mode)
            else { throw PreparationError.bakeFailed }
            cube = composed.texture
            warpKnots = composed.warpKnots
        } else if mode == .encodedDisplayP3RGBA8 {
            guard let activation = makeSDRActivationCube(invocation: source) else {
                throw PreparationError.bakeFailed
            }
            cube = activation
            warpKnots = Self.identityWarpKnots
        } else {
            guard let linear = bakeHDRPrintCube(invocation: source) else {
                throw PreparationError.bakeFailed
            }
            cube = linear
            warpKnots = Self.identityWarpKnots
        }

        let gradeBase = FilmEngineInvocation.gradeOffset
        let gradeLift = SIMD4<Float>(
            source.configuration[gradeBase], source.configuration[gradeBase + 1],
            source.configuration[gradeBase + 2], 0)
        let gradeGain = SIMD4<Float>(
            source.configuration[gradeBase + 3], source.configuration[gradeBase + 4],
            source.configuration[gradeBase + 5], 1)
        let gradeExponent = SIMD4<Float>(
            source.configuration[gradeBase + 6], source.configuration[gradeBase + 7],
            source.configuration[gradeBase + 8], 1)
        let gradeActive = gradeLift.x != 0 || gradeLift.y != 0 || gradeLift.z != 0
            || gradeGain.x != 1 || gradeGain.y != 1 || gradeGain.z != 1
            || gradeExponent.x != 1 || gradeExponent.y != 1 || gradeExponent.z != 1
        let flags = SIMD4<UInt32>(
            source.featureMask & FilmEngineFeature.reversal != 0 ? 1 : 0,
            source.featureMask & FilmEngineFeature.monochrome != 0 ? 1 : 0,
            gradeActive ? 1 : 0,
            source.configuration[FilmEngineInvocation.gradeSpaceOffset] != 0 ? 1 : 0)
        let paperCube: MTLTexture
        if mode != .encodedDisplayP3RGBA8 || usesComposedCube {
            // The HDR cube already contains the complete tail; keep one retained placeholder.
            paperCube = cube
        } else if lookupLayout == .oriented2DArray {
            if flags.x != 0 {
                // Reversal has no paper stage. Its exact mono/grade/transfer remains in the
                // shader, and the bound placeholder is never sampled.
                paperCube = cube
            } else {
                guard let orientedPaperCube = makeSDROrientedPaperCube(
                    invocation: source)
                else {
                    throw PreparationError.allocationFailed("oriented SDR paper cube")
                }
                paperCube = orientedPaperCube
            }
        } else {
            let paperValues = source.spectral.paperOutput?.values
                ?? source.spectral.filmOutput.values
            let paperEdge = source.spectral.paperOutput?.dimension
                ?? source.spectral.filmOutput.dimension
            guard let exactPaperCube = uploadCube(
                values: paperValues, edge: paperEdge, pixelFormat: .rgba32Float,
                label: "Fotufilm exact spectral paper cube")
            else { throw PreparationError.allocationFailed("spectral paper cube") }
            paperCube = exactPaperCube
        }

        let value = Prepared(
            mode: mode, width: frameWidth, height: frameHeight,
            baseSeed: source.seed, minimum: minimum,
            inverseRange: SIMD4(1 / ranges.x, 1 / ranges.y, 1 / ranges.z, 1),
            printCube: cube, paperCube: paperCube,
            gradeLift: gradeLift, gradeGain: gradeGain,
            gradeExponent: gradeExponent, flags: flags,
            warpKnots: warpKnots)
        lock.lock()
        prepared[key] = value
        lock.unlock()
    }

    /// Compatibility convenience for callers that select another renderer on preparation error.
    @discardableResult
    public func prepare(
        key: String, invocation: FilmEngineInvocation,
        mode: OutputMode, frameWidth: Int, frameHeight: Int
    ) -> Bool {
        do {
            try prepareChecked(
                key: key, invocation: invocation, mode: mode,
                frameWidth: frameWidth, frameHeight: frameHeight)
            return true
        } catch {
            return false
        }
    }

    /// Records one full-frame delivery pass into a caller-owned command buffer.
    ///
    /// Both modes consume RGBA16F developed density. SDR writes encoded premultiplied RGBA8;
    /// HDR writes nonnegative, otherwise-unclamped linear Display P3 RGBA16F. Alpha is copied
    /// from `originalInput` in both modes.
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
              validDensity(developedDensity)
        else { return false }
        lock.lock()
        let state = prepared[key]
        lock.unlock()
        guard let state,
              developedDensity.width == state.width,
              developedDensity.height == state.height,
              let byteCount = Self.byteCount(
                mode: state.mode, width: state.width, height: state.height),
              originalInput.length >= byteCount, output.length >= byteCount,
              originalInput.device.registryID == device.registryID,
              output.device.registryID == device.registryID,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        let pipeline = state.mode == .encodedDisplayP3RGBA8
            ? sdrPipeline : hdrPipeline
        var parameters = FrameParameters(
            width: UInt32(state.width), height: UInt32(state.height),
            frameWidth: UInt32(state.width),
            seed: Self.animatedSeed(base: state.baseSeed, frameIndex: frameIndex),
            minimum: state.minimum, inverseRange: state.inverseRange,
            gradeLift: state.gradeLift, gradeGain: state.gradeGain,
            gradeExponent: state.gradeExponent, flags: state.flags)
        var resources: [AnyObject] = [
            self, developedDensity, originalInput, output,
            state.printCube, state.paperCube, pipeline,
        ]
        if state.mode == .encodedDisplayP3RGBA8 { resources.append(transfer) }
        retain(resources, untilCompletedBy: commandBuffer)

        encoder.label = "Fotufilm composite density-to-delivery tail"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(originalInput, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBytes(
            &parameters, length: MemoryLayout<FrameParameters>.stride, index: 2)
        if usesComposedCube {
            state.warpKnots.withUnsafeBytes { bytes in
                encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 3)
            }
        }
        encoder.setTexture(developedDensity, index: 0)
        encoder.setTexture(state.printCube, index: 1)
        if state.mode == .encodedDisplayP3RGBA8 {
            encoder.setTexture(state.paperCube, index: 2)
            encoder.setTexture(transfer, index: 3)
        }
        dispatch(encoder, pipeline: pipeline, width: state.width, height: state.height)
        encoder.endEncoding()
        return true
    }

    /// Records the HDR delivery pass directly into a GPU-resident RGBA16F texture.
    ///
    /// The prepared key must use `linearRec2020RGBA16Float`. RGB is the same nonnegative,
    /// otherwise-unclamped linear master produced by the buffer API. Alpha is copied from the
    /// developed-density texture, allowing a fully texture-resident spatial-to-tail chain without
    /// retaining or reading the original shared input buffer.
    @discardableResult
    public func encodeTail(
        developedDensity: MTLTexture, output: MTLTexture,
        key: String, frameIndex: UInt64 = 0,
        originX: Int = 0, originY: Int = 0,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard originX == 0, originY == 0,
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              validDensity(developedDensity), validHDROutput(output),
              developedDensity !== output
        else { return false }
        lock.lock()
        let state = prepared[key]
        lock.unlock()
        guard let state,
              state.mode == .linearRec2020RGBA16Float,
              developedDensity.width == state.width,
              developedDensity.height == state.height,
              output.width == state.width, output.height == state.height,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        var parameters = FrameParameters(
            width: UInt32(state.width), height: UInt32(state.height),
            frameWidth: UInt32(state.width),
            seed: Self.animatedSeed(base: state.baseSeed, frameIndex: frameIndex),
            minimum: state.minimum, inverseRange: state.inverseRange,
            gradeLift: state.gradeLift, gradeGain: state.gradeGain,
            gradeExponent: state.gradeExponent, flags: state.flags)
        retain(
            [self, developedDensity, output, state.printCube, hdrTexturePipeline],
            untilCompletedBy: commandBuffer)

        encoder.label = "Fotufilm composite HDR texture tail"
        encoder.setComputePipelineState(hdrTexturePipeline)
        encoder.setBytes(
            &parameters, length: MemoryLayout<FrameParameters>.stride, index: 2)
        if usesComposedCube {
            state.warpKnots.withUnsafeBytes { bytes in
                encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 3)
            }
        }
        encoder.setTexture(developedDensity, index: 0)
        encoder.setTexture(state.printCube, index: 1)
        encoder.setTexture(output, index: 2)
        dispatch(
            encoder, pipeline: hdrTexturePipeline,
            width: state.width, height: state.height)
        encoder.endEncoding()
        return true
    }

    /// Returns the exact baseline HDR lookup used by `encodeTail`. The caller retains the binding
    /// until its command buffer completes, so replacing or removing a prepared edit is safe.
    func linearHDRBinding(forKey key: String) -> LinearHDRBinding? {
        guard lookupLayout == .baseline3D else { return nil }
        lock.lock()
        let state = prepared[key]
        lock.unlock()
        guard let state, state.mode == .linearRec2020RGBA16Float,
              state.printCube.textureType == .type3D,
              state.printCube.pixelFormat == .rgba16Float else { return nil }
        return LinearHDRBinding(
            width: state.width, height: state.height,
            minimum: state.minimum, inverseRange: state.inverseRange,
            printCube: state.printCube)
    }

    public func removeAll() {
        lock.lock()
        prepared.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func bakeHDRPrintCube(
        invocation source: FilmEngineInvocation
    ) -> MTLTexture? {
        guard let linear = bakeLinearCubeValues(
            invocation: source, edge: Self.cubeEdge,
            warpKnots: Self.identityWarpKnots)
        else { return nil }
        var values = [Float16]()
        values.reserveCapacity(linear.count)
        for value in linear {
            guard value.isFinite else { return nil }
            values.append(Float16(value))
        }
        return uploadLookup(
            values: values, edge: Self.cubeEdge, pixelFormat: .rgba16Float,
            label: "Fotufilm composite density-to-linear cube")
    }

    private func bakeLinearCubeValues(
        invocation source: FilmEngineInvocation, edge: Int,
        warpKnots: [Float]
    ) -> [Float]? {
        guard edge >= 2, warpKnots.count == 3 * (Self.warpSegments + 1) else {
            return nil
        }
        return HandwrittenPrintResponseBaker.linearCubeValues(
            invocation: source, edge: edge, warpKnots: warpKnots)
    }

    private func makeWarpedComposedCube(
        invocation: FilmEngineInvocation, mode: OutputMode
    ) -> WarpedCube? {
        let edge = Self.composedCubeEdge
        let shoulderKnee = FilmSDRDelivery.shoulderKnee(
            isReversal: invocation.featureMask & FilmEngineFeature.reversal != 0)
        guard let analysisLinear = bakeLinearCubeValues(
            invocation: invocation, edge: edge,
            warpKnots: Self.identityWarpKnots)
        else { return nil }
        var analysisSignal = [Float](repeating: 0, count: analysisLinear.count)
        for pixel in 0..<(edge * edge * edge) {
            for channel in 0..<3 {
                analysisSignal[pixel * 4 + channel] = Self.sdrSignal(
                    linear: analysisLinear[pixel * 4 + channel],
                    shoulderKnee: shoulderKnee)
            }
        }
        let warpKnots = Self.adaptiveWarpKnots(
            signal: analysisSignal, linear: analysisLinear, edge: edge)
        guard let warpedLinear = bakeLinearCubeValues(
            invocation: invocation, edge: edge, warpKnots: warpKnots)
        else { return nil }
        var values = [Float16](repeating: 0, count: warpedLinear.count)
        for pixel in 0..<(edge * edge * edge) {
            for channel in 0..<3 {
                let source = warpedLinear[pixel * 4 + channel]
                let value = mode == .encodedDisplayP3RGBA8
                    ? Self.sdrSignal(linear: source,
                                     shoulderKnee: shoulderKnee) : source
                guard value.isFinite else { return nil }
                values[pixel * 4 + channel] = Float16(value)
            }
            values[pixel * 4 + 3] = 1
        }
        guard let texture = uploadCube(
            values: values, edge: edge, pixelFormat: .rgba16Float,
            label: mode == .encodedDisplayP3RGBA8
                ? "Fotufilm warped composed density-to-SDR-signal cube"
                : "Fotufilm warped composed density-to-HDR-linear cube")
        else { return nil }
        return WarpedCube(texture: texture, warpKnots: warpKnots)
    }

    private static func adaptiveWarpKnots(
        signal: [Float], linear: [Float], edge: Int
    ) -> [Float] {
        precondition(edge % 2 == 1 && signal.count == edge * edge * edge * 4
                     && linear.count == signal.count)
        let bins = (edge - 1) / 2
        var result = [Float](repeating: 0, count: 3 * (warpSegments + 1))
        @inline(__always)
        func index(_ x: Int, _ y: Int, _ z: Int, _ channel: Int) -> Int {
            ((z * edge + y) * edge + x) * 4 + channel
        }
        for axis in 0..<3 {
            var weights = [Float](repeating: 1, count: bins)
            for bin in 0..<bins {
                let low = 2 * bin
                let middle = low + 1
                let high = low + 2
                var maximumCurvature: Float = 0
                var maximumSpan: Float = 0
                var maximumLinearCurvature: Float = 0
                var maximumLinearSpan: Float = 0
                for second in 0..<edge {
                    for first in 0..<edge {
                        let points: ((Int, Int, Int), (Int, Int, Int), (Int, Int, Int))
                        switch axis {
                        case 0:
                            points = ((low, first, second),
                                      (middle, first, second),
                                      (high, first, second))
                        case 1:
                            points = ((first, low, second),
                                      (first, middle, second),
                                      (first, high, second))
                        default:
                            points = ((first, second, low),
                                      (first, second, middle),
                                      (first, second, high))
                        }
                        for channel in 0..<3 {
                            let a = signal[index(
                                points.0.0, points.0.1, points.0.2, channel)]
                            let b = signal[index(
                                points.1.0, points.1.1, points.1.2, channel)]
                            let c = signal[index(
                                points.2.0, points.2.1, points.2.2, channel)]
                            maximumCurvature = max(
                                maximumCurvature, abs(b - (a + c) * 0.5))
                            maximumSpan = max(maximumSpan, abs(c - a))
                            let linearA = linear[index(
                                points.0.0, points.0.1, points.0.2, channel)]
                            let linearB = linear[index(
                                points.1.0, points.1.1, points.1.2, channel)]
                            let linearC = linear[index(
                                points.2.0, points.2.1, points.2.2, channel)]
                            maximumLinearCurvature = max(
                                maximumLinearCurvature,
                                abs(linearB - (linearA + linearC) * 0.5))
                            maximumLinearSpan = max(
                                maximumLinearSpan, abs(linearC - linearA))
                        }
                    }
                }
                let curvatureCodes = maximumCurvature * 255
                let spanCodes = maximumSpan * 255
                weights[bin] += min(curvatureCodes * 4, 96)
                    + min(spanCodes * 0.125, 8)
                    + min(maximumLinearCurvature * 64, 32)
                    + min(maximumLinearSpan * 2, 8)
            }
            let total = weights.reduce(0, +)
            let base = axis * (warpSegments + 1)
            result[base] = 0
            result[base + warpSegments] = 1
            var bin = 0
            var cumulative: Float = 0
            for knot in 1..<warpSegments {
                let target = total * Float(knot) / Float(warpSegments)
                while bin < bins - 1, cumulative + weights[bin] < target {
                    cumulative += weights[bin]
                    bin += 1
                }
                let fraction = min(max(
                    (target - cumulative) / max(weights[bin], 1e-6), 0), 1)
                result[base + knot] = (Float(bin) + fraction) / Float(bins)
            }
        }
        return result
    }

    private static func sdrSignal(
        linear value: Float, shoulderKnee: Float
    ) -> Float {
        let delivered = min(max(ColorScience.displayShoulder(
            value, knee: shoulderKnee), 0), 1)
        let q = sqrt(delivered) * Float(transferSamples - 1)
        let index = min(Int(q), transferSamples - 2)
        let fraction = q - Float(index)
        let low = Float(transferValues[index])
        return low + fraction * (Float(transferValues[index + 1]) - low)
    }

    /// The first SDR cube ends at paper activation. That seam is deliberately before the final
    /// 33-cube: the spectral paper transform is piecewise tetrahedral and can contain steep
    /// near-black changes wholly inside one 65-cube density cell. Composing it into a regular
    /// density cube would linearly smear those changes regardless of output companding.
    private func makeSDRActivationCube(
        invocation: FilmEngineInvocation
    ) -> MTLTexture? {
        let configuration = invocation.configuration
        let reversal = invocation.featureMask & FilmEngineFeature.reversal != 0
        let paperBases = [
            FilmEngineInvocation.paperRedOffset, 33,
            FilmEngineInvocation.paperBlueOffset,
        ]
        let paperMidpoints = [
            FilmEngineInvocation.paperMidpointRedOffset, 62,
            FilmEngineInvocation.paperMidpointBlueOffset,
        ]
        var curves = [[Float]]()
        curves.reserveCapacity(3)
        for base in paperBases {
            var values = [Float](repeating: 0, count: Self.curveSamples)
            for index in values.indices {
                let exposure = -8 + 16 * Float(index) / Float(Self.curveSamples - 1)
                values[index] = Self.curveDensity(
                    configuration, base: base, exposure: exposure)
                guard values[index].isFinite else { return nil }
            }
            curves.append(values)
        }

        let valueCount = Self.cubeEdge * Self.cubeEdge * Self.cubeEdge * 4
        var values = [Float16](repeating: 0, count: valueCount)
        for blue in 0..<Self.cubeEdge {
            for green in 0..<Self.cubeEdge {
                for red in 0..<Self.cubeEdge {
                    let unit = SIMD3<Float>(
                        Float(red) / Float(Self.cubeEdge - 1),
                        Float(green) / Float(Self.cubeEdge - 1),
                        Float(blue) / Float(Self.cubeEdge - 1))
                    let relative = invocation.spectral.filmOutput.sample(unit)
                    var mapped = relative
                    if !reversal {
                        for channel in 0..<3 {
                            let base = paperBases[channel]
                            let exposure = configuration[paperMidpoints[channel]]
                                + configuration[39 + channel] * relative[channel]
                            let density = Self.sampleCurve(curves[channel], exposure: exposure)
                            let range = configuration[base + 1]
                                * (configuration[base + 4] - configuration[base + 2])
                            guard range.isFinite, range > 0 else { return nil }
                            mapped[channel] = (density - configuration[base]) / range
                        }
                    }
                    guard mapped.x.isFinite, mapped.y.isFinite, mapped.z.isFinite else {
                        return nil
                    }
                    let index = ((blue * Self.cubeEdge + green) * Self.cubeEdge + red) * 4
                    values[index] = Float16(mapped.x)
                    values[index + 1] = Float16(mapped.y)
                    values[index + 2] = Float16(mapped.z)
                    values[index + 3] = 1
                }
            }
        }
        return uploadLookup(
            values: values, edge: Self.cubeEdge, pixelFormat: .rgba16Float,
            label: reversal
                ? "Fotufilm composite density-to-relative cube"
                : "Fotufilm composite density-to-paper-activation cube")
    }

    /// Keep the final paper transform linear until after tetrahedral interpolation. Applying the
    /// output transfer at its vertices would smear a steep black transition inside a paper cell,
    /// reproducing the defect this split representation is designed to avoid.
    private func makeSDROrientedPaperCube(
        invocation: FilmEngineInvocation
    ) -> MTLTexture? {
        guard let paper = invocation.spectral.paperOutput else { return nil }
        let edge = paper.dimension
        var values = [Float16]()
        values.reserveCapacity(paper.values.count)
        for value in paper.values {
            guard value.isFinite else { return nil }
            values.append(Float16(value))
        }
        return uploadOrientedCube(
            values: values, edge: edge, pixelFormat: .rgba16Float,
            label: "Fotufilm oriented linear spectral paper cube")
    }

    private func uploadCube<T>(
        values: [T], edge: Int, pixelFormat: MTLPixelFormat, label: String
    ) -> MTLTexture? {
        guard edge >= 2, values.count == edge * edge * edge * 4 else { return nil }
        let stagingDescriptor = MTLTextureDescriptor()
        stagingDescriptor.textureType = .type3D
        stagingDescriptor.pixelFormat = pixelFormat
        stagingDescriptor.width = edge
        stagingDescriptor.height = edge
        stagingDescriptor.depth = edge
        stagingDescriptor.mipmapLevelCount = 1
        stagingDescriptor.storageMode = .shared
        stagingDescriptor.usage = .shaderRead
        let privateDescriptor = stagingDescriptor.copy() as! MTLTextureDescriptor
        privateDescriptor.storageMode = .private
        privateDescriptor.usage = .shaderRead
        guard let staging = device.makeTexture(descriptor: stagingDescriptor),
              let cube = device.makeTexture(descriptor: privateDescriptor)
        else { return nil }
        values.withUnsafeBytes { bytes in
            staging.replace(
                region: MTLRegionMake3D(
                    0, 0, 0, edge, edge, edge),
                mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: edge * 4 * MemoryLayout<T>.stride,
                bytesPerImage: edge * edge * 4 * MemoryLayout<T>.stride)
        }
        guard let commandBuffer = uploadQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder()
        else { return nil }
        encoder.copy(
            from: staging, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: edge, height: edge, depth: edge),
            to: cube, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        cube.label = label
        return cube
    }

    private func uploadLookup<T>(
        values: [T], edge: Int, pixelFormat: MTLPixelFormat, label: String
    ) -> MTLTexture? {
        switch lookupLayout {
        case .baseline3D:
            return uploadCube(
                values: values, edge: edge, pixelFormat: pixelFormat, label: label)
        case .oriented2DArray:
            return uploadOrientedCube(
                values: values, edge: edge, pixelFormat: pixelFormat, label: label)
        case .composed129WarpedTetrahedral, .composed129WarpedTrilinear:
            return uploadCube(
                values: values, edge: edge, pixelFormat: pixelFormat, label: label)
        }
    }

    /// Three edge-oriented copies: X edges are indexed by Z slices, Y edges by X slices, and Z
    /// edges by Y slices. Every tetrahedral edge is consequently one 1D interpolation inside a
    /// 2D slice, while adjacent screen pixels retain coherent array-slice access.
    private func uploadOrientedCube<T>(
        values: [T], edge: Int, pixelFormat: MTLPixelFormat, label: String
    ) -> MTLTexture? {
        guard edge >= 2, values.count == edge * edge * edge * 4 else { return nil }
        var oriented = [T]()
        oriented.reserveCapacity(values.count * 3)
        // X edges: slice Z, row Y, column X. This is the source's native order.
        oriented.append(contentsOf: values)
        // Y edges: slice X, row Z, column Y.
        for x in 0..<edge {
            for z in 0..<edge {
                for y in 0..<edge {
                    let source = ((z * edge + y) * edge + x) * 4
                    oriented.append(contentsOf: values[source..<(source + 4)])
                }
            }
        }
        // Z edges: slice Y, row X, column Z.
        for y in 0..<edge {
            for x in 0..<edge {
                for z in 0..<edge {
                    let source = ((z * edge + y) * edge + x) * 4
                    oriented.append(contentsOf: values[source..<(source + 4)])
                }
            }
        }

        let stagingDescriptor = MTLTextureDescriptor()
        stagingDescriptor.textureType = .type2DArray
        stagingDescriptor.pixelFormat = pixelFormat
        stagingDescriptor.width = edge
        stagingDescriptor.height = edge
        stagingDescriptor.arrayLength = 3 * edge
        stagingDescriptor.mipmapLevelCount = 1
        stagingDescriptor.storageMode = .shared
        stagingDescriptor.usage = .shaderRead
        let privateDescriptor = stagingDescriptor.copy() as! MTLTextureDescriptor
        privateDescriptor.storageMode = .private
        guard let staging = device.makeTexture(descriptor: stagingDescriptor),
              let texture = device.makeTexture(descriptor: privateDescriptor)
        else { return nil }
        let bytesPerRow = edge * 4 * MemoryLayout<T>.stride
        let bytesPerImage = edge * bytesPerRow
        oriented.withUnsafeBytes { bytes in
            for slice in 0..<(3 * edge) {
                staging.replace(
                    region: MTLRegionMake2D(0, 0, edge, edge),
                    mipmapLevel: 0, slice: slice,
                    withBytes: bytes.baseAddress!.advanced(by: slice * bytesPerImage),
                    bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)
            }
        }
        guard let commandBuffer = uploadQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder()
        else { return nil }
        for slice in 0..<(3 * edge) {
            encoder.copy(
                from: staging, sourceSlice: slice, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: edge, height: edge, depth: 1),
                to: texture, destinationSlice: slice, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        texture.label = label
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

    private static func sampleCurve(_ values: [Float], exposure: Float) -> Float {
        let q = min(max(
            (exposure + 8) * (Float(curveSamples - 1) / 16), 0),
            Float(curveSamples - 1))
        let index = min(Int(q), curveSamples - 2)
        return values[index] + (q - Float(index)) * (values[index + 1] - values[index])
    }

    private static func makeTransferTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.pixelFormat = .r16Float
        descriptor.width = transferValues.count
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        transferValues.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake1D(0, transferValues.count), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: bytes.count)
        }
        return texture
    }

    private var usesComposedCube: Bool {
        switch lookupLayout {
        case .composed129WarpedTetrahedral, .composed129WarpedTrilinear:
            return true
        case .baseline3D, .oriented2DArray:
            return false
        }
    }

    private func validDensity(_ texture: MTLTexture) -> Bool {
        texture.device.registryID == device.registryID
            && texture.textureType == .type2D
            && texture.pixelFormat == .rgba16Float
            && texture.sampleCount == 1
            && texture.mipmapLevelCount == 1
            && texture.arrayLength == 1
            && texture.depth == 1
            && texture.usage.contains(.shaderRead)
    }

    private func validHDROutput(_ texture: MTLTexture) -> Bool {
        texture.device.registryID == device.registryID
            && texture.textureType == .type2D
            && texture.pixelFormat == .rgba16Float
            && texture.sampleCount == 1
            && texture.mipmapLevelCount == 1
            && texture.arrayLength == 1
            && texture.depth == 1
            && texture.usage.contains(.shaderWrite)
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

    private static func byteCount(mode: OutputMode, width: Int, height: Int) -> Int? {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let bytesPerPixel = mode == .encodedDisplayP3RGBA8
            ? 4 : 4 * MemoryLayout<Float16>.stride
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        return pixelOverflow || byteOverflow ? nil : bytes
    }

    private static func animatedSeed(base: UInt32, frameIndex: UInt64) -> UInt32 {
        base &+ UInt32(truncatingIfNeeded: frameIndex &* 0x9E3779B97F4A7C15)
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

}
#endif
