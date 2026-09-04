import Foundation
import Metal
import MetalPerformanceShaders

// Developer benchmark oracle only. Production camera, still, and recording paths use
// HandwrittenMetalFullFrameRenderer and HandwrittenMetalDigitalDelivery exclusively.

#if canImport(FotufilmCore)
import FotufilmCore
#endif

#if canImport(FotufilmHalide)
import FotufilmHalide
private let fotufilm_native_lut_process_buffers = fotufilm_halide_metal_process_buffers
private let fotufilm_native_lut_process_buffers_float = fotufilm_halide_metal_process_buffers_float
#else
@_silgen_name("fotufilm_halide_metal_process_buffers")
private func fotufilm_native_lut_process_buffers(
    _ input: UInt64, _ output: UInt64,
    _ width: Int32, _ height: Int32, _ originX: Int32, _ originY: Int32,
    _ configuration: UnsafePointer<Float>?, _ exposure: UnsafePointer<Float>?,
    _ film: UnsafePointer<Float>?, _ paper: UnsafePointer<Float>?,
    _ dimension: Int32, _ cacheID: UInt64, _ featureMask: Int32, _ seed: UInt32
) -> Int32

@_silgen_name("fotufilm_halide_metal_process_buffers_float")
private func fotufilm_native_lut_process_buffers_float(
    _ input: UInt64, _ output: UInt64,
    _ width: Int32, _ height: Int32, _ originX: Int32, _ originY: Int32,
    _ configuration: UnsafePointer<Float>?, _ exposure: UnsafePointer<Float>?,
    _ film: UnsafePointer<Float>?, _ paper: UnsafePointer<Float>?,
    _ dimension: Int32, _ cacheID: UInt64, _ featureMask: Int32, _ seed: UInt32
) -> Int32

#endif

/// A single Gaussian with the same second moment as the full engine's three-scale halation
/// mixture. The blur is evaluated on a one-eighth-resolution field; its result is folded into the
/// scene before the film cube, so the stock's characteristic curves still shape the returned
/// light. Keeping the full 3x3 return matrix preserves the stock's layered colour bias.
private final class NativeRealtimeHalation {
    static let reduction = 8

    let blur: MPSImageGaussianBlur
    let matrixRows: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    init?(device: MTLDevice, invocation: FilmEngineInvocation) {
        guard invocation.featureMask & FilmEngineFeature.halation != 0 else { return nil }
        let matrixOffset = FilmEngineInvocation.halationMatrixOffset
        let matrix = Array(invocation.configuration[
            matrixOffset..<(matrixOffset + 9)])
        let totalMix = matrix.reduce(0) { $0 + max($1, 0) }
        guard totalMix > 1e-7 else { return nil }

        let kernelOffset = FilmEngineInvocation.halationKernelOffset
        let kernels = Array(invocation.configuration[
            kernelOffset..<(kernelOffset + 9)])
        let radii = (0..<3).map {
            max(invocation.configuration[48 + $0], 0)
        }
        var variance: Float = 0
        for source in 0..<3 {
            let sourceMix = (0..<3).reduce(Float.zero) {
                $0 + max(matrix[$1 * 3 + source], 0)
            }
            guard sourceMix > 0 else { continue }
            let weightSum = (0..<3).reduce(Float.zero) {
                $0 + max(kernels[source * 3 + $1], 0)
            }
            guard weightSum > 0 else { continue }
            for scale in 0..<3 {
                let weight = max(kernels[source * 3 + scale], 0) / weightSum
                // Three passes of a radius-r box have variance r(r + 1).
                variance += sourceMix * weight
                    * radii[scale] * (radii[scale] + 1)
            }
        }
        let sigma = sqrt(max(variance / totalMix, 0))
        guard sigma > 0.3 else { return nil }
        blur = MPSImageGaussianBlur(
            device: device, sigma: sigma / Float(Self.reduction))
        blur.edgeMode = .clamp
        matrixRows = (
            SIMD4(matrix[0], matrix[1], matrix[2], 0),
            SIMD4(matrix[3], matrix[4], matrix[5], 0),
            SIMD4(matrix[6], matrix[7], matrix[8], 0))
    }
}

private struct NativeRealtimeHalationScratch {
    let source: MTLTexture
    let blurred: MTLTexture
}

private struct NativeRealtimeHalationFieldKey: Hashable {
    let rendererKey: String
    let width: Int
    let height: Int
    let commandQueue: ObjectIdentifier
}

/// One temporal halation field is only safe to reuse on a single command queue. Metal preserves
/// command-buffer order within a queue, while separate queues have no implicit ordering between
/// their reads and writes. Retaining the queue also prevents its object identifier from being
/// reused while the cached field exists.
private struct NativeRealtimeHalationField {
    let commandQueue: MTLCommandQueue
    let scratch: NativeRealtimeHalationScratch
}

/// A caller can create a command buffer with unretained references. Keep every externally owned
/// resource used by an encoded frame alive independently of that command-buffer option.
private func retainNativeRealtimeResources(
    _ resources: [AnyObject], untilCompletedBy commandBuffer: MTLCommandBuffer
) {
    commandBuffer.addCompletedHandler { _ in
        withExtendedLifetime(resources) {}
    }
}

private func makeNativeRealtimeHalationScratch(
    device: MTLDevice, width: Int, height: Int
) -> NativeRealtimeHalationScratch? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: (width + NativeRealtimeHalation.reduction - 1)
            / NativeRealtimeHalation.reduction,
        height: (height + NativeRealtimeHalation.reduction - 1)
            / NativeRealtimeHalation.reduction,
        mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite]
    guard let source = device.makeTexture(descriptor: descriptor),
          let blurred = device.makeTexture(descriptor: descriptor) else { return nil }
    return NativeRealtimeHalationScratch(source: source, blurred: blurred)
}

/// Native-resolution colour schedule for recording modes whose frame budget cannot carry the
/// spatial Halide pipeline. A compact cube retains the stock's pointwise chemistry and print
/// response. Stochastic corner selection converges to trilinear interpolation over successive
/// frames while costing one lookup per output pixel; the residual variation supplies fine texture
/// in place of the spatial grain stage.
public final class NativeRealtimeFilmRenderer {
    public static let shared = NativeRealtimeFilmRenderer()

    private static let edge = 65
    // 65³ samples, factored so the bake fits inside both a 1080p and a 4K frame.
    private static let tableWidth = 5 * edge
    private static let tableHeight = 13 * edge
    private static let spatialFeatures = FilmEngineFeature.flare
        | FilmEngineFeature.mtf | FilmEngineFeature.mtfLuma
        | FilmEngineFeature.halation | FilmEngineFeature.couplerDiffusion
        | FilmEngineFeature.adjacency | FilmEngineFeature.grain
        | FilmEngineFeature.grainMottle | FilmEngineFeature.discGrain
        | FilmEngineFeature.printMTF | FilmEngineFeature.diffusion
        | FilmEngineFeature.annularHalation

    /// Legacy packed offsets mirrored from FotufilmHalide.h. Newer appended offsets are exposed by
    /// FilmEngineInvocation; keeping the old block together makes the AOT-superset neutralization
    /// auditable against the C ABI.
    private enum Configuration {
        static let halationMix = 18
        static let grain = 30
        static let mtfRadius = 45
        static let halationRadius = 48
        static let couplerRadius = 52
        static let adjacencyRadius = 54
        static let grainRadius = 56
        static let flare = 57
        static let adjacencyStrength = 59
        static let mtfLumaShare = FilmEngineInvocation.sceneAdjustOffset + 14
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let halationPipeline: MTLComputePipelineState
    private let halationExtractPipeline: MTLComputePipelineState
    private let lock = NSLock()
    private struct Table {
        let texture: MTLTexture
        let halation: NativeRealtimeHalation?
    }
    private var tables: [String: Table] = [:]
    private var halationFields: [
        NativeRealtimeHalationFieldKey: NativeRealtimeHalationField
    ] = [:]
    private var warmHalationFields: Set<NativeRealtimeHalationFieldKey> = []

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        static inline uint pcg(uint value) {
            uint state = value * 747796405u + 2891336453u;
            uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
            return (word >> 22u) ^ word;
        }

