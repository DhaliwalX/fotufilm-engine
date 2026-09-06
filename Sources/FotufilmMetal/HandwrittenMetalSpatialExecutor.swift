#if canImport(Metal)
import Foundation
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Hand-written Metal implementation of the spatial portion of the film pipeline.
///
/// The input is record exposure, not display RGB, and the output is developed negative density.
/// Keeping those domains explicit lets the split-table renderer place this executor between its
/// scene-to-exposure and density-to-print cubes without moving any physical operation across a
/// nonlinear curve. All intermediate textures use private RGBA16F storage and every dispatch is
/// encoded into the caller's command buffer.
///
/// The executor is whole-frame by design. Cropped and tiled inputs are rejected until the API can
/// describe both the full-frame boundaries and the physical apron carried by the input texture.
public final class HandwrittenMetalSpatialExecutor {
    public enum OptimizationVariant: String, CaseIterable, Sendable {
        /// Production selection: the fastest measured exact graph supported by the stock.
        case automatic
        /// Original nine-dispatch endpoint, retained as a measurement control.
        case fusedDevelopPrint
        /// Uses 15x15 fused-blur tiles and overwrites captured rows after their last read.
        case compactBlur15
        /// Materializes developed transmittance, then runs the print tile without halo development.
        case splitDevelopPrint
        /// Uses small threadgroup-memory row/column passes for the largest halation kernels.
        case adaptiveSeparableBlur
        /// Runs independent halation and field blurs in concurrent compute frontiers.
        case concurrentFrontiers
        /// Keeps every canonical f16 seam while specializing the measured realtime topology.
        case exactSpecialized
        /// Keeps full-resolution MTF and development, but evaluates optically band-limited
        /// halation and development fields on variance-compensated half/quarter grids.
        case perceptualMultires
    }

    public struct ExecutionPlan: Sendable, Equatable {
        public let name: String
        public let dispatchCount: Int
        /// Dynamic threadgroup allocation for each dispatch, in graph order. Zero denotes a
        /// kernel that uses no dynamic threadgroup storage.
        public let threadgroupMemoryBytes: [Int]

        public var maximumThreadgroupMemoryBytes: Int {
            threadgroupMemoryBytes.max() ?? 0
        }
    }

    public struct DispatchTiming: Sendable, Equatable {
        public let name: String
        public let startTimestamp: UInt64
        public let endTimestamp: UInt64
        /// Hardware timestamp frequency in ticks per second. This is nil before iOS/macOS 26,
        /// where Metal exposes timestamp samples but not their device-specific frequency.
        public let timestampFrequency: UInt64?

        public var durationTicks: UInt64 {
            endTimestamp >= startTimestamp ? endTimestamp - startTimestamp : 0
        }

        public var durationNanoseconds: Double? {
            guard let timestampFrequency, timestampFrequency > 0 else { return nil }
            return Double(durationTicks) * 1_000_000_000 / Double(timestampFrequency)
        }
    }

    /// The most recently completed profiled fast graph for one preparation key. Counter sampling
    /// inserts dispatch-boundary barriers and is therefore an opt-in diagnostic, not production
    /// timing behavior.
    public struct DispatchProfile: Sendable, Equatable {
        public let planName: String
        public let frameIndex: UInt64
        public let dispatches: [DispatchTiming]

        public var totalDurationTicks: UInt64 {
            dispatches.reduce(0) { $0 &+ $1.durationTicks }
        }

        public var totalDurationNanoseconds: Double? {
            let values = dispatches.compactMap(\.durationNanoseconds)
            return values.count == dispatches.count ? values.reduce(0, +) : nil
        }
    }

