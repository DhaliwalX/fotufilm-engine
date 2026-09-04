import CoreVideo
import Foundation
import Metal
import simd

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif
#if canImport(FotufilmMetal)
import FotufilmMetal
#endif

/// Shared x420/HLG/Apple Log capture metadata helpers. Camera pixels are decoded by the
/// handwritten full-frame graph; the buffer converters below exist only for developer benchmarks.
final class HLGConverter {
    /// Which curve the capture is carrying.
    enum Transfer {
        case hlg
        case appleLog

        /// What the decode multiplies by to land diffuse white on 1.0.
        var sceneScale: Float {
            switch self {
            case .hlg: return PrintEncoding.hdrHeadroom
            case .appleLog: return AppleLog.sceneScale
            }
        }
    }

    private struct MetalState {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState
        let halfPipeline: MTLComputePipelineState
    }

    private static let metalState: MetalState? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        let options = MTLCompileOptions()
        if #available(macOS 15.0, iOS 18.0, *) {
            options.mathMode = .safe
        } else {
            options.fastMathEnabled = false
        }
        guard let library = try? device.makeLibrary(source: metalSource,
                                                    options: options),
              let function = library.makeFunction(name: "fotufilm_capture_to_linear"),
              let halfFunction = library.makeFunction(
                name: "fotufilm_capture_to_linear_half"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let halfPipeline = try? device.makeComputePipelineState(
                function: halfFunction)
        else { return nil }
        return MetalState(device: device, queue: queue, pipeline: pipeline,
                          halfPipeline: halfPipeline)
    }()

    /// True when this process can decode a 10-bit capture on the GPU at all.
    // Capability checks must not compile the old benchmark kernels on the camera's first frame.
    static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    let width: Int
    let height: Int
    let transfer: Transfer
    private var textureCache: CVMetalTextureCache?
    private var attempted = false
    private var reportedIncompatibleFrame = false

    init?(width: Int, height: Int, transfer: Transfer = .hlg) {
        guard width > 0, height > 0, Self.metalState != nil else { return nil }
        self.width = width
        self.height = height
        self.transfer = transfer
    }

    private func ensureResources(_ state: MetalState) -> Bool {
        if !attempted {
            attempted = true
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, state.device,
                                      nil, &textureCache)
        }
        return textureCache != nil
    }

    /// Decodes one `420YpCbCr10BiPlanarVideoRange` frame straight into the
    /// engine's float input buffer.
    func convert(_ pixelBuffer: CVPixelBuffer, into destination: MTLBuffer) -> Bool {
        convert(pixelBuffer, into: destination, half: false)
    }

    /// Decodes into packed half-float RGBA for the native realtime HDR schedule.
    func convertHalf(_ pixelBuffer: CVPixelBuffer,
                     into destination: MTLBuffer) -> Bool {
        convert(pixelBuffer, into: destination, half: true)
    }

    /// Fuses capture decode with the native HDR film transform, so a 4K linear intermediate is
    /// never written and read back between the two kernels.
    func developHalf(
        _ pixelBuffer: CVPixelBuffer, into destination: MTLBuffer,
        renderer: NativeRealtimeHDRFilmRenderer,
        width: Int, height: Int, originX: Int, originY: Int,
        key: String, frameIndex: UInt64, inputGain: Float
    ) -> Bool {
        guard let state = Self.metalState, ensureResources(state),
              let textureCache,
              Self.isCompatibleFrame(pixelBuffer, transfer: transfer)
        else { return false }
        let frameWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let frameHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard frameWidth > 0, frameHeight > 0 else { return false }
        var lumaReference: CVMetalTexture?
        var chromaReference: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .r16Unorm, frameWidth, frameHeight, 0,
                &lumaReference) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .rg16Unorm, CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 1), 1,
                &chromaReference) == kCVReturnSuccess,
              let lumaReference, let chromaReference,
              let luma = CVMetalTextureGetTexture(lumaReference),
              let chroma = CVMetalTextureGetTexture(chromaReference)
        else { return false }
        let developed = renderer.processCapturedHalf(
            luma: luma, chroma: chroma, output: destination,
            width: width, height: height,
            frameWidth: frameWidth, frameHeight: frameHeight,
            originX: originX, originY: originY,
            chromaOffset: Self.chromaOffset(
                for: pixelBuffer, width: frameWidth, height: frameHeight),
            sceneScale: transfer.sceneScale,
            appleLog: transfer == .appleLog,
            key: key, frameIndex: frameIndex, inputGain: inputGain)
        withExtendedLifetime((lumaReference, chromaReference)) {}
        return developed
    }

    private func convert(_ pixelBuffer: CVPixelBuffer,
                         into destination: MTLBuffer, half: Bool) -> Bool {
        guard let state = Self.metalState, ensureResources(state),
              let textureCache else { return false }
        guard Self.isCompatibleFrame(pixelBuffer, transfer: transfer) else {
            if !reportedIncompatibleFrame {
                reportedIncompatibleFrame = true
                print("Fotufilm: discarded an HDR frame that was not x420 "
                      + (transfer == .appleLog ? "Apple Log" : "HLG/BT.2020"))
            }
            return false
        }
        guard destination.length >= width * height * (half ? 8 : 16)
        else { return false }
        let sourceWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let sourceHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard sourceWidth > 0, sourceHeight > 0 else { return false }

        var lumaTexture: CVMetalTexture?
        var chromaTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .r16Unorm, sourceWidth, sourceHeight, 0,
                &lumaTexture) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .rg16Unorm, CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 1), 1,
                &chromaTexture) == kCVReturnSuccess,
              let lumaTexture, let chromaTexture,
              let luma = CVMetalTextureGetTexture(lumaTexture),
              let chroma = CVMetalTextureGetTexture(chromaTexture)
        else { return false }

        guard let commands = state.queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(half ? state.halfPipeline : state.pipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setBuffer(destination, offset: 0, index: 0)
        var size = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.size, index: 1)
        var scale = transfer.sceneScale
        encoder.setBytes(&scale, length: MemoryLayout<Float>.size, index: 2)
        var chromaOffset = Self.chromaOffset(
            for: pixelBuffer, width: sourceWidth, height: sourceHeight)
        encoder.setBytes(&chromaOffset,
                         length: MemoryLayout<SIMD2<Float>>.size, index: 3)
        var curve = UInt32(transfer == .appleLog ? 1 : 0)
        encoder.setBytes(&curve, length: MemoryLayout<UInt32>.size, index: 4)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime((lumaTexture, chromaTexture)) {}
        return commands.status == .completed
    }

    static func isCompatibleFrame(_ pixelBuffer: CVPixelBuffer,
                                  transfer: Transfer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer)
                == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2
        else { return false }
        let reading: CapturedFrameColour.Reading =
            transfer == .hlg ? .hlg : .appleLog
        return CapturedFrameColour.isCompatible(attachments(of: pixelBuffer),
                                                with: reading)
    }

    private static func attachments(
        of pixelBuffer: CVPixelBuffer
    ) -> CapturedFrameColour.Attachments {
        var log: String?
        if #available(iOS 17.2, macOS 14.2, *) {
            log = string(pixelBuffer, kCVImageBufferLogTransferFunctionKey)
        }
        return CapturedFrameColour.Attachments(
            yCbCrMatrix: string(pixelBuffer, kCVImageBufferYCbCrMatrixKey),
            colorPrimaries: string(pixelBuffer, kCVImageBufferColorPrimariesKey),
            transferFunction: string(pixelBuffer,
                                     kCVImageBufferTransferFunctionKey),
            logTransferFunction: log)
    }

    private static func string(_ pixelBuffer: CVPixelBuffer,
                               _ key: CFString) -> String? {
        guard let value = CVBufferCopyAttachment(pixelBuffer, key, nil),
              CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    static func chromaOffset(
        for pixelBuffer: CVPixelBuffer, width: Int, height: Int
    ) -> SIMD2<Float> {
        guard width > 0, height > 0,
              let attachment = CVBufferCopyAttachment(
                pixelBuffer, kCVImageBufferChromaLocationTopFieldKey, nil)
        else { return .zero }
        guard CFGetTypeID(attachment) == CFStringGetTypeID() else { return .zero }
        let location = attachment as! CFString
        let halfX = 0.5 / Float(width)
        let halfY = 0.5 / Float(height)
        if CFEqual(location, kCVImageBufferChromaLocation_Left) {
            return SIMD2(halfX, 0)
        } else if CFEqual(location, kCVImageBufferChromaLocation_TopLeft) {
            return SIMD2(halfX, halfY)
        } else if CFEqual(location, kCVImageBufferChromaLocation_Top) {
            return SIMD2(0, halfY)
        } else if CFEqual(location, kCVImageBufferChromaLocation_BottomLeft) {
            return SIMD2(halfX, -halfY)
        } else if CFEqual(location, kCVImageBufferChromaLocation_Bottom) {
            return SIMD2(0, -halfY)
        } else if CFEqual(location, kCVImageBufferChromaLocation_DV420) {
            return SIMD2(halfX, 0)
        }
        return .zero
    }

    /// Prepares a film region's scene light for the emulsion: the feed's exposure trim, negative
    /// lobes cut at zero, opaque alpha — the film's own shoulder does any compressing.
    func prepareFilmRegion(_ region: MTLBuffer, pixels: Int) -> Bool {
        guard pixels > 0 else { return true }
        guard let state = Self.prepareState else { return false }
        guard region.length >= pixels * 16 else { return false }
        guard let commands = state.queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(state.pipeline)
        encoder.setBuffer(region, offset: 0, index: 0)
        var count = UInt32(pixels)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: pixels, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return commands.status == .completed
    }

    private static let prepareState: MetalState? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        let options = MTLCompileOptions()
        if #available(macOS 15.0, iOS 18.0, *) {
            options.mathMode = .safe
        } else {
            options.fastMathEnabled = false
        }
        guard let library = try? device.makeLibrary(source: prepareSource,
                                                    options: options),
              let function = library.makeFunction(
                  name: "fotufilm_prepare_film_region"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        return MetalState(device: device, queue: queue, pipeline: pipeline,
                          halfPipeline: pipeline)
    }()

    private static var prepareSource: String { """
    #include <metal_stdlib>
    using namespace metal;

    kernel void fotufilm_prepare_film_region(
        device float4 *pixels [[buffer(0)]],
        constant uint &count [[buffer(1)]],
        uint gid [[thread_position_in_grid]])
    {
        if (gid >= count) { return; }
        pixels[gid] = float4(max(pixels[gid].rgb, 0.0f)
            * \(HLGTransfer.videoExposureTrim)f, 1.0f);
    }
    """ }

    /// Writes a developed float print into a half-float texture for the viewfinder, rolling it
    /// off into whatever headroom the screen actually has.
    func present(_ printed: MTLBuffer, into texture: MTLTexture,
                 rectangle: (x: Int, y: Int, width: Int, height: Int),
                 ceiling: Float) -> Bool {
        present(printed, into: texture, rectangle: rectangle,
                ceiling: ceiling, half: false)
    }

    /// Half-float input form used by native realtime HDR video.
    func presentHalf(_ printed: MTLBuffer, into texture: MTLTexture,
                     rectangle: (x: Int, y: Int, width: Int, height: Int),
                     ceiling: Float) -> Bool {
        present(printed, into: texture, rectangle: rectangle,
                ceiling: ceiling, half: true)
    }

    private func present(
        _ printed: MTLBuffer, into texture: MTLTexture,
        rectangle: (x: Int, y: Int, width: Int, height: Int),
        ceiling: Float, half: Bool
    ) -> Bool {
        guard let state = Self.presentState else { return false }
        guard printed.length >= rectangle.width * rectangle.height
                * (half ? 8 : 16) else { return false }
        guard let commands = state.queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(half ? state.halfPipeline : state.pipeline)
        encoder.setBuffer(printed, offset: 0, index: 0)
        encoder.setTexture(texture, index: 0)
        var size = SIMD2<UInt32>(UInt32(rectangle.width), UInt32(rectangle.height))
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.size, index: 1)
        var origin = SIMD2<UInt32>(UInt32(rectangle.x), UInt32(rectangle.y))
        encoder.setBytes(&origin, length: MemoryLayout<SIMD2<UInt32>>.size, index: 2)
        var top = min(max(ceiling, 1), PrintEncoding.hdrDisplayCeiling)
        encoder.setBytes(&top, length: MemoryLayout<Float>.size, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: rectangle.width, height: rectangle.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return commands.status == .completed
    }

    private static let presentState: MetalState? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        guard let library = try? device.makeLibrary(source: presentSource,
                                                    options: nil),
              let function = library.makeFunction(name: "fotufilm_print_to_edr"),
              let halfFunction = library.makeFunction(
                name: "fotufilm_print_half_to_edr"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let halfPipeline = try? device.makeComputePipelineState(
                function: halfFunction)
        else { return nil }
        return MetalState(device: device, queue: queue, pipeline: pipeline,
                          halfPipeline: halfPipeline)
    }()

    private static var presentSource: String { """
    #include <metal_stdlib>
    using namespace metal;

    static float shoulder(float peak, float ceiling)
    {
        const float knee = 0.9f;
        if (peak <= knee) { return peak; }
        float over = peak - knee;
        float room = ceiling - knee;
        return knee + room * over / (over + room);
    }

    kernel void fotufilm_print_to_edr(
        device const float4 *printed [[buffer(0)]],
        texture2d<float, access::write> destination [[texture(0)]],
        constant uint2 &size [[buffer(1)]],
        constant uint2 &origin [[buffer(2)]],
        constant float &ceiling [[buffer(3)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= size.x || gid.y >= size.y) { return; }
        float4 value = printed[gid.y * size.x + gid.x];
        float3 positive = max(value.rgb, 0.0f);
        float peak = max(positive.r, max(positive.g, positive.b));
        float3 rolled = peak > 1e-6f
            ? positive * (shoulder(peak, ceiling) / peak)
            : float3(0.0f);
        destination.write(float4(rolled, 1.0f), gid + origin);
    }

    kernel void fotufilm_print_half_to_edr(
        device const half4 *printed [[buffer(0)]],
        texture2d<float, access::write> destination [[texture(0)]],
        constant uint2 &size [[buffer(1)]],
        constant uint2 &origin [[buffer(2)]],
        constant float &ceiling [[buffer(3)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= size.x || gid.y >= size.y) { return; }
        float4 value = float4(printed[gid.y * size.x + gid.x]);
        float3 positive = max(value.rgb, 0.0f);
        float peak = max(positive.r, max(positive.g, positive.b));
        float3 rolled = peak > 1e-6f
            ? positive * (shoulder(peak, ceiling) / peak)
            : float3(0.0f);
        destination.write(float4(rolled, 1.0f), gid + origin);
    }
    """ }

    private static var metalSource: String { """
    #include <metal_stdlib>
    using namespace metal;

    static float hlg_scene_light(float signal)
    {
        const float a = \(PrintEncoding.hlgA)f;
        const float b = \(PrintEncoding.hlgB)f;
        const float c = \(PrintEncoding.hlgC)f;
        float e = clamp(signal, 0.0f, 1.0f);
        return e <= 0.5f ? (e * e / 3.0f)
                         : ((exp((e - c) / a) + b) / 12.0f);
    }

    \(AppleLog.metalFunction)

    static float scene_light(float signal, uint curve)
    {
        return curve == 0 ? hlg_scene_light(signal)
                          : apple_log_to_linear(clamp(signal, 0.0f, 1.0f));
    }

    kernel void fotufilm_capture_to_linear(
        texture2d<float, access::sample> luma [[texture(0)]],
        texture2d<float, access::sample> chroma [[texture(1)]],
        device float4 *destination [[buffer(0)]],
        constant uint2 &size [[buffer(1)]],
        constant float &scale [[buffer(2)]],
        constant float2 &chroma_offset [[buffer(3)]],
        constant uint &curve [[buffer(4)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= size.x || gid.y >= size.y) { return; }
        constexpr sampler bilinear(coord::normalized, address::clamp_to_edge,
                                   filter::linear);
        float2 uv = (float2(gid) + 0.5f) / float2(size);

        // 'x420' stores each 10-bit sample left-justified in a 16-bit word, so the unorm read comes back as code * 64 / 65535.
        const float toCode = 65535.0f / 64.0f;
        float y10 = luma.sample(bilinear, uv).r * toCode;
        float2 c10 = chroma.sample(bilinear, uv + chroma_offset).rg * toCode;

        float y = (y10 - 64.0f) / 876.0f;
        float u = (c10.x - 512.0f) / 896.0f;
        float v = (c10.y - 512.0f) / 896.0f;
        float3 signal = float3(y + 1.4746f * v,
                               y - 0.164553f * u - 0.571353f * v,
                               y + 1.8814f * u);

        // HLG and Apple Log both carry BT.2020 primaries — the engine's own working
        // space — so decoding the curve is the whole conversion; no gamut matrix.
        float3 open = max(float3(scene_light(signal.x, curve),
                                 scene_light(signal.y, curve),
                                 scene_light(signal.z, curve)), 0.0f) * scale;
        destination[gid.y * size.x + gid.x] = float4(open, 1.0f);
    }

    kernel void fotufilm_capture_to_linear_half(
        texture2d<float, access::sample> luma [[texture(0)]],
        texture2d<float, access::sample> chroma [[texture(1)]],
        device half4 *destination [[buffer(0)]],
        constant uint2 &size [[buffer(1)]],
        constant float &scale [[buffer(2)]],
        constant float2 &chroma_offset [[buffer(3)]],
        constant uint &curve [[buffer(4)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= size.x || gid.y >= size.y) { return; }
        constexpr sampler bilinear(coord::normalized, address::clamp_to_edge,
                                   filter::linear);
        float2 uv = (float2(gid) + 0.5f) / float2(size);
        const float toCode = 65535.0f / 64.0f;
        float y10 = luma.sample(bilinear, uv).r * toCode;
        float2 c10 = chroma.sample(bilinear, uv + chroma_offset).rg * toCode;
        float y = (y10 - 64.0f) / 876.0f;
        float u = (c10.x - 512.0f) / 896.0f;
        float v = (c10.y - 512.0f) / 896.0f;
        float3 signal = float3(y + 1.4746f * v,
                               y - 0.164553f * u - 0.571353f * v,
                               y + 1.8814f * u);
        float3 open = max(float3(scene_light(signal.x, curve),
                                 scene_light(signal.y, curve),
                                 scene_light(signal.z, curve)), 0.0f) * scale;
        destination[gid.y * size.x + gid.x] = half4(float4(open, 1.0f));
    }
    """ }
}
