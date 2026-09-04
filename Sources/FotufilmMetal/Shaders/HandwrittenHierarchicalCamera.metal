#include <metal_stdlib>
using namespace metal;

constant bool kLocalTone [[function_constant(0)]];
constant uint kDecodeSamples = FOTUFILM_HIERARCHICAL_DECODE_SAMPLES;

struct HierarchicalSceneParameters {
    float4 white_balance;
    float4 adjustment;
    float4 exposure_and_cube;
};

struct HierarchicalCameraParameters {
    uint4 output_and_tone;
    uint4 source;
    float4 transform;
};

static inline float decode_transfer(
    texture1d<half, access::sample> table, float encoded) {
    constexpr sampler linear_table(
        coord::normalized, address::clamp_to_edge, filter::linear);
    float q = clamp(encoded, 0.0f, 1.0f) * float(kDecodeSamples - 1u);
    return float(table.sample(
        linear_table, (q + 0.5f) / float(kDecodeSamples)).r);
}

#include "HandwrittenCameraSceneTransfer.metalinc"

static inline float capture_scene_light(float signal, uint transfer) {
    return transfer == 0u ? hlg_scene_light(signal)
        : apple_log_to_linear(clamp(signal, 0.0f, 1.0f));
}

static inline float3 encoded_to_working(
    texture1d<half, access::sample> decode, float3 encoded,
    uint primaries) {
    float3 linear = float3(
        decode_transfer(decode, encoded.x),
        decode_transfer(decode, encoded.y),
        decode_transfer(decode, encoded.z));
    if (primaries == 0u) {
        return float3(
            dot(float3(0.753833034f, 0.198597369f, 0.047569597f), linear),
            dot(float3(0.045743849f, 0.941777220f, 0.012478931f), linear),
            dot(float3(-0.001210340f, 0.017601717f, 0.983608623f), linear));
    }
    return float3(
        dot(float3(0.627403896f, 0.329283038f, 0.043313066f), linear),
        dot(float3(0.069097289f, 0.919540395f, 0.011362316f), linear),
        dot(float3(0.016391439f, 0.088013308f, 0.895595253f), linear));
}

#include "HandwrittenCameraYCbCr.metalinc"

static inline float bilinear_plane(
    const device float *plane, uint width, uint height,
    float gx, float gy) {
    int x0 = clamp(int(gx), 0, max(int(width) - 2, 0));
    int y0 = clamp(int(gy), 0, max(int(height) - 2, 0));
    int x1 = min(x0 + 1, int(width) - 1);
    int y1 = min(y0 + 1, int(height) - 1);
    float fx = clamp(gx - float(x0), 0.0f, 1.0f);
    float fy = clamp(gy - float(y0), 0.0f, 1.0f);
    float top = mix(plane[y0 * int(width) + x0],
                    plane[y0 * int(width) + x1], fx);
    float bottom = mix(plane[y1 * int(width) + x0],
                       plane[y1 * int(width) + x1], fx);
    return mix(top, bottom, fy);
}

static inline float tone_base(
    const device float *tone_a, const device float *tone_b,
    float stops, uint2 position,
    constant HierarchicalCameraParameters &parameters) {
    if (!kLocalTone) return stops;
    uint width = max(parameters.output_and_tone.z, 1u);
    uint height = max(parameters.output_and_tone.w, 1u);
    float gx = clamp(
        (float(position.x) + 0.5f) * float(width)
            / float(parameters.output_and_tone.x) - 0.5f,
        0.0f, float(width - 1u));
    float gy = clamp(
        (float(position.y) + 0.5f) * float(height)
            / float(parameters.output_and_tone.y) - 0.5f,
        0.0f, float(height - 1u));
    return bilinear_plane(tone_a, width, height, gx, gy) * stops
        + bilinear_plane(tone_b, width, height, gx, gy);
}

