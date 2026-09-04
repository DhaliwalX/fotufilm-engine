import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// How the pixels of an opened clip are to be interpreted.
enum VideoSourceEncoding: String, CaseIterable, Identifiable {
    /// Trust the container's tags and convert SDR, HLG, or PQ to scene-linear Rec.2020.
    case standard
    case appleLog
    case slog3Cine
    case slog3
    case slog2
    case flog
    case flog2
    case flog2C
    case hlg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .appleLog: return "Apple Log · Rec.2020"
        case .slog3Cine: return "S-Log3 · S-Gamut3.Cine"
        case .slog3: return "S-Log3 · S-Gamut3"
        case .slog2: return "S-Log2 · S-Gamut"
        case .flog: return "F-Log · F-Gamut"
        case .flog2: return "F-Log2 · F-Gamut"
        case .flog2C: return "F-Log2 C · F-Gamut C"
        case .hlg: return "HLG · Rec.2020"
        }
    }

    /// Whether the app must receive untouched code values and perform the declared curve/gamut
    /// conversion itself. This includes HLG even though HLG is not a log camera format.
    var requiresExplicitDecode: Bool { self != .standard }

    /// The engine-side description of this encoding — curve, gamut, and contract — which is where
    /// the conversion's numbers actually live.
    var cameraEncoding: CameraLogEncoding? {
        switch self {
        case .standard: return nil
        case .appleLog: return .appleLog
        case .slog3Cine: return .slog3Cine
        case .slog3: return .slog3
        case .slog2: return .slog2
        case .flog: return .flog
        case .flog2: return .flog2
        case .flog2C: return .flog2C
        case .hlg: return .hlg
        }
    }

    /// The light contract a clip in this encoding presents to the engine.
    var sourceLight: SourceLight? { cameraEncoding?.sourceLight }
}

/// Converts camera-log frames either to the engine's scene-linear Rec.2020 float contract or to an
/// SDR Display-P3 byte preview.
final class LogConverter {
    let encoding: VideoSourceEncoding
    let width: Int
    let height: Int

    private var decodeTable: [Float]
    private var matrix: [Float]
    private var displayTable: [Float]
    private let decodeFunction: (Float) -> Float
    private let linearMatrix: [Float]
    private let workingMatrix: [Float]
    private let curveIndex: UInt32

    private var bytePlanes: [UnsafeMutablePointer<UInt8>]
    private var floatIn: [UnsafeMutablePointer<Float>]
    private var floatOut: [UnsafeMutablePointer<Float>]
    private var alphaPlane: UnsafeMutablePointer<UInt8>
    private var alphaScratch: UnsafeMutablePointer<UInt8>

    private static let displayTableEntries = 4096

