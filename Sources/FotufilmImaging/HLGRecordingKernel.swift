import Foundation

#if canImport(Metal)
import Metal
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Metal implementation of `HLGTransfer.encode420` for one 2×2 Display P3 block. It applies the
/// shoulder, converts to Rec.2020, reverses the OOTF, and writes 10-bit HLG Y′CbCr. The source is
/// colocated with the Swift transfer so parity tests compile the production kernel.
public enum HLGRecordingKernel {
    /// The compute function the recorder builds its pipeline from.
    public static let functionName = "fotufilm_hlg_record"
    public static let halfFunctionName = "fotufilm_hlg_record_half"
    public static let previewFunctionName = "fotufilm_hlg_preview"
    public static let halfPreviewFunctionName = previewFunctionName
    public static let recordPreviewFunctionName = "fotufilm_hlg_record_preview"
    public static let halfRecordPreviewFunctionName =
        "fotufilm_hlg_record_half_preview"

    /// The same transfer with packed half-float input for realtime HDR capture.
    public static var halfSource: String {
        source
            .replacingOccurrences(of: functionName, with: halfFunctionName)
            .replacingOccurrences(of: "device const float4 *source",
                                  with: "device const half4 *source")
    }

    /// Where each argument is bound, so the recorder and the test cannot disagree about it.
    public enum Argument {
        public static let source = 0
        public static let size = 1
        public static let curve = 2
        public static let tail = 3
        public static let previewOrigin = 4
    }

    /// `curve`, as the kernel reads it: the scene headroom, the display ceiling the shoulder
    /// rolls towards, HLG's system gamma, and the OETF's `a`.
    public static var curve: SIMD4<Float> {
        SIMD4(PrintEncoding.hdrHeadroom, PrintEncoding.hdrDisplayCeiling,
              HLGTransfer.systemGamma, PrintEncoding.hlgA)
    }

    /// `tail`, as the kernel reads it: the OETF's `b` and `c`.
    public static var tail: SIMD2<Float> {
        SIMD2(PrintEncoding.hlgB, PrintEncoding.hlgC)
    }