    public struct Capabilities: OptionSet, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let emulsionMTF = Self(rawValue: 1 << 0)
        public static let threeScaleHalation = Self(rawValue: 1 << 1)
        public static let annularHalation = Self(rawValue: 1 << 2)
        public static let lensDiffusion = Self(rawValue: 1 << 3)
        public static let couplerDiffusion = Self(rawValue: 1 << 4)
        public static let adjacency = Self(rawValue: 1 << 5)
        public static let clumpGrain = Self(rawValue: 1 << 6)
        public static let mottle = Self(rawValue: 1 << 7)
        public static let printMTF = Self(rawValue: 1 << 8)
        public static let donorLayer = Self(rawValue: 1 << 9)
        /// Declared for negotiation but absent from `capabilities`: all stores are currently f16.
        public static let hdrLinearDomain = Self(rawValue: 1 << 10)
        /// Declared for feature negotiation but intentionally absent from `capabilities`.
        public static let booleanDiscGrain = Self(rawValue: 1 << 11)
        /// Accepts the private float4 produced by `HandwrittenMetalGlobalMeasurements` directly.
        public static let onGPUFlareMeasurement = Self(rawValue: 1 << 12)
    }

    /// Boolean-disc grain is intentionally absent: substituting clump grain would change silver
    /// physics, so `prepareChecked` reports that request instead of degrading it.
    public static let capabilities: Capabilities = [
        .emulsionMTF, .threeScaleHalation, .annularHalation, .lensDiffusion,
        .couplerDiffusion, .adjacency, .clumpGrain, .mottle, .printMTF,
        .donorLayer, .onGPUFlareMeasurement,
    ]

    /// Feature bits this scene-light-to-density executor implements. Pipeline seam, delivery,
    /// exact-f32, measurement, and texture-difference bits are deliberately absent.
    public static let supportedFeatureMask: Int32 =
        FilmEngineFeature.flare | FilmEngineFeature.mtf | FilmEngineFeature.halation
        | FilmEngineFeature.couplers | FilmEngineFeature.adjacency | FilmEngineFeature.grain
        | FilmEngineFeature.reversal | FilmEngineFeature.monochrome | FilmEngineFeature.mtfLuma
        | FilmEngineFeature.couplerDiffusion | FilmEngineFeature.grainMottle
        | FilmEngineFeature.printMTF | FilmEngineFeature.diffusion
        | FilmEngineFeature.donorLayer | FilmEngineFeature.annularHalation

    public enum PreparationError: Swift.Error, CustomStringConvertible {
        case invalidDimensions
        case unsupportedPipelineStage
        case unsupportedFeatureMask(Int32)
        case unsupportedDiscGrain
        case unsupportedGrainRadius(Int)
        case unsupportedMTFRadius(Int)
        case allocationFailed(String)
        case metalCompilation(String)

        public var description: String {
            switch self {
            case .invalidDimensions:
                return "frame dimensions must be positive"
            case .unsupportedPipelineStage:
                return "the spatial executor requires the full pipeline stage"
            case let .unsupportedFeatureMask(mask):
                return String(format: "unsupported spatial feature mask 0x%08X", mask)
            case .unsupportedDiscGrain:
                return "Boolean-disc grain is not yet available in the realtime spatial executor"
            case let .unsupportedGrainRadius(radius):
                return "grain radius \(radius) exceeds the fused realtime kernel's limit"
            case let .unsupportedMTFRadius(radius):
                return "MTF radius \(radius) exceeds this device's threadgroup-memory limit"
            case let .allocationFailed(resource):
                return "unable to allocate \(resource)"
            case let .metalCompilation(message):
                return "Metal compilation failed: \(message)"
            }
        }
    }

    private enum Configuration {
        // Stable C ABI offsets from FotufilmHalide.h. Appended values remain explicit here so a
        // mismatch is visible in review instead of silently changing one stock's behaviour.
        static let curves = 0
        static let coupler = 21
        static let grain = 30
        static let mtfSigma = 42
        static let mtfRadius = 45
        static let halationRadius = 48
        static let couplerSigma = 51
        static let couplerRadius = 52
        static let adjacencySigma = 53
        static let adjacencyRadius = 54
        static let flare = 57
        static let couplerScale = 58
        static let adjacencyStrength = 59
        static let grainLambda = 60
        static let flareMean = 63
        static let halationKernel = 457
        static let grainCorrelation = 466
        static let mtfLumaShare = 467
        static let mtfLumaSigma = 468
        static let mtfLumaRadius = 469
        static let mottleRadius = 8_682
        static let mottleLambda = 8_683
        static let mottle = 8_684
        static let grainLaw = 8_701
        static let grainAnchor = 8_702
        static let grainFog = 8_705
        static let grainSigmaLayer = 8_708
        static let mottleSigmaLayer = 8_711
        static let printMTFSigma = 8_714
        static let printMTFRadius = 8_715
        static let printSharpen = 8_733
        static let diffusionDirect = 8_734
        static let diffusionKernel = 8_735
        static let diffusionRadius = 8_744
        static let donorCurve = 8_747
        static let donorRelease = 8_753
        static let halationRingRadius = 8_756
        static let halationMatrix = 8_759
        static let curveSecondary = 8_768
        static let mtfSecondarySigma = 8_783
        static let mtfSecondaryRadius = 8_786
        static let mtfPrimaryShare = 8_789
        static let couplerReleaseGamma = 8_792
        static let donorReleaseGamma = 8_795
        static let donorDiffusionKernel = 8_796
        static let developComplement = 8_799
    }

    private static let tile = 16
    private static let maximumCounterSamples = 32
    private static let maximumFusedGrainRadius = 8
    private static let enableNineDispatchFastPath = true
    private static let curveSamples = 2_048
    private static let curveMinimum: Float = -8
    private static let curveMaximum: Float = 8

    private struct ScratchKey: Hashable {
        let width: Int
        let height: Int
        let scale0Width: Int
        let scale0Height: Int
        let scale1Width: Int
        let scale1Height: Int
        let scale2Width: Int
        let scale2Height: Int
    }

    private final class Scratch {
        let work: MTLTexture
        let gridA: MTLTexture
        let gridB: MTLTexture
        let scales: [MTLTexture]
        let concurrentCoarse: [MTLTexture]
        let multiresRelease: MTLTexture?
        let counterSampleBuffer: MTLCounterSampleBuffer?
        var leased = false

        init(
            work: MTLTexture, gridA: MTLTexture, gridB: MTLTexture,
            scales: [MTLTexture], concurrentCoarse: [MTLTexture],
            multiresRelease: MTLTexture?,
            counterSampleBuffer: MTLCounterSampleBuffer?
        ) {
            self.work = work
            self.gridA = gridA
            self.gridB = gridB
            self.scales = scales
            self.concurrentCoarse = concurrentCoarse
            self.multiresRelease = multiresRelease
            self.counterSampleBuffer = counterSampleBuffer
        }
    }

    private struct SeparableBlurPlan {
        let horizontalPipeline: MTLComputePipelineState
        let verticalPipeline: MTLComputePipelineState
        let threadgroupBytes: Int
        let tile: Int
    }

    private struct ScalePlan {
        let stride: Int
        let radius: Int
        let ringRadius: Float
        let weights: MTLBuffer
        let fusedPipeline: MTLComputePipelineState?
        let threadgroupBytes: Int
        let fusedTile: Int
        let separable: SeparableBlurPlan?
    }

    private struct GaussianPlan {
        let stride: Int
        let radius: Int
        let weights: MTLBuffer
        let fusedPipeline: MTLComputePipelineState?
        let threadgroupBytes: Int
        let fusedTile: Int
    }

    private struct PrintPlan {
        let gaussian: GaussianPlan
        let fusedPipeline: MTLComputePipelineState?
        let threadgroupBytes: Int
    }

    private struct MTFPlan {
        let pipeline: MTLComputePipelineState
        let downsamplePipeline: MTLComputePipelineState?
        let radius: Int
        let extended: Bool
        let threadgroupBytes: Int
        let weights: MTLBuffer
    }

    private struct GrainPlan {
        let pipeline: MTLComputePipelineState
        let radius: Int
        let threadgroupBytes: Int
        let fineWeights: MTLBuffer
        let mottleWeights: MTLBuffer
        let finePoisson: MTLBuffer
        let mottlePoisson: MTLBuffer
        let normal: MTLBuffer
    }

    private struct MTFPipelineKey: Hashable {
        let radius: Int
        let extended: Bool
        let downsample: Bool
        let packedPrimary: Bool
    }

    private enum BlurPipelineKind: UInt8, Hashable {
        case fused16
        case compact15
        case horizontal16
        case vertical16
    }

    private struct BlurPipelineKey: Hashable {
        let radius: Int
        let kind: BlurPipelineKind
    }

    private struct GrainPipelineKey: Hashable {
        let curveMode: Int
        let radius: Int
        let enabled: Bool
        let mottle: Bool
        let monochrome: Bool
        let printTransmittance: Bool
        let inputLog: Bool
        let exactSpecialized: Bool
        let dyeCloud: Bool
        let donor: Bool
        let nonlinearWarp: Bool
        let complement: Bool
        let multires: Bool
    }

    private struct FusedHDRPipelineKey: Hashable {
        let curveMode: Int
        let donor: Bool
        let nonlinearWarp: Bool
        let complement: Bool
    }

    private struct MultiresFieldPipelineKey: Hashable {
        let couplerRadius: Int
        let adjacencyRadius: Int
    }

    private struct DevelopPrintPipelineKey: Hashable {
        let grainRadius: Int
        let printRadius: Int
        let grain: Bool
        let mottle: Bool
        let monochrome: Bool
    }

    /// The fast graph is deliberately structural rather than stock-ID based. Any future stock
    /// with the same exact decimation topology and supported radii gets the optimization; every
    /// other graph retains the general implementation below.
    private struct FastPathPlan {
        let name: String
        let dispatchCount: Int
        let developPrintPipeline: MTLComputePipelineState?
        let splitDevelopPipeline: MTLComputePipelineState?
        let fusedHDRPipeline: MTLComputePipelineState?
        let finishThreadgroupBytes: Int
        let developThreadgroupBytes: Int
        let printRadius: Int
        let concurrentFrontiers: Bool
        let exactSpecialized: Bool
    }

    /// Approximate only fields whose physical support has already removed frequencies above the
    /// reduced-grid Nyquist limits. Direct MTF light and the nonlinear development curve remain
    /// full resolution, so texture and edge detail never pass through these field grids.
    private struct MultiresPathPlan {
        let name: String
        let dispatchCount: Int
        let coupler: GaussianPlan
        let adjacency: GaussianPlan
        let jointFieldsPipeline: MTLComputePipelineState
        let developPipeline: MTLComputePipelineState
        let finishThreadgroupBytes: Int
        let jointThreadgroupBytes: Int
        let developThreadgroupBytes: Int
    }

    private final class DispatchProfiler {
        let sampleBuffer: MTLCounterSampleBuffer
        let planName: String
        let key: String
        let frameIndex: UInt64
        private(set) var labels: [String] = []
        private var nextSampleIndex = 0

        init(
            sampleBuffer: MTLCounterSampleBuffer, planName: String,
            key: String, frameIndex: UInt64
        ) {
            self.sampleBuffer = sampleBuffer
            self.planName = planName
            self.key = key
            self.frameIndex = frameIndex
        }

        func begin(_ encoder: MTLComputeCommandEncoder) {
            encoder.sampleCounters(
                sampleBuffer: sampleBuffer, sampleIndex: 0, barrier: true)
            nextSampleIndex = 1
        }

        func complete(_ name: String, encoder: MTLComputeCommandEncoder) {
            precondition(nextSampleIndex < sampleBuffer.sampleCount)
            labels.append(name)
            encoder.sampleCounters(
                sampleBuffer: sampleBuffer, sampleIndex: nextSampleIndex,
                barrier: true)
            nextSampleIndex += 1
        }

        var sampleCount: Int { nextSampleIndex }
    }

    private struct Prepared {
        let width: Int
        let height: Int
        let featureMask: Int32
        let baseSeed: UInt32
        let configuration: [Float]
        let configurationBuffer: MTLBuffer
        let curves: MTLTexture
        let halfResponseLUT: MTLTexture?
        let diffusion: [ScalePlan]
        let halation: [ScalePlan]
        let coupler: GaussianPlan?
        let adjacency: GaussianPlan?
        let printMTF: PrintPlan?
        let mtf: MTFPlan?
        let grain: GrainPlan
        var fastPath: FastPathPlan?
        var multiresPath: MultiresPathPlan?
    }

    private struct SpatialParameters {
        var extent: SIMD4<UInt32>
        var geometry: SIMD4<UInt32>
    }

    private struct CopyParameters {
        var extent: SIMD4<UInt32>
        var mean: SIMD4<Float>
    }

    private struct PyramidParameters {
        var extent: SIMD4<UInt32>
        var grid0: SIMD4<UInt32>
        var grid1: SIMD4<UInt32>
        var grid2: SIMD4<UInt32>
        var strides: SIMD4<UInt32>
        var rings: SIMD4<Float>
    }

    private struct FastFinishParameters {
        var extent: SIMD4<UInt32>
        var grid0: SIMD4<UInt32>
        var grid1: SIMD4<UInt32>
        var grid2: SIMD4<UInt32>
        var strides: SIMD4<UInt32>
        var coupler: SIMD4<UInt32>
        var adjacency: SIMD4<UInt32>
    }

    private struct MultiresFieldParameters {
        var activationExtent: SIMD4<UInt32>
        var couplerExtent: SIMD4<UInt32>
    }

    private struct MTFParameters {
        var extent: SIMD4<UInt32>
        var mean: SIMD4<Float>
        var shares: SIMD4<Float>
    }

    /// One shader argument for both paths: CPU means use Metal's inline constant storage, while a
    /// measured mean binds its private buffer without a readback or intermediate copy.
    private enum FlareMeanBinding {
        case inline(SIMD4<Float>)
        case gpu(HandwrittenMetalGlobalMeasurements.FlareMean)

        func bind(to encoder: MTLComputeCommandEncoder, index: Int) {
            switch self {
            case var .inline(value):
                encoder.setBytes(
                    &value, length: MemoryLayout<SIMD4<Float>>.stride, index: index)
            case let .gpu(mean):
                mean.bind(to: encoder, index: index)
            }
        }
    }

    private struct LinearHDREndpoint {
        let binding: HandwrittenMetalCompositeTail.LinearHDRBinding
        let output: MTLTexture
    }

    private struct DevelopParameters {
        var extent: SIMD4<UInt32>
        var state: SIMD4<UInt32>
        var coupler: SIMD4<UInt32>
        var adjacency: SIMD4<UInt32>
        var phases: SIMD4<UInt32>
        var grain: SIMD4<Float>
    }

    private struct ExactCameraTailParameters {
        var minimum: SIMD4<Float>
        var inverseRange: SIMD4<Float>
    }

    private struct PrintParameters {
        var extent: SIMD4<UInt32>
        var values: SIMD4<Float>
    }

    private let device: MTLDevice
    private let optimizationVariant: OptimizationVariant
    private let dispatchProfilingEnabled: Bool
    private let timestampCounterSet: MTLCounterSet?
    private let timestampFrequency: UInt64?
    private let library: MTLLibrary
    private let copyPipeline: MTLComputePipelineState
    private let transformPipeline: MTLComputePipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private let horizontalPipeline: MTLComputePipelineState
    private let verticalPipeline: MTLComputePipelineState
    private let pyramidPipeline: MTLComputePipelineState
    private let printPipeline: MTLComputePipelineState
    private let pyramidDownPairPipeline: MTLComputePipelineState
    private let finishFieldsPipeline: MTLComputePipelineState
    private let finishFieldsLUTPipeline: MTLComputePipelineState
    private let multiresFinishPipeline: MTLComputePipelineState
    private let halfResponseBakePipeline: MTLComputePipelineState
    private let preparationQueue: MTLCommandQueue
    private let maximumInFlightFrames: Int

    private let lock = NSLock()
    private var prepared: [String: Prepared] = [:]
    private var scratch: [ScratchKey: [Scratch]] = [:]
    private var mtfPipelines: [MTFPipelineKey: MTLComputePipelineState] = [:]
    private var grainPipelines: [GrainPipelineKey: MTLComputePipelineState] = [:]
    private var fusedHDRPipelines: [FusedHDRPipelineKey: MTLComputePipelineState] = [:]
    private var printPipelines: [Int: MTLComputePipelineState] = [:]
    private var blurPipelines: [BlurPipelineKey: MTLComputePipelineState] = [:]
    private var developPrintPipelines: [DevelopPrintPipelineKey: MTLComputePipelineState] = [:]
    private var multiresFieldPipelines: [MultiresFieldPipelineKey: MTLComputePipelineState] = [:]
    private var dispatchProfiles: [String: DispatchProfile] = [:]

    public convenience init?(
        maximumInFlightFrames: Int = 2,
        optimizationVariant: OptimizationVariant = .automatic,
        dispatchProfilingEnabled: Bool = false
    ) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.init(
            device: device, maximumInFlightFrames: maximumInFlightFrames,
            optimizationVariant: optimizationVariant,
            dispatchProfilingEnabled: dispatchProfilingEnabled)
    }

    public init?(
        device: MTLDevice, maximumInFlightFrames: Int = 2,
        optimizationVariant: OptimizationVariant = .automatic,
        dispatchProfilingEnabled: Bool = false
    ) {
        guard maximumInFlightFrames > 0,
              let preparationQueue = device.makeCommandQueue() else { return nil }
        let options = MTLCompileOptions()
        options.fastMathEnabled = true
        do {
            let library = try HandwrittenMetalShaderLibrary.makeLibrary(
                device: device, shader: .spatial, options: options)
            func pipeline(_ name: String) throws -> MTLComputePipelineState {
                let function = try library.makeFunction(
                    name: name, constantValues: MTLFunctionConstantValues())
                return try device.makeComputePipelineState(function: function)
            }
            func booleanPipeline(
                _ name: String, constant index: Int, value: Bool
            ) throws -> MTLComputePipelineState {
                let values = MTLFunctionConstantValues()
                var selected = value
                values.setConstantValue(&selected, type: .bool, index: index)
                let function = try library.makeFunction(
                    name: name, constantValues: values)
                return try device.makeComputePipelineState(function: function)
            }
            self.library = library
            copyPipeline = try pipeline("fotufilm_spatial_copy")
            transformPipeline = try pipeline("fotufilm_spatial_transform")
            downsamplePipeline = try pipeline("fotufilm_spatial_downsample")
            horizontalPipeline = try pipeline("fotufilm_spatial_blur_horizontal")
            verticalPipeline = try pipeline("fotufilm_spatial_blur_vertical")
            pyramidPipeline = try pipeline("fotufilm_spatial_finish_pyramid")
            printPipeline = try pipeline("fotufilm_spatial_finish_print_mtf")
            pyramidDownPairPipeline = try pipeline("fotufilm_spatial_pyramid_down_pair")
            finishFieldsPipeline = try booleanPipeline(
                "fotufilm_spatial_finish_fields", constant: 10, value: false)
            finishFieldsLUTPipeline = try booleanPipeline(
                "fotufilm_spatial_finish_fields", constant: 10, value: true)
            multiresFinishPipeline = try pipeline("fotufilm_spatial_multires_finish")
            halfResponseBakePipeline = try pipeline("fotufilm_spatial_bake_half_response")
        } catch {
            return nil
        }
        self.device = device
        self.preparationQueue = preparationQueue
        self.optimizationVariant = optimizationVariant
        self.dispatchProfilingEnabled = dispatchProfilingEnabled
        timestampCounterSet = dispatchProfilingEnabled
            && device.supportsCounterSampling(.atDispatchBoundary)
            ? device.counterSets?.first {
                $0.name == MTLCommonCounterSet.timestamp.rawValue
            } : nil
        #if os(macOS)
        if dispatchProfilingEnabled, timestampCounterSet != nil,
           #available(macOS 26.0, *) {
            let frequency = device.queryTimestampFrequency()
            timestampFrequency = frequency > 0 ? frequency : nil
        } else {
            timestampFrequency = nil
        }
        #else
        // iOS exposes dispatch-boundary timestamp samples but not the device tick frequency.
        // Raw ticks remain available in DispatchTiming; nanosecond conversion stays nil.
        timestampFrequency = nil
        #endif
        self.maximumInFlightFrames = maximumInFlightFrames
    }

    /// Prepares immutable curve, filter, and random-distribution tables. This is intended for an
    /// edit/stock change, never for the camera frame loop.
    public func prepareChecked(
        key: String, stock: FilmStock, options: FotufilmEngine.Options,
        frameWidth: Int, frameHeight: Int
    ) throws {
        guard frameWidth > 0, frameHeight > 0 else {
            throw PreparationError.invalidDimensions
        }
        guard options.stage == .full else {
            throw PreparationError.unsupportedPipelineStage
        }
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: frameWidth, height: frameHeight)
        let mask = invocation.featureMask
        if mask & FilmEngineFeature.discGrain != 0 {
            // Falling back is preferable to silently exchanging opaque silver discs for dye-cloud
            // noise; the two models do not have the same density law.
            throw PreparationError.unsupportedDiscGrain
        }
        let unsupportedMask = mask & ~Self.supportedFeatureMask
        guard unsupportedMask == 0 else {
            throw PreparationError.unsupportedFeatureMask(unsupportedMask)
        }
        let configuration = invocation.configuration
        guard let configurationBuffer = makeBuffer(configuration) else {
            throw PreparationError.allocationFailed("configuration buffer")
        }
        guard let curves = makeCurveTexture(configuration: configuration) else {
            throw PreparationError.allocationFailed("film curve texture")
        }
        let halfResponseLUT: MTLTexture?
        if optimizationVariant == .exactSpecialized
            || optimizationVariant == .perceptualMultires {
            guard let table = makeHalfResponseLUT(
                    configuration: configurationBuffer, curves: curves) else {
                throw PreparationError.allocationFailed("half-response lookup table")
            }
            halfResponseLUT = table
        } else {
            halfResponseLUT = nil
        }

        let diffusion = try (0..<3).map { scale -> ScalePlan in
            let radius = max(Int(configuration[Configuration.diffusionRadius + scale]), 0)
            return try makeBoxScale(
                radius: radius, stride: Self.diffusionStride(radius), ringRadius: 0,
                adaptiveCandidate: false)
        }
        let halation = try (0..<3).map { scale -> ScalePlan in
            let radius = max(Int(configuration[Configuration.halationRadius + scale]), 0)
            return try makeBoxScale(
                radius: radius, stride: Self.halationStride(radius),
                ringRadius: max(configuration[Configuration.halationRingRadius + scale], 0),
                adaptiveCandidate: true)
        }
        let coupler = mask & FilmEngineFeature.couplerDiffusion != 0
            ? try makeGaussianPlan(
                sigma: max(configuration[Configuration.couplerSigma], 0.151),
                radius: max(Int(configuration[Configuration.couplerRadius]), 0))
            : nil
        let adjacency = mask & FilmEngineFeature.adjacency != 0
            ? try makeGaussianPlan(
                sigma: max(configuration[Configuration.adjacencySigma], 0.151),
                radius: max(Int(configuration[Configuration.adjacencyRadius]), 0))
            : nil
        let printMTF: PrintPlan?
        if mask & FilmEngineFeature.printMTF != 0 {
            let gaussian = try makeGaussianPlan(
                sigma: max(configuration[Configuration.printMTFSigma], 0.151),
                radius: max(Int(configuration[Configuration.printMTFRadius]), 0),
                decimate: false)
            let fused = gaussian.radius <= Self.maximumFusedGrainRadius
                ? try specializedPrintPipeline(radius: gaussian.radius) : nil
            let padded = Self.tile + 2 * gaussian.radius
            let cells = padded * padded + Self.tile * padded
            printMTF = PrintPlan(
                gaussian: gaussian, fusedPipeline: fused,
                threadgroupBytes: cells * MemoryLayout<SIMD4<Float16>>.stride)
        } else {
            printMTF = nil
        }
        let mtf = mask & FilmEngineFeature.mtf != 0
            ? try makeMTFPlan(configuration: configuration, featureMask: mask) : nil
        let grain = try makeGrainPlan(configuration: configuration, featureMask: mask)
        let fastPath = try makeFastPathPlan(
            featureMask: mask, configuration: configuration,
            diffusion: diffusion, halation: halation,
            coupler: coupler, adjacency: adjacency, printMTF: printMTF,
            mtf: mtf, grain: grain)
        let multiresPath = try makeMultiresPathPlan(
            featureMask: mask, configuration: configuration,
            frameWidth: frameWidth, frameHeight: frameHeight,
            diffusion: diffusion, halation: halation,
            coupler: coupler, adjacency: adjacency, printMTF: printMTF,
            mtf: mtf, grain: grain)

        let value = Prepared(
            width: frameWidth, height: frameHeight, featureMask: mask,
            baseSeed: invocation.seed, configuration: configuration,
            configurationBuffer: configurationBuffer, curves: curves,
            halfResponseLUT: halfResponseLUT,
            diffusion: diffusion, halation: halation, coupler: coupler,
            adjacency: adjacency, printMTF: printMTF, mtf: mtf, grain: grain,
            fastPath: fastPath, multiresPath: multiresPath)
        lock.lock()
        prepared[key] = value
        lock.unlock()
    }

    /// Compatibility convenience for callers that select another renderer on failure.
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

    /// Encodes record-exposure to developed-density, including the enlarger MTF when selected.
    /// Both textures must be distinct, whole-frame, single-sample RGBA16F 2D textures on this
    /// executor's device. Nothing is committed or waited here.
    @discardableResult
    public func encodeDevelopedDensity(
        recordExposure: MTLTexture, densityOutput: MTLTexture,
        key: String, frameIndex: UInt64,
        originX: Int = 0, originY: Int = 0,
        flareMean suppliedFlareMean: SIMD3<Float>? = nil,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        encodeDevelopedDensityImpl(
            recordExposure: recordExposure, densityOutput: densityOutput,
            key: key, frameIndex: frameIndex, originX: originX, originY: originY,
            cpuFlareMean: suppliedFlareMean, gpuFlareMean: nil,
            linearHDREndpoint: nil,
            commandBuffer: commandBuffer)
    }

    /// Encodes the spatial graph with the GPU flare mean produced by
    /// `HandwrittenMetalGlobalMeasurements.encodeFlareMean`. The resource may be written by an
    /// earlier encoder in this same command buffer; this method binds it directly and never maps or
    /// synchronizes it through the CPU.
    @discardableResult
    public func encodeDevelopedDensity(
        recordExposure: MTLTexture, densityOutput: MTLTexture,
        key: String, frameIndex: UInt64,
        originX: Int = 0, originY: Int = 0,
        flareMean: HandwrittenMetalGlobalMeasurements.FlareMean,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        encodeDevelopedDensityImpl(
            recordExposure: recordExposure, densityOutput: densityOutput,
            key: key, frameIndex: frameIndex, originX: originX, originY: originY,
            cpuFlareMean: nil, gpuFlareMean: flareMean,
            linearHDREndpoint: nil,
            commandBuffer: commandBuffer)
    }

    /// Encodes the exact no-grain spatial graph directly into its Digital Reference HDR master.
    /// `workingTexture` still carries the authored half-precision MTF/log seam; developed density is
    /// rounded to half in registers and never materialized as another full-resolution texture.
    @discardableResult
    func encodeLinearHDR(
        recordExposure: MTLTexture, workingTexture: MTLTexture,
        output: MTLTexture, tail: HandwrittenMetalCompositeTail.LinearHDRBinding,
        key: String, frameIndex: UInt64,
        originX: Int = 0, originY: Int = 0,
        flareMean suppliedFlareMean: SIMD3<Float>? = nil,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        encodeDevelopedDensityImpl(
            recordExposure: recordExposure, densityOutput: workingTexture,
            key: key, frameIndex: frameIndex, originX: originX, originY: originY,
            cpuFlareMean: suppliedFlareMean, gpuFlareMean: nil,
            linearHDREndpoint: LinearHDREndpoint(binding: tail, output: output),
            commandBuffer: commandBuffer)
    }

    @discardableResult
    func encodeLinearHDR(
        recordExposure: MTLTexture, workingTexture: MTLTexture,
        output: MTLTexture, tail: HandwrittenMetalCompositeTail.LinearHDRBinding,
        key: String, frameIndex: UInt64,
        originX: Int = 0, originY: Int = 0,
        flareMean: HandwrittenMetalGlobalMeasurements.FlareMean,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        encodeDevelopedDensityImpl(
            recordExposure: recordExposure, densityOutput: workingTexture,
            key: key, frameIndex: frameIndex, originX: originX, originY: originY,
            cpuFlareMean: nil, gpuFlareMean: flareMean,
            linearHDREndpoint: LinearHDREndpoint(binding: tail, output: output),
            commandBuffer: commandBuffer)
    }

    private func encodeDevelopedDensityImpl(
        recordExposure: MTLTexture, densityOutput: MTLTexture,
        key: String, frameIndex: UInt64, originX: Int, originY: Int,
        cpuFlareMean suppliedFlareMean: SIMD3<Float>?,
        gpuFlareMean: HandwrittenMetalGlobalMeasurements.FlareMean?,
        linearHDREndpoint: LinearHDREndpoint?,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        if let suppliedFlareMean, !Self.validFlareMean(suppliedFlareMean) {
            return false
        }
        if let gpuFlareMean,
           !gpuFlareMean.isCompatible(
                with: device, frameWidth: recordExposure.width,
                frameHeight: recordExposure.height) {
            return false
        }
        guard originX == 0, originY == 0,
              commandBuffer.status == .notEnqueued,
              recordExposure.pixelFormat == .rgba16Float,
              densityOutput.pixelFormat == .rgba16Float,
              recordExposure.textureType == .type2D,
              densityOutput.textureType == .type2D,
              recordExposure.sampleCount == 1,
              densityOutput.sampleCount == 1,
              recordExposure.mipmapLevelCount == 1,
              densityOutput.mipmapLevelCount == 1,
              recordExposure.arrayLength == 1,
              densityOutput.arrayLength == 1,
              recordExposure.depth == 1,
              densityOutput.depth == 1,
              recordExposure.usage.contains(.shaderRead),
              densityOutput.usage.contains(.shaderRead),
              densityOutput.usage.contains(.shaderWrite),
              !sameTexture(recordExposure, densityOutput),
              recordExposure.device.registryID == device.registryID,
              densityOutput.device.registryID == device.registryID,
              commandBuffer.commandQueue.device.registryID == device.registryID else {
            return false
        }
        lock.lock()
        let state = prepared[key]
        lock.unlock()
        guard let state,
              state.width == recordExposure.width,
              state.height == recordExposure.height,
              state.width == densityOutput.width,
              state.height == densityOutput.height else { return false }
        if let endpoint = linearHDREndpoint {
            guard state.fastPath?.fusedHDRPipeline != nil,
                  endpoint.binding.width == state.width,
                  endpoint.binding.height == state.height,
                  endpoint.binding.printCube.device.registryID == device.registryID,
                  endpoint.output.device.registryID == device.registryID,
                  endpoint.output.textureType == .type2D,
                  endpoint.output.pixelFormat == .rgba16Float,
                  endpoint.output.width == state.width,
                  endpoint.output.height == state.height,
                  endpoint.output.depth == 1,
                  endpoint.output.arrayLength == 1,
                  endpoint.output.mipmapLevelCount == 1,
                  endpoint.output.sampleCount == 1,
                  endpoint.output.usage.contains(.shaderWrite),
                  !sameTexture(endpoint.output, recordExposure),
                  !sameTexture(endpoint.output, densityOutput) else { return false }
        }

        let flareMeanBinding: FlareMeanBinding
        if state.featureMask & FilmEngineFeature.flare == 0 {
            flareMeanBinding = .inline(.zero)
        } else if let gpuFlareMean {
            flareMeanBinding = .gpu(gpuFlareMean)
        } else if let suppliedFlareMean {
            flareMeanBinding = .inline(Self.flareMean4(suppliedFlareMean))
        } else {
            let configured = SIMD3<Float>(
                state.configuration[Configuration.flareMean],
                state.configuration[Configuration.flareMean + 1],
                state.configuration[Configuration.flareMean + 2])
            guard Self.validFlareMean(configured) else {
                // Veiling glare is global; a crop-local substitute would make tiling observable.
                return false
            }
            flareMeanBinding = .inline(Self.flareMean4(configured))
        }

        guard let frameScratch = acquireScratch(for: state) else {
            return false
        }
        let selectedEncoder: MTLComputeCommandEncoder?
        if state.fastPath?.concurrentFrontiers == true {
            selectedEncoder = commandBuffer.makeComputeCommandEncoder(
                dispatchType: .concurrent)
        } else {
            selectedEncoder = commandBuffer.makeComputeCommandEncoder()
        }
        guard let encoder = selectedEncoder else {
            releaseScratch(frameScratch)
            return false
        }
        encoder.label = "Fotufilm handwritten spatial develop ["
            + (state.multiresPath?.name ?? state.fastPath?.name ?? "generic") + "]"

        let width = state.width
        let height = state.height
        let animatedSeed = state.baseSeed &+ UInt32(truncatingIfNeeded: frameIndex)
            &* 0x7F4A7C15

        if let multiresPath = state.multiresPath {
            let profiler = frameScratch.counterSampleBuffer.map {
                DispatchProfiler(
                    sampleBuffer: $0, planName: multiresPath.name,
                    key: key, frameIndex: frameIndex)
            }
            profiler?.begin(encoder)
            encodeMultiresPath(
                encoder, recordExposure: recordExposure, densityOutput: densityOutput,
                scratch: frameScratch, state: state, plan: multiresPath,
                flare: state.featureMask & FilmEngineFeature.flare != 0
                    ? state.configuration[Configuration.flare] : 0,
                mean: flareMeanBinding, seed: animatedSeed, profiler: profiler)
            encoder.endEncoding()
            commandBuffer.addCompletedHandler {
                [weak self, frameScratch, state, profiler, gpuFlareMean] _ in
                if let profiler {
                    self?.publishDispatchProfile(profiler)
                }
                self?.releaseScratch(frameScratch)
                withExtendedLifetime((state, gpuFlareMean)) {}
            }
            return true
        }

        if let fastPath = state.fastPath {
            let profiler = frameScratch.counterSampleBuffer.map {
                DispatchProfiler(
                    sampleBuffer: $0, planName: fastPath.name,
                    key: key, frameIndex: frameIndex)
            }
            profiler?.begin(encoder)
            encodeFastPath(
                encoder, recordExposure: recordExposure, densityOutput: densityOutput,
                scratch: frameScratch, state: state, plan: fastPath,
                flare: state.featureMask & FilmEngineFeature.flare != 0
                    ? state.configuration[Configuration.flare] : 0,
                mean: flareMeanBinding, seed: animatedSeed,
                linearHDREndpoint: linearHDREndpoint, profiler: profiler)
            encoder.endEncoding()
            commandBuffer.addCompletedHandler {
                [weak self, frameScratch, state, profiler, gpuFlareMean] _ in
                if let profiler {
                    self?.publishDispatchProfile(profiler)
                }
                self?.releaseScratch(frameScratch)
                withExtendedLifetime((state, gpuFlareMean, linearHDREndpoint)) {}
            }
            return true
        }

        var current: MTLTexture = recordExposure

        if state.featureMask & FilmEngineFeature.diffusion != 0 {
            encodePyramid(
                encoder, source: current, outputs: frameScratch.scales,
                temporary: frameScratch.gridB, plans: state.diffusion,
                width: width, height: height,
                configuration: state.configurationBuffer, curves: state.curves)
            encodeFinishPyramid(
                encoder, source: current, outputs: frameScratch.scales,
                destination: densityOutput, plans: state.diffusion,
                mode: 0, annular: false, donor: state.featureMask
                    & FilmEngineFeature.donorLayer != 0,
                configuration: state.configurationBuffer,
                width: width, height: height)
            current = densityOutput
        }

        let flare = state.featureMask & FilmEngineFeature.flare != 0
            ? state.configuration[Configuration.flare] : 0
        if let mtf = state.mtf {
            let destination = sameTexture(current, frameScratch.work)
                ? densityOutput : frameScratch.work
            encodeMTF(
                encoder, source: current, destination: destination, plan: mtf,
                flare: flare, mean: flareMeanBinding,
                configuration: state.configuration,
                width: width, height: height)
            current = destination
        } else if flare > 0 {
            let destination = sameTexture(current, frameScratch.work)
                ? densityOutput : frameScratch.work
            encodeCopy(
                encoder, source: current, destination: destination,
                flare: flare, mean: flareMeanBinding, width: width, height: height)
            current = destination
        }

        if state.featureMask & FilmEngineFeature.halation != 0 {
            let annular = state.featureMask & FilmEngineFeature.annularHalation != 0
            encodePyramid(
                encoder, source: current, outputs: frameScratch.scales,
                temporary: frameScratch.gridB, plans: state.halation,
                width: width, height: height,
                configuration: state.configurationBuffer, curves: state.curves)
            let destination = sameTexture(current, densityOutput)
                ? frameScratch.work : densityOutput
            encodeFinishPyramid(
                encoder, source: current, outputs: frameScratch.scales,
                destination: destination, plans: state.halation,
                mode: 1, annular: annular, donor: false,
                configuration: state.configurationBuffer,
                width: width, height: height)
            current = destination
        }

        // Development is in-place in densityOutput. It reads only the current pixel from this
        // texture; all neighbourhood fields have been materialized before the overwrite begins.
        if !sameTexture(current, densityOutput) {
            encodeCopy(
                encoder, source: current, destination: densityOutput,
                flare: 0, mean: .inline(.zero), width: width, height: height)
        }

        var couplerGeometry = SIMD4<UInt32>.zero
        var adjacencyGeometry = SIMD4<UInt32>.zero
        let couplerGrid = frameScratch.work
        let releaseActive = state.featureMask
            & (FilmEngineFeature.couplers | FilmEngineFeature.donorLayer) != 0
        if releaseActive {
            if let plan = state.coupler {
                couplerGeometry = encodeGaussianField(
                    encoder, source: densityOutput, destination: couplerGrid,
                    temporaryA: frameScratch.gridA, temporaryB: frameScratch.gridB,
                    plan: plan, transform: 2, width: width, height: height,
                    originX: originX, originY: originY,
                    configuration: state.configurationBuffer, curves: state.curves)
            } else {
                // The reference realtime schedule stores released inhibitor in half even when it
                // does not diffuse. Keep that pointwise seam, and let develop take the stride-one
                // direct-read path rather than recomputing release in float registers.
                encodeTransform(
                    encoder, source: densityOutput, destination: couplerGrid,
                    transform: 2, configuration: state.configurationBuffer,
                    curves: state.curves, width: width, height: height)
                couplerGeometry = SIMD4(
                    UInt32(width), UInt32(height), 1, 0)
            }
        }

        let adjacencyGrid: MTLTexture
        if let plan = state.adjacency {
            adjacencyGeometry = encodeGaussianField(
                encoder, source: densityOutput, destination: frameScratch.gridA,
                temporaryA: frameScratch.gridA, temporaryB: frameScratch.gridB,
                plan: plan, transform: 1, width: width, height: height,
                originX: originX, originY: originY,
                configuration: state.configurationBuffer, curves: state.curves)
            adjacencyGrid = frameScratch.gridA
        } else {
            adjacencyGrid = frameScratch.gridA
        }

        encodeDevelop(
            encoder, io: densityOutput, coupler: couplerGrid,
            adjacency: adjacencyGrid, printOutput: frameScratch.gridB, state: state,
            couplerGeometry: couplerGeometry,
            adjacencyGeometry: adjacencyGeometry,
            seed: animatedSeed, originX: originX, originY: originY)

        if let print = state.printMTF {
            if let fusedPipeline = print.fusedPipeline {
                encodeFusedPrint(
                    encoder, transmittance: frameScratch.gridB,
                    density: densityOutput, plan: print,
                    pipeline: fusedPipeline,
                    sharpen: state.configuration[Configuration.printSharpen],
                    width: width, height: height)
            } else {
                // Large, unusual print kernels retain the generic implementation. Copying the
                // developed transmittance back also restores its in-place input contract.
                encodeCopy(
                    encoder, source: frameScratch.gridB, destination: densityOutput,
                    flare: 0, mean: .inline(.zero), width: width, height: height)
                _ = encodeGaussianField(
                    encoder, source: densityOutput, destination: frameScratch.work,
                    temporaryA: frameScratch.gridA, temporaryB: frameScratch.gridB,
                    plan: print.gaussian, transform: 0, width: width, height: height,
                    originX: originX, originY: originY,
                    configuration: state.configurationBuffer, curves: state.curves)
                encodeFinishPrint(
                    encoder, density: densityOutput, spread: frameScratch.work,
                    sharpen: state.configuration[Configuration.printSharpen],
                    width: width, height: height)
            }
        }

        encoder.endEncoding()
        commandBuffer.addCompletedHandler {
            [weak self, frameScratch, state, gpuFlareMean] _ in
            self?.releaseScratch(frameScratch)
            withExtendedLifetime((state, gpuFlareMean)) {}
        }
        return true
    }

    public func removeAll() {
        lock.lock()
        prepared.removeAll(keepingCapacity: false)
        dispatchProfiles.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// True when opt-in timestamp sampling was requested and the device supports samples at
    /// compute-dispatch boundaries.
    public var isDispatchProfilingAvailable: Bool {
        dispatchProfilingEnabled && timestampCounterSet != nil
    }

    /// Returns the last completed profile for `key`. Profiles are published by command-buffer
    /// completion handlers, so this remains nil until a profiled fast graph has completed.
    public func latestDispatchProfile(forKey key: String) -> DispatchProfile? {
        lock.lock()
        defer { lock.unlock() }
        return dispatchProfiles[key]
    }

    private func publishDispatchProfile(_ profiler: DispatchProfiler) {
        guard profiler.sampleCount == profiler.labels.count + 1,
              let data = try? profiler.sampleBuffer.resolveCounterRange(
                0..<profiler.sampleCount) else { return }
        let timestamps: [UInt64] = data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: MTLCounterResultTimestamp.self).map(\.timestamp))
        }
        guard timestamps.count == profiler.sampleCount,
              !timestamps.contains(UInt64.max) else { return }
        let dispatches = profiler.labels.indices.map { index in
            DispatchTiming(
                name: profiler.labels[index],
                startTimestamp: timestamps[index],
                endTimestamp: timestamps[index + 1],
                timestampFrequency: timestampFrequency)
        }
        let profile = DispatchProfile(
            planName: profiler.planName, frameIndex: profiler.frameIndex,
            dispatches: dispatches)
        lock.lock()
        dispatchProfiles[profiler.key] = profile
        lock.unlock()
    }

    /// Reports the immutable graph selected during preparation. This is read-only and intended
    /// for benchmark/profiling metadata; encoding never consults caller-provided schedule state.
    public func executionPlan(forKey key: String) -> ExecutionPlan? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = prepared[key] else { return nil }
        if let multires = state.multiresPath, let mtf = state.mtf {
            var bytes = [mtf.threadgroupBytes, 0]
            for index in [0, 2, 1] {
                bytes.append(state.halation[index].threadgroupBytes)
            }
            bytes.append(multires.finishThreadgroupBytes)
            bytes.append(multires.jointThreadgroupBytes)
            bytes.append(multires.developThreadgroupBytes)
            return ExecutionPlan(
                name: multires.name, dispatchCount: multires.dispatchCount,
                threadgroupMemoryBytes: bytes)
        }
        if let fast = state.fastPath, let mtf = state.mtf,
           let coupler = state.coupler, let adjacency = state.adjacency {
            var bytes = [
                mtf.threadgroupBytes,
                0,
            ]
            for index in [0, 2, 1] {
                let halation = state.halation[index]
                if let separable = halation.separable {
                    bytes.append(separable.threadgroupBytes)
                    bytes.append(separable.threadgroupBytes)
                } else {
                    bytes.append(halation.threadgroupBytes)
                }
            }
            bytes.append(fast.finishThreadgroupBytes)
            bytes.append(coupler.threadgroupBytes)
            bytes.append(adjacency.threadgroupBytes)
            bytes.append(fast.developThreadgroupBytes)
            if fast.splitDevelopPipeline != nil, let print = state.printMTF {
                bytes.append(print.threadgroupBytes)
            }
            return ExecutionPlan(
                name: fast.name, dispatchCount: fast.dispatchCount,
                threadgroupMemoryBytes: bytes)
        }
        return ExecutionPlan(
            name: "generic", dispatchCount: genericDispatchCount(state),
            threadgroupMemoryBytes: [])
    }

    private func genericDispatchCount(_ state: Prepared) -> Int {
        var dispatches = 0
        var current = 0 // record = 0, density output = 1, work = 2
        if state.featureMask & FilmEngineFeature.diffusion != 0 {
            dispatches += 10
            current = 1
        }
        let flare = state.featureMask & FilmEngineFeature.flare != 0
            && state.configuration[Configuration.flare] > 0
        if state.mtf != nil || flare {
            dispatches += 1
            current = current == 2 ? 1 : 2
        }
        if state.featureMask & FilmEngineFeature.halation != 0 {
            dispatches += 10
            current = current == 1 ? 2 : 1
        }
        if current != 1 { dispatches += 1 }
        let release = state.featureMask
            & (FilmEngineFeature.couplers | FilmEngineFeature.donorLayer) != 0
        if release {
            if let coupler = state.coupler {
                dispatches += coupler.fusedPipeline == nil ? 3 : 2
            } else {
                dispatches += 1
            }
        }
        if let adjacency = state.adjacency {
            dispatches += adjacency.fusedPipeline == nil ? 3 : 2
        }
        dispatches += 1
        if let print = state.printMTF {
            dispatches += print.fusedPipeline == nil ? 4 : 1
        }
        return dispatches
    }

    @discardableResult
    func _disableFastPathForTesting(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var value = prepared[key],
              value.fastPath != nil || value.multiresPath != nil else { return false }
        value.fastPath = nil
        value.multiresPath = nil
        prepared[key] = value
        return true
    }

    // MARK: - Encoding

    /// Eight-dispatch Digital Reference camera graph. Only the smooth halo correction and the
    /// already-diffused inhibitor/adjacency fields use half/quarter grids. The MTF surface and
    /// nonlinear film development remain one sample per output pixel.
    private func encodeMultiresPath(
        _ encoder: MTLComputeCommandEncoder,
        recordExposure: MTLTexture, densityOutput: MTLTexture,
        scratch: Scratch, state: Prepared, plan: MultiresPathPlan,
        flare: Float, mean: FlareMeanBinding, seed: UInt32,
        profiler: DispatchProfiler?
    ) {
        guard let mtf = state.mtf,
              let mtfDownsample = mtf.downsamplePipeline,
              let blur0 = state.halation[0].fusedPipeline,
              let blur1 = state.halation[1].fusedPipeline,
              let blur2 = state.halation[2].fusedPipeline,
              let halfResponseLUT = state.halfResponseLUT else {
            preconditionFailure("invalid handwritten multires spatial plan")
        }
        let width = state.width
        let height = state.height
        let scale0Width = (width + state.halation[0].stride - 1)
            / state.halation[0].stride
        let scale0Height = (height + state.halation[0].stride - 1)
            / state.halation[0].stride
        let scale1Width = (width + state.halation[1].stride - 1)
            / state.halation[1].stride
        let scale1Height = (height + state.halation[1].stride - 1)
            / state.halation[1].stride

        // 1. Full-resolution ordered MTF plus its exact 4x4 box-reduced first halo level.
        var mtfParameters = MTFParameters(
            extent: SIMD4(UInt32(width), UInt32(height), flare.bitPattern, 1),
            mean: .zero,
            shares: SIMD4(
                state.configuration[Configuration.mtfLumaShare],
                state.configuration[Configuration.mtfPrimaryShare],
                state.configuration[Configuration.mtfPrimaryShare + 1],
                state.configuration[Configuration.mtfPrimaryShare + 2]))
        encoder.setComputePipelineState(mtfDownsample)
        encoder.setTexture(recordExposure, index: 0)
        encoder.setTexture(densityOutput, index: 1)
        encoder.setTexture(scratch.scales[0], index: 2)
        encoder.setBuffer(mtf.weights, offset: 0, index: 0)
        encoder.setBytes(
            &mtfParameters, length: MemoryLayout<MTFParameters>.stride, index: 1)
        mean.bind(to: encoder, index: 2)
        encoder.setThreadgroupMemoryLength(mtf.threadgroupBytes, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + Self.tile - 1) / Self.tile,
                    height: (height + Self.tile - 1) / Self.tile, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: Self.tile, height: Self.tile, depth: 1))
        textureBarrier(encoder)
        profiler?.complete("mtf-downsample-scale0", encoder: encoder)

        // 2. The two coarser physical halo bands share the same stride-eight source reduction.
        var downParameters = SpatialParameters(
            extent: SIMD4(
                UInt32(scale0Width), UInt32(scale0Height),
                UInt32(scale1Width), UInt32(scale1Height)),
            geometry: SIMD4(2, 0, 0, 0))
        encoder.setComputePipelineState(pyramidDownPairPipeline)
        encoder.setTexture(scratch.scales[0], index: 0)
        encoder.setTexture(scratch.scales[1], index: 1)
        encoder.setTexture(scratch.scales[2], index: 2)
        encoder.setBytes(
            &downParameters, length: MemoryLayout<SpatialParameters>.stride, index: 0)
        dispatch(encoder, width: scale1Width, height: scale1Height)
        textureBarrier(encoder)
        profiler?.complete("downsample-scale1-scale2", encoder: encoder)

        // 3-5. Retain all three authored halation bands. Their supports are already decimated by
        // the exact physical schedule; this approximation changes their reconstruction, not their
        // scale weights or convolution kernels.
        encodeFastBlur(
            encoder, source: scratch.scales[0], destination: scratch.gridA,
            temporary: scratch.work, plan: state.halation[0],
            fusedPipeline: blur0, width: scale0Width, height: scale0Height,
            label: "halation-scale0-blur", profiler: profiler)
        encodeFastBlur(
            encoder, source: scratch.scales[2], destination: scratch.scales[0],
            temporary: scratch.work, plan: state.halation[2],
            fusedPipeline: blur2, width: scale1Width, height: scale1Height,
            label: "halation-scale2-blur", profiler: profiler)
        encodeFastBlur(
            encoder, source: scratch.scales[1], destination: scratch.scales[2],
            temporary: scratch.work, plan: state.halation[1],
            fusedPipeline: blur1, width: scale1Width, height: scale1Height,
            label: "halation-scale1-blur", profiler: profiler)

        guard let multiresRelease = scratch.multiresRelease else {
            preconditionFailure("multires plan has no released-inhibitor surface")
        }
        let couplerWidth = (width + plan.coupler.stride - 1) / plan.coupler.stride
        let couplerHeight = (height + plan.coupler.stride - 1) / plan.coupler.stride
        let activationWidth = (width + plan.adjacency.stride - 1)
            / plan.adjacency.stride
        let activationHeight = (height + plan.adjacency.stride - 1)
            / plan.adjacency.stride

        // 6. Evaluate the smooth additive halo correction once per 2x2 block, then average the
        // four full-rate nonlinear responses separately into activation and released-inhibitor
        // half grids. Direct MTF light stays full resolution in `densityOutput`.
        var finish = FastFinishParameters(
            extent: SIMD4(UInt32(width), UInt32(height), 0, 0),
            grid0: SIMD4(UInt32(scale0Width), UInt32(scale0Height), 0, 0),
            grid1: SIMD4(UInt32(scale1Width), UInt32(scale1Height), 0, 0),
            grid2: SIMD4(UInt32(scale1Width), UInt32(scale1Height), 0, 0),
            strides: SIMD4(
                UInt32(state.halation[0].stride), UInt32(state.halation[1].stride),
                UInt32(state.halation[2].stride), 0),
            coupler: SIMD4(
                UInt32(couplerWidth), UInt32(couplerHeight),
                UInt32(plan.coupler.stride), 0),
            adjacency: SIMD4(
                UInt32(activationWidth), UInt32(activationHeight),
                UInt32(plan.adjacency.stride), 0))
        encoder.setComputePipelineState(multiresFinishPipeline)
        encoder.setTexture(densityOutput, index: 0)
        encoder.setTexture(scratch.gridA, index: 1)
        encoder.setTexture(scratch.scales[2], index: 2)
        encoder.setTexture(scratch.scales[0], index: 3)
        encoder.setTexture(scratch.work, index: 4)
        encoder.setTexture(scratch.gridB, index: 5)
        encoder.setTexture(halfResponseLUT, index: 6)
        encoder.setTexture(multiresRelease, index: 7)
        encoder.setBuffer(state.configurationBuffer, offset: 0, index: 0)
        encoder.setBytes(
            &finish, length: MemoryLayout<FastFinishParameters>.stride, index: 1)
        encoder.setThreadgroupMemoryLength(plan.finishThreadgroupBytes, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (activationWidth + Self.tile - 1) / Self.tile,
                    height: (activationHeight + Self.tile - 1) / Self.tile, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: Self.tile, height: Self.tile, depth: 1))
        textureBarrier(encoder)
        profiler?.complete("half-halo-activation-release", encoder: encoder)

        // 7. Blur both already-rounded fields together. Coupler performs its exact 2x2 reduction
        // to quarter resolution inside the convolution; adjacency remains at half resolution.
        encoder.setComputePipelineState(plan.jointFieldsPipeline)
        encoder.setTexture(scratch.gridB, index: 0)
        encoder.setTexture(multiresRelease, index: 1)
        encoder.setTexture(scratch.scales[0], index: 2)
        encoder.setTexture(scratch.gridA, index: 3)
        encoder.setBuffer(plan.coupler.weights, offset: 0, index: 0)
        encoder.setBuffer(plan.adjacency.weights, offset: 0, index: 1)
        encoder.setBuffer(state.configurationBuffer, offset: 0, index: 2)
        var fieldExtent = MultiresFieldParameters(
            activationExtent: SIMD4(
                UInt32(activationWidth), UInt32(activationHeight), 0, 0),
            couplerExtent: SIMD4(
                UInt32(couplerWidth), UInt32(couplerHeight), 0, 0))
        encoder.setBytes(
            &fieldExtent, length: MemoryLayout<MultiresFieldParameters>.stride,
            index: 3)
        encoder.setThreadgroupMemoryLength(plan.jointThreadgroupBytes, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (activationWidth + Self.tile - 1) / Self.tile,
                    height: (activationHeight + Self.tile - 1) / Self.tile, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: Self.tile, height: Self.tile, depth: 1))
        textureBarrier(encoder)
        profiler?.complete("joint-half-quarter-fields", encoder: encoder)

        // 8. Reconstruct the smooth linear-light correction, then perform log conversion,
        // inhibition, the film curve, and density storage independently at every output pixel.
        var develop = DevelopParameters(
            extent: SIMD4(UInt32(width), UInt32(height), 0, 0),
            state: SIMD4(seed, UInt32(bitPattern: state.featureMask), 1, 1),
            coupler: SIMD4(
                UInt32(couplerWidth), UInt32(couplerHeight),
                UInt32(plan.coupler.stride), 0),
            adjacency: SIMD4(
                UInt32(activationWidth), UInt32(activationHeight),
                UInt32(plan.adjacency.stride), 0),
            phases: SIMD4(0, 0, 0, 0), grain: .zero)
        encoder.setComputePipelineState(plan.developPipeline)
        encoder.setTexture(state.curves, index: 0)
        encoder.setTexture(scratch.scales[0], index: 1)
        encoder.setTexture(scratch.gridA, index: 2)
        encoder.setTexture(densityOutput, index: 3)
        encoder.setTexture(scratch.gridB, index: 4)
        encoder.setTexture(halfResponseLUT, index: 5)
        encoder.setTexture(scratch.work, index: 6)
        encoder.setBuffer(state.configurationBuffer, offset: 0, index: 0)
        encoder.setBuffer(state.grain.finePoisson, offset: 0, index: 1)
        encoder.setBuffer(state.grain.normal, offset: 0, index: 2)
        encoder.setBuffer(state.grain.mottlePoisson, offset: 0, index: 3)
        encoder.setBuffer(state.grain.normal, offset: 0, index: 4)
        encoder.setBuffer(state.grain.fineWeights, offset: 0, index: 5)
        encoder.setBuffer(state.grain.mottleWeights, offset: 0, index: 6)
        encoder.setBytes(
            &develop, length: MemoryLayout<DevelopParameters>.stride, index: 7)
        encoder.setThreadgroupMemoryLength(plan.developThreadgroupBytes, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + Self.tile - 1) / Self.tile,
                    height: (height + Self.tile - 1) / Self.tile, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: Self.tile, height: Self.tile, depth: 1))
        textureBarrier(encoder)
        profiler?.complete("full-resolution-develop", encoder: encoder)
    }

    /// Nine-dispatch whole-frame graph used by the realtime PRO-style topology:
    /// MTF/down0, progressive down1+2, three fused pyramid blurs, halation/log/field extraction,
    /// two fused field blurs, and developed-density/print reconstruction.
    private func encodeFastPath(
        _ encoder: MTLComputeCommandEncoder,
        recordExposure: MTLTexture, densityOutput: MTLTexture,
        scratch: Scratch, state: Prepared, plan: FastPathPlan,
        flare: Float, mean: FlareMeanBinding, seed: UInt32,
        linearHDREndpoint: LinearHDREndpoint?,
        profiler: DispatchProfiler?
    ) {
        guard let mtf = state.mtf,
              let mtfDownsample = mtf.downsamplePipeline,
              let blur0 = state.halation[0].fusedPipeline,
              let blur1 = state.halation[1].fusedPipeline,
              let blur2 = state.halation[2].fusedPipeline,
              let coupler = state.coupler,
              let couplerBlur = coupler.fusedPipeline,
              let adjacency = state.adjacency,
              let adjacencyBlur = adjacency.fusedPipeline else {
            preconditionFailure("invalid handwritten spatial fast-path plan")
        }
        let print = state.printMTF
        let width = state.width
        let height = state.height
        let scale0Width = (width + state.halation[0].stride - 1)
            / state.halation[0].stride
        let scale0Height = (height + state.halation[0].stride - 1)
            / state.halation[0].stride
        let scale1Width = (width + state.halation[1].stride - 1)
            / state.halation[1].stride
        let scale1Height = (height + state.halation[1].stride - 1)
            / state.halation[1].stride
        if plan.concurrentFrontiers {
            precondition(scratch.concurrentCoarse.count == 2)
        }

        // 1. The final MTF tile is also the exact 4x4 source of the first pyramid level.
        var mtfParameters = MTFParameters(
            extent: SIMD4(UInt32(width), UInt32(height), flare.bitPattern, 1),
            mean: .zero,
            shares: SIMD4(
                state.configuration[Configuration.mtfLumaShare],
                state.configuration[Configuration.mtfPrimaryShare],
                state.configuration[Configuration.mtfPrimaryShare + 1],
                state.configuration[Configuration.mtfPrimaryShare + 2]))
        encoder.setComputePipelineState(mtfDownsample)
        encoder.setTexture(recordExposure, index: 0)
        encoder.setTexture(densityOutput, index: 1)
        encoder.setTexture(scratch.scales[0], index: 2)
        encoder.setBuffer(mtf.weights, offset: 0, index: 0)
        encoder.setBytes(&mtfParameters, length: MemoryLayout<MTFParameters>.stride, index: 1)
        mean.bind(to: encoder, index: 2)
        encoder.setThreadgroupMemoryLength(mtf.threadgroupBytes, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + Self.tile - 1) / Self.tile,
                    height: (height + Self.tile - 1) / Self.tile, depth: 1),
            threadsPerThreadgroup: MTLSize(width: Self.tile, height: Self.tile, depth: 1))
        textureBarrier(encoder)
        profiler?.complete("mtf-downsample-scale0", encoder: encoder)

        // 2. Stride eight is a 2x2 reduction from stride four. Scale two has the same stride, so
        // the one rounded half result is written to both retained pyramid levels.
        var downParameters = SpatialParameters(
            extent: SIMD4(
                UInt32(scale0Width), UInt32(scale0Height),
                UInt32(scale1Width), UInt32(scale1Height)),
            geometry: SIMD4(2, 0, 0, 0))
        encoder.setComputePipelineState(pyramidDownPairPipeline)
        encoder.setTexture(scratch.scales[0], index: 0)
        encoder.setTexture(scratch.scales[1], index: 1)
        encoder.setTexture(scratch.scales[2], index: 2)
        encoder.setBytes(
            &downParameters, length: MemoryLayout<SpatialParameters>.stride, index: 0)
        dispatch(encoder, width: scale1Width, height: scale1Height)
        textureBarrier(encoder)
        profiler?.complete("downsample-scale1-scale2", encoder: encoder)

        // 3-5. Rotate the raw levels after their last read. This leaves both full-size grid
        // textures free for field extraction without allocating another 4K intermediate.
        let scale2Blur = plan.concurrentFrontiers
            ? scratch.concurrentCoarse[0] : scratch.scales[0]
        let scale1Blur = plan.concurrentFrontiers
            ? scratch.concurrentCoarse[1] : scratch.scales[2]
        encodeFastBlur(
            encoder, source: scratch.scales[0], destination: scratch.gridA,
            temporary: scratch.work, plan: state.halation[0],
            fusedPipeline: blur0, width: scale0Width, height: scale0Height,
            label: "halation-scale0-blur", profiler: profiler,
            barrierAfter: !plan.concurrentFrontiers)
        encodeFastBlur(
            encoder, source: scratch.scales[2], destination: scale2Blur,
            temporary: scratch.work, plan: state.halation[2],
            fusedPipeline: blur2, width: scale1Width, height: scale1Height,
            label: "halation-scale2-blur", profiler: profiler,
            barrierAfter: !plan.concurrentFrontiers)
        encodeFastBlur(
            encoder, source: scratch.scales[1], destination: scale1Blur,
            temporary: scratch.work, plan: state.halation[1],
            fusedPipeline: blur1, width: scale1Width, height: scale1Height,
            label: "halation-scale1-blur", profiler: profiler,
            barrierAfter: true)

        let couplerWidth = (width + coupler.stride - 1) / coupler.stride
        let couplerHeight = (height + coupler.stride - 1) / coupler.stride
        let adjacencyWidth = (width + adjacency.stride - 1) / adjacency.stride
        let adjacencyHeight = (height + adjacency.stride - 1) / adjacency.stride

        // 6. Finish halation, replace the MTF surface with stored log exposure, and reduce the
        // exact activation/release fields directly into their decimated grids.
        var finish = FastFinishParameters(
            extent: SIMD4(UInt32(width), UInt32(height), 0, 0),
            grid0: SIMD4(UInt32(scale0Width), UInt32(scale0Height), 0, 0),
            grid1: SIMD4(UInt32(scale1Width), UInt32(scale1Height), 0, 0),
            grid2: SIMD4(UInt32(scale1Width), UInt32(scale1Height), 0, 0),
            strides: SIMD4(
                UInt32(state.halation[0].stride), UInt32(state.halation[1].stride),
                UInt32(state.halation[2].stride), 0),
            coupler: SIMD4(
                UInt32(couplerWidth), UInt32(couplerHeight), UInt32(coupler.stride), 0),
            adjacency: SIMD4(
                UInt32(adjacencyWidth), UInt32(adjacencyHeight),
                UInt32(adjacency.stride), 0))
        encoder.setComputePipelineState(
            plan.exactSpecialized ? finishFieldsLUTPipeline : finishFieldsPipeline)
        encoder.setTexture(densityOutput, index: 0)
        encoder.setTexture(scratch.gridA, index: 1)
        encoder.setTexture(scale1Blur, index: 2)
        encoder.setTexture(scale2Blur, index: 3)
        let couplerRaw = plan.concurrentFrontiers
            ? scratch.scales[0] : scratch.work
        encoder.setTexture(couplerRaw, index: 4)
        encoder.setTexture(scratch.gridB, index: 5)
        encoder.setTexture(state.curves, index: 6)
        if plan.exactSpecialized {
            guard let halfResponseLUT = state.halfResponseLUT else {
                preconditionFailure("exact spatial plan has no half-response lookup table")
            }
            encoder.setTexture(halfResponseLUT, index: 7)
        }
        encoder.setBuffer(state.configurationBuffer, offset: 0, index: 0)
        encoder.setBytes(&finish, length: MemoryLayout<FastFinishParameters>.stride, index: 1)
        encoder.setThreadgroupMemoryLength(plan.finishThreadgroupBytes, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + Self.tile - 1) / Self.tile,
                    height: (height + Self.tile - 1) / Self.tile, depth: 1),
            threadsPerThreadgroup: MTLSize(width: Self.tile, height: Self.tile, depth: 1))
        textureBarrier(encoder)
        profiler?.complete("halation-finish-field-extraction", encoder: encoder)

        // 7-8. Each separable Gaussian keeps both half-store seams inside one tile dispatch.
        encodeFusedBlur(
            encoder, source: couplerRaw, destination: scratch.gridA,
            pipeline: couplerBlur, weights: coupler.weights, radius: coupler.radius,
            width: couplerWidth, height: couplerHeight,
            threadgroupBytes: coupler.threadgroupBytes, tile: coupler.fusedTile,
            barrierAfter: !plan.concurrentFrontiers)
        profiler?.complete("coupler-blur", encoder: encoder)
        encodeFusedBlur(
            encoder, source: scratch.gridB, destination: scratch.work,
            pipeline: adjacencyBlur, weights: adjacency.weights, radius: adjacency.radius,
            width: adjacencyWidth, height: adjacencyHeight,
            threadgroupBytes: adjacency.threadgroupBytes, tile: adjacency.fusedTile,
            barrierAfter: true)
        profiler?.complete("adjacency-blur", encoder: encoder)

        // 9. The automatic path develops the print halo in one dispatch. The measured split
        // variant instead stores transmittance here and gives dispatch 10 only the cheap print
        // convolution, avoiding repeated curves, release, and grain work around every tile.
        var develop = DevelopParameters(
            extent: SIMD4(UInt32(width), UInt32(height), 0, 0),
            state: SIMD4(
                seed, UInt32(bitPattern: state.featureMask), 1, 1),
            coupler: SIMD4(
                UInt32(couplerWidth), UInt32(couplerHeight), UInt32(coupler.stride), 0),
            adjacency: SIMD4(
                UInt32(adjacencyWidth), UInt32(adjacencyHeight),
                UInt32(adjacency.stride), 0),
            phases: SIMD4(0, 0, UInt32(state.grain.radius), UInt32(plan.printRadius)),
            grain: SIMD4(
                state.configuration[Configuration.grainLambda],
                state.configuration[Configuration.mottleLambda],
                state.configuration[Configuration.grainCorrelation],
                state.configuration[Configuration.printSharpen]))
        if let endpoint = linearHDREndpoint,
           let fusedHDR = plan.fusedHDRPipeline {
            guard let halfResponseLUT = state.halfResponseLUT else {
                preconditionFailure("exact spatial plan has no half-response lookup table")
            }
            var tail = ExactCameraTailParameters(
                minimum: endpoint.binding.minimum,
                inverseRange: endpoint.binding.inverseRange)
            encoder.setComputePipelineState(fusedHDR)
            encoder.setTexture(state.curves, index: 0)
            encoder.setTexture(scratch.gridA, index: 1)
            encoder.setTexture(scratch.work, index: 2)
            encoder.setTexture(densityOutput, index: 3)
            encoder.setTexture(halfResponseLUT, index: 5)
            encoder.setTexture(endpoint.binding.printCube, index: 6)
            encoder.setTexture(endpoint.output, index: 7)
            encoder.setBuffer(state.configurationBuffer, offset: 0, index: 0)
            encoder.setBytes(
                &develop, length: MemoryLayout<DevelopParameters>.stride, index: 7)
            encoder.setBytes(
                &tail, length: MemoryLayout<ExactCameraTailParameters>.stride, index: 8)
            encoder.setThreadgroupMemoryLength(plan.developThreadgroupBytes, index: 0)
            encoder.dispatchThreadgroups(
                MTLSize(width: (width + Self.tile - 1) / Self.tile,
                        height: (height + Self.tile - 1) / Self.tile, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: Self.tile, height: Self.tile, depth: 1))
            textureBarrier(encoder)
            profiler?.complete("develop-density-print-cube", encoder: encoder)
            return
        }
        if let splitDevelop = plan.splitDevelopPipeline {
            encoder.setComputePipelineState(splitDevelop)
            encoder.setTexture(state.curves, index: 0)
            encoder.setTexture(scratch.gridA, index: 1)
            encoder.setTexture(scratch.work, index: 2)
            encoder.setTexture(densityOutput, index: 3)
            encoder.setTexture(scratch.gridB, index: 4)
            if plan.exactSpecialized {
                guard let halfResponseLUT = state.halfResponseLUT else {
                    preconditionFailure("exact spatial plan has no half-response lookup table")
                }
                encoder.setTexture(halfResponseLUT, index: 5)
            }
            encoder.setBuffer(state.configurationBuffer, offset: 0, index: 0)
            encoder.setBuffer(state.grain.finePoisson, offset: 0, index: 1)
            encoder.setBuffer(state.grain.normal, offset: 0, index: 2)
            encoder.setBuffer(state.grain.mottlePoisson, offset: 0, index: 3)
            encoder.setBuffer(state.grain.normal, offset: 0, index: 4)
            encoder.setBuffer(state.grain.fineWeights, offset: 0, index: 5)
            encoder.setBuffer(state.grain.mottleWeights, offset: 0, index: 6)
            encoder.setBytes(
                &develop, length: MemoryLayout<DevelopParameters>.stride, index: 7)
            encoder.setThreadgroupMemoryLength(plan.developThreadgroupBytes, index: 0)
            encoder.dispatchThreadgroups(
                MTLSize(width: (width + Self.tile - 1) / Self.tile,
                        height: (height + Self.tile - 1) / Self.tile, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: Self.tile, height: Self.tile, depth: 1))
            textureBarrier(encoder)
            if let print, let printPipeline = print.fusedPipeline {
                profiler?.complete("develop-store-transmittance", encoder: encoder)
                encodeFusedPrint(
                    encoder, transmittance: scratch.gridB, density: densityOutput,
                    plan: print, pipeline: printPipeline, sharpen: 0,
                    width: width, height: height)
                profiler?.complete("print-mtf", encoder: encoder)
            } else {
                profiler?.complete("develop-density", encoder: encoder)
            }
            return
        }

        guard let developPrint = plan.developPrintPipeline, let print else {
            preconditionFailure("fast endpoint plan has no pipeline")
        }
        encoder.setComputePipelineState(developPrint)
        encoder.setTexture(state.curves, index: 0)
        encoder.setTexture(scratch.gridA, index: 1)
        encoder.setTexture(scratch.work, index: 2)
        encoder.setTexture(densityOutput, index: 3)
        encoder.setBuffer(state.configurationBuffer, offset: 0, index: 0)
        encoder.setBuffer(state.grain.finePoisson, offset: 0, index: 1)
        encoder.setBuffer(state.grain.normal, offset: 0, index: 2)
        encoder.setBuffer(state.grain.mottlePoisson, offset: 0, index: 3)
        encoder.setBuffer(state.grain.normal, offset: 0, index: 4)
        encoder.setBuffer(state.grain.fineWeights, offset: 0, index: 5)
        encoder.setBuffer(state.grain.mottleWeights, offset: 0, index: 6)
        encoder.setBuffer(print.gaussian.weights, offset: 0, index: 7)
        encoder.setBytes(&develop, length: MemoryLayout<DevelopParameters>.stride, index: 8)
        encoder.setThreadgroupMemoryLength(plan.developThreadgroupBytes, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + Self.tile - 1) / Self.tile,
                    height: (height + Self.tile - 1) / Self.tile, depth: 1),
            threadsPerThreadgroup: MTLSize(width: Self.tile, height: Self.tile, depth: 1))
        textureBarrier(encoder)
        profiler?.complete("develop-print", encoder: encoder)
    }

    private func encodeFastBlur(
        _ encoder: MTLComputeCommandEncoder,
        source: MTLTexture, destination: MTLTexture, temporary: MTLTexture,
        plan: ScalePlan, fusedPipeline: MTLComputePipelineState,
        width: Int, height: Int, label: String, profiler: DispatchProfiler?,
        barrierAfter: Bool = true
    ) {
        if let separable = plan.separable {
            encodeTiledSeparableBlurPass(
                encoder, source: source, destination: temporary,
                pipeline: separable.horizontalPipeline, weights: plan.weights,
                radius: plan.radius, width: width, height: height,
                threadgroupBytes: separable.threadgroupBytes, tile: separable.tile)
            profiler?.complete(label + "-horizontal", encoder: encoder)
            encodeTiledSeparableBlurPass(
                encoder, source: temporary, destination: destination,
                pipeline: separable.verticalPipeline, weights: plan.weights,
                radius: plan.radius, width: width, height: height,
                threadgroupBytes: separable.threadgroupBytes, tile: separable.tile)
            profiler?.complete(label + "-vertical", encoder: encoder)
        } else {
            encodeFusedBlur(
                encoder, source: source, destination: destination,
                pipeline: fusedPipeline, weights: plan.weights,
                radius: plan.radius, width: width, height: height,
                threadgroupBytes: plan.threadgroupBytes, tile: plan.fusedTile,
                barrierAfter: barrierAfter)
            profiler?.complete(label, encoder: encoder)
        }
    }

    private func encodeTiledSeparableBlurPass(
        _ encoder: MTLComputeCommandEncoder,
        source: MTLTexture, destination: MTLTexture,
        pipeline: MTLComputePipelineState, weights: MTLBuffer,
        radius: Int, width: Int, height: Int, threadgroupBytes: Int, tile: Int,
        barrierAfter: Bool = true
    ) {
        precondition(!sameTexture(source, destination))
        var parameters = SpatialParameters(
            extent: SIMD4(UInt32(width), UInt32(height), 0, 0),
            geometry: SIMD4(UInt32(radius), 0, 0, 0))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBuffer(weights, offset: 0, index: 0)
        encoder.setBytes(
            &parameters, length: MemoryLayout<SpatialParameters>.stride, index: 1)
        encoder.setThreadgroupMemoryLength(threadgroupBytes, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + tile - 1) / tile,
                    height: (height + tile - 1) / tile, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tile, height: tile, depth: 1))
        if barrierAfter { textureBarrier(encoder) }
    }

    private func encodeFusedBlur(
        _ encoder: MTLComputeCommandEncoder,
        source: MTLTexture, destination: MTLTexture,
        pipeline: MTLComputePipelineState, weights: MTLBuffer,
        radius: Int, width: Int, height: Int, threadgroupBytes: Int, tile: Int,
        barrierAfter: Bool = true
    ) {
        precondition(!sameTexture(source, destination))
        var parameters = SpatialParameters(
            extent: SIMD4(UInt32(width), UInt32(height), 0, 0),
            geometry: SIMD4(UInt32(radius), 0, 0, 0))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBuffer(weights, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<SpatialParameters>.stride, index: 1)
        encoder.setThreadgroupMemoryLength(threadgroupBytes, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + tile - 1) / tile,
                    height: (height + tile - 1) / tile, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tile, height: tile, depth: 1))
        if barrierAfter { textureBarrier(encoder) }
    }

    private func encodeCopy(
        _ encoder: MTLComputeCommandEncoder, source: MTLTexture,
        destination: MTLTexture, flare: Float, mean: FlareMeanBinding,
        width: Int, height: Int
    ) {
        var parameters = CopyParameters(
            extent: SIMD4(UInt32(width), UInt32(height), 0, 0), mean: .zero)
        parameters.extent.z = flare.bitPattern
        encoder.setComputePipelineState(copyPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<CopyParameters>.stride, index: 0)
        mean.bind(to: encoder, index: 1)
        dispatch(encoder, width: width, height: height)
        textureBarrier(encoder)
    }

    private func encodePyramid(
        _ encoder: MTLComputeCommandEncoder, source: MTLTexture,
        outputs: [MTLTexture], temporary: MTLTexture, plans: [ScalePlan],
        width: Int, height: Int, configuration: MTLBuffer, curves: MTLTexture
    ) {
        precondition(outputs.count == 3 && plans.count == 3)
        var previous = source
        var previousWidth = width
        var previousHeight = height
        var previousStride = 1
        for scale in 0..<3 {
            let plan = plans[scale]
            precondition(plan.stride >= previousStride
                         && plan.stride % previousStride == 0,
                         "pyramid strides must be monotonic powers of two")
            let factor = plan.stride / previousStride
            let gridWidth = (width + plan.stride - 1) / plan.stride
            let gridHeight = (height + plan.stride - 1) / plan.stride
            encodeDownsample(
                encoder, source: previous, destination: outputs[scale],
                sourceWidth: previousWidth, sourceHeight: previousHeight,
                destinationWidth: gridWidth, destinationHeight: gridHeight,
                stride: factor, phaseX: 0, phaseY: 0, transform: 0,
                configuration: configuration, curves: curves)
            previous = outputs[scale]
            previousWidth = gridWidth
            previousHeight = gridHeight
            previousStride = plan.stride
        }
        for scale in 0..<3 {
            let plan = plans[scale]
            let gridWidth = (width + plan.stride - 1) / plan.stride
            let gridHeight = (height + plan.stride - 1) / plan.stride
            encodeHorizontal(
                encoder, source: outputs[scale], destination: temporary,
                plan: plan.weights, width: gridWidth, height: gridHeight,
                radius: plan.radius, transform: 0,
                configuration: configuration, curves: curves)
            encodeVertical(
                encoder, source: temporary, destination: outputs[scale],
                plan: plan.weights, width: gridWidth, height: gridHeight,
                radius: plan.radius)
        }
    }

    private func encodeFinishPyramid(
        _ encoder: MTLComputeCommandEncoder, source: MTLTexture,
        outputs: [MTLTexture], destination: MTLTexture, plans: [ScalePlan],
        mode: UInt32, annular: Bool, donor: Bool,
        configuration: MTLBuffer, width: Int, height: Int
    ) {
        precondition(outputs.count == 3 && plans.count == 3)
        precondition(!sameTexture(source, destination))
        var parameters = PyramidParameters(
            extent: SIMD4(
                UInt32(width), UInt32(height), mode, donor ? 1 : 0),
            grid0: SIMD4(
                UInt32((width + plans[0].stride - 1) / plans[0].stride),
                UInt32((height + plans[0].stride - 1) / plans[0].stride), 0, 0),
            grid1: SIMD4(
                UInt32((width + plans[1].stride - 1) / plans[1].stride),
                UInt32((height + plans[1].stride - 1) / plans[1].stride), 0, 0),
            grid2: SIMD4(
                UInt32((width + plans[2].stride - 1) / plans[2].stride),
                UInt32((height + plans[2].stride - 1) / plans[2].stride), 0, 0),
            strides: SIMD4(
                UInt32(plans[0].stride), UInt32(plans[1].stride),
                UInt32(plans[2].stride), annular ? 1 : 0),
            rings: SIMD4(
                plans[0].ringRadius, plans[1].ringRadius,
                plans[2].ringRadius, 0))
        encoder.setComputePipelineState(pyramidPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(outputs[0], index: 1)
        encoder.setTexture(outputs[1], index: 2)
        encoder.setTexture(outputs[2], index: 3)
        encoder.setTexture(destination, index: 4)
        encoder.setBuffer(configuration, offset: 0, index: 0)
        encoder.setBytes(
            &parameters, length: MemoryLayout<PyramidParameters>.stride, index: 1)
        dispatch(encoder, width: width, height: height)
        textureBarrier(encoder)
    }

    private func encodeMTF(
        _ encoder: MTLComputeCommandEncoder, source: MTLTexture,
        destination: MTLTexture, plan: MTFPlan, flare: Float,
        mean: FlareMeanBinding, configuration: [Float], width: Int, height: Int
    ) {
        var parameters = MTFParameters(
            extent: SIMD4(
                UInt32(width), UInt32(height), flare.bitPattern, plan.extended ? 1 : 0),
            mean: .zero,
            shares: SIMD4(
                configuration[Configuration.mtfLumaShare],
                configuration[Configuration.mtfPrimaryShare],
                configuration[Configuration.mtfPrimaryShare + 1],
                configuration[Configuration.mtfPrimaryShare + 2]))
        encoder.setComputePipelineState(plan.pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        // Bound for the shared MTF entry point; the ordinary specialization compiles out writes.
        encoder.setTexture(destination, index: 2)
        encoder.setBuffer(plan.weights, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<MTFParameters>.stride, index: 1)
        mean.bind(to: encoder, index: 2)
        encoder.setThreadgroupMemoryLength(plan.threadgroupBytes, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (width + Self.tile - 1) / Self.tile,
                height: (height + Self.tile - 1) / Self.tile, depth: 1),
            threadsPerThreadgroup: MTLSize(width: Self.tile, height: Self.tile, depth: 1))
        textureBarrier(encoder)
    }

    @discardableResult
    private func encodeGaussianField(
        _ encoder: MTLComputeCommandEncoder, source: MTLTexture,
        destination: MTLTexture, temporaryA: MTLTexture, temporaryB: MTLTexture,
        plan: GaussianPlan, transform: UInt32,
        width: Int, height: Int, originX: Int, originY: Int,
        configuration: MTLBuffer, curves: MTLTexture
    ) -> SIMD4<UInt32> {
        precondition(!sameTexture(source, temporaryA),
                     "Gaussian transform source must not alias its materialization texture")
        precondition(!sameTexture(temporaryA, temporaryB),
                     "Gaussian horizontal source and destination must not alias")
        precondition(!sameTexture(destination, temporaryB),
                     "Gaussian vertical source and destination must not alias")
        let phaseX = originX % plan.stride
        let phaseY = originY % plan.stride
        let gridWidth = (width + phaseX + plan.stride - 1) / plan.stride
        let gridHeight = (height + phaseY + plan.stride - 1) / plan.stride
        let verticalSource: MTLTexture
        if plan.stride > 1 {
            let materialized = sameTexture(temporaryA, destination)
                ? temporaryB : temporaryA
            encodeDownsample(
                encoder, source: source, destination: materialized,
                sourceWidth: width, sourceHeight: height,
                destinationWidth: gridWidth, destinationHeight: gridHeight,
                stride: plan.stride, phaseX: phaseX, phaseY: phaseY,
                transform: transform, configuration: configuration, curves: curves)
            if let fused = plan.fusedPipeline {
                encodeFusedBlur(
                    encoder, source: materialized, destination: destination,
                    pipeline: fused, weights: plan.weights, radius: plan.radius,
                    width: gridWidth, height: gridHeight,
                    threadgroupBytes: plan.threadgroupBytes, tile: plan.fusedTile)
                return SIMD4(
                    UInt32(gridWidth), UInt32(gridHeight),
                    UInt32(plan.stride), UInt32(phaseX))
            }
            let horizontalDestination = sameTexture(materialized, temporaryA)
                ? temporaryB : temporaryA
            encodeHorizontal(
                encoder, source: materialized, destination: horizontalDestination,
                plan: plan.weights, width: gridWidth, height: gridHeight,
                radius: plan.radius, transform: 0,
                configuration: configuration, curves: curves)
            verticalSource = horizontalDestination
        } else if transform != 0 {
            // Activation, inhibitor release, and transmittance are nonlinear. Materialize the
            // transformed field once so a radius-r horizontal pass does not evaluate them 2r+1
            // times per output pixel. `temporaryA` may also be `destination`; the horizontal
            // pass consumes it completely before the vertical pass writes the final field back.
            encodeTransform(
                encoder, source: source, destination: temporaryA,
                transform: transform, configuration: configuration,
                curves: curves, width: width, height: height)
            encodeHorizontal(
                encoder, source: temporaryA, destination: temporaryB,
                plan: plan.weights, width: width, height: height,
                radius: plan.radius, transform: 0,
                configuration: configuration, curves: curves)
            verticalSource = temporaryB
        } else {
            encodeHorizontal(
                encoder, source: source, destination: temporaryB,
                plan: plan.weights, width: width, height: height,
                radius: plan.radius, transform: 0,
                configuration: configuration, curves: curves)
            verticalSource = temporaryB
        }
        encodeVertical(
            encoder, source: verticalSource, destination: destination,
            plan: plan.weights, width: gridWidth, height: gridHeight,
            radius: plan.radius)
        return SIMD4(
            UInt32(gridWidth), UInt32(gridHeight), UInt32(plan.stride), UInt32(phaseX))
    }

    private func encodeTransform(
        _ encoder: MTLComputeCommandEncoder, source: MTLTexture,
        destination: MTLTexture, transform: UInt32,
        configuration: MTLBuffer, curves: MTLTexture,
        width: Int, height: Int
    ) {
        var parameters = SpatialParameters(
            extent: SIMD4(UInt32(width), UInt32(height), 0, 0),
            geometry: SIMD4(transform, 0, 0, 0))
        encoder.setComputePipelineState(transformPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setTexture(curves, index: 2)
        encoder.setBuffer(configuration, offset: 0, index: 0)
        encoder.setBytes(
            &parameters, length: MemoryLayout<SpatialParameters>.stride, index: 1)
        dispatch(encoder, width: width, height: height)
        textureBarrier(encoder)
    }

    private func encodeDownsample(
        _ encoder: MTLComputeCommandEncoder, source: MTLTexture,
        destination: MTLTexture, sourceWidth: Int, sourceHeight: Int,
        destinationWidth: Int, destinationHeight: Int,
        stride: Int, phaseX: Int, phaseY: Int, transform: UInt32,
        configuration: MTLBuffer, curves: MTLTexture
    ) {
        var parameters = SpatialParameters(
            extent: SIMD4(
                UInt32(sourceWidth), UInt32(sourceHeight),
                UInt32(destinationWidth), UInt32(destinationHeight)),
            geometry: SIMD4(
                UInt32(stride), UInt32(phaseX), UInt32(phaseY), transform))
        encoder.setComputePipelineState(downsamplePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setTexture(curves, index: 2)
        encoder.setBuffer(configuration, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<SpatialParameters>.stride,
                         index: 1)
        dispatch(encoder, width: destinationWidth, height: destinationHeight)
        textureBarrier(encoder)
    }

    private func encodeHorizontal(
        _ encoder: MTLComputeCommandEncoder, source: MTLTexture,
        destination: MTLTexture, plan weights: MTLBuffer,
        width: Int, height: Int, radius: Int, transform: UInt32,
        configuration: MTLBuffer, curves: MTLTexture
    ) {
        var parameters = SpatialParameters(
            extent: SIMD4(UInt32(width), UInt32(height), 0, 0),
            geometry: SIMD4(UInt32(radius), transform, 0, 0))
        encoder.setComputePipelineState(horizontalPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setTexture(curves, index: 2)
        encoder.setBuffer(weights, offset: 0, index: 0)
        encoder.setBuffer(configuration, offset: 0, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<SpatialParameters>.stride,
                         index: 2)
        dispatch(encoder, width: width, height: height)
        textureBarrier(encoder)
    }

    private func encodeVertical(
        _ encoder: MTLComputeCommandEncoder, source: MTLTexture,
        destination: MTLTexture, plan weights: MTLBuffer,
        width: Int, height: Int, radius: Int
    ) {
        var parameters = SpatialParameters(
            extent: SIMD4(UInt32(width), UInt32(height), 0, 0),
            geometry: SIMD4(UInt32(radius), 0, 0, 0))
        encoder.setComputePipelineState(verticalPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBuffer(weights, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<SpatialParameters>.stride,
                         index: 1)
        dispatch(encoder, width: width, height: height)
        textureBarrier(encoder)
    }

    private func encodeDevelop(
        _ encoder: MTLComputeCommandEncoder, io: MTLTexture,
        coupler: MTLTexture, adjacency: MTLTexture, printOutput: MTLTexture,
        state: Prepared,
        couplerGeometry: SIMD4<UInt32>, adjacencyGeometry: SIMD4<UInt32>,
        seed: UInt32, originX: Int, originY: Int
    ) {
        var parameters = DevelopParameters(
            extent: SIMD4(
                UInt32(state.width), UInt32(state.height),
                UInt32(originX), UInt32(originY)),
            state: SIMD4(
                seed, UInt32(bitPattern: state.featureMask),
                couplerGeometry.z == 0 ? 0 : 1,
                state.adjacency == nil ? 0 : 1),
            coupler: couplerGeometry,
            adjacency: adjacencyGeometry,
            phases: SIMD4(
                UInt32(originY % max(state.coupler?.stride ?? 1, 1)),
                UInt32(originY % max(state.adjacency?.stride ?? 1, 1)),
                UInt32(state.grain.radius), 0),
            grain: SIMD4(
                state.configuration[Configuration.grainLambda],
                state.configuration[Configuration.mottleLambda],
                state.configuration[Configuration.grainCorrelation], 0))
        encoder.setComputePipelineState(state.grain.pipeline)
        encoder.setTexture(state.curves, index: 0)
        encoder.setTexture(coupler, index: 1)
        encoder.setTexture(adjacency, index: 2)
        encoder.setTexture(io, index: 3)
        encoder.setTexture(printOutput, index: 4)
        encoder.setBuffer(state.configurationBuffer, offset: 0, index: 0)
        encoder.setBuffer(state.grain.finePoisson, offset: 0, index: 1)
        encoder.setBuffer(state.grain.normal, offset: 0, index: 2)
        encoder.setBuffer(state.grain.mottlePoisson, offset: 0, index: 3)
        encoder.setBuffer(state.grain.normal, offset: 0, index: 4)
        encoder.setBuffer(state.grain.fineWeights, offset: 0, index: 5)
        encoder.setBuffer(state.grain.mottleWeights, offset: 0, index: 6)
        encoder.setBytes(&parameters, length: MemoryLayout<DevelopParameters>.stride,
                         index: 7)
        encoder.setThreadgroupMemoryLength(state.grain.threadgroupBytes, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (state.width + Self.tile - 1) / Self.tile,
                height: (state.height + Self.tile - 1) / Self.tile, depth: 1),
            threadsPerThreadgroup: MTLSize(width: Self.tile, height: Self.tile, depth: 1))
        textureBarrier(encoder)
    }

    private func encodeFinishPrint(
        _ encoder: MTLComputeCommandEncoder, density: MTLTexture,
        spread: MTLTexture, sharpen: Float, width: Int, height: Int
    ) {
        var parameters = PrintParameters(
            extent: SIMD4(UInt32(width), UInt32(height), 0, 0),
            values: SIMD4(sharpen, 0, 0, 0))
        encoder.setComputePipelineState(printPipeline)
        encoder.setTexture(density, index: 0)
        encoder.setTexture(spread, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<PrintParameters>.stride,
                         index: 0)
        dispatch(encoder, width: width, height: height)
        textureBarrier(encoder)
    }

    /// The ordinary print graph is horizontal blur -> half store -> vertical blur -> half store
    /// -> sharpen/log. A tile holds both halos and both half seams, so the common small-radius
    /// case needs one dispatch and never aliases its neighborhood source with its destination.
    private func encodeFusedPrint(
        _ encoder: MTLComputeCommandEncoder, transmittance: MTLTexture,
        density: MTLTexture, plan: PrintPlan,
        pipeline: MTLComputePipelineState, sharpen: Float,
        width: Int, height: Int
    ) {
        precondition(!sameTexture(transmittance, density))
        var parameters = PrintParameters(
            extent: SIMD4(UInt32(width), UInt32(height), 0, 0),
            values: SIMD4(sharpen, 0, 0, 0))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(transmittance, index: 0)
        encoder.setTexture(density, index: 1)
        encoder.setBuffer(plan.gaussian.weights, offset: 0, index: 0)
        encoder.setBytes(
            &parameters, length: MemoryLayout<PrintParameters>.stride, index: 1)
        encoder.setThreadgroupMemoryLength(plan.threadgroupBytes, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (width + Self.tile - 1) / Self.tile,
                height: (height + Self.tile - 1) / Self.tile, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: Self.tile, height: Self.tile, depth: 1))
        textureBarrier(encoder)
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder, width: Int, height: Int
    ) {
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: Self.tile, height: Self.tile, depth: 1))
    }

    private func textureBarrier(_ encoder: MTLComputeCommandEncoder) {
        encoder.memoryBarrier(scope: .textures)
    }

    // MARK: - Preparation

    private func makeMTFPlan(
        configuration: [Float], featureMask: Int32
    ) throws -> MTFPlan {
        let primaryRadii = (0..<3).map {
            max(Int(configuration[Configuration.mtfRadius + $0]), 0)
        }
        let primaryRadius = primaryRadii.max() ?? 0
        let extended = featureMask & FilmEngineFeature.mtfLuma != 0
        let secondaryRadii = (0..<3).map {
            max(Int(configuration[Configuration.mtfSecondaryRadius + $0]), 0)
        }
        let lumaRadius = max(Int(configuration[Configuration.mtfLumaRadius]), 0)
        let extendedRadius = extended
            ? max(lumaRadius, secondaryRadii.max() ?? 0)
            : 0
        let radius = max(primaryRadius, extendedRadius)
        let width = 2 * radius + 1
        let channelCount = extended ? 7 : 3
        var values = [Float16](repeating: 0, count: width * channelCount)
        for channel in 0..<channelCount {
            let sigma: Float
            let window: Int
            if channel < 3 {
                sigma = max(configuration[Configuration.mtfSigma + channel], 0.151)
                window = primaryRadius
            } else if channel == 3 {
                sigma = max(configuration[Configuration.mtfLumaSigma], 0.151)
                window = extendedRadius
            } else {
                sigma = max(
                    configuration[Configuration.mtfSecondarySigma + channel - 4], 0.151)
                window = extendedRadius
            }
            let weights = Self.gaussianWeights(sigma: sigma, radius: window)
            for tap in -window...window {
                values[channel * width + tap + radius] = Float16(weights[tap + window])
            }
        }
        let wide = radius > 20
        // An all-primary two-scale mix makes the three secondary channels algebraically dead.
        // Pack the remaining RGB and optional luma taps so Metal executes each ordered half FMA
        // once per tap rather than walking three or four scalar channel loops.
        let packedPrimary = (optimizationVariant == .exactSpecialized
                || optimizationVariant == .perceptualMultires) && !wide
            && (!extended || (0..<3).allSatisfy {
                configuration[Configuration.mtfPrimaryShare + $0] == 1
            })
        let buffer: MTLBuffer?
        if packedPrimary {
            let packed = (0..<width).map { tap in
                SIMD4<Float16>(
                    values[tap], values[width + tap], values[2 * width + tap],
                    extended ? values[3 * width + tap] : 0)
            }
            buffer = makeBuffer(packed)
        } else {
            buffer = makeBuffer(values)
        }
        guard let buffer else {
            throw PreparationError.allocationFailed("MTF weights")
        }
        let padded = Self.tile + 2 * radius
        let tileCells = wide ? 0 : padded * padded * 4
        let rowCells = Self.tile * padded * (packedPrimary ? 4 : channelCount)
        let bytes = Self.aligned16((tileCells + rowCells) * MemoryLayout<Float16>.stride)
        guard bytes <= device.maxThreadgroupMemoryLength else {
            throw PreparationError.unsupportedMTFRadius(radius)
        }
        let pipeline = try specializedMTFPipeline(
            radius: radius, wide: wide, extended: extended, downsample: false,
            packedPrimary: packedPrimary)
        // The fused reduction reuses the source tile after the vertical pass. Wide MTF kernels
        // alias that storage with their row buffer, so unusual large-radius plans stay generic.
        let downsamplePipeline = wide ? nil : try specializedMTFPipeline(
            radius: radius, wide: false, extended: extended, downsample: true,
            packedPrimary: packedPrimary)
        return MTFPlan(
            pipeline: pipeline, downsamplePipeline: downsamplePipeline,
            radius: radius, extended: extended,
            threadgroupBytes: bytes, weights: buffer)
    }

    private func makeGrainPlan(
        configuration: [Float], featureMask: Int32
    ) throws -> GrainPlan {
        let enabled = featureMask & FilmEngineFeature.grain != 0
        let mottle = enabled && featureMask & FilmEngineFeature.grainMottle != 0
        let monochrome = enabled && featureMask & FilmEngineFeature.monochrome != 0
        let printTransmittance = featureMask & FilmEngineFeature.printMTF != 0
        let fineRadius = enabled ? max(Int(configuration[56]), 0) : 0
        let mottleRadius = mottle ? max(Int(configuration[Configuration.mottleRadius]), 0) : 0
        let radius = max(fineRadius, mottleRadius)
        guard radius <= Self.maximumFusedGrainRadius else {
            throw PreparationError.unsupportedGrainRadius(radius)
        }
        let fine = Self.vectorGaussianWeights(
            sigmas: SIMD3(
                configuration[Configuration.grainSigmaLayer],
                configuration[Configuration.grainSigmaLayer + 1],
                configuration[Configuration.grainSigmaLayer + 2]),
            componentRadius: fineRadius, storageRadius: radius)
        let coarse = Self.vectorGaussianWeights(
            sigmas: SIMD3(
                configuration[Configuration.mottleSigmaLayer],
                configuration[Configuration.mottleSigmaLayer + 1],
                configuration[Configuration.mottleSigmaLayer + 2]),
            componentRadius: mottleRadius, storageRadius: radius)
        guard let fineWeights = makeBuffer(fine),
              let mottleWeights = makeBuffer(coarse),
              let finePoisson = makeBuffer(Self.poissonTable(
                lambda: max(configuration[Configuration.grainLambda], 1e-4))),
              let mottlePoisson = makeBuffer(Self.poissonTable(
                lambda: max(configuration[Configuration.mottleLambda], 1e-4))),
              let normal = makeBuffer(Self.normalTable()) else {
            throw PreparationError.allocationFailed("grain tables")
        }
        let pipeline = try specializedGrainPipeline(
            curveMode: Self.curveMode(configuration),
            radius: radius, enabled: enabled, mottle: mottle,
            monochrome: monochrome, printTransmittance: printTransmittance,
            inputLog: false)
        let padded = Self.tile + 2 * radius
        let half4Bytes = MemoryLayout<SIMD4<Float16>>.stride
        let fields = enabled ? (mottle ? 2 : 1) : 0
        let bytes = Self.aligned16(max(
            fields * (padded * padded + Self.tile * padded) * half4Bytes, 16))
        guard bytes <= device.maxThreadgroupMemoryLength else {
            throw PreparationError.unsupportedGrainRadius(radius)
        }
        return GrainPlan(
            pipeline: pipeline, radius: radius, threadgroupBytes: bytes,
            fineWeights: fineWeights, mottleWeights: mottleWeights,
            finePoisson: finePoisson, mottlePoisson: mottlePoisson,
            normal: normal)
    }

    private func makeBoxScale(
        radius: Int, stride: Int, ringRadius: Float, adaptiveCandidate: Bool
    ) throws -> ScalePlan {
        let reducedRadius = Self.stridedRadius(radius, stride: stride)
        let collapsed = Self.collapsedBoxWeights(radius: reducedRadius)
        let blurRadius = reducedRadius * 3
        let vectors = collapsed.map {
            SIMD4<Float16>(repeating: Float16($0))
        }
        guard let buffer = makeBuffer(vectors) else {
            throw PreparationError.allocationFailed("three-box weights")
        }
        let fused = makeFusedBlurPlan(radius: blurRadius)
        let separable = adaptiveCandidate
            && optimizationVariant == .adaptiveSeparableBlur && blurRadius >= 12
            ? makeSeparableBlurPlan(radius: blurRadius) : nil
        return ScalePlan(
            stride: stride, radius: blurRadius,
            ringRadius: ringRadius, weights: buffer,
            fusedPipeline: fused?.0, threadgroupBytes: fused?.1 ?? 0,
            fusedTile: fused?.2 ?? Self.tile, separable: separable)
    }

    private func makeGaussianPlan(
        sigma: Float, radius: Int, decimate: Bool = true
    ) throws -> GaussianPlan {
        let stride = decimate ? Self.gaussianStride(sigma) : 1
        precondition(stride > 0 && stride.nonzeroBitCount == 1)
        let reducedSigma = sqrt(Self.compensatedGaussianVariance(
            sigma: sigma, stride: stride))
        let reducedRadius = stride == 1 ? max(radius, 0)
            : max((radius + stride - 1) / stride, 1)
        let weights = Self.gaussianWeights(sigma: reducedSigma, radius: reducedRadius)
            .map { SIMD4<Float16>(repeating: Float16($0)) }
        guard let buffer = makeBuffer(weights) else {
            throw PreparationError.allocationFailed("Gaussian weights")
        }
        let fused = makeFusedBlurPlan(radius: reducedRadius)
        return GaussianPlan(
            stride: stride, radius: reducedRadius, weights: buffer,
            fusedPipeline: fused?.0, threadgroupBytes: fused?.1 ?? 0,
            fusedTile: fused?.2 ?? Self.tile)
    }

    /// Kernel variance in reduced-grid pixels after compensating for the fixed box-downsample
    /// plus bilinear-reconstruction spread. The resampling pair contributes 0.25 grid-pixel², so
    /// `(kernelVariance + 0.25) * stride² == authoredSigma²` while the safety floor is inactive.
    /// The multires schedule reuses these authored strides and weights; it only fuses evaluation
    /// of fields that are already band-limited by this contract.
    static func compensatedGaussianVariance(sigma: Float, stride: Int) -> Float {
        precondition(stride > 0 && stride.nonzeroBitCount == 1)
        guard stride > 1 else { return sigma * sigma }
        return max(
            sigma * sigma / Float(stride * stride) - 0.25,
            0.0625)
    }

    private func makeFusedBlurPlan(
        radius: Int
    ) -> (MTLComputePipelineState, Int, Int)? {
        let compact15 = optimizationVariant == .compactBlur15
        let tile = compact15 ? 15 : Self.tile
        let padded = tile + 2 * radius
        let bytes = Self.aligned16(
            (padded * padded + (compact15 ? 0 : tile * padded))
                * MemoryLayout<SIMD4<Float16>>.stride)
        guard bytes <= device.maxThreadgroupMemoryLength,
              let pipeline = try? specializedBlurPipeline(
                radius: radius, kind: compact15 ? .compact15 : .fused16) else {
            return nil
        }
        return (pipeline, bytes, tile)
    }

    private func makeSeparableBlurPlan(radius: Int) -> SeparableBlurPlan? {
        let tile = Self.tile
        let bytes = Self.aligned16(
            tile * (tile + 2 * radius)
                * MemoryLayout<SIMD4<Float16>>.stride)
        guard bytes <= device.maxThreadgroupMemoryLength,
              let horizontal = try? specializedBlurPipeline(
                radius: radius, kind: .horizontal16),
              let vertical = try? specializedBlurPipeline(
                radius: radius, kind: .vertical16) else { return nil }
        return SeparableBlurPlan(
            horizontalPipeline: horizontal, verticalPipeline: vertical,
            threadgroupBytes: bytes, tile: tile)
    }

    private func makeFastPathPlan(
        featureMask: Int32, configuration: [Float],
        diffusion: [ScalePlan], halation: [ScalePlan],
        coupler: GaussianPlan?, adjacency: GaussianPlan?, printMTF: PrintPlan?,
        mtf: MTFPlan?, grain: GrainPlan
    ) throws -> FastPathPlan? {
        guard Self.enableNineDispatchFastPath else { return nil }
        // `.perceptualMultires` is all-or-nothing. Unsupported topology executes the strict
        // generic graph instead of falling into a differently specialized schedule.
        guard optimizationVariant != .perceptualMultires else { return nil }
        let required = FilmEngineFeature.mtf | FilmEngineFeature.halation
            | FilmEngineFeature.couplers | FilmEngineFeature.couplerDiffusion
            | FilmEngineFeature.adjacency
        guard featureMask & required == required,
              featureMask & (FilmEngineFeature.diffusion
                  | FilmEngineFeature.annularHalation) == 0,
              diffusion.count == 3, halation.count == 3,
              halation.map(\.stride) == [4, 8, 8],
              halation.allSatisfy({ $0.fusedPipeline != nil }),
              let coupler, coupler.stride == 4, coupler.fusedPipeline != nil,
              let adjacency, adjacency.stride == 2, adjacency.fusedPipeline != nil,
              let mtf, mtf.downsamplePipeline != nil else {
            return nil
        }

        let grainEnabled = featureMask & FilmEngineFeature.grain != 0
        let mottle = grainEnabled && featureMask & FilmEngineFeature.grainMottle != 0
        let monochrome = grainEnabled && featureMask & FilmEngineFeature.monochrome != 0
        // activation float4 + released half4 + the 6x6/4x4/4x4 halation caches.
        let half4Bytes = MemoryLayout<SIMD4<Float16>>.stride
        let float4Bytes = MemoryLayout<SIMD4<Float>>.stride
        let finishBytes = Self.aligned16(
            Self.tile * Self.tile * float4Bytes
                + (Self.tile * Self.tile + 36 + 16 + 16) * half4Bytes)
        guard finishBytes <= device.maxThreadgroupMemoryLength else { return nil }
        let adaptiveExtraDispatches = halation.reduce(0) {
            $0 + ($1.separable == nil ? 0 : 1)
        }

        // Digital Reference HDR reads the developed layers directly. Its camera schedule has no
        // enlarger/paper convolution, and the 60 fps contract disables grain, so the exact path
        // ends at density in dispatch nine instead of manufacturing a transmittance intermediate.
        if optimizationVariant == .exactSpecialized,
           !grainEnabled,
           featureMask & FilmEngineFeature.printMTF == 0,
           printMTF == nil {
            let donor = featureMask & FilmEngineFeature.donorLayer != 0
            let nonlinearWarp = (0..<3).contains {
                configuration[Configuration.couplerReleaseGamma + $0] != 1
            } || configuration[Configuration.donorReleaseGamma] != 1
            let complement = configuration[Configuration.developComplement] != 0
            let develop = try specializedGrainPipeline(
                curveMode: Self.curveMode(configuration),
                radius: grain.radius, enabled: false, mottle: false,
                monochrome: false, printTransmittance: false,
                inputLog: true, exactSpecialized: true,
                dyeCloud: configuration[Configuration.grainLaw] <= 0.5,
                donor: donor, nonlinearWarp: nonlinearWarp,
                complement: complement)
            let fusedHDR = try specializedFusedHDRPipeline(
                curveMode: Self.curveMode(configuration),
                donor: donor, nonlinearWarp: nonlinearWarp, complement: complement)
            let developBytes = grain.threadgroupBytes
                + (6 * 6 + 10 * 10) * half4Bytes
            return FastPathPlan(
                name: "exact-specialized-no-print-no-grain",
                dispatchCount: 9,
                developPrintPipeline: nil, splitDevelopPipeline: develop,
                fusedHDRPipeline: fusedHDR,
                finishThreadgroupBytes: finishBytes,
                developThreadgroupBytes: developBytes,
                printRadius: 0, concurrentFrontiers: false,
                exactSpecialized: true)
        }

        guard featureMask & FilmEngineFeature.printMTF != 0,
              let printMTF else { return nil }
        let printRadius = printMTF.gaussian.radius

        let prefersSplitEndpoint = optimizationVariant == .automatic
            || optimizationVariant == .splitDevelopPrint
            || optimizationVariant == .adaptiveSeparableBlur
            || optimizationVariant == .concurrentFrontiers
            || optimizationVariant == .exactSpecialized
        if prefersSplitEndpoint,
           configuration[Configuration.printSharpen] == 0,
           printMTF.fusedPipeline != nil {
            let develop = try specializedGrainPipeline(
                curveMode: Self.curveMode(configuration),
                radius: grain.radius, enabled: grainEnabled, mottle: mottle,
                monochrome: monochrome, printTransmittance: true,
                inputLog: true,
                exactSpecialized: optimizationVariant == .exactSpecialized,
                dyeCloud: configuration[Configuration.grainLaw] <= 0.5,
                donor: featureMask & FilmEngineFeature.donorLayer != 0,
                nonlinearWarp: (0..<3).contains {
                    configuration[Configuration.couplerReleaseGamma + $0] != 1
                } || configuration[Configuration.donorReleaseGamma] != 1,
                complement: configuration[Configuration.developComplement] != 0)
            let developBytes = grain.threadgroupBytes
                + (optimizationVariant == .exactSpecialized
                    ? (6 * 6 + 10 * 10) * half4Bytes : 0)
            return FastPathPlan(
                name: optimizationVariant == .exactSpecialized
                    ? "exact-specialized-split-print"
                    : optimizationVariant == .concurrentFrontiers
                        ? "concurrent-frontiers-split-print"
                        : adaptiveExtraDispatches > 0
                            ? "adaptive-separable-split-print"
                            : "ten-dispatch-split-print",
                dispatchCount: 10 + adaptiveExtraDispatches,
                developPrintPipeline: nil, splitDevelopPipeline: develop,
                fusedHDRPipeline: nil,
                finishThreadgroupBytes: finishBytes,
                developThreadgroupBytes: developBytes,
                printRadius: printRadius,
                concurrentFrontiers: optimizationVariant == .concurrentFrontiers,
                exactSpecialized: optimizationVariant == .exactSpecialized)
        }

        let developSize = Self.tile + 2 * printRadius
        let noiseSize = developSize + 2 * grain.radius
        let grainFields = grainEnabled ? (mottle ? 2 : 1) : 0
        let couplerSpan = (developSize + coupler.stride - 1) / coupler.stride + 3
        let adjacencySpan = (developSize + adjacency.stride - 1) / adjacency.stride + 3
        let halfCells = grainFields * (
                noiseSize * noiseSize + developSize * noiseSize)
            + couplerSpan * couplerSpan + adjacencySpan * adjacencySpan
            + Self.tile * developSize
        let developBytes = Self.aligned16(
            developSize * developSize * float4Bytes + halfCells * half4Bytes)
        guard developBytes <= device.maxThreadgroupMemoryLength else { return nil }

        let pipeline = try specializedDevelopPrintPipeline(
            grainRadius: grain.radius, printRadius: printRadius,
            grain: grainEnabled, mottle: mottle, monochrome: monochrome)
        return FastPathPlan(
            name: adaptiveExtraDispatches > 0
                ? "adaptive-separable-fused-print"
                : optimizationVariant == .compactBlur15
                    ? "nine-dispatch-compact15" : "nine-dispatch",
            dispatchCount: 9 + adaptiveExtraDispatches,
            developPrintPipeline: pipeline, splitDevelopPipeline: nil,
            fusedHDRPipeline: nil,
            finishThreadgroupBytes: finishBytes,
            developThreadgroupBytes: developBytes,
            printRadius: printRadius,
            concurrentFrontiers: optimizationVariant == .concurrentFrontiers,
            exactSpecialized: false)
    }

    private func makeMultiresPathPlan(
        featureMask: Int32, configuration: [Float],
        frameWidth: Int, frameHeight: Int,
        diffusion: [ScalePlan], halation: [ScalePlan],
        coupler: GaussianPlan?, adjacency: GaussianPlan?, printMTF: PrintPlan?,
        mtf: MTFPlan?, grain: GrainPlan
    ) throws -> MultiresPathPlan? {
        guard optimizationVariant == .perceptualMultires else { return nil }

        // This is a hard topology gate, not feature ablation. If a stock asks for any field that
        // this schedule cannot carry, preparation keeps the strict generic graph instead of
        // silently omitting or substituting it.
        let required = FilmEngineFeature.mtf | FilmEngineFeature.halation
            | FilmEngineFeature.couplers | FilmEngineFeature.couplerDiffusion
            | FilmEngineFeature.adjacency
        let forbidden = FilmEngineFeature.diffusion | FilmEngineFeature.annularHalation
            | FilmEngineFeature.grain | FilmEngineFeature.grainMottle
            | FilmEngineFeature.printMTF
        guard featureMask & required == required,
              featureMask & forbidden == 0,
              frameWidth.isMultiple(of: 4), frameHeight.isMultiple(of: 4),
              diffusion.count == 3, halation.count == 3,
              halation.map(\.stride) == [4, 8, 8],
              halation.allSatisfy({ $0.fusedPipeline != nil }),
              let coupler, coupler.stride == 4,
              let adjacency, adjacency.stride == 2,
              printMTF == nil,
              let mtf, mtf.downsamplePipeline != nil,
              grain.radius == 0 else {
            return nil
        }

        let jointPipeline = try specializedMultiresFieldPipeline(
            couplerRadius: coupler.radius,
            adjacencyRadius: adjacency.radius)
        // One 16x16 half-grid tile covers a 32x32 full-resolution footprint. The three authored
        // halo grids need 10x10, 6x6, and 6x6 cached samples including their bilinear aprons.
        // Loading these cells once replaces twelve global samples per half-grid thread without
        // changing sample phase or any optical kernel.
        let fullFinishTile = Self.tile * adjacency.stride
        let finishSpans = halation.map { fullFinishTile / $0.stride + 2 }
        let finishBytes = Self.aligned16(
            finishSpans.reduce(0) { $0 + $1 * $1 }
                * MemoryLayout<SIMD4<Float16>>.stride)
        guard finishSpans == [10, 6, 6],
              finishBytes <= device.maxThreadgroupMemoryLength else { return nil }

        // Coupler samples a quarter grid, so each tap spans two half-grid activation cells and
        // includes the second cell of the exact 2x2 reduction. Adjacency stays at its authored
        // half-resolution stride and therefore keeps the existing variance-compensated kernel.
        let releasePadded = Self.tile + 4 * coupler.radius
        let activationPadded = Self.tile + 2 * adjacency.radius
        let jointBytes = Self.aligned16(
            (releasePadded * releasePadded
                + activationPadded * activationPadded
                + (Self.tile / 2) * releasePadded
                + Self.tile * activationPadded)
                * MemoryLayout<SIMD4<Float16>>.stride)
        guard jointBytes <= device.maxThreadgroupMemoryLength else { return nil }

        let develop = try specializedGrainPipeline(
            curveMode: Self.curveMode(configuration),
            radius: 0, enabled: false, mottle: false, monochrome: false,
            printTransmittance: false, inputLog: false,
            exactSpecialized: true, dyeCloud: true,
            donor: featureMask & FilmEngineFeature.donorLayer != 0,
            nonlinearWarp: (0..<3).contains {
                configuration[Configuration.couplerReleaseGamma + $0] != 1
            } || configuration[Configuration.donorReleaseGamma] != 1,
            complement: configuration[Configuration.developComplement] != 0,
            multires: true)
        let developBytes = Self.aligned16(
            ((Self.tile / coupler.stride + 2) * (Self.tile / coupler.stride + 2)
                + (Self.tile / adjacency.stride + 2)
                    * (Self.tile / adjacency.stride + 2))
                * MemoryLayout<SIMD4<Float16>>.stride)
        return MultiresPathPlan(
            name: "perceptual-multires-half-fields-screen-no-grain",
            dispatchCount: 8,
            coupler: coupler, adjacency: adjacency,
            jointFieldsPipeline: jointPipeline,
            developPipeline: develop,
            finishThreadgroupBytes: finishBytes,
            jointThreadgroupBytes: jointBytes,
            developThreadgroupBytes: developBytes)
    }

    private func specializedMultiresFieldPipeline(
        couplerRadius: Int, adjacencyRadius: Int
    ) throws -> MTLComputePipelineState {
        let key = MultiresFieldPipelineKey(
            couplerRadius: couplerRadius, adjacencyRadius: adjacencyRadius)
        lock.lock()
        if let hit = multiresFieldPipelines[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let values = MTLFunctionConstantValues()
        var coupler = Int32(couplerRadius)
        var adjacency = Int32(adjacencyRadius)
        values.setConstantValue(&coupler, type: .int, index: 17)
        values.setConstantValue(&adjacency, type: .int, index: 18)
        let pipeline = try makeSpecializedPipeline(
            name: "fotufilm_spatial_multires_joint_fields", values: values)
        lock.lock()
        multiresFieldPipelines[key] = pipeline
        lock.unlock()
        return pipeline
    }

    private func specializedBlurPipeline(
        radius: Int, kind: BlurPipelineKind
    ) throws -> MTLComputePipelineState {
        let key = BlurPipelineKey(radius: radius, kind: kind)
        lock.lock()
        if let hit = blurPipelines[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let values = MTLFunctionConstantValues()
        var radius32 = Int32(radius)
        values.setConstantValue(&radius32, type: .int, index: 0)
        let functionName: String
        switch kind {
        case .fused16:
            functionName = "fotufilm_spatial_fused_blur"
        case .compact15:
            functionName = "fotufilm_spatial_fused_blur_compact15"
        case .horizontal16:
            functionName = "fotufilm_spatial_tiled_blur_horizontal"
        case .vertical16:
            functionName = "fotufilm_spatial_tiled_blur_vertical"
        }
        let pipeline = try makeSpecializedPipeline(
            name: functionName, values: values)
        lock.lock()
        blurPipelines[key] = pipeline
        lock.unlock()
        return pipeline
    }

    private func specializedDevelopPrintPipeline(
        grainRadius: Int, printRadius: Int,
        grain: Bool, mottle: Bool, monochrome: Bool
    ) throws -> MTLComputePipelineState {
        let key = DevelopPrintPipelineKey(
            grainRadius: grainRadius, printRadius: printRadius,
            grain: grain, mottle: mottle, monochrome: monochrome)
        lock.lock()
        if let hit = developPrintPipelines[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let values = MTLFunctionConstantValues()
        var grainRadius32 = Int32(grainRadius)
        var printRadius32 = Int32(printRadius)
        var grainValue = grain
        var mottleValue = mottle
        var monochromeValue = monochrome
        values.setConstantValue(&grainRadius32, type: .int, index: 0)
        values.setConstantValue(&grainValue, type: .bool, index: 3)
        values.setConstantValue(&mottleValue, type: .bool, index: 4)
        values.setConstantValue(&monochromeValue, type: .bool, index: 5)
        values.setConstantValue(&printRadius32, type: .int, index: 8)
        let pipeline = try makeSpecializedPipeline(
            name: "fotufilm_spatial_develop_print", values: values)
        lock.lock()
        developPrintPipelines[key] = pipeline
        lock.unlock()
        return pipeline
    }

    private func specializedMTFPipeline(
        radius: Int, wide: Bool, extended: Bool, downsample: Bool,
        packedPrimary: Bool = false
    ) throws -> MTLComputePipelineState {
        let key = MTFPipelineKey(
            radius: radius, extended: extended, downsample: downsample,
            packedPrimary: packedPrimary)
        lock.lock()
        if let hit = mtfPipelines[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let values = MTLFunctionConstantValues()
        var radius32 = Int32(radius)
        var wideValue = wide
        var extendedValue = extended
        var downsampleValue = downsample
        var packedPrimaryValue = packedPrimary
        values.setConstantValue(&radius32, type: .int, index: 0)
        values.setConstantValue(&wideValue, type: .bool, index: 1)
        values.setConstantValue(&extendedValue, type: .bool, index: 2)
        values.setConstantValue(&downsampleValue, type: .bool, index: 7)
        values.setConstantValue(&packedPrimaryValue, type: .bool, index: 12)
        let pipeline = try makeSpecializedPipeline(
            name: "fotufilm_spatial_mtf", values: values)
        lock.lock()
        mtfPipelines[key] = pipeline
        lock.unlock()
        return pipeline
    }

    private static let curveCellPadding: Double = 0.000002

    private static func curveCacheWidth(_ configuration: [Float]) -> Int {
        var minimumSpacing = Float.infinity
        for channel in 0..<3 {
            let base = FilmEngineInvocation.sampledCurvesOffset
                + channel * FilmEngineInvocation.sampledCurveStride
            let count = Int(configuration[base])
            if count >= 2 {
                for knot in 1..<count {
                    minimumSpacing = min(minimumSpacing, configuration[base + 1 + knot * 3]
                        - configuration[base + 1 + (knot - 1) * 3])
                }
            }
        }
        var width = 4_096
        while width < 16_384 && 16 / Float(width) + Float(2 * curveCellPadding) >= minimumSpacing {
            width *= 2
        }
        return width
    }

    // 0: analytic; 1: every channel is covered by the branch-free cubic cache;
    // 2: mixed, unusually dense, or out-of-range records keep the general evaluator.
    static func curveMode(_ configuration: [Float]) -> Int {
        let cellWidth = 16 / Float(curveCacheWidth(configuration))
        var sampled = 0
        var complete = true
        for channel in 0..<3 {
            let base = FilmEngineInvocation.sampledCurvesOffset
                + channel * FilmEngineInvocation.sampledCurveStride
            let count = Int(configuration[base])
            guard count >= 2 else { complete = false; continue }
            sampled += 1
            // Extreme values use the general evaluator rather than overflowing cached coefficients.
            for knot in 0..<count {
                complete = complete && abs(configuration[base + 2 + knot * 3]) < 1e20
                    && abs(configuration[base + 3 + knot * 3]) < 1e20
            }
            complete = complete && configuration[base + 1] > -8
                && configuration[base + 1 + (count - 1) * 3] < 8
            for knot in 1..<count {
                complete = complete && configuration[base + 1 + knot * 3]
                    - configuration[base + 1 + (knot - 1) * 3] > cellWidth + Float(2 * curveCellPadding)
            }
        }
        return sampled == 0 ? 0 : complete ? 1 : 2
    }

    private func specializedFusedHDRPipeline(
        curveMode: Int,
        donor: Bool, nonlinearWarp: Bool, complement: Bool
    ) throws -> MTLComputePipelineState {
        let key = FusedHDRPipelineKey(
            curveMode: curveMode,
            donor: donor, nonlinearWarp: nonlinearWarp, complement: complement)
        lock.lock()
        if let hit = fusedHDRPipelines[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let values = MTLFunctionConstantValues()
        var curveModeValue = UInt32(curveMode)
        values.setConstantValue(&curveModeValue, type: .uint, index: 20)
        var cachedFields = true
        var donorValue = donor
        var nonlinearWarpValue = nonlinearWarp
        var complementValue = complement
        values.setConstantValue(&cachedFields, type: .bool, index: 11)
        values.setConstantValue(&donorValue, type: .bool, index: 14)
        values.setConstantValue(&nonlinearWarpValue, type: .bool, index: 15)
        values.setConstantValue(&complementValue, type: .bool, index: 16)
        let pipeline = try makeSpecializedPipeline(
            name: "fotufilm_spatial_develop_linear_hdr", values: values)
        lock.lock()
        fusedHDRPipelines[key] = pipeline
        lock.unlock()
        return pipeline
    }

    private func specializedGrainPipeline(
        curveMode: Int,
        radius: Int, enabled: Bool, mottle: Bool, monochrome: Bool,
        printTransmittance: Bool, inputLog: Bool,
        exactSpecialized: Bool = false, dyeCloud: Bool = false,
        donor: Bool = false, nonlinearWarp: Bool = false,
        complement: Bool = false, multires: Bool = false
    ) throws -> MTLComputePipelineState {
        let key = GrainPipelineKey(
            curveMode: curveMode,
            radius: radius, enabled: enabled, mottle: mottle,
            monochrome: monochrome, printTransmittance: printTransmittance,
            inputLog: inputLog, exactSpecialized: exactSpecialized,
            dyeCloud: dyeCloud, donor: donor, nonlinearWarp: nonlinearWarp,
            complement: complement, multires: multires)
        lock.lock()
        if let hit = grainPipelines[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let values = MTLFunctionConstantValues()
        var curveModeValue = UInt32(curveMode)
        values.setConstantValue(&curveModeValue, type: .uint, index: 20)
        var radius32 = Int32(radius)
        var enabledValue = enabled
        var mottleValue = mottle
        var monochromeValue = monochrome
        var printValue = printTransmittance
        var inputLogValue = inputLog
        var exactValue = exactSpecialized
        var dyeCloudValue = dyeCloud
        var donorValue = donor
        var nonlinearWarpValue = nonlinearWarp
        var complementValue = complement
        var multiresValue = multires
        values.setConstantValue(&radius32, type: .int, index: 0)
        values.setConstantValue(&enabledValue, type: .bool, index: 3)
        values.setConstantValue(&mottleValue, type: .bool, index: 4)
        values.setConstantValue(&monochromeValue, type: .bool, index: 5)
        values.setConstantValue(&printValue, type: .bool, index: 6)
        values.setConstantValue(&inputLogValue, type: .bool, index: 9)
        values.setConstantValue(&exactValue, type: .bool, index: 10)
        values.setConstantValue(&exactValue, type: .bool, index: 11)
        values.setConstantValue(&dyeCloudValue, type: .bool, index: 13)
        values.setConstantValue(&donorValue, type: .bool, index: 14)
        values.setConstantValue(&nonlinearWarpValue, type: .bool, index: 15)
        values.setConstantValue(&complementValue, type: .bool, index: 16)
        values.setConstantValue(&multiresValue, type: .bool, index: 19)
        let pipeline = try makeSpecializedPipeline(
            name: "fotufilm_spatial_develop", values: values)
        lock.lock()
        grainPipelines[key] = pipeline
        lock.unlock()
        return pipeline
    }

    private func specializedPrintPipeline(radius: Int) throws -> MTLComputePipelineState {
        lock.lock()
        if let hit = printPipelines[radius] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let values = MTLFunctionConstantValues()
        var radius32 = Int32(radius)
        values.setConstantValue(&radius32, type: .int, index: 0)
        let pipeline = try makeSpecializedPipeline(
            name: "fotufilm_spatial_fused_print_mtf", values: values)
        lock.lock()
        printPipelines[radius] = pipeline
        lock.unlock()
        return pipeline
    }

    private func makeSpecializedPipeline(
        name: String, values: MTLFunctionConstantValues
    ) throws -> MTLComputePipelineState {
        let function: MTLFunction
        do {
            function = try library.makeFunction(name: name, constantValues: values)
        } catch {
            throw PreparationError.metalCompilation(String(describing: error))
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            throw PreparationError.metalCompilation(String(describing: error))
        }
    }

    // Each cell selects a knot and stores both adjacent Hermite cubics around that knot.
    // At the knot, dx is zero and evaluation returns its original Float32 density exactly.
    // Cells containing multiple knots are marked for the canonical general evaluator.
    func makeCurveTexture(configuration: [Float]) -> MTLTexture? {
        let hasSamples = (0..<3).contains {
            configuration[FilmEngineInvocation.sampledCurvesOffset
                + $0 * FilmEngineInvocation.sampledCurveStride] >= 2
        }
        let width = hasSamples ? Self.curveCacheWidth(configuration) : Self.curveSamples
        let height = hasSamples ? 10 : 4
        let components = hasSamples ? 4 : 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: hasSamples ? .rgba32Float : .r32Float,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var table = [Float](repeating: 0, count: width * height * components)
        for row in 0..<4 {
            let base = row < 3 ? Configuration.curves + row * 6 : Configuration.donorCurve
            for sample in 0..<Self.curveSamples {
                let t = Float(sample) / Float(Self.curveSamples - 1)
                let exposure = Self.curveMinimum + (Self.curveMaximum - Self.curveMinimum) * t
                var value = Self.curveDensity(configuration: configuration, base: base, exposure: exposure)
                if row < 3 {
                    value += Self.curveComponentDensity(configuration: configuration,
                        base: Configuration.curveSecondary + row * 5, exposure: exposure)
                    if let sampled = FilmEngineInvocation.sampledFilmDensity(
                        configuration: configuration, channel: row, logExposure: exposure) {
                        value = sampled
                    }
                }
                table[(row * width + sample) * components] = value
            }
        }
        if hasSamples {
            func put(_ row: Int, _ column: Int, _ value: SIMD4<Float>) {
                let index = (row * width + column) * 4
                for component in 0..<4 { table[index + component] = value[component] }
            }
            for channel in 0..<3 {
                let base = FilmEngineInvocation.sampledCurvesOffset
                    + channel * FilmEngineInvocation.sampledCurveStride
                let count = Int(configuration[base])
                guard count >= 2 else {
                    for bin in 0..<width { put(4 + 2 * channel, bin, SIMD4(.nan, 0, 0, 0)) }
                    continue
                }
                var pairs: [(SIMD4<Float>, SIMD4<Float>)] = []
                for knot in 0..<count {
                    let i = base + 1 + knot * 3
                    let x = configuration[i], y = configuration[i + 1], m = configuration[i + 2]
                    var leftA = 0.0, leftB = 0.0, rightA = 0.0, rightB = 0.0
                    if knot > 0 {
                        let h = Double(x) - Double(configuration[i - 3])
                        let secant = (Double(y) - Double(configuration[i - 2])) / h
                        let previous = Double(configuration[i - 1])
                        leftA = (-3 * secant + previous + 2 * Double(m)) / h
                        leftB = (previous + Double(m) - 2 * secant) / (h * h)
                    }
                    if knot + 1 < count {
                        let h = Double(configuration[i + 3]) - Double(x)
                        let secant = (Double(configuration[i + 4]) - Double(y)) / h
                        let next = Double(configuration[i + 5])
                        rightA = (3 * secant - 2 * Double(m) - next) / h
                        rightB = (Double(m) + next - 2 * secant) / (h * h)
                    }
                    pairs.append((SIMD4(x, y, m, 0), SIMD4(
                        Float(leftA), Float(leftB), Float(rightA), Float(rightB))))
                }
                var nextKnot = 0
                for bin in 0..<width {
                    let cellWidth = 16 / Double(width)
                    let origin = Double(bin) * cellWidth - 8
                    // Covers Float32 rounding of (exposure + 8) at either cell edge.
                    let left = origin - Self.curveCellPadding
                    let right = origin + cellWidth + Self.curveCellPadding
                    while nextKnot < count && Double(configuration[base + 1 + nextKnot * 3]) < left {
                        nextKnot += 1
                    }
                    let containsKnot = nextKnot < count
                        && Double(configuration[base + 1 + nextKnot * 3]) <= right
                    let multiple = containsKnot && nextKnot + 1 < count
                        && Double(configuration[base + 1 + (nextKnot + 1) * 3]) <= right
                    let anchor = containsKnot ? nextKnot : max(0, nextKnot - 1)
                    let pair = pairs[anchor]
                    let finite = (0..<4).allSatisfy { pair.1[$0].isFinite }
                    put(4 + 2 * channel, bin, multiple || !finite ? SIMD4(.nan, 0, 0, 0) : pair.0)
                    put(5 + 2 * channel, bin, pair.1)
                }
            }
        }

        table.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: width * components * MemoryLayout<Float>.stride)
        }
        return texture
    }

    /// Bakes the nonlinear response for every finite f16 bit pattern with the same Metal helpers
    /// used by the frame kernels. A later lookup therefore begins at the canonical stored-log seam
    /// and observes the same curve interpolation and release rounding as direct evaluation.
    private func makeHalfResponseLUT(
        configuration: MTLBuffer, curves: MTLTexture
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rg32Float
        descriptor.width = 256
        descriptor.height = 256
        descriptor.arrayLength = 4
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let table = device.makeTexture(descriptor: descriptor),
              let commandBuffer = preparationQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        table.label = "Fotufilm exact half response"
        encoder.label = "Fotufilm bake exact half response"
        encoder.setComputePipelineState(halfResponseBakePipeline)
        encoder.setTexture(curves, index: 0)
        encoder.setTexture(table, index: 1)
        encoder.setBuffer(configuration, offset: 0, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: 256, height: 256, depth: 4),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        return table
    }

    private func makeBuffer<T>(_ values: [T]) -> MTLBuffer? {
        values.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }
    }

    // MARK: - Scratch

    private func acquireScratch(for state: Prepared) -> Scratch? {
        let key = scratchKey(for: state)
        lock.lock()
        if let available = scratch[key]?.first(where: { !$0.leased }) {
            available.leased = true
            lock.unlock()
            return available
        }
        let count = scratch[key]?.count ?? 0
        guard count < maximumInFlightFrames else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        func texture(width: Int, height: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height,
                mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            return device.makeTexture(descriptor: descriptor)
        }
        guard let work = texture(width: key.width, height: key.height),
              let gridA = texture(width: key.width, height: key.height),
              let gridB = texture(width: key.width, height: key.height),
              let scale0 = texture(width: key.scale0Width, height: key.scale0Height),
              let scale1 = texture(width: key.scale1Width, height: key.scale1Height),
              let scale2 = texture(width: key.scale2Width, height: key.scale2Height) else {
            return nil
        }
        work.label = "Fotufilm spatial work"
        gridA.label = "Fotufilm spatial grid A"
        gridB.label = "Fotufilm spatial grid B"
        let scales = [scale0, scale1, scale2]
        for (index, texture) in scales.enumerated() {
            texture.label = "Fotufilm spatial scale \(index)"
        }
        var concurrentCoarse: [MTLTexture] = []
        if optimizationVariant == .concurrentFrontiers {
            guard let coarse0 = texture(
                    width: key.scale1Width, height: key.scale1Height),
                  let coarse1 = texture(
                    width: key.scale1Width, height: key.scale1Height) else {
                return nil
            }
            coarse0.label = "Fotufilm spatial concurrent coarse 0"
            coarse1.label = "Fotufilm spatial concurrent coarse 1"
            concurrentCoarse = [coarse0, coarse1]
        }
        let multiresRelease: MTLTexture?
        if optimizationVariant == .perceptualMultires {
            multiresRelease = texture(
                width: (key.width + 1) / 2, height: (key.height + 1) / 2)
            guard multiresRelease != nil else { return nil }
            multiresRelease?.label = "Fotufilm spatial multires released inhibitor"
        } else {
            multiresRelease = nil
        }
        let counterSampleBuffer: MTLCounterSampleBuffer?
        if let timestampCounterSet {
            let descriptor = MTLCounterSampleBufferDescriptor()
            descriptor.counterSet = timestampCounterSet
            descriptor.label = "Fotufilm spatial dispatch timestamps"
            descriptor.storageMode = .shared
            descriptor.sampleCount = Self.maximumCounterSamples
            counterSampleBuffer = try? device.makeCounterSampleBuffer(
                descriptor: descriptor)
        } else {
            counterSampleBuffer = nil
        }
        let value = Scratch(
            work: work, gridA: gridA, gridB: gridB, scales: scales,
            concurrentCoarse: concurrentCoarse,
            multiresRelease: multiresRelease,
            counterSampleBuffer: counterSampleBuffer)
        lock.lock()
        if let available = scratch[key]?.first(where: { !$0.leased }) {
            available.leased = true
            lock.unlock()
            return available
        }
        guard (scratch[key]?.count ?? 0) < maximumInFlightFrames else {
            lock.unlock()
            return nil
        }
        value.leased = true
        scratch[key, default: []].append(value)
        lock.unlock()
        return value
    }

    private func scratchKey(for state: Prepared) -> ScratchKey {
        var widths = [Int](repeating: 1, count: 3)
        var heights = [Int](repeating: 1, count: 3)
        func include(_ plans: [ScalePlan]) {
            for (scale, plan) in plans.enumerated() {
                widths[scale] = max(
                    widths[scale], (state.width + plan.stride - 1) / plan.stride)
                heights[scale] = max(
                    heights[scale], (state.height + plan.stride - 1) / plan.stride)
            }
        }
        if state.featureMask & FilmEngineFeature.diffusion != 0 {
            include(state.diffusion)
        }
        if state.featureMask & FilmEngineFeature.halation != 0 {
            include(state.halation)
        }
        return ScratchKey(
            width: state.width, height: state.height,
            scale0Width: widths[0], scale0Height: heights[0],
            scale1Width: widths[1], scale1Height: heights[1],
            scale2Width: widths[2], scale2Height: heights[2])
    }

    private func releaseScratch(_ value: Scratch) {
        lock.lock()
        value.leased = false
        lock.unlock()
    }

    private func sameTexture(_ lhs: MTLTexture, _ rhs: MTLTexture) -> Bool {
        (lhs as AnyObject) === (rhs as AnyObject)
    }

    private static func validFlareMean(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
            && value.x >= 0 && value.y >= 0 && value.z >= 0
    }

    private static func flareMean4(_ value: SIMD3<Float>) -> SIMD4<Float> {
        SIMD4(value.x, value.y, value.z, (value.x + value.y + value.z) / 3)
    }

    // MARK: - Tables

    private static func aligned16(_ value: Int) -> Int { (value + 15) & ~15 }

    private static func gaussianWeights(sigma: Float, radius: Int) -> [Float] {
        guard radius > 0 else { return [1] }
        let denominator = max(2 * sigma * sigma, 1e-8)
        var result = (-radius...radius).map { tap in
            exp(-Float(tap * tap) / denominator)
        }
        let sum = result.reduce(0, +)
        if sum > 0 {
            for index in result.indices { result[index] /= sum }
        }
        return result
    }

    private static func vectorGaussianWeights(
        sigmas: SIMD3<Float>, componentRadius: Int, storageRadius: Int
    ) -> [SIMD4<Float16>] {
        var result = [SIMD4<Float16>](
            repeating: .zero, count: storageRadius * 2 + 1)
        for channel in 0..<3 {
            let weights = gaussianWeights(
                sigma: max(sigmas[channel], 0.151), radius: componentRadius)
            for tap in -componentRadius...componentRadius {
                result[tap + storageRadius][channel] = Float16(
                    weights[tap + componentRadius])
            }
        }
        return result
    }

    /// The convolution of three equal normalized boxes, matching gpu_triple_box_blur's table.
    private static func collapsedBoxWeights(radius: Int) -> [Float] {
        guard radius > 0 else { return [1] }
        let box = [Float](repeating: 1 / Float(2 * radius + 1), count: 2 * radius + 1)
        func convolve(_ lhs: [Float], _ rhs: [Float]) -> [Float] {
            var result = [Float](repeating: 0, count: lhs.count + rhs.count - 1)
            for i in lhs.indices {
                for j in rhs.indices { result[i + j] += lhs[i] * rhs[j] }
            }
            return result
        }
        return convolve(convolve(box, box), box)
    }

    private static func halationStride(_ radius: Int) -> Int {
        let width = Float(2 * radius + 1)
        let sigma = sqrt((width * width - 1) * 0.25)
        var stride = 1
        while stride < 8, Float(2 * stride) * 2.5 <= sigma { stride *= 2 }
        return stride
    }

    private static func diffusionStride(_ radius: Int) -> Int {
        let width = Float(2 * radius + 1)
        let sigma = sqrt((width * width - 1) * 0.25)
        var stride = 1
        while stride < 64, Float(2 * stride) * 2.5 <= sigma { stride *= 2 }
        return stride
    }

    private static func stridedRadius(_ radius: Int, stride: Int) -> Int {
        guard stride > 1 else { return radius }
        let width = Float(2 * radius + 1)
        let sigma = sqrt((width * width - 1) * 0.25)
        let variance = max(sigma * sigma / Float(stride * stride) - 0.25, 0.25)
        let scaled = Int((sqrt(4 * variance + 1) - 1) * 0.5 + 0.5)
        return max(scaled, 1)
    }

    private static func gaussianStride(_ sigma: Float) -> Int {
        if sigma >= 8 { return 8 }
        if sigma >= 4 { return 4 }
        if sigma >= 2 { return 2 }
        return 1
    }

    private static func softplus(_ value: Float) -> Float {
        if value > 20 { return value }
        if value < -20 { return exp(value) }
        return log1p(exp(value))
    }

    private static func curveDensity(
        configuration: [Float], base: Int, exposure: Float
    ) -> Float {
        let dMin = configuration[base]
        let gamma = configuration[base + 1]
        let toe = configuration[base + 2]
        let toeWidth = max(configuration[base + 3], 1e-6)
        let shoulder = configuration[base + 4]
        let shoulderWidth = max(configuration[base + 5], 1e-6)
        let toeTerm = toeWidth * softplus((exposure - toe) / toeWidth)
        let shoulderTerm = shoulderWidth * softplus((exposure - shoulder) / shoulderWidth)
        return dMin + gamma * min(max(toeTerm - shoulderTerm, 0), shoulder - toe)
    }

    private static func curveComponentDensity(
        configuration: [Float], base: Int, exposure: Float
    ) -> Float {
        let gamma = configuration[base]
        let toe = configuration[base + 1]
        let toeWidth = max(configuration[base + 2], 1e-6)
        let shoulder = configuration[base + 3]
        let shoulderWidth = max(configuration[base + 4], 1e-6)
        let toeTerm = toeWidth * softplus((exposure - toe) / toeWidth)
        let shoulderTerm = shoulderWidth * softplus((exposure - shoulder) / shoulderWidth)
        return gamma * min(max(toeTerm - shoulderTerm, 0), shoulder - toe)
    }

    private static func normalized(_ values: [Float]) -> [Float] {
        let mean = values.reduce(Float.zero, +) / Float(values.count)
        let variance = values.reduce(Float.zero) {
            let delta = $1 - mean
            return $0 + delta * delta
        } / Float(values.count)
        let deviation = sqrt(max(variance, 1e-12))
        return values.map { ($0 - mean) / deviation }
    }

    private static func poissonTable(lambda: Float) -> [Float] {
        var pmf = [Float](repeating: 0, count: 64)
        var cdf = [Float](repeating: 0, count: 64)
        pmf[0] = exp(-lambda)
        cdf[0] = pmf[0]
        if pmf.count > 1 {
            for n in 1..<pmf.count {
                pmf[n] = pmf[n - 1] * lambda / Float(n)
                cdf[n] = cdf[n - 1] + pmf[n]
            }
        }
        let raw = (0..<1_024).map { index -> Float in
            let p = (Float(index) + 0.5) / 1_024
            return Float(cdf.reduce(0) { $0 + ($1 < p ? 1 : 0) })
        }
        return normalized(raw)
    }

    private static func normalTable() -> [Float] {
        let raw = (0..<1_024).map { index -> Float in
            let p = (Float(index) + 0.5) / 1_024
            let pLow: Float = 0.02425
            let q = p - 0.5
            let r = q * q
            let central = (((((-39.6968303 * r + 220.9461) * r - 275.9285) * r
                + 138.35776) * r - 30.664799) * r + 2.5066283) * q
                / (((((-54.476097 * r + 161.58583) * r - 155.69897) * r
                    + 66.801315) * r - 13.280682) * r + 1)
            let tailP = min(p, 1 - p)
            let t = sqrt(-2 * log(max(tailP, 1e-8)))
            let tail = (((((-0.007784894 * t - 0.32239646) * t - 2.4007583) * t
                - 2.5497324) * t + 4.3746643) * t + 2.938164)
                / ((((0.007784696 * t + 0.32246712) * t + 2.4451342) * t
                    + 3.7544086) * t + 1)
            if p < pLow { return tail }
            if p > 1 - pLow { return -tail }
            return central
        }
        return normalized(raw)
    }

    // MARK: - Metal

}
#endif