    /// `camera` and `sceneCCT` are the clip's capture metadata, when the container states any:
    /// they compose the illuminant-aware profile delta into the gamut matrix once, here, so the
    /// per-frame kernels and vDSP bands run exactly as many operations as before. Both default
    /// nil — and stay nil for sources without metadata — which leaves every matrix
    /// bit-identical to a converter built without the wiring.
    init?(encoding: VideoSourceEncoding, width: Int, height: Int,
          camera: CameraIdentity? = nil, sceneCCT: Float? = nil) {
        guard let cameraEncoding = encoding.cameraEncoding,
              width > 0, height > 0 else { return nil }
        self.encoding = encoding
        self.width = width
        self.height = height

        let logCurve = cameraEncoding.curve
        let decode: (Float) -> Float = { logCurve.linear($0) }
        let gamut = cameraEncoding.gamut.toDisplayP3
        let curve = logCurve.rawValue

        decodeTable = (0..<256).map { decode(Float($0) / 255) }
        let decodeMax = decode(1.0)
        // The profile delta is a working-space (Rec.2020) operator, so it composes onto the
        // gamut's working-space matrix; only the corrected result is carried back to this
        // path's Display P3 byte basis. The gate hands the base array itself back when there
        // is nothing to apply, and that comparison keeps the metadata-free path on the
        // original double-precision P3 scaling — bit-identical to a build without the wiring.
        let baseWorking = cameraEncoding.gamut.toRec2020.map { Float($0) }
        let composedWorking = CameraProfileCorrection.composedGamut(
            base: baseWorking, camera: camera, cct: sceneCCT)
        workingMatrix = composedWorking
        if composedWorking == baseWorking {
            matrix = gamut.map { Float($0 / Double(decodeMax)) }
            linearMatrix = gamut.map { Float($0) }
        } else {
            // Column by column through the shared conversion, so the delivery digits cannot
            // drift from ColorScience's.
            var correctedP3 = [Float](repeating: 0, count: 9)
            for column in 0..<3 {
                let p3 = ColorScience.linearRec2020ToDisplayP3(SIMD3(
                    composedWorking[column], composedWorking[3 + column],
                    composedWorking[6 + column]))
                correctedP3[column] = p3.x
                correctedP3[3 + column] = p3.y
                correctedP3[6 + column] = p3.z
            }
            matrix = correctedP3.map { $0 / decodeMax }
            linearMatrix = correctedP3
        }
        decodeFunction = decode
        curveIndex = curve
        displayTable = (0..<Self.displayTableEntries).map { i in
            let u = Float(i) / Float(Self.displayTableEntries - 1)
            let t = u * u * u * u * decodeMax
            return Self.encodeSRGB(Self.displayRender(t))
        }

        let count = width * height
        bytePlanes = (0..<3).map { _ in .allocate(capacity: count) }
        floatIn = (0..<3).map { _ in .allocate(capacity: count) }
        floatOut = (0..<3).map { _ in .allocate(capacity: count) }
        alphaPlane = .allocate(capacity: count)
        alphaPlane.initialize(repeating: 255, count: count)
        alphaScratch = .allocate(capacity: count)
    }

    deinit {
        bytePlanes.forEach { $0.deallocate() }
        floatIn.forEach { $0.deallocate() }
        floatOut.forEach { $0.deallocate() }
        alphaPlane.deallocate()
        alphaScratch.deallocate()
    }

    /// Converts one decoded frame straight into the engine's input buffer, on the GPU when the
    /// frame can take that path: the decoder's IOSurface becomes a zero-copy texture, the kernel
    /// runs the same tables and the same arithmetic as the CPU bands, and the engine reads the
    /// buffer it wrote.
    func convert(_ pixelBuffer: CVPixelBuffer, into buffer: MTLBuffer) -> Bool {
        guard CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height else { return false }
        if convertOnGPU(pixelBuffer, into: buffer) { return true }
        return convert(pixelBuffer, into: buffer.contents())
    }

