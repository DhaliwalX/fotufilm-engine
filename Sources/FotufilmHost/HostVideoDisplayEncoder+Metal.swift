#if canImport(Metal)
import Metal
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Reconstructs the 8-bit decoder's Display P3 codes on the GPU before the film develops.
/// Coefficients and quantization boundaries come from the same color functions as the CPU path.
final class MetalVideoDisplayEncoder {
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let parameters: MTLBuffer

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        guard let library = try? device.makeLibrary(source: Self.source, options: options),
              let function = library.makeFunction(name: "display8"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        let columns = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
            .map(ColorScience.linearRec2020ToDisplayP3)
        var values = (0..<3).flatMap { row in columns.map { $0[row] } }
        values += (0..<255).map { ColorScience.srgbToLinear((Float($0) + 0.5) / 255) }
        guard let parameters = device.makeBuffer(bytes: values, length: values.count * 4,
                                                  options: .storageModeShared) else { return nil }
        self.queue = queue
        self.pipeline = pipeline
        self.parameters = parameters
    }

    /// The caller owns each frame's buffers until this synchronous conversion completes.
    func encode(_ scene: UnsafeBufferPointer<Float>, staging: MTLBuffer,
                output: MTLBuffer, pixels: Int) -> Bool {
        guard pixels > 0, scene.count >= pixels * 4, staging.length >= pixels * 16,
              output.length >= pixels * 4, let source = scene.baseAddress,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return false }
        staging.contents().assumingMemoryBound(to: Float.self).update(from: source, count: pixels * 4)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(staging, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBuffer(parameters, offset: 0, index: 2)
        var count = UInt32(pixels)
        encoder.setBytes(&count, length: 4, index: 3)
        encoder.dispatchThreads(MTLSize(width: pixels, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup),
                                         height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        return command.status == .completed
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void display8(device const float4* source [[buffer(0)]],
                         device uchar4* output [[buffer(1)]],
                         constant float* p [[buffer(2)]],
                         constant uint& count [[buffer(3)]], uint i [[thread_position_in_grid]]) {
        if (i >= count) return;
        float3 rgb = source[i].rgb;
        uchar4 codes = uchar4(0, 0, 0, 255);
        for (uint c = 0; c < 3; ++c) {
            float value = (p[c * 3] * rgb.r + p[c * 3 + 1] * rgb.g) + p[c * 3 + 2] * rgb.b;
            if (!(value >= p[9])) continue;
            uint low = 0, high = 255;
            while (high - low > 1) {
                uint middle = (low + high) / 2;
                if (value >= p[9 + middle]) low = middle; else high = middle;
            }
            codes[c] = uchar(high);
        }
        output[i] = codes;
    }
    """
}
#endif