static inline float3 adjust_scene(
    float3 scene, uint2 position,
    const device HierarchicalSceneParameters &scene_parameters,
    const device float *tone_a, const device float *tone_b,
    constant HierarchicalCameraParameters &parameters) {
    constexpr float3 luma = float3(0.2627002f, 0.6779981f, 0.0593017f);
    float3 balance = scene_parameters.white_balance.xyz;
    // Balance first: the metering, the luminance and the colourfulness below
    // all read the adapted scene, matching creative_exposure in the shared header.
    float3 adjusted = scene * balance;
    float4 controls = scene_parameters.adjustment;
    if (controls.x != 0.0f || controls.y != 0.0f) {
        float metered = dot(luma, adjusted)
            * scene_parameters.exposure_and_cube.x;
        float stops = log2(max(metered, 1.0e-6f));
        float keyed = tone_base(
            tone_a, tone_b, stops, position, parameters);
        float high = clamp(keyed * (1.0f / 6.0f), 0.0f, 1.0f);
        float low = clamp(-keyed * (1.0f / 6.0f), 0.0f, 1.0f);
        float high_mask = high * high * (3.0f - 2.0f * high);
        float low_mask = low * low * (3.0f - 2.0f * low);
        adjusted *= exp2(3.0f
            * (controls.x * high_mask + controls.y * low_mask));
    }
    if (controls.z != 1.0f || controls.w != 0.0f) {
        float luminance = dot(luma, adjusted);
        float peak = max(adjusted.x, max(adjusted.y, adjusted.z));
        float colourfulness =
            (peak - min(adjusted.x, min(adjusted.y, adjusted.z)))
            / max(peak, 1.0e-6f);
        float chroma = controls.z
            * (1.0f + controls.w * (1.0f - colourfulness));
        adjusted = luminance + chroma * (adjusted - luminance);
    }
    // Unlike the exposure table, the composed pointwise cube is indexed by scene-linear
    // Rec.2020. Keep this seam in that basis so the cube's own pointwise bake applies the
    // Rec.2020-to-exposure-domain transform exactly once.
    float3 physical = adjusted;
    float luminance = dot(luma, adjusted);
    if (luminance <= 0.0f) {
        physical = 0.0f;
    } else if (any(adjusted < 0.0f)) {
        float3 ratio = select(
            float3(1.0f), luminance / (luminance - adjusted),
            adjusted < 0.0f);
        float saturation = min(ratio.x, min(ratio.y, ratio.z));
        physical = luminance + saturation * (adjusted - luminance);
    }
    return max(physical, 0.0f);
}

static inline float4 tetrahedral(
    texture3d<half, access::sample> cube, float3 point) {
    uint edge = cube.get_width();
    float3 q = clamp(point, 0.0f, 1.0f) * float(edge - 1u);
    uint3 low = min(uint3(q), uint3(edge - 2u));
    float3 f = q - float3(low);
    float largest = max(f.x, max(f.y, f.z));
    float smallest = min(f.x, min(f.y, f.z));
    float middle = max(min(f.x, f.y), min(max(f.x, f.y), f.z));
    bool x_largest = f.x >= f.y && f.x >= f.z;
    bool y_largest = !x_largest && f.y >= f.z;
    bool x_smallest = f.x <= f.y && f.x <= f.z;
    bool y_smallest = !x_smallest && f.y <= f.z;
    uint3 near_step = uint3(x_largest, y_largest,
                            !x_largest && !y_largest);
    uint3 far_step = uint3(!x_smallest, !y_smallest,
                           x_smallest || y_smallest);
    float first_fraction = middle < 1.0f
        ? (largest - middle) / (1.0f - middle) : 0.0f;
    float second_fraction = middle > 0.0f
        ? smallest / middle : 0.0f;
    float inverse_edge = 1.0f / float(edge);
    float3 first_coordinate = (float3(low) + 0.5f
        + first_fraction * float3(near_step)) * inverse_edge;
    uint3 far = low + far_step;
    float3 second_coordinate = (float3(far) + 0.5f
        + second_fraction * float3(1u - far_step)) * inverse_edge;
    constexpr sampler linear_cube(
        coord::normalized, address::clamp_to_edge, filter::linear);
    float4 first = float4(cube.sample(linear_cube, first_coordinate));
    float4 second = float4(cube.sample(linear_cube, second_coordinate));
    return mix(first, second, middle);
}

static inline float3 develop(
    texture3d<half, access::sample> cube, float3 scene,
    const device HierarchicalSceneParameters &scene_parameters) {
    float knee = scene_parameters.exposure_and_cube.y;
    float scale = scene_parameters.exposure_and_cube.z;
    float3 grid = min(log2(max(scene, 0.0f) / knee + 1.0f) * scale,
                      float(cube.get_width() - 1u));
    return tetrahedral(cube, grid / float(cube.get_width() - 1u)).rgb;
}

static inline float3 read_sdr_scene(
    texture2d<float, access::sample> luma,
    texture2d<float, access::sample> chroma,
    texture1d<half, access::sample> decode,
    uint2 position, constant HierarchicalCameraParameters &parameters) {
    return fotufilm_decode_nv12_scene(
        luma, chroma, decode, position, parameters.output_and_tone.xy,
        parameters.transform.yz, parameters.source.x, parameters.source.y)
        * parameters.transform.x;
}

static inline float3 read_hdr_scene(
    texture2d<float, access::sample> luma,
    texture2d<float, access::sample> chroma,
    uint2 position, constant HierarchicalCameraParameters &parameters) {
    return fotufilm_decode_x420_scene(
        luma, chroma, position, parameters.output_and_tone.xy,
        parameters.transform.yz, parameters.source.x, parameters.transform.w)
        * parameters.transform.x;
}