    #if canImport(Metal)
    /// Production compile options shared with parity tests. Fast math is disabled for CPU/GPU
    /// agreement.
    public static var compileOptions: MTLCompileOptions {
        let options = MTLCompileOptions()
        if #available(macOS 15.0, iOS 18.0, *) {
            options.mathMode = .safe
        } else {
            options.fastMathEnabled = false
        }
        return options
    }
    #endif

    /// One element of the shared P3 -> Rec.2020 matrix, spelled for Metal source.
    private static func m(_ index: Int) -> String {
        String(HLGTransfer.displayP3ToRec2020[index])
    }

    /// One element of the inverse Rec.2020 -> Display P3 matrix used after decoding the exact
    /// quantized Main10 block for the viewfinder.
    private static func inverseM(_ index: Int) -> String {
        String(HLGTransfer.rec2020ToDisplayP3[index])
    }

    public static var source: String { #"""
    #include <metal_stdlib>
    using namespace metal;

    inline float shoulder(float peak, float ceiling) {
        const float knee = 0.9f;
        if (peak <= knee) return peak;
        const float over = peak - knee;
        const float room = ceiling - knee;
        return knee + room * over / (over + room);
    }

    inline float hlg(float value, float headroom, float a, float b, float c) {
        const float e = clamp(value / headroom, 0.0f, 1.0f);
        return e <= (1.0f / 12.0f)
            ? sqrt(3.0f * e)
            : a * log(12.0f * e - b) + c;
    }

    inline float3 encode_pixel(float3 print, float4 curve, float2 tail) {
        float3 positive = max(print, float3(0.0f));
        const float peak = max(positive.x, max(positive.y, positive.z));
        float3 rolled = float3(0.0f);
        if (peak > 1.0e-6f) {
            rolled = positive * (shoulder(peak, curve.y) / peak);
        }

        // Interpolated from HLGTransfer, which takes them from ColorScience: a hand-copied
        // literal here is how the CPU and GPU paths drifted apart in the first place.
        float3 wide;
        wide.x = dot(float3(\#(m(0))f, \#(m(1))f, \#(m(2))f), rolled);
        wide.y = dot(float3(\#(m(3))f, \#(m(4))f, \#(m(5))f), rolled);
        wide.z = dot(float3(\#(m(6))f, \#(m(7))f, \#(m(8))f), rolled);
        wide = max(wide, float3(0.0f));

        const float luminance = dot(float3(0.2627f, 0.6780f, 0.0593f), wide);
        if (luminance > 1.0e-6f) {
            const float inverse_ootf = pow(
                luminance, (1.0f - curve.z) / curve.z);
            wide *= inverse_ootf;
        } else {
            wide = float3(0.0f);
        }

        const float3 signal = float3(
            hlg(wide.x, curve.x, curve.w, tail.x, tail.y),
            hlg(wide.y, curve.x, curve.w, tail.x, tail.y),
            hlg(wide.z, curve.x, curve.w, tail.x, tail.y));
        const float y = dot(float3(0.2627f, 0.6780f, 0.0593f), signal);
        return float3(y, (signal.z - y) / 1.8814f,
                      (signal.x - y) / 1.4746f);
    }

    // The fourth channel is a gain, not coverage: a value above one scales the print before it is
    // rolled, which is what the CPU fallback below and `FilmOutputConversion.rec2020HLG` both do
    // with it. Ordinary alpha is at or below one and changes nothing.
    template<typename Pixel>
    inline float3 print_light(Pixel pixel) {
        const float4 value = float4(pixel);
        return value.xyz * max(value.w, 1.0f);
    }

    inline float stored_code(float code) {
        return code * (64.0f / 65535.0f);
    }

    struct encoded_block {
        float4 luma;
        float2 chroma;
    };

    template<typename Pixel>
    inline encoded_block encode_block(
        device const Pixel *source, uint2 top_left, uint width,
        float4 curve, float2 tail) {
        const uint a_index = top_left.y * width + top_left.x;
        const uint b_index = a_index + 1;
        const uint c_index = a_index + width;
        const uint d_index = c_index + 1;
        const float3 a = encode_pixel(print_light(source[a_index]), curve, tail);
        const float3 b = encode_pixel(print_light(source[b_index]), curve, tail);
        const float3 c = encode_pixel(print_light(source[c_index]), curve, tail);
        const float3 d = encode_pixel(print_light(source[d_index]), curve, tail);
        encoded_block result;
        result.luma = clamp(floor(float4(a.x, b.x, c.x, d.x) * 876.0f
            + 64.5f), 0.0f, 1023.0f);
        result.chroma = clamp(floor(float2(
            (a.y + b.y + c.y + d.y) * 224.0f + 512.5f,
            (a.z + b.z + c.z + d.z) * 224.0f + 512.5f)),
            0.0f, 1023.0f);
        return result;
    }

    inline float hlg_scene_light(float signal, float a, float b, float c) {
        const float value = clamp(signal, 0.0f, 1.0f);
        return value <= 0.5f ? value * value / 3.0f
            : (exp((value - c) / a) + b) / 12.0f;
    }

    inline float3 preview_pixel(
        float luma_code, float2 chroma_code, float4 curve, float2 tail) {
        const float y = (luma_code - 64.0f) / 876.0f;
        const float u = (chroma_code.x - 512.0f) / 896.0f;
        const float v = (chroma_code.y - 512.0f) / 896.0f;
        const float3 signal = clamp(float3(
            y + 1.4746f * v,
            y - 0.164553f * u - 0.571353f * v,
            y + 1.8814f * u), 0.0f, 1.0f);
        float3 wide = float3(
            hlg_scene_light(signal.x, curve.w, tail.x, tail.y),
            hlg_scene_light(signal.y, curve.w, tail.x, tail.y),
            hlg_scene_light(signal.z, curve.w, tail.x, tail.y)) * curve.x;
        const float luminance = dot(
            float3(0.2627f, 0.6780f, 0.0593f), wide);
        if (luminance > 1.0e-6f) {
            wide *= pow(luminance, curve.z - 1.0f);
        } else {
            wide = float3(0.0f);
        }
        return max(float3(
            dot(float3(\#(inverseM(0))f, \#(inverseM(1))f,
                       \#(inverseM(2))f), wide),
            dot(float3(\#(inverseM(3))f, \#(inverseM(4))f,
                       \#(inverseM(5))f), wide),
            dot(float3(\#(inverseM(6))f, \#(inverseM(7))f,
                       \#(inverseM(8))f), wide)), float3(0.0f));
    }

    kernel void fotufilm_hlg_record(
        device const float4 *source [[buffer(0)]],
        constant uint2 &size [[buffer(1)]],
        constant float4 &curve [[buffer(2)]],
        constant float2 &tail [[buffer(3)]],
        texture2d<float, access::write> luma [[texture(0)]],
        texture2d<float, access::write> chroma [[texture(1)]],
        uint2 block [[thread_position_in_grid]]) {
        const uint2 top_left = block * 2;
        if (top_left.x >= size.x || top_left.y >= size.y) return;
        const encoded_block encoded = encode_block(
            source, top_left, size.x, curve, tail);
        luma.write(float4(stored_code(encoded.luma.x)), top_left);
        luma.write(float4(stored_code(encoded.luma.y)),
                   top_left + uint2(1, 0));
        luma.write(float4(stored_code(encoded.luma.z)),
                   top_left + uint2(0, 1));
        luma.write(float4(stored_code(encoded.luma.w)),
                   top_left + uint2(1, 1));
        chroma.write(float4(stored_code(encoded.chroma.x),
                            stored_code(encoded.chroma.y), 0.0f, 1.0f),
                     block);
    }

    // The viewfinder is decoded from the same rounded 10-bit 4:2:0 block the writer receives.
    // It therefore cannot diverge in gain, shoulder, gamut, transfer, or chroma subsampling.
    kernel void fotufilm_hlg_preview(
        device const float4 *source [[buffer(0)]],
        constant uint2 &size [[buffer(1)]],
        constant float4 &curve [[buffer(2)]],
        constant float2 &tail [[buffer(3)]],
        constant uint2 &origin [[buffer(4)]],
        texture2d<float, access::write> preview [[texture(2)]],
        uint2 block [[thread_position_in_grid]]) {
        const uint2 top_left = block * 2;
        if (top_left.x >= size.x || top_left.y >= size.y) return;
        const encoded_block encoded = encode_block(
            source, top_left, size.x, curve, tail);
        preview.write(float4(preview_pixel(
            encoded.luma.x, encoded.chroma, curve, tail), 1.0f),
            origin + top_left);
        preview.write(float4(preview_pixel(
            encoded.luma.y, encoded.chroma, curve, tail), 1.0f),
            origin + top_left + uint2(1, 0));
        preview.write(float4(preview_pixel(
            encoded.luma.z, encoded.chroma, curve, tail), 1.0f),
            origin + top_left + uint2(0, 1));
        preview.write(float4(preview_pixel(
            encoded.luma.w, encoded.chroma, curve, tail), 1.0f),
            origin + top_left + uint2(1, 1));
    }

    kernel void fotufilm_hlg_record_preview(
        device const float4 *source [[buffer(0)]],
        constant uint2 &size [[buffer(1)]],
        constant float4 &curve [[buffer(2)]],
        constant float2 &tail [[buffer(3)]],
        constant uint2 &origin [[buffer(4)]],
        texture2d<float, access::write> luma [[texture(0)]],
        texture2d<float, access::write> chroma [[texture(1)]],
        texture2d<float, access::write> preview [[texture(2)]],
        uint2 block [[thread_position_in_grid]]) {
        const uint2 top_left = block * 2;
        if (top_left.x >= size.x || top_left.y >= size.y) return;
        const encoded_block encoded = encode_block(
            source, top_left, size.x, curve, tail);
        luma.write(float4(stored_code(encoded.luma.x)), top_left);
        luma.write(float4(stored_code(encoded.luma.y)),
                   top_left + uint2(1, 0));
        luma.write(float4(stored_code(encoded.luma.z)),
                   top_left + uint2(0, 1));
        luma.write(float4(stored_code(encoded.luma.w)),
                   top_left + uint2(1, 1));
        chroma.write(float4(stored_code(encoded.chroma.x),
                            stored_code(encoded.chroma.y), 0.0f, 1.0f),
                     block);
        preview.write(float4(preview_pixel(
            encoded.luma.x, encoded.chroma, curve, tail), 1.0f),
            origin + top_left);
        preview.write(float4(preview_pixel(
            encoded.luma.y, encoded.chroma, curve, tail), 1.0f),
            origin + top_left + uint2(1, 0));
        preview.write(float4(preview_pixel(
            encoded.luma.z, encoded.chroma, curve, tail), 1.0f),
            origin + top_left + uint2(0, 1));
        preview.write(float4(preview_pixel(
            encoded.luma.w, encoded.chroma, curve, tail), 1.0f),
            origin + top_left + uint2(1, 1));
    }
    """# }
}