        struct Params {
            uint width;
            uint height;
            uint origin_x;
            uint origin_y;
            uint frame;
        };

        struct HalationParams {
            uint4 extent;
            uint4 state;
            float4 matrix_0;
            float4 matrix_1;
            float4 matrix_2;
        };

        static float3 srgb_to_linear(float3 encoded) {
            return select(encoded / 12.92f,
                pow((encoded + 0.055f) / 1.055f, 2.4f),
                encoded > 0.04045f);
        }

        static float3 linear_to_srgb(float3 linear) {
            const float3 positive = max(linear, 0.0f);
            return select(positive * 12.92f,
                1.055f * pow(positive, 1.0f / 2.4f) - 0.055f,
                positive > 0.0031308f);
        }

        kernel void fotufilm_native_realtime_sdr_halation_extract(
            const device uchar4 *input [[buffer(0)]],
            texture2d<half, access::write> reduced [[texture(0)]],
            constant HalationParams &params [[buffer(1)]],
            uint2 position [[thread_position_in_grid]]) {
            if (position.x >= reduced.get_width()
                || position.y >= reduced.get_height()) return;
            const uint2 start = position * 8u;
            float3 sum = 0.0f;
            uint count = 0;
            for (uint y = 0; y < 8u; ++y) {
                for (uint x = 0; x < 8u; ++x) {
                    const uint2 sample = start + uint2(x, y);
                    if (sample.x < params.extent.x && sample.y < params.extent.y) {
                        const uchar4 pixel = input[
                            sample.y * params.extent.x + sample.x];
                        sum += srgb_to_linear(float3(pixel.xyz) / 255.0f);
                        ++count;
                    }
                }
            }
            reduced.write(half4(
                half3(sum / float(max(count, 1u))), 1.0h), position);
        }

        kernel void fotufilm_native_realtime(
            const device uchar4 *input [[buffer(0)]],
            device uchar4 *output [[buffer(1)]],
            texture3d<float, access::read> table [[texture(0)]],
            constant Params &params [[buffer(2)]],
            uint2 position [[thread_position_in_grid]]) {
            if (position.x >= params.width || position.y >= params.height) return;
            uint offset = position.y * params.width + position.x;
            uchar4 pixel = input[offset];
            float3 grid = float3(pixel.xyz) * (64.0f / 255.0f);
            uint3 coordinate = uint3(grid);
            float3 fraction = grid - floor(grid);
            uint frame_x = position.x + params.origin_x;
            uint frame_y = position.y + params.origin_y;
            uint random = pcg(frame_x ^ pcg(frame_y ^ pcg(params.frame)));
            coordinate.x += float(random & 1023u) < fraction.x * 1024.0f;
            coordinate.y += float((random >> 10) & 1023u) < fraction.y * 1024.0f;
            coordinate.z += float((random >> 20) & 1023u) < fraction.z * 1024.0f;
            float3 developed = table.read(coordinate).rgb;
            output[offset] = uchar4(
                uchar3(clamp(developed * 255.0f, 0.0f, 255.0f)), pixel.w);
        }