    /// Converts one decoded frame of log code values into display-referred P3
    /// RGBA8, tightly packed at `dest`.
    func convert(_ pixelBuffer: CVPixelBuffer,
                 into dest: UnsafeMutableRawPointer) -> Bool {
        guard CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height else { return false }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        return convertPacked(base,
                             rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer),
                             bgra: true, into: dest)
    }

    /// Same conversion from raw interleaved bytes; `bgra` says whether the
    /// source channel order is BGRA (the decoders') or RGBA (CGContext's).
    func convertPacked(_ src: UnsafeRawPointer, rowBytes: Int, bgra: Bool,
                       into dest: UnsafeMutableRawPointer) -> Bool {
        let bandRows = 128
        let bands = width * height >= 3_000_000
            ? (height + bandRows - 1) / bandRows : 1
        if bands <= 1 {
            return convertBand(0..<height, src: src, rowBytes: rowBytes,
                               bgra: bgra, into: dest)
        }
        var results = [Bool](repeating: false, count: bands)
        results.withUnsafeMutableBufferPointer { outcomes in
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                let rows = band * bandRows..<min(height, (band + 1) * bandRows)
                outcomes[band] = self.convertBand(rows, src: src,
                                                  rowBytes: rowBytes,
                                                  bgra: bgra, into: dest)
            }
        }
        return results.allSatisfy { $0 }
    }

    private func convertBand(_ rows: Range<Int>, src: UnsafeRawPointer,
                             rowBytes: Int, bgra: Bool,
                             into dest: UnsafeMutableRawPointer) -> Bool {
        let flags = vImage_Flags(kvImageNoFlags)
        let w = vImagePixelCount(width)
        let h = vImagePixelCount(rows.count)
        let count = vDSP_Length(width * rows.count)
        let plane = rows.lowerBound * width

        var source = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: src + rows.lowerBound * rowBytes),
            height: h, width: w, rowBytes: rowBytes)
        var r8 = vImage_Buffer(data: bytePlanes[0] + plane, height: h, width: w, rowBytes: width)
        var g8 = vImage_Buffer(data: bytePlanes[1] + plane, height: h, width: w, rowBytes: width)
        var b8 = vImage_Buffer(data: bytePlanes[2] + plane, height: h, width: w, rowBytes: width)
        var aScratch = vImage_Buffer(data: alphaScratch + plane, height: h, width: w, rowBytes: width)
        let deinterleave: vImage_Error = bgra
            ? vImageConvert_ARGB8888toPlanar8(&source, &b8, &g8, &r8, &aScratch, flags)
            : vImageConvert_ARGB8888toPlanar8(&source, &r8, &g8, &b8, &aScratch, flags)
        guard deinterleave == kvImageNoError else { return false }

        for channel in 0..<3 {
            var plane8 = vImage_Buffer(data: bytePlanes[channel] + plane,
                                       height: h, width: w, rowBytes: width)
            var planeF = vImage_Buffer(data: floatIn[channel] + plane,
                                       height: h, width: w, rowBytes: width * 4)
            guard vImageLookupTable_Planar8toPlanarF(
                &plane8, &planeF, decodeTable, flags) == kvImageNoError
            else { return false }
        }

        for out in 0..<3 {
            var m = matrix[out * 3]
            vDSP_vsmul(floatIn[0] + plane, 1, &m, floatOut[out] + plane, 1, count)
            for component in 1..<3 {
                m = matrix[out * 3 + component]
                vDSP_vsma(floatIn[component] + plane, 1, &m,
                          floatOut[out] + plane, 1, floatOut[out] + plane, 1, count)
            }
        }

        for channel in 0..<3 {
            var zero: Float = 0
            vDSP_vthr(floatOut[channel] + plane, 1, &zero,
                      floatOut[channel] + plane, 1, count)
            var n = Int32(width * rows.count)
            vvsqrtf(floatOut[channel] + plane, floatOut[channel] + plane, &n)
            vvsqrtf(floatOut[channel] + plane, floatOut[channel] + plane, &n)
            var planeF = vImage_Buffer(data: floatOut[channel] + plane,
                                       height: h, width: w, rowBytes: width * 4)
            guard vImageInterpolatedLookupTable_PlanarF(
                &planeF, &planeF, displayTable,
                vImagePixelCount(Self.displayTableEntries),
                1.0, 0.0, flags) == kvImageNoError
            else { return false }
            var plane8 = vImage_Buffer(data: bytePlanes[channel] + plane,
                                       height: h, width: w, rowBytes: width)
            guard vImageConvert_PlanarFtoPlanar8(
                &planeF, &plane8, 1.0, 0.0, flags) == kvImageNoError
            else { return false }
        }

        var alpha = vImage_Buffer(data: alphaPlane + plane, height: h, width: w, rowBytes: width)
        var destination = vImage_Buffer(data: dest + plane * 4, height: h, width: w,
                                        rowBytes: width * 4)
        r8 = vImage_Buffer(data: bytePlanes[0] + plane, height: h, width: w, rowBytes: width)
        g8 = vImage_Buffer(data: bytePlanes[1] + plane, height: h, width: w, rowBytes: width)
        b8 = vImage_Buffer(data: bytePlanes[2] + plane, height: h, width: w, rowBytes: width)
        return vImageConvert_Planar8toARGB8888(
            &r8, &g8, &b8, &alpha, &destination, flags) == kvImageNoError
    }

    private static var metalSource: String { """
    #include <metal_stdlib>
    using namespace metal;

    kernel void fotufilm_log_convert(
        texture2d<float, access::read> source [[texture(0)]],
        device uchar4 *destination [[buffer(0)]],
        constant float *decode [[buffer(1)]],
        constant float *gamut [[buffer(2)]],
        constant float *display [[buffer(3)]],
        constant uint2 &size [[buffer(4)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= size.x || gid.y >= size.y) { return; }
        float4 texel = source.read(gid);
        uint3 code = uint3(rint(texel.rgb * 255.0f));
        float3 lin = float3(decode[code.x], decode[code.y], decode[code.z]);
        float3 v = float3(
            gamut[0] * lin.x + gamut[1] * lin.y + gamut[2] * lin.z,
            gamut[3] * lin.x + gamut[4] * lin.y + gamut[5] * lin.z,
            gamut[6] * lin.x + gamut[7] * lin.y + gamut[8] * lin.z);
        v = clamp(v, 0.0f, 1.0f);
        v = sqrt(sqrt(v));
        float3 t = v * \(displayTableEntries - 1).0f;
        uint3 index = min(uint3(t), uint3(\(displayTableEntries - 2)));
        float3 f = t - float3(index);
        float3 d = float3(
            display[index.x] + f.x * (display[index.x + 1] - display[index.x]),
            display[index.y] + f.y * (display[index.y + 1] - display[index.y]),
            display[index.z] + f.z * (display[index.z + 1] - display[index.z]));
        uint3 out = uint3(clamp(d, 0.0f, 1.0f) * 255.0f + 0.5f);
        destination[gid.y * size.x + gid.x] =
            uchar4(uchar(out.x), uchar(out.y), uchar(out.z), 255);
    }


    \(CameraLogCurve.metalSource)

    \(displayMetalSource)

    // Scene reflectance to the engine's input value, normalized so diffuse white (0.9) is 1.0.
    // Negative components are kept: a camera gamut wider than Rec.2020 puts real colour outside
    // the working cube, and the engine clamps that at its spectral recovery and nowhere earlier.
    static float deliver_scene(float scene)
    {
        return scene / 0.9f;
    }

    kernel void fotufilm_log_convert_linear(
        texture2d<float, access::read> source [[texture(0)]],
        device float4 *destination [[buffer(0)]],
        constant float *gamut [[buffer(1)]],
        constant uint2 &size [[buffer(2)]],
        constant uint &curve [[buffer(3)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= size.x || gid.y >= size.y) { return; }
        float3 code = source.read(gid).rgb;
        float3 lin = float3(decode_curve(code.x, curve),
                            decode_curve(code.y, curve),
                            decode_curve(code.z, curve));
        float3 scene = float3(
            gamut[0] * lin.x + gamut[1] * lin.y + gamut[2] * lin.z,
            gamut[3] * lin.x + gamut[4] * lin.y + gamut[5] * lin.z,
            gamut[6] * lin.x + gamut[7] * lin.y + gamut[8] * lin.z);
        destination[gid.y * size.x + gid.x] = float4(
            deliver_scene(scene.x), deliver_scene(scene.y),
            deliver_scene(scene.z), 1.0f);
    }

    kernel void fotufilm_log_convert_deep(
        texture2d<float, access::read> source [[texture(0)]],
        device uchar4 *destination [[buffer(0)]],
        constant float *gamut [[buffer(1)]],
        constant uint2 &size [[buffer(2)]],
        constant uint &curve [[buffer(3)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= size.x || gid.y >= size.y) { return; }
        float3 code = source.read(gid).rgb;
        float3 lin = float3(decode_curve(code.x, curve),
                            decode_curve(code.y, curve),
                            decode_curve(code.z, curve));
        float3 scene = float3(
            gamut[0] * lin.x + gamut[1] * lin.y + gamut[2] * lin.z,
            gamut[3] * lin.x + gamut[4] * lin.y + gamut[5] * lin.z,
            gamut[6] * lin.x + gamut[7] * lin.y + gamut[8] * lin.z);
        float3 d = float3(encode_srgb(display_render(scene.x)),
                          encode_srgb(display_render(scene.y)),
                          encode_srgb(display_render(scene.z)));
        uint3 out = uint3(clamp(d, 0.0f, 1.0f) * 255.0f + 0.5f);
        destination[gid.y * size.x + gid.x] =
            uchar4(uchar(out.x), uchar(out.y), uchar(out.z), 255);
    }
    """ }

    private struct MetalState {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState
        let linearPipeline: MTLComputePipelineState
        let deepPipeline: MTLComputePipelineState
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
              let function = library.makeFunction(name: "fotufilm_log_convert"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let linearFunction = library.makeFunction(
                  name: "fotufilm_log_convert_linear"),
              let linearPipeline = try? device.makeComputePipelineState(
                  function: linearFunction),
              let deepFunction = library.makeFunction(
                  name: "fotufilm_log_convert_deep"),
              let deepPipeline = try? device.makeComputePipelineState(
                  function: deepFunction)
        else { return nil }
        return MetalState(device: device, queue: queue, pipeline: pipeline,
                          linearPipeline: linearPipeline,
                          deepPipeline: deepPipeline)
    }()

    private var metalAttempted = false
    private var textureCache: CVMetalTextureCache?
    private var decodeBuffer: MTLBuffer?
    private var displayBuffer: MTLBuffer?
    private var matrixBuffer: MTLBuffer?
    private var linearMatrixBuffer: MTLBuffer?
    private var workingMatrixBuffer: MTLBuffer?

    private func ensureMetalResources(_ state: MetalState) -> Bool {
        if !metalAttempted {
            metalAttempted = true
            decodeBuffer = state.device.makeBuffer(
                bytes: decodeTable, length: decodeTable.count * 4)
            displayBuffer = state.device.makeBuffer(
                bytes: displayTable, length: displayTable.count * 4)
            matrixBuffer = state.device.makeBuffer(
                bytes: matrix, length: matrix.count * 4)
            linearMatrixBuffer = state.device.makeBuffer(
                bytes: linearMatrix, length: linearMatrix.count * 4)
            workingMatrixBuffer = state.device.makeBuffer(
                bytes: workingMatrix, length: workingMatrix.count * 4)
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, state.device,
                                      nil, &textureCache)
        }
        return textureCache != nil
    }

    private func convertOnGPU(_ pixelBuffer: CVPixelBuffer,
                              into dest: MTLBuffer) -> Bool {
        guard let state = Self.metalState,
              ensureMetalResources(state) else { return false }
        guard let decodeBuffer, let displayBuffer, let matrixBuffer,
              let textureCache else { return false }

        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .bgra8Unorm, width, height, 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture)
        else { return false }

        guard let commands = state.queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(state.pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(dest, offset: 0, index: 0)
        encoder.setBuffer(decodeBuffer, offset: 0, index: 1)
        encoder.setBuffer(matrixBuffer, offset: 0, index: 2)
        encoder.setBuffer(displayBuffer, offset: 0, index: 3)
        var size = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.size, index: 4)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime(cvTexture) {}
        return commands.status == .completed
    }

    /// The float path's kernel dispatch: scene-linear Rec.2020 float RGBA written
    /// straight into the engine's input buffer.
    func convertLinearOnGPU(_ pixelBuffer: CVPixelBuffer,
                            into dest: MTLBuffer) -> Bool {
        guard let state = Self.metalState else { return false }
        return dispatchDeepKernel(pixelBuffer, into: dest,
                                  pipeline: state.linearPipeline, working: true)
    }

    /// The same dispatch for the deep input's other exit: display-referred
    /// RGBA8 rather than display-linear float.
    func convertDeepOnGPU(_ pixelBuffer: CVPixelBuffer,
                          into dest: MTLBuffer) -> Bool {
        guard let state = Self.metalState else { return false }
        return dispatchDeepKernel(pixelBuffer, into: dest,
                                  pipeline: state.deepPipeline, working: false)
    }

    private func dispatchDeepKernel(_ pixelBuffer: CVPixelBuffer,
                                    into dest: MTLBuffer,
                                    pipeline: MTLComputePipelineState,
                                    working: Bool) -> Bool {
        guard let state = Self.metalState,
              ensureMetalResources(state) else { return false }
        guard let gamutBuffer = working ? workingMatrixBuffer : linearMatrixBuffer,
              let textureCache,
              CVPixelBufferGetPixelFormatType(pixelBuffer)
                  == kCVPixelFormatType_128RGBAFloat
        else { return false }

        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .rgba32Float, width, height, 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture)
        else { return false }

        guard let commands = state.queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(dest, offset: 0, index: 0)
        encoder.setBuffer(gamutBuffer, offset: 0, index: 1)
        var size = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.size, index: 2)
        var curve = curveIndex
        encoder.setBytes(&curve, length: MemoryLayout<UInt32>.size, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime(cvTexture) {}
        return commands.status == .completed
    }

    /// Converts one decoded full-float frame of raw code values into scene-linear Rec.2020 float
    /// RGBA — the engine's working space — in the engine's float input buffer.
    func convertLinear(_ pixelBuffer: CVPixelBuffer, into buffer: MTLBuffer) -> Bool {
        guard CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height,
              CVPixelBufferGetPixelFormatType(pixelBuffer)
                  == kCVPixelFormatType_128RGBAFloat
        else { return false }
        if convertLinearOnGPU(pixelBuffer, into: buffer) { return true }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        return convertLinearPacked(
            base, rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer),
            into: buffer.contents().assumingMemoryBound(to: Float.self))
    }

    /// The CPU reference: interleaved full-float RGBA code values at `src` to tightly packed
    /// scene-linear Rec.2020 float RGBA at `dest`, in the same row bands as the 8-bit path.
    func convertLinearPacked(_ src: UnsafeRawPointer, rowBytes: Int,
                             into dest: UnsafeMutablePointer<Float>) -> Bool {
        let bandRows = 128
        let bands = width * height >= 3_000_000
            ? (height + bandRows - 1) / bandRows : 1
        if bands <= 1 {
            convertLinearBand(0..<height, src: src, rowBytes: rowBytes, into: dest)
            return true
        }
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let rows = band * bandRows..<min(self.height, (band + 1) * bandRows)
            self.convertLinearBand(rows, src: src, rowBytes: rowBytes, into: dest)
        }
        return true
    }

    private func convertLinearBand(_ rows: Range<Int>, src: UnsafeRawPointer,
                                   rowBytes: Int,
                                   into dest: UnsafeMutablePointer<Float>) {
        workingMatrix.withUnsafeBufferPointer { m in
            for row in rows {
                let source = (src + row * rowBytes)
                    .assumingMemoryBound(to: Float.self)
                let out = dest + row * width * 4
                for x in 0..<width {
                    let lin = SIMD3<Float>(
                        decodeFunction(source[x * 4]),
                        decodeFunction(source[x * 4 + 1]),
                        decodeFunction(source[x * 4 + 2]))
                    for channel in 0..<3 {
                        let scene = m[channel * 3] * lin.x
                            + m[channel * 3 + 1] * lin.y
                            + m[channel * 3 + 2] * lin.z
                        // Normalized so diffuse white (0.9) lands on 1.0. Negatives survive:
                        // out-of-Rec.2020 colour is the engine's to handle at its own seam.
                        out[x * 4 + channel] = scene / 0.9
                    }
                    out[x * 4 + 3] = 1
                }
            }
        }
    }

    /// The CPU reference: interleaved full-float RGBA code values at `src` to tightly packed
    /// display-referred RGBA8 at `dest`, in the same row bands as every other path.
    func convertDeepPacked(_ src: UnsafeRawPointer, rowBytes: Int,
                           into dest: UnsafeMutablePointer<UInt8>) -> Bool {
        let bandRows = 128
        let bands = width * height >= 3_000_000
            ? (height + bandRows - 1) / bandRows : 1
        if bands <= 1 {
            convertDeepBand(0..<height, src: src, rowBytes: rowBytes, into: dest)
            return true
        }
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let rows = band * bandRows..<min(self.height, (band + 1) * bandRows)
            self.convertDeepBand(rows, src: src, rowBytes: rowBytes, into: dest)
        }
        return true
    }

    private func convertDeepBand(_ rows: Range<Int>, src: UnsafeRawPointer,
                                 rowBytes: Int,
                                 into dest: UnsafeMutablePointer<UInt8>) {
        linearMatrix.withUnsafeBufferPointer { m in
            for row in rows {
                let source = (src + row * rowBytes)
                    .assumingMemoryBound(to: Float.self)
                let out = dest + row * width * 4
                for x in 0..<width {
                    let lin = SIMD3<Float>(
                        decodeFunction(source[x * 4]),
                        decodeFunction(source[x * 4 + 1]),
                        decodeFunction(source[x * 4 + 2]))
                    for channel in 0..<3 {
                        let scene = m[channel * 3] * lin.x
                            + m[channel * 3 + 1] * lin.y
                            + m[channel * 3 + 2] * lin.z
                        let display = Self.encodeSRGB(Self.displayRender(scene))
                        out[x * 4 + channel] = UInt8(
                            min(255, max(0, display * 255 + 0.5)))
                    }
                    out[x * 4 + 3] = 255
                }
            }
        }
    }

    /// One already-decoded 8-bit still rendered to a Display P3 image through
    /// the 8-bit path's tables.
    static func convertImage(_ image: CGImage,
                             encoding: VideoSourceEncoding,
                             camera: CameraIdentity? = nil,
                             sceneCCT: Float? = nil) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let converter = LogConverter(encoding: encoding,
                                           width: width, height: height,
                                           camera: camera, sceneCCT: sceneCCT),
              let p3 = CGColorSpace(name: CGColorSpace.displayP3)
        else { return nil }
        let sourceSpace = image.colorSpace.flatMap {
            $0.model == .rgb ? $0 : nil
        } ?? CGColorSpaceCreateDeviceRGB()

        let rowBytes = width * 4
        var raw = [UInt8](repeating: 0, count: rowBytes * height)
        let drew = raw.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: rowBytes, space: sourceSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        var display = [UInt8](repeating: 0, count: rowBytes * height)
        let converted = raw.withUnsafeBytes { source in
            display.withUnsafeMutableBytes { dest in
                converter.convertPacked(source.baseAddress!, rowBytes: rowBytes,
                                        bgra: false, into: dest.baseAddress!)
            }
        }
        guard converted,
              let provider = CGDataProvider(data: Data(display) as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: rowBytes, space: p3,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)
    }

    /// The 8-bit display path's highlight shoulder. RGBA8 output is display-referred by
    /// construction — it cannot carry exposure above white — so scene light takes this shoulder
    /// before the sRGB encode: diffuse white (0.9) to full scale, linear below the knee, then an
    /// exponential shoulder that is C1 at the knee and asymptotes at 1.0.
    static func displayRender(_ scene: Float) -> Float {
        let t = max(0, scene) / 0.9
        let knee: Float = 0.7
        if t <= knee { return t }
        let s = 1 - knee
        return knee + s * (1 - exp(-(t - knee) / s))
    }

    /// The sRGB transfer encode that finishes the 8-bit display path.
    static func encodeSRGB(_ linear: Float) -> Float {
        let v = min(max(linear, 0), 1)
        if v <= 0.0031308 { return 12.92 * v }
        return 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    private static var displayMetalSource: String { """
    static float display_render(float scene)
    {
        float t = max(0.0f, scene) / 0.9f;
        const float knee = 0.7f;
        if (t <= knee) { return t; }
        float s = 1.0f - knee;
        return knee + s * (1.0f - exp(-(t - knee) / s));
    }

    static float encode_srgb(float linear)
    {
        float v = clamp(linear, 0.0f, 1.0f);
        if (v <= 0.0031308f) { return 12.92f * v; }
        return 1.055f * pow(v, 1.0f / 2.4f) - 0.055f;
    }
    """ }
}