static inline float3 spatially_correct(
    float3 base, texture2d<half, access::sample> low_full,
    texture2d<half, access::sample> low_base,
    uint2 position, uint2 extent) {
    constexpr sampler bilinear(
        coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(position) + 0.5f) / float2(extent);
    float3 full = float3(low_full.sample(bilinear, uv).rgb);
    float3 local = float3(low_base.sample(bilinear, uv).rgb);
    constexpr float epsilon = 0.001f;
    return max((base + epsilon) * (full + epsilon)
        / max(local + epsilon, epsilon) - epsilon, 0.0f);
}

kernel void fotufilm_hierarchical_sdr_base(
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    texture3d<half, access::sample> cube [[texture(2)]],
    texture1d<half, access::sample> decode [[texture(3)]],
    texture2d<half, access::write> output [[texture(4)]],
    const device HierarchicalSceneParameters &scene_parameters [[buffer(0)]],
    constant HierarchicalCameraParameters &parameters [[buffer(1)]],
    const device float *tone_a [[buffer(2)]],
    const device float *tone_b [[buffer(3)]],
    uint2 position [[thread_position_in_grid]]) {
    if (any(position >= parameters.output_and_tone.xy)) return;
    float3 scene = read_sdr_scene(
        luma, chroma, decode, position, parameters);
    float3 adjusted = adjust_scene(
        scene, position, scene_parameters, tone_a, tone_b, parameters);
    output.write(half4(
        half3(develop(cube, adjusted, scene_parameters)), 1.0h), position);
}

kernel void fotufilm_hierarchical_hdr_base(
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    texture3d<half, access::sample> cube [[texture(2)]],
    texture2d<half, access::write> output [[texture(4)]],
    const device HierarchicalSceneParameters &scene_parameters [[buffer(0)]],
    constant HierarchicalCameraParameters &parameters [[buffer(1)]],
    const device float *tone_a [[buffer(2)]],
    const device float *tone_b [[buffer(3)]],
    uint2 position [[thread_position_in_grid]]) {
    if (any(position >= parameters.output_and_tone.xy)) return;
    float3 scene = read_hdr_scene(luma, chroma, position, parameters);
    float3 adjusted = adjust_scene(
        scene, position, scene_parameters, tone_a, tone_b, parameters);
    output.write(half4(
        half3(develop(cube, adjusted, scene_parameters)), 1.0h), position);
}

kernel void fotufilm_hierarchical_sdr_finish(
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    texture3d<half, access::sample> cube [[texture(2)]],
    texture1d<half, access::sample> decode [[texture(3)]],
    texture2d<half, access::sample> low_full [[texture(4)]],
    texture2d<half, access::sample> low_base [[texture(5)]],
    texture2d<half, access::write> output [[texture(6)]],
    const device HierarchicalSceneParameters &scene_parameters [[buffer(0)]],
    constant HierarchicalCameraParameters &parameters [[buffer(1)]],
    const device float *tone_a [[buffer(2)]],
    const device float *tone_b [[buffer(3)]],
    uint2 position [[thread_position_in_grid]]) {
    if (any(position >= parameters.output_and_tone.xy)) return;
    float3 scene = read_sdr_scene(
        luma, chroma, decode, position, parameters);
    float3 adjusted = adjust_scene(
        scene, position, scene_parameters, tone_a, tone_b, parameters);
    float3 base = develop(cube, adjusted, scene_parameters);
    output.write(half4(half3(spatially_correct(
        base, low_full, low_base, position, parameters.output_and_tone.xy)), 1.0h),
        position);
}

kernel void fotufilm_hierarchical_hdr_finish(
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    texture3d<half, access::sample> cube [[texture(2)]],
    texture2d<half, access::sample> low_full [[texture(4)]],
    texture2d<half, access::sample> low_base [[texture(5)]],
    texture2d<half, access::write> output [[texture(6)]],
    const device HierarchicalSceneParameters &scene_parameters [[buffer(0)]],
    constant HierarchicalCameraParameters &parameters [[buffer(1)]],
    const device float *tone_a [[buffer(2)]],
    const device float *tone_b [[buffer(3)]],
    uint2 position [[thread_position_in_grid]]) {
    if (any(position >= parameters.output_and_tone.xy)) return;
    float3 scene = read_hdr_scene(luma, chroma, position, parameters);
    float3 adjusted = adjust_scene(
        scene, position, scene_parameters, tone_a, tone_b, parameters);
    float3 base = develop(cube, adjusted, scene_parameters);
    output.write(half4(half3(spatially_correct(
        base, low_full, low_base, position, parameters.output_and_tone.xy)), 1.0h),
        position);
}