        kernel void fotufilm_native_realtime_sdr_halation(
            const device uchar4 *input [[buffer(0)]],
            device uchar4 *output [[buffer(1)]],
            texture3d<float, access::read> table [[texture(0)]],
            texture2d<float, access::sample> halo [[texture(1)]],
            texture2d<half, access::write> next_halo [[texture(2)]],
            constant HalationParams &params [[buffer(2)]],
            uint2 position [[thread_position_in_grid]]) {
            if (position.x >= params.extent.x || position.y >= params.extent.y) return;
            const uint offset = position.y * params.extent.x + position.x;
            const uchar4 pixel = input[offset];
            const float3 direct = srgb_to_linear(float3(pixel.xyz) / 255.0f);
            if ((position.x & 7u) == 0u && (position.y & 7u) == 0u) {
                next_halo.write(half4(half3(direct), 1.0h), position / 8u);
            }
            constexpr sampler bilinear(coord::normalized, address::clamp_to_edge,
                                       filter::linear);
            const float2 uv = (float2(position) + 0.5f)
                / float2(params.extent.xy);
            // The stored field is binary16. Compare against the same quantization so a
            // uniform field cannot acquire a halo from float-to-half rounding alone.
            const float4 blurred = halo.sample(bilinear, uv);
            const float3 returned = float3(half3(blurred.rgb / blurred.a)) - float3(half3(direct));
            const float3 exposed = max(direct + float3(
                dot(params.matrix_0.xyz, returned),
                dot(params.matrix_1.xyz, returned),
                dot(params.matrix_2.xyz, returned)), 0.0f);
            // Preserve the pointwise lookup exactly when no returned-light contrast exists.
            const float3 grid = all(returned == float3(0.0f))
                ? float3(pixel.xyz) * (64.0f / 255.0f)
                : clamp(linear_to_srgb(exposed), 0.0f, 1.0f) * 64.0f;
            uint3 coordinate = uint3(grid);
            const float3 fraction = grid - floor(grid);
            const uint frame_x = position.x + params.extent.z;
            const uint frame_y = position.y + params.extent.w;
            const uint random = pcg(frame_x ^ pcg(frame_y ^ pcg(params.state.x)));
            coordinate.x += float(random & 1023u) < fraction.x * 1024.0f;
            coordinate.y += float((random >> 10) & 1023u) < fraction.y * 1024.0f;
            coordinate.z += float((random >> 20) & 1023u) < fraction.z * 1024.0f;
            const float3 developed = table.read(coordinate).rgb;
            output[offset] = uchar4(
                uchar3(clamp(developed * 255.0f, 0.0f, 255.0f)), pixel.w);
        }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard let function = library.makeFunction(
                name: "fotufilm_native_realtime"),
                  let halationFunction = library.makeFunction(
                    name: "fotufilm_native_realtime_sdr_halation"),
                  let extractFunction = library.makeFunction(
                    name: "fotufilm_native_realtime_sdr_halation_extract")
            else { return nil }
            pipeline = try device.makeComputePipelineState(function: function)
            halationPipeline = try device.makeComputePipelineState(
                function: halationFunction)
            halationExtractPipeline = try device.makeComputePipelineState(
                function: extractFunction)
        } catch {
            print("NativeRealtimeFilmRenderer: Metal library failed (\(error))")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    /// Bakes the pointwise part of one stock at the output frame's native dimensions. Callers own
    /// the key and replace it whenever an edit changes; keeping that lifecycle outside this type
    /// avoids hashing the engine's large tone-grid configuration on every camera frame.
    @discardableResult
    public func prepare(
        key: String, stock: FilmStock, options: FotufilmEngine.Options,
        frameWidth: Int, frameHeight: Int
    ) -> Bool {
        guard frameWidth > 0, frameHeight > 0 else { return false }
        var invocation = FilmEngineInvocation(
            stock: stock, options: options,
            width: frameWidth, height: frameHeight)
        let halation = NativeRealtimeHalation(
            device: device, invocation: invocation)
        invocation.featureMask &= ~Self.spatialFeatures
        // iOS may serve a narrow request from a generated superset. Zero the spatial runtime
        // parameters as well as their feature bits so every such extra stage is an exact no-op.
        invocation.configuration.replaceSubrange(
            Configuration.halationMix..<(Configuration.halationMix + 3),
            with: [Float](repeating: 0, count: 3))
        invocation.configuration.replaceSubrange(
            Configuration.grain..<(Configuration.grain + 3),
            with: [Float](repeating: 0, count: 3))
        invocation.configuration.replaceSubrange(
            Configuration.mtfRadius..<(Configuration.mtfRadius + 3),
            with: [Float](repeating: 0, count: 3))
        invocation.configuration.replaceSubrange(
            Configuration.halationRadius..<(Configuration.halationRadius + 3),
            with: [Float](repeating: 0, count: 3))
        invocation.configuration[Configuration.couplerRadius] = 0
        invocation.configuration[Configuration.adjacencyRadius] = 0
        invocation.configuration[Configuration.grainRadius] = 0
        invocation.configuration[Configuration.flare] = 0
        invocation.configuration[Configuration.adjacencyStrength] = 0
        invocation.configuration[Configuration.mtfLumaShare] = 0
        invocation.configuration.replaceSubrange(
            FilmEngineInvocation.mottleOffset..<(FilmEngineInvocation.mottleOffset + 3),
            with: [Float](repeating: 0, count: 3))
        invocation.configuration[FilmEngineInvocation.mottleSigmaOffset + 1] = 0
        invocation.configuration[FilmEngineInvocation.printMTFOffset + 1] = 0
        invocation.configuration.replaceSubrange(
            FilmEngineInvocation.diffusionKernelOffset..<(
                FilmEngineInvocation.diffusionKernelOffset + 9),
            with: [Float](repeating: 0, count: 9))
        invocation.configuration[FilmEngineInvocation.diffusionDirectOffset] = 1
        invocation.configuration.replaceSubrange(
            FilmEngineInvocation.diffusionRadiusOffset..<(
                FilmEngineInvocation.diffusionRadiusOffset + 3),
            with: [Float](repeating: 0, count: 3))
        invocation.configuration.replaceSubrange(
            FilmEngineInvocation.halationRingRadiusOffset..<(
                FilmEngineInvocation.halationRingRadiusOffset + 3),
            with: [Float](repeating: 0, count: 3))
        invocation.configuration.replaceSubrange(
            FilmEngineInvocation.halationMatrixOffset..<(
                FilmEngineInvocation.halationMatrixOffset + 9),
            with: [Float](repeating: 0, count: 9))
        invocation.configuration.replaceSubrange(
            FilmEngineInvocation.mtfSecondaryRadiusOffset..<(
                FilmEngineInvocation.mtfSecondaryRadiusOffset + 3),
            with: [Float](repeating: 0, count: 3))

        let width = Self.tableWidth
        let height = Self.tableHeight
        let byteCount = width * height * 4
        guard let input = device.makeBuffer(length: byteCount,
                                            options: .storageModeShared),
              let output = device.makeBuffer(length: byteCount,
                                             options: .storageModeShared) else { return false }
        let samples = input.contents().assumingMemoryBound(to: UInt8.self)
        for blue in 0..<Self.edge {
            for green in 0..<Self.edge {
                for red in 0..<Self.edge {
                    let offset = ((blue * Self.edge + green) * Self.edge + red) * 4
                    samples[offset] = UInt8((red * 255) / (Self.edge - 1))
                    samples[offset + 1] = UInt8((green * 255) / (Self.edge - 1))
                    samples[offset + 2] = UInt8((blue * 255) / (Self.edge - 1))
                    samples[offset + 3] = 255
                }
            }
        }
        let inputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(input as AnyObject).toOpaque()))
        let outputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(output as AnyObject).toOpaque()))
        let rendered = invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                fotufilm_native_lut_process_buffers(
                    inputHandle, outputHandle, Int32(width), Int32(height), 0, 0,
                    configuration.baseAddress, exposure, film, paper,
                    Int32(invocation.spectral.exposure.dimension),
                    invocation.spectralCacheID, invocation.featureMask,
                    invocation.seed) == 0
            }
        }
        guard rendered else { return false }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = Self.edge
        descriptor.height = Self.edge
        descriptor.depth = Self.edge
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let table = device.makeTexture(descriptor: descriptor) else { return false }
        table.replace(
            region: MTLRegionMake3D(0, 0, 0, Self.edge, Self.edge, Self.edge),
            mipmapLevel: 0, slice: 0, withBytes: output.contents(),
            bytesPerRow: Self.edge * 4,
            bytesPerImage: Self.edge * Self.edge * 4)
        lock.lock()
        tables[key] = Table(texture: table, halation: halation)
        lock.unlock()
        return true
    }

    @discardableResult
    public func processRGBA8(
        input: MTLBuffer, output: MTLBuffer,
        width: Int, height: Int, originX: Int = 0, originY: Int = 0,
        key: String, frameIndex: UInt64
    ) -> Bool {
        guard let commandBuffer = queue.makeCommandBuffer(),
              encodeRGBA8(
                input: input, output: output, width: width, height: height,
                originX: originX, originY: originY, key: key,
                frameIndex: frameIndex, commandBuffer: commandBuffer)
        else { return false }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    /// Encodes a frame into a caller-owned command buffer without committing or waiting for it.
    /// This lets capture conversion, film rendering, and presentation share one GPU submission.
    /// The caller must finish any encoder already open on `commandBuffer` before calling.
    @discardableResult
    public func encodeRGBA8(
        input: MTLBuffer, output: MTLBuffer,
        width: Int, height: Int, originX: Int = 0, originY: Int = 0,
        key: String, frameIndex: UInt64,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        let byteCount = width * height * 4
        guard width > 0, height > 0, originX >= 0, originY >= 0,
              input.length >= byteCount, output.length >= byteCount,
              commandBuffer.device === device,
              commandBuffer.status == .notEnqueued else { return false }
        guard let resources = frameResources(
            key: key, width: width, height: height,
            commandBuffer: commandBuffer) else { return false }
        let table = resources.table
        if let halation = table.halation {
            guard let fieldKey = resources.fieldKey,
                  let field = resources.field else { return false }
            let fieldIsWarm = resources.fieldIsWarm
            let scratch = field.scratch
            retainNativeRealtimeResources(
                [self, input, output, table.texture, halation,
                 field.commandQueue, scratch.source, scratch.blurred],
                untilCompletedBy: commandBuffer)
            var halationParameters = HalationParameters(
                extent: SIMD4(UInt32(width), UInt32(height),
                              UInt32(originX), UInt32(originY)),
                state: SIMD4(UInt32(truncatingIfNeeded: frameIndex), 0, 0, 0),
                matrix0: halation.matrixRows.0,
                matrix1: halation.matrixRows.1,
                matrix2: halation.matrixRows.2)
            if !fieldIsWarm {
                guard let extract = commandBuffer.makeComputeCommandEncoder() else {
                    return false
                }
                extract.setComputePipelineState(halationExtractPipeline)
                extract.setBuffer(input, offset: 0, index: 0)
                extract.setTexture(scratch.source, index: 0)
                extract.setBytes(&halationParameters,
                                 length: MemoryLayout<HalationParameters>.stride,
                                 index: 1)
                extract.dispatchThreads(
                    MTLSize(width: scratch.source.width,
                            height: scratch.source.height, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                extract.endEncoding()
                halation.blur.encode(
                    commandBuffer: commandBuffer, sourceTexture: scratch.source,
                    destinationTexture: scratch.blurred)
            }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                return false
            }
            encoder.setComputePipelineState(halationPipeline)
            encoder.setBuffer(input, offset: 0, index: 0)
            encoder.setBuffer(output, offset: 0, index: 1)
            encoder.setTexture(table.texture, index: 0)
            encoder.setTexture(scratch.blurred, index: 1)
            encoder.setTexture(scratch.source, index: 2)
            encoder.setBytes(&halationParameters,
                             length: MemoryLayout<HalationParameters>.stride,
                             index: 2)
            encoder.dispatchThreads(
                MTLSize(width: width, height: height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
            encoder.endEncoding()
            if fieldIsWarm {
                halation.blur.encode(
                    commandBuffer: commandBuffer, sourceTexture: scratch.source,
                    destinationTexture: scratch.blurred)
            }
            if !fieldIsWarm {
                commandBuffer.addCompletedHandler { [weak self, source = scratch.source] in
                    guard $0.status == .completed, let self else { return }
                    self.lock.lock()
                    if self.halationFields[fieldKey]?.scratch.source === source {
                        self.warmHalationFields.insert(fieldKey)
                    }
                    self.lock.unlock()
                }
            }
            return true
        }
        retainNativeRealtimeResources(
            [self, input, output, table.texture], untilCompletedBy: commandBuffer)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        var parameters = Parameters(
            width: UInt32(width), height: UInt32(height),
            originX: UInt32(originX), originY: UInt32(originY),
            frame: UInt32(truncatingIfNeeded: frameIndex))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setTexture(table.texture, index: 0)
        encoder.setBytes(&parameters,
                         length: MemoryLayout<Parameters>.stride, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
        encoder.endEncoding()
        return true
    }

    public func removeAll() {
        lock.lock()
        tables.removeAll(keepingCapacity: false)
        halationFields.removeAll(keepingCapacity: false)
        warmHalationFields.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func frameResources(
        key: String, width: Int, height: Int,
        commandBuffer: MTLCommandBuffer
    ) -> (
        table: Table,
        fieldKey: NativeRealtimeHalationFieldKey?,
        field: NativeRealtimeHalationField?,
        fieldIsWarm: Bool
    )? {
        lock.lock()
        defer { lock.unlock() }
        guard let table = tables[key] else { return nil }
        guard table.halation != nil else {
            return (table, nil, nil, false)
        }
        let fieldKey = NativeRealtimeHalationFieldKey(
            rendererKey: key, width: width, height: height,
            commandQueue: ObjectIdentifier(commandBuffer.commandQueue))
        if let field = halationFields[fieldKey] {
            return (table, fieldKey, field,
                    warmHalationFields.contains(fieldKey))
        }
        guard let scratch = makeNativeRealtimeHalationScratch(
            device: device, width: width, height: height) else { return nil }
        let field = NativeRealtimeHalationField(
            commandQueue: commandBuffer.commandQueue, scratch: scratch)
        halationFields[fieldKey] = field
        return (table, fieldKey, field, false)
    }

    private struct Parameters {
        var width: UInt32
        var height: UInt32
        var originX: UInt32
        var originY: UInt32
        var frame: UInt32
    }

    private struct HalationParameters {
        var extent: SIMD4<UInt32>
        var state: SIMD4<UInt32>
        var matrix0: SIMD4<Float>
        var matrix1: SIMD4<Float>
        var matrix2: SIMD4<Float>
    }
}

/// Native-resolution HDR counterpart to `NativeRealtimeFilmRenderer`. The cube is sampled and
/// stored in float formats, so the 10-bit camera signal keeps its scene headroom through the film
/// transform. A logarithmic input axis gives shadows and diffuse light most of the cube while
/// retaining values through Apple Log's full scene range.
public final class NativeRealtimeHDRFilmRenderer {
    public static let shared = NativeRealtimeHDRFilmRenderer()

    private static let edge = 65
    private static let tableWidth = 5 * edge
    private static let tableHeight = 13 * edge
    private static let inputCeiling: Float = 16
    /// A log shaper toe below the darkest camera value worth distinguishing. The former log1p
    /// axis put every component from zero through 0.045 in its first cell; saturated shadows then
    /// interpolated across black and visibly changed hue.
    private static let inputKnee: Float = 0.01
    private static let spatialFeatures = FilmEngineFeature.flare
        | FilmEngineFeature.mtf | FilmEngineFeature.mtfLuma
        | FilmEngineFeature.halation | FilmEngineFeature.couplerDiffusion
        | FilmEngineFeature.adjacency | FilmEngineFeature.grain
        | FilmEngineFeature.grainMottle | FilmEngineFeature.discGrain
        | FilmEngineFeature.printMTF | FilmEngineFeature.diffusion
        | FilmEngineFeature.annularHalation

    private enum Configuration {
        static let halationMix = 18
        static let grain = 30
        static let mtfRadius = 45
        static let halationRadius = 48
        static let couplerRadius = 52
        static let adjacencyRadius = 54
        static let grainRadius = 56
        static let flare = 57
        static let adjacencyStrength = 59
        static let mtfLumaShare = FilmEngineInvocation.sceneAdjustOffset + 14
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let capturePipeline: MTLComputePipelineState
    private let halationPipeline: MTLComputePipelineState
    private let captureHalationPipeline: MTLComputePipelineState
    private let halationExtractPipeline: MTLComputePipelineState
    private let captureHalationExtractPipeline: MTLComputePipelineState
    private let lock = NSLock()
    private struct Cube {
        let texture: MTLTexture
        let shaperScale: Float
        let halation: NativeRealtimeHalation?
    }
    private var tables: [String: Cube] = [:]
    private var halationFields: [
        NativeRealtimeHalationFieldKey: NativeRealtimeHalationField
    ] = [:]
    private var warmHalationFields: Set<NativeRealtimeHalationFieldKey> = []

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        static inline uint pcg(uint value) {
            uint state = value * 747796405u + 2891336453u;
            uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
            return (word >> 22u) ^ word;
        }

        struct Params {
            uint width;
            uint height;
            uint origin_x;
            uint origin_y;
            uint frame;
            float input_gain;
            float shaper_scale;
        };

        struct HalationParams {
            uint4 extent;
            uint4 state;
            float4 transform;
            float4 matrix_0;
            float4 matrix_1;
            float4 matrix_2;
        };

        kernel void fotufilm_native_realtime_hdr_halation_extract(
            const device half4 *input [[buffer(0)]],
            texture2d<half, access::write> reduced [[texture(0)]],
            constant HalationParams &params [[buffer(1)]],
            uint2 position [[thread_position_in_grid]]) {
            if (position.x >= reduced.get_width()
                || position.y >= reduced.get_height()) return;
            const uint2 start = position * 8u;
            float3 sum = 0.0f;
            uint count = 0;
            for (uint y = 0; y < 8u; ++y) {
                for (uint x = 0; x < 8u; ++x) {
                    const uint2 sample = start + uint2(x, y);
                    if (sample.x < params.extent.x && sample.y < params.extent.y) {
                        sum += max(float3(input[
                            sample.y * params.extent.x + sample.x].xyz)
                            * params.transform.x, 0.0f);
                        ++count;
                    }
                }
            }
            reduced.write(half4(
                half3(sum / float(max(count, 1u))), 1.0h), position);
        }

        kernel void fotufilm_native_realtime_hdr(
            const device half4 *input [[buffer(0)]],
            device half4 *output [[buffer(1)]],
            texture3d<float, access::read> table [[texture(0)]],
            constant Params &params [[buffer(2)]],
            uint2 position [[thread_position_in_grid]]) {
            if (position.x >= params.width || position.y >= params.height) return;
            uint offset = position.y * params.width + position.x;
            float4 pixel = float4(input[offset]);
            float3 positive = max(pixel.xyz * params.input_gain, 0.0f);
            float3 grid = min(log2(positive / \(Self.inputKnee)f + 1.0f)
                * params.shaper_scale, 64.0f);
            uint3 coordinate = uint3(grid);
            float3 fraction = grid - floor(grid);
            uint frame_x = position.x + params.origin_x;
            uint frame_y = position.y + params.origin_y;
            uint random = pcg(frame_x ^ pcg(frame_y ^ pcg(params.frame)));
            coordinate.x += float(random & 1023u) < fraction.x * 1024.0f;
            coordinate.y += float((random >> 10) & 1023u) < fraction.y * 1024.0f;
            coordinate.z += float((random >> 20) & 1023u) < fraction.z * 1024.0f;
            output[offset] = half4(table.read(coordinate));
        }

        kernel void fotufilm_native_realtime_hdr_halation(
            const device half4 *input [[buffer(0)]],
            device half4 *output [[buffer(1)]],
            texture3d<float, access::read> table [[texture(0)]],
            texture2d<float, access::sample> halo [[texture(1)]],
            texture2d<half, access::write> next_halo [[texture(2)]],
            constant HalationParams &params [[buffer(2)]],
            uint2 position [[thread_position_in_grid]]) {
            if (position.x >= params.extent.x || position.y >= params.extent.y) return;
            const uint offset = position.y * params.extent.x + position.x;
            const float4 pixel = float4(input[offset]);
            const float3 direct = max(pixel.xyz * params.transform.x, 0.0f);
            if ((position.x & 7u) == 0u && (position.y & 7u) == 0u) {
                next_halo.write(half4(half3(direct), 1.0h), position / 8u);
            }
            constexpr sampler bilinear(coord::normalized, address::clamp_to_edge,
                                       filter::linear);
            const float2 uv = (float2(position) + 0.5f)
                / float2(params.extent.xy);
            const float3 returned = halo.sample(bilinear, uv).rgb - direct;
            const float3 exposed = max(direct + float3(
                dot(params.matrix_0.xyz, returned),
                dot(params.matrix_1.xyz, returned),
                dot(params.matrix_2.xyz, returned)), 0.0f);
            const float3 grid = min(log2(exposed / 0.01f + 1.0f)
                * params.transform.y, 64.0f);
            uint3 coordinate = uint3(grid);
            const float3 fraction = grid - floor(grid);
            const uint frame_x = position.x + params.extent.z;
            const uint frame_y = position.y + params.extent.w;
            const uint random = pcg(frame_x ^ pcg(frame_y ^ pcg(params.state.x)));
            coordinate.x += float(random & 1023u) < fraction.x * 1024.0f;
            coordinate.y += float((random >> 10) & 1023u)
                < fraction.y * 1024.0f;
            coordinate.z += float((random >> 20) & 1023u)
                < fraction.z * 1024.0f;
            output[offset] = half4(table.read(coordinate));
        }

        struct CaptureParams {
            uint width;
            uint height;
            uint frame_width;
            uint frame_height;
            uint origin_x;
            uint origin_y;
            uint frame;
            uint curve;
            float input_gain;
            float scene_scale;
            float shaper_scale;
            float2 chroma_offset;
        };

        struct CaptureHalationParams {
            uint4 extent;
            uint4 region;
            float4 transform;
            float4 chroma;
            float4 matrix_0;
            float4 matrix_1;
            float4 matrix_2;
        };

        static float hlg_scene_light(float signal) {
            const float e = clamp(signal, 0.0f, 1.0f);
            return e <= 0.5f ? e * e / 3.0f
                : (exp((e - \(HLGSceneTransfer.c)f) / \(HLGSceneTransfer.a)f)
                   + \(HLGSceneTransfer.b)f) / 12.0f;
        }

        \(AppleLogCurve.metalFunction)

        static float scene_light(float signal, uint curve) {
            return curve == 0 ? hlg_scene_light(signal)
                              : apple_log_to_linear(clamp(signal, 0.0f, 1.0f));
        }

        kernel void fotufilm_native_realtime_hdr_capture_halation_extract(
            texture2d<float, access::sample> luma [[texture(0)]],
            texture2d<float, access::sample> chroma [[texture(1)]],
            texture2d<half, access::write> reduced [[texture(2)]],
            constant CaptureHalationParams &params [[buffer(0)]],
            uint2 position [[thread_position_in_grid]]) {
            if (position.x >= reduced.get_width()
                || position.y >= reduced.get_height()) return;
            constexpr sampler bilinear(coord::normalized, address::clamp_to_edge,
                                       filter::linear);
            const uint2 start = position * 8u;
            const float to_code = 65535.0f / 64.0f;
            float3 sum = 0.0f;
            uint count = 0;
            // Four quadrant samples seed the first field without paying for sixty-four transfer
            // decodes per reduced pixel. Following fields are emitted by the main render.
            for (uint y = 2; y < 8u; y += 4) {
                for (uint x = 2; x < 8u; x += 4) {
                    const uint2 local = start + uint2(x, y);
                    if (local.x >= params.extent.x || local.y >= params.extent.y) continue;
                    const uint2 absolute = local + params.region.xy;
                    const float2 uv = (float2(absolute) + 0.5f)
                        / float2(params.extent.zw);
                    const float y10 = luma.sample(bilinear, uv).r * to_code;
                    const float2 c10 = chroma.sample(
                        bilinear, uv + params.chroma.xy).rg * to_code;
                    const float openY = (y10 - 64.0f) / 876.0f;
                    const float u = (c10.x - 512.0f) / 896.0f;
                    const float v = (c10.y - 512.0f) / 896.0f;
                    const float3 signal = float3(
                        openY + 1.4746f * v,
                        openY - 0.164553f * u - 0.571353f * v,
                        openY + 1.8814f * u);
                    sum += max(float3(
                        scene_light(signal.x, params.region.w),
                        scene_light(signal.y, params.region.w),
                        scene_light(signal.z, params.region.w)), 0.0f)
                        * params.transform.y * params.transform.x;
                    ++count;
                }
            }
            reduced.write(half4(
                half3(sum / float(max(count, 1u))), 1.0h), position);
        }

        kernel void fotufilm_native_realtime_hdr_capture(
            texture2d<float, access::sample> luma [[texture(0)]],
            texture2d<float, access::sample> chroma [[texture(1)]],
            texture3d<float, access::read> table [[texture(2)]],
            device half4 *output [[buffer(0)]],
            constant CaptureParams &params [[buffer(1)]],
            uint2 position [[thread_position_in_grid]]) {
            if (position.x >= params.width || position.y >= params.height) return;
            const uint2 absolute = position
                + uint2(params.origin_x, params.origin_y);
            constexpr sampler bilinear(coord::normalized, address::clamp_to_edge,
                                       filter::linear);
            const float2 uv = (float2(absolute) + 0.5f)
                / float2(params.frame_width, params.frame_height);
            const float to_code = 65535.0f / 64.0f;
            const float y10 = luma.sample(bilinear, uv).r * to_code;
            const float2 c10 = chroma.sample(
                bilinear, uv + params.chroma_offset).rg * to_code;
            const float y = (y10 - 64.0f) / 876.0f;
            const float u = (c10.x - 512.0f) / 896.0f;
            const float v = (c10.y - 512.0f) / 896.0f;
            const float3 signal = float3(
                y + 1.4746f * v,
                y - 0.164553f * u - 0.571353f * v,
                y + 1.8814f * u);
            const float3 open = max(float3(
                scene_light(signal.x, params.curve),
                scene_light(signal.y, params.curve),
                scene_light(signal.z, params.curve)), 0.0f)
                * params.scene_scale * params.input_gain;
            const float3 grid = min(
                log2(open / \(Self.inputKnee)f + 1.0f)
                    * params.shaper_scale, 64.0f);
            uint3 coordinate = uint3(grid);
            const float3 fraction = grid - floor(grid);
            const uint random = pcg(absolute.x
                ^ pcg(absolute.y ^ pcg(params.frame)));
            coordinate.x += float(random & 1023u) < fraction.x * 1024.0f;
            coordinate.y += float((random >> 10) & 1023u)
                < fraction.y * 1024.0f;
            coordinate.z += float((random >> 20) & 1023u)
                < fraction.z * 1024.0f;
            output[position.y * params.width + position.x]
                = half4(table.read(coordinate));
        }

        kernel void fotufilm_native_realtime_hdr_capture_halation(
            texture2d<float, access::sample> luma [[texture(0)]],
            texture2d<float, access::sample> chroma [[texture(1)]],
            texture3d<float, access::read> table [[texture(2)]],
            texture2d<float, access::sample> halo [[texture(3)]],
            texture2d<half, access::write> next_halo [[texture(4)]],
            device half4 *output [[buffer(0)]],
            constant CaptureHalationParams &params [[buffer(1)]],
            uint2 position [[thread_position_in_grid]]) {
            if (position.x >= params.extent.x || position.y >= params.extent.y) return;
            const uint2 absolute = position + params.region.xy;
            constexpr sampler bilinear(coord::normalized, address::clamp_to_edge,
                                       filter::linear);
            const float2 captureUV = (float2(absolute) + 0.5f)
                / float2(params.extent.zw);
            const float to_code = 65535.0f / 64.0f;
            const float y10 = luma.sample(bilinear, captureUV).r * to_code;
            const float2 c10 = chroma.sample(
                bilinear, captureUV + params.chroma.xy).rg * to_code;
            const float openY = (y10 - 64.0f) / 876.0f;
            const float u = (c10.x - 512.0f) / 896.0f;
            const float v = (c10.y - 512.0f) / 896.0f;
            const float3 signal = float3(
                openY + 1.4746f * v,
                openY - 0.164553f * u - 0.571353f * v,
                openY + 1.8814f * u);
            const float3 direct = max(float3(
                scene_light(signal.x, params.region.w),
                scene_light(signal.y, params.region.w),
                scene_light(signal.z, params.region.w)), 0.0f)
                * params.transform.y * params.transform.x;
            if ((position.x & 7u) == 0u && (position.y & 7u) == 0u) {
                next_halo.write(half4(half3(direct), 1.0h), position / 8u);
            }
            const float2 haloUV = (float2(position) + 0.5f)
                / float2(params.extent.xy);
            const float3 returned = halo.sample(bilinear, haloUV).rgb - direct;
            const float3 exposed = max(direct + float3(
                dot(params.matrix_0.xyz, returned),
                dot(params.matrix_1.xyz, returned),
                dot(params.matrix_2.xyz, returned)), 0.0f);
            const float3 grid = min(
                log2(exposed / 0.01f + 1.0f)
                    * params.transform.z, 64.0f);
            uint3 coordinate = uint3(grid);
            const float3 fraction = grid - floor(grid);
            const uint random = pcg(absolute.x
                ^ pcg(absolute.y ^ pcg(params.region.z)));
            coordinate.x += float(random & 1023u) < fraction.x * 1024.0f;
            coordinate.y += float((random >> 10) & 1023u)
                < fraction.y * 1024.0f;
            coordinate.z += float((random >> 20) & 1023u)
                < fraction.z * 1024.0f;
            output[position.y * params.extent.x + position.x]
                = half4(table.read(coordinate));
        }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard let function = library.makeFunction(
                name: "fotufilm_native_realtime_hdr"),
                  let captureFunction = library.makeFunction(
                    name: "fotufilm_native_realtime_hdr_capture"),
                  let halationFunction = library.makeFunction(
                    name: "fotufilm_native_realtime_hdr_halation"),
                  let captureHalationFunction = library.makeFunction(
                    name: "fotufilm_native_realtime_hdr_capture_halation"),
                  let extractFunction = library.makeFunction(
                    name: "fotufilm_native_realtime_hdr_halation_extract"),
                  let captureExtractFunction = library.makeFunction(
                    name: "fotufilm_native_realtime_hdr_capture_halation_extract")
            else { return nil }
            pipeline = try device.makeComputePipelineState(function: function)
            capturePipeline = try device.makeComputePipelineState(
                function: captureFunction)
            halationPipeline = try device.makeComputePipelineState(
                function: halationFunction)
            captureHalationPipeline = try device.makeComputePipelineState(
                function: captureHalationFunction)
            halationExtractPipeline = try device.makeComputePipelineState(
                function: extractFunction)
            captureHalationExtractPipeline = try device.makeComputePipelineState(
                function: captureExtractFunction)
        } catch {
            print("NativeRealtimeHDRFilmRenderer: Metal library failed (\(error))")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    @discardableResult
    public func prepare(
        key: String, stock: FilmStock, options: FotufilmEngine.Options,
        frameWidth: Int, frameHeight: Int
    ) -> Bool {
        guard frameWidth > 0, frameHeight > 0 else { return false }
        var invocation = FilmEngineInvocation(
            stock: stock, options: options,
            width: frameWidth, height: frameHeight)
        let halation = NativeRealtimeHalation(
            device: device, invocation: invocation)
        invocation.featureMask &= ~Self.spatialFeatures
        invocation.featureMask |= FilmEngineFeature.floatIO
        Self.neutralizeSpatialConfiguration(&invocation.configuration)

        let width = Self.tableWidth
        let height = Self.tableHeight
        let floatCount = width * height * 4
        guard let input = device.makeBuffer(
                length: floatCount * MemoryLayout<Float>.size,
                options: .storageModeShared),
              let output = device.makeBuffer(
                length: floatCount * MemoryLayout<Float>.size,
                options: .storageModeShared) else { return false }
        let samples = input.contents().assumingMemoryBound(to: Float.self)
        let inputCeiling = options.sceneHeadroom > 1
            ? min(Self.inputCeiling, options.sceneHeadroom)
            : Self.inputCeiling
        let logCeiling = log2(inputCeiling / Self.inputKnee + 1)
        for blue in 0..<Self.edge {
            for green in 0..<Self.edge {
                for red in 0..<Self.edge {
                    let offset = ((blue * Self.edge + green) * Self.edge + red) * 4
                    samples[offset] = Self.inputKnee
                        * (exp2(Float(red) / 64 * logCeiling) - 1)
                    samples[offset + 1] = Self.inputKnee
                        * (exp2(Float(green) / 64 * logCeiling) - 1)
                    samples[offset + 2] = Self.inputKnee
                        * (exp2(Float(blue) / 64 * logCeiling) - 1)
                    samples[offset + 3] = 1
                }
            }
        }
        let inputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(input as AnyObject).toOpaque()))
        let outputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(output as AnyObject).toOpaque()))
        let result = invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                fotufilm_native_lut_process_buffers_float(
                    inputHandle, outputHandle, Int32(width), Int32(height), 0, 0,
                    configuration.baseAddress, exposure, film, paper,
                    Int32(invocation.spectral.exposure.dimension),
                    invocation.spectralCacheID, invocation.featureMask,
                    invocation.seed)
            }
        }
        guard result == 0 else {
            print("NativeRealtimeHDRFilmRenderer: LUT bake failed (\(result), mask "
                  + "\(invocation.featureMask))")
            return false
        }

        let developed = output.contents().assumingMemoryBound(to: Float.self)
        var packed = [UInt16](repeating: 0, count: floatCount)
        for index in 0..<floatCount {
            packed[index] = Float16(developed[index]).bitPattern
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = Self.edge
        descriptor.height = Self.edge
        descriptor.depth = Self.edge
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let table = device.makeTexture(descriptor: descriptor) else { return false }
        packed.withUnsafeBytes { bytes in
            table.replace(
                region: MTLRegionMake3D(0, 0, 0, Self.edge, Self.edge, Self.edge),
                mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: Self.edge * 8,
                bytesPerImage: Self.edge * Self.edge * 8)
        }
        lock.lock()
        tables[key] = Cube(
            texture: table, shaperScale: 64 / logCeiling,
            halation: halation)
        lock.unlock()
        return true
    }

    /// Validation form of the cube's exact pointwise transform. It runs the same masked engine
    /// invocation used to bake the table, but evaluates the supplied float pixels directly so
    /// benchmarks can separate cube interpolation error from omitted spatial stages.
    @discardableResult
    public func processLinearFloatReference(
        input: MTLBuffer, output: MTLBuffer,
        width: Int, height: Int, stock: FilmStock,
        options: FotufilmEngine.Options, frameIndex: UInt64 = 0
    ) -> Bool {
        let byteCount = width * height * 16
        guard width > 0, height > 0,
              input.length >= byteCount, output.length >= byteCount else { return false }
        let invocation = Self.pointwiseInvocation(
            stock: stock, options: options, width: width, height: height,
            frameIndex: frameIndex)
        let inputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(input as AnyObject).toOpaque()))
        let outputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(output as AnyObject).toOpaque()))
        return invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                fotufilm_native_lut_process_buffers_float(
                    inputHandle, outputHandle, Int32(width), Int32(height), 0, 0,
                    configuration.baseAddress, exposure, film, paper,
                    Int32(invocation.spectral.exposure.dimension),
                    invocation.spectralCacheID, invocation.featureMask,
                    invocation.seed) == 0
            }
        }
    }

    @discardableResult
    public func processLinearHalf(
        input: MTLBuffer, output: MTLBuffer,
        width: Int, height: Int, originX: Int = 0, originY: Int = 0,
        key: String, frameIndex: UInt64, inputGain: Float = 1
    ) -> Bool {
        guard let commandBuffer = queue.makeCommandBuffer(),
              encodeLinearHalf(
                input: input, output: output, width: width, height: height,
                originX: originX, originY: originY, key: key,
                frameIndex: frameIndex, inputGain: inputGain,
                commandBuffer: commandBuffer)
        else { return false }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    /// Encodes the linear-half transform into a caller-owned command buffer without committing
    /// or waiting for it. Bound buffers, lookup tables, and temporal halation textures remain
    /// retained until that command buffer completes.
    @discardableResult
    public func encodeLinearHalf(
        input: MTLBuffer, output: MTLBuffer,
        width: Int, height: Int, originX: Int = 0, originY: Int = 0,
        key: String, frameIndex: UInt64, inputGain: Float = 1,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        let byteCount = width * height * 8
        guard width > 0, height > 0, originX >= 0, originY >= 0,
              input.length >= byteCount, output.length >= byteCount,
              commandBuffer.device === device,
              commandBuffer.status == .notEnqueued else { return false }
        guard let resources = frameResources(
            key: key, width: width, height: height,
            commandBuffer: commandBuffer) else { return false }
        let cube = resources.cube
        if let halation = cube.halation {
            guard let fieldKey = resources.fieldKey,
                  let field = resources.field else { return false }
            let fieldIsWarm = resources.fieldIsWarm
            let scratch = field.scratch
            retainNativeRealtimeResources(
                [self, input, output, cube.texture, halation,
                 field.commandQueue, scratch.source, scratch.blurred],
                untilCompletedBy: commandBuffer)
            var halationParameters = HalationParameters(
                extent: SIMD4(UInt32(width), UInt32(height),
                              UInt32(originX), UInt32(originY)),
                state: SIMD4(UInt32(truncatingIfNeeded: frameIndex), 0, 0, 0),
                transform: SIMD4(inputGain, cube.shaperScale, 0, 0),
                matrix0: halation.matrixRows.0,
                matrix1: halation.matrixRows.1,
                matrix2: halation.matrixRows.2)
            if !fieldIsWarm {
                guard let extract = commandBuffer.makeComputeCommandEncoder() else {
                    return false
                }
                extract.setComputePipelineState(halationExtractPipeline)
                extract.setBuffer(input, offset: 0, index: 0)
                extract.setTexture(scratch.source, index: 0)
                extract.setBytes(&halationParameters,
                                 length: MemoryLayout<HalationParameters>.stride,
                                 index: 1)
                extract.dispatchThreads(
                    MTLSize(width: scratch.source.width,
                            height: scratch.source.height, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                extract.endEncoding()
                halation.blur.encode(
                    commandBuffer: commandBuffer, sourceTexture: scratch.source,
                    destinationTexture: scratch.blurred)
            }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                return false
            }
            encoder.setComputePipelineState(halationPipeline)
            encoder.setBuffer(input, offset: 0, index: 0)
            encoder.setBuffer(output, offset: 0, index: 1)
            encoder.setTexture(cube.texture, index: 0)
            encoder.setTexture(scratch.blurred, index: 1)
            encoder.setTexture(scratch.source, index: 2)
            encoder.setBytes(&halationParameters,
                             length: MemoryLayout<HalationParameters>.stride,
                             index: 2)
            encoder.dispatchThreads(
                MTLSize(width: width, height: height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
            encoder.endEncoding()
            if fieldIsWarm {
                halation.blur.encode(
                    commandBuffer: commandBuffer, sourceTexture: scratch.source,
                    destinationTexture: scratch.blurred)
            }
            if !fieldIsWarm {
                commandBuffer.addCompletedHandler { [weak self, source = scratch.source] in
                    guard $0.status == .completed, let self else { return }
                    self.lock.lock()
                    if self.halationFields[fieldKey]?.scratch.source === source {
                        self.warmHalationFields.insert(fieldKey)
                    }
                    self.lock.unlock()
                }
            }
            return true
        }
        retainNativeRealtimeResources(
            [self, input, output, cube.texture], untilCompletedBy: commandBuffer)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        var parameters = Parameters(
            width: UInt32(width), height: UInt32(height),
            originX: UInt32(originX), originY: UInt32(originY),
            frame: UInt32(truncatingIfNeeded: frameIndex),
            inputGain: inputGain, shaperScale: cube.shaperScale)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setTexture(cube.texture, index: 0)
        encoder.setBytes(&parameters,
                         length: MemoryLayout<Parameters>.stride, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
        encoder.endEncoding()
        return true
    }

    /// Decodes a native 10-bit HLG/Apple Log capture and applies the HDR cube in one pass,
    /// avoiding a frame-sized intermediate between the camera IOSurface and the film transform.
    @discardableResult
    public func processCapturedHalf(
        luma: MTLTexture, chroma: MTLTexture, output: MTLBuffer,
        width: Int, height: Int, frameWidth: Int, frameHeight: Int,
        originX: Int = 0, originY: Int = 0,
        chromaOffset: SIMD2<Float>, sceneScale: Float, appleLog: Bool,
        key: String, frameIndex: UInt64, inputGain: Float = 1
    ) -> Bool {
        guard let commandBuffer = queue.makeCommandBuffer(),
              encodeCapturedHalf(
                luma: luma, chroma: chroma, output: output,
                width: width, height: height,
                frameWidth: frameWidth, frameHeight: frameHeight,
                originX: originX, originY: originY,
                chromaOffset: chromaOffset, sceneScale: sceneScale,
                appleLog: appleLog, key: key, frameIndex: frameIndex,
                inputGain: inputGain, commandBuffer: commandBuffer)
        else { return false }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    /// Encodes capture decoding and the HDR film transform into a caller-owned command buffer
    /// without committing or waiting for it. This is the zero-intermediate path for camera frames.
    @discardableResult
    public func encodeCapturedHalf(
        luma: MTLTexture, chroma: MTLTexture, output: MTLBuffer,
        width: Int, height: Int, frameWidth: Int, frameHeight: Int,
        originX: Int = 0, originY: Int = 0,
        chromaOffset: SIMD2<Float>, sceneScale: Float, appleLog: Bool,
        key: String, frameIndex: UInt64, inputGain: Float = 1,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        let byteCount = width * height * 8
        guard width > 0, height > 0, frameWidth > 0, frameHeight > 0,
              originX >= 0, originY >= 0,
              originX + width <= frameWidth, originY + height <= frameHeight,
              output.length >= byteCount,
              commandBuffer.device === device,
              commandBuffer.status == .notEnqueued else { return false }
        guard let resources = frameResources(
            key: key, width: width, height: height,
            commandBuffer: commandBuffer) else { return false }
        let cube = resources.cube
        if let halation = cube.halation {
            guard let fieldKey = resources.fieldKey,
                  let field = resources.field else { return false }
            let fieldIsWarm = resources.fieldIsWarm
            let scratch = field.scratch
            retainNativeRealtimeResources(
                [self, luma, chroma, output, cube.texture, halation,
                 field.commandQueue, scratch.source, scratch.blurred],
                untilCompletedBy: commandBuffer)
            var halationParameters = CaptureHalationParameters(
                extent: SIMD4(UInt32(width), UInt32(height),
                              UInt32(frameWidth), UInt32(frameHeight)),
                region: SIMD4(UInt32(originX), UInt32(originY),
                              UInt32(truncatingIfNeeded: frameIndex),
                              appleLog ? 1 : 0),
                transform: SIMD4(inputGain, sceneScale, cube.shaperScale, 0),
                chroma: SIMD4(chromaOffset.x, chromaOffset.y, 0, 0),
                matrix0: halation.matrixRows.0,
                matrix1: halation.matrixRows.1,
                matrix2: halation.matrixRows.2)
            if !fieldIsWarm {
                guard let extract = commandBuffer.makeComputeCommandEncoder() else {
                    return false
                }
                extract.setComputePipelineState(captureHalationExtractPipeline)
                extract.setTexture(luma, index: 0)
                extract.setTexture(chroma, index: 1)
                extract.setTexture(scratch.source, index: 2)
                extract.setBytes(&halationParameters,
                                 length: MemoryLayout<CaptureHalationParameters>.stride,
                                 index: 0)
                extract.dispatchThreads(
                    MTLSize(width: scratch.source.width,
                            height: scratch.source.height, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                extract.endEncoding()
                halation.blur.encode(
                    commandBuffer: commandBuffer, sourceTexture: scratch.source,
                    destinationTexture: scratch.blurred)
            }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                return false
            }
            encoder.setComputePipelineState(captureHalationPipeline)
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(chroma, index: 1)
            encoder.setTexture(cube.texture, index: 2)
            encoder.setTexture(scratch.blurred, index: 3)
            encoder.setTexture(scratch.source, index: 4)
            encoder.setBuffer(output, offset: 0, index: 0)
            encoder.setBytes(&halationParameters,
                             length: MemoryLayout<CaptureHalationParameters>.stride,
                             index: 1)
            encoder.dispatchThreads(
                MTLSize(width: width, height: height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            if fieldIsWarm {
                halation.blur.encode(
                    commandBuffer: commandBuffer, sourceTexture: scratch.source,
                    destinationTexture: scratch.blurred)
            }
            if !fieldIsWarm {
                commandBuffer.addCompletedHandler { [weak self, source = scratch.source] in
                    guard $0.status == .completed, let self else { return }
                    self.lock.lock()
                    if self.halationFields[fieldKey]?.scratch.source === source {
                        self.warmHalationFields.insert(fieldKey)
                    }
                    self.lock.unlock()
                }
            }
            return true
        }
        retainNativeRealtimeResources(
            [self, luma, chroma, output, cube.texture],
            untilCompletedBy: commandBuffer)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        var parameters = CaptureParameters(
            width: UInt32(width), height: UInt32(height),
            frameWidth: UInt32(frameWidth), frameHeight: UInt32(frameHeight),
            originX: UInt32(originX), originY: UInt32(originY),
            frame: UInt32(truncatingIfNeeded: frameIndex),
            curve: appleLog ? 1 : 0,
            inputGain: inputGain, sceneScale: sceneScale,
            shaperScale: cube.shaperScale,
            chromaOffset: chromaOffset)
        encoder.setComputePipelineState(capturePipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(cube.texture, index: 2)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBytes(&parameters,
                         length: MemoryLayout<CaptureParameters>.stride,
                         index: 1)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        return true
    }

    public func removeAll() {
        lock.lock()
        tables.removeAll(keepingCapacity: false)
        halationFields.removeAll(keepingCapacity: false)
        warmHalationFields.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func frameResources(
        key: String, width: Int, height: Int,
        commandBuffer: MTLCommandBuffer
    ) -> (
        cube: Cube,
        fieldKey: NativeRealtimeHalationFieldKey?,
        field: NativeRealtimeHalationField?,
        fieldIsWarm: Bool
    )? {
        lock.lock()
        defer { lock.unlock() }
        guard let cube = tables[key] else { return nil }
        guard cube.halation != nil else {
            return (cube, nil, nil, false)
        }
        let fieldKey = NativeRealtimeHalationFieldKey(
            rendererKey: key, width: width, height: height,
            commandQueue: ObjectIdentifier(commandBuffer.commandQueue))
        if let field = halationFields[fieldKey] {
            return (cube, fieldKey, field,
                    warmHalationFields.contains(fieldKey))
        }
        guard let scratch = makeNativeRealtimeHalationScratch(
            device: device, width: width, height: height) else { return nil }
        let field = NativeRealtimeHalationField(
            commandQueue: commandBuffer.commandQueue, scratch: scratch)
        halationFields[fieldKey] = field
        return (cube, fieldKey, field, false)
    }

    private static func neutralizeSpatialConfiguration(
        _ configuration: inout [Float]
    ) {
        configuration.replaceSubrange(
            Configuration.halationMix..<(Configuration.halationMix + 3),
            with: [Float](repeating: 0, count: 3))
        configuration.replaceSubrange(
            Configuration.grain..<(Configuration.grain + 3),
            with: [Float](repeating: 0, count: 3))
        configuration.replaceSubrange(
            Configuration.mtfRadius..<(Configuration.mtfRadius + 3),
            with: [Float](repeating: 0, count: 3))
        configuration.replaceSubrange(
            Configuration.halationRadius..<(Configuration.halationRadius + 3),
            with: [Float](repeating: 0, count: 3))
        configuration[Configuration.couplerRadius] = 0
        configuration[Configuration.adjacencyRadius] = 0
        configuration[Configuration.grainRadius] = 0
        configuration[Configuration.flare] = 0
        configuration[Configuration.adjacencyStrength] = 0
        configuration[Configuration.mtfLumaShare] = 0
        configuration.replaceSubrange(
            FilmEngineInvocation.mottleOffset..<(FilmEngineInvocation.mottleOffset + 3),
            with: [Float](repeating: 0, count: 3))
        configuration[FilmEngineInvocation.mottleSigmaOffset + 1] = 0
        configuration[FilmEngineInvocation.printMTFOffset + 1] = 0
        configuration.replaceSubrange(
            FilmEngineInvocation.diffusionKernelOffset..<(
                FilmEngineInvocation.diffusionKernelOffset + 9),
            with: [Float](repeating: 0, count: 9))
        configuration[FilmEngineInvocation.diffusionDirectOffset] = 1
        configuration.replaceSubrange(
            FilmEngineInvocation.diffusionRadiusOffset..<(
                FilmEngineInvocation.diffusionRadiusOffset + 3),
            with: [Float](repeating: 0, count: 3))
        configuration.replaceSubrange(
            FilmEngineInvocation.halationRingRadiusOffset..<(
                FilmEngineInvocation.halationRingRadiusOffset + 3),
            with: [Float](repeating: 0, count: 3))
        configuration.replaceSubrange(
            FilmEngineInvocation.halationMatrixOffset..<(
                FilmEngineInvocation.halationMatrixOffset + 9),
            with: [Float](repeating: 0, count: 9))
        configuration.replaceSubrange(
            FilmEngineInvocation.mtfSecondaryRadiusOffset..<(
                FilmEngineInvocation.mtfSecondaryRadiusOffset + 3),
            with: [Float](repeating: 0, count: 3))
    }

    private static func pointwiseInvocation(
        stock: FilmStock, options: FotufilmEngine.Options,
        width: Int, height: Int, frameIndex: UInt64 = 0
    ) -> FilmEngineInvocation {
        var invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width, height: height,
            frameIndex: frameIndex)
        invocation.featureMask &= ~spatialFeatures
        invocation.featureMask |= FilmEngineFeature.floatIO
        neutralizeSpatialConfiguration(&invocation.configuration)
        return invocation
    }

    private struct Parameters {
        var width: UInt32
        var height: UInt32
        var originX: UInt32
        var originY: UInt32
        var frame: UInt32
        var inputGain: Float
        var shaperScale: Float
    }

    private struct HalationParameters {
        var extent: SIMD4<UInt32>
        var state: SIMD4<UInt32>
        var transform: SIMD4<Float>
        var matrix0: SIMD4<Float>
        var matrix1: SIMD4<Float>
        var matrix2: SIMD4<Float>
    }

    private struct CaptureParameters {
        var width: UInt32
        var height: UInt32
        var frameWidth: UInt32
        var frameHeight: UInt32
        var originX: UInt32
        var originY: UInt32
        var frame: UInt32
        var curve: UInt32
        var inputGain: Float
        var sceneScale: Float
        var shaperScale: Float
        var chromaOffset: SIMD2<Float>
    }

    private struct CaptureHalationParameters {
        var extent: SIMD4<UInt32>
        var region: SIMD4<UInt32>
        var transform: SIMD4<Float>
        var chroma: SIMD4<Float>
        var matrix0: SIMD4<Float>
        var matrix1: SIMD4<Float>
        var matrix2: SIMD4<Float>
    }
}
