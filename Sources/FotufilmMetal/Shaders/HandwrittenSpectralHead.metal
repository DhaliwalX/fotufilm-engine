#include <metal_stdlib>
using namespace metal;

constant bool kTone [[function_constant(0)]];
constant bool kLocalTone [[function_constant(1)]];
constant bool kChroma [[function_constant(2)]];
constant uint kDecodeSamples = FOTUFILM_HEAD_DECODE_SAMPLES;

struct SceneParameters {
    float4 white_balance;
    float4 adjustment;
    float4 exposure_and_padding;
};

struct FrameParameters {
    uint4 extent_and_tone;
    float4 input_gain_and_padding;
};

struct CaptureParameters {
    FrameParameters frame;
    float4 transform;
    uint4 source_and_padding;
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

// The canonical tetrahedral walk restricted to an upper cube face. The >= comparisons retain
// its diagonal tie ordering. Three vertices are sufficient because the normalized point lies
// exactly on one face; no trilinear approximation is introduced.
static inline float4 exposure_face(
    texture2d_array<half, access::read> faces, float3 point) {
    uint face;
    float2 coordinate;
    if (point.x >= point.y && point.x >= point.z) {
        face = 0u;
        coordinate = point.yz;
    } else if (point.y >= point.z) {
        face = 1u;
        coordinate = point.xz;
    } else {
        face = 2u;
        coordinate = point.xy;
    }
    uint edge = faces.get_width();
    float2 q = clamp(coordinate, 0.0f, 1.0f) * float(edge - 1u);
    uint2 low = min(uint2(q), uint2(edge - 2u));
    float2 f = q - float2(low);
    float4 c00 = float4(faces.read(low, face));
    float4 c11 = float4(faces.read(low + 1u, face));
    if (f.x >= f.y) {
        float4 c10 = float4(faces.read(low + uint2(1u, 0u), face));
        return c00 + f.x * (c10 - c00) + f.y * (c11 - c10);
    }
    float4 c01 = float4(faces.read(low + uint2(0u, 1u), face));
    return c00 + f.y * (c01 - c00) + f.x * (c11 - c01);
}

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
    float stops, uint2 position, constant FrameParameters &frame) {
    if (!kLocalTone) return stops;
    uint width = max(frame.extent_and_tone.z, 1u);
    uint height = max(frame.extent_and_tone.w, 1u);
    float gx = clamp(
        (float(position.x) + 0.5f) * float(width)
            / float(frame.extent_and_tone.x) - 0.5f,
        0.0f, float(width - 1u));
    float gy = clamp(
        (float(position.y) + 0.5f) * float(height)
            / float(frame.extent_and_tone.y) - 0.5f,
        0.0f, float(height - 1u));
    return bilinear_plane(tone_a, width, height, gx, gy) * stops
        + bilinear_plane(tone_b, width, height, gx, gy);
}

static inline float4 recover_exposure(
    texture2d_array<half, access::read> exposure,
    const device SceneParameters &scene_parameters,
    const device float *tone_a, const device float *tone_b,
    float3 scene, uint2 position, constant FrameParameters &frame) {
    constexpr float3 luma = float3(0.2627002f, 0.6779981f, 0.0593017f);
    float3 balance = scene_parameters.white_balance.xyz;
    // Balance first: the metering, the luminance and the colourfulness below
    // all read the adapted scene, matching creative_exposure in the shared header.
    float3 adjusted = scene * balance;
    if (kTone) {
        float metered = dot(luma, adjusted)
            * scene_parameters.exposure_and_padding.x;
        float stops = log2(max(metered, 1.0e-6f));
        float keyed = tone_base(tone_a, tone_b, stops, position, frame);
        float high = clamp(keyed * (1.0f / 6.0f), 0.0f, 1.0f);
        float low = clamp(-keyed * (1.0f / 6.0f), 0.0f, 1.0f);
        float high_mask = high * high * (3.0f - 2.0f * high);
        float low_mask = low * low * (3.0f - 2.0f * low);
        float tone_ev = 3.0f
            * (scene_parameters.adjustment.x * high_mask
               + scene_parameters.adjustment.y * low_mask);
        adjusted *= exp2(tone_ev);
    }
    if (kChroma) {
        float luminance = dot(luma, adjusted);
        float peak = max(adjusted.x, max(adjusted.y, adjusted.z));
        float colourfulness =
            (peak - min(adjusted.x, min(adjusted.y, adjusted.z)))
            / max(peak, 1.0e-6f);
        float chroma = scene_parameters.adjustment.z
            * (1.0f + scene_parameters.adjustment.w
                         * (1.0f - colourfulness));
        adjusted = luminance + chroma * (adjusted - luminance);
    }

    // The exposure table is indexed in a basis whose cube encloses the spectral locus; this
    // seam mirrors kRec2020ToExposureDomain in FotufilmHalideShared.h digit for digit.
    float3 domain = float3(
        0.670231843f * adjusted.x + 0.152168745f * adjusted.y + 0.177599412f * adjusted.z,
        0.044501114f * adjusted.x + 0.854482372f * adjusted.y + 0.101016514f * adjusted.z,
        0.025777047f * adjusted.y + 0.974222953f * adjusted.z);
    float3 physical = domain;
    float luminance = dot(luma, adjusted);
    if (luminance <= 0.0f) {
        physical = 0.0f;
    } else if (any(domain < 0.0f)) {
        float3 ratio = select(
            float3(1.0f), luminance / (luminance - domain),
            domain < 0.0f);
        float saturation = min(ratio.x, min(ratio.y, ratio.z));
        physical = luminance + saturation * (domain - luminance);
    }
    physical = max(physical, 0.0f);
    float radiance = max(physical.x, max(physical.y, physical.z));
    if (radiance <= 0.0f) return 0.0f;
    return max(
        exposure_face(exposure, physical / radiance)
            * (radiance * scene_parameters.exposure_and_padding.x),
        0.0f);
}

kernel void fotufilm_fast_spectral_head_sdr(
    const device uchar4 *input [[buffer(0)]],
    const device SceneParameters &scene [[buffer(1)]],
    constant FrameParameters &frame [[buffer(2)]],
    const device float *tone_a [[buffer(3)]],
    const device float *tone_b [[buffer(4)]],
    texture2d_array<half, access::read> exposure [[texture(0)]],
    texture2d<half, access::write> record [[texture(1)]],
    texture1d<half, access::sample> decode [[texture(2)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= frame.extent_and_tone.x
        || position.y >= frame.extent_and_tone.y) return;
    uint index = position.y * frame.extent_and_tone.x + position.x;
    uchar4 pixel = input[index];
    float denominator = pixel.w > 0u && pixel.w < 255u
        ? float(pixel.w) : 255.0f;
    float3 encoded = clamp(float3(pixel.xyz) / denominator, 0.0f, 1.0f);
    float3 working = encoded_to_working(decode, encoded, 0u);
    record.write(half4(recover_exposure(
        exposure, scene, tone_a, tone_b, working, position, frame)), position);
}

kernel void fotufilm_fast_spectral_head_hdr(
    const device half4 *input [[buffer(0)]],
    const device SceneParameters &scene [[buffer(1)]],
    constant FrameParameters &frame [[buffer(2)]],
    const device float *tone_a [[buffer(3)]],
    const device float *tone_b [[buffer(4)]],
    texture2d_array<half, access::read> exposure [[texture(0)]],
    texture2d<half, access::write> record [[texture(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= frame.extent_and_tone.x
        || position.y >= frame.extent_and_tone.y) return;
    uint index = position.y * frame.extent_and_tone.x + position.x;
    float3 working = float3(input[index].xyz)
        * frame.input_gain_and_padding.x;
    record.write(half4(recover_exposure(
        exposure, scene, tone_a, tone_b, working, position, frame)), position);
}

kernel void fotufilm_fast_spectral_head_hdr_float(
    const device float4 *input [[buffer(0)]],
    const device SceneParameters &scene [[buffer(1)]],
    constant FrameParameters &frame [[buffer(2)]],
    const device float *tone_a [[buffer(3)]],
    const device float *tone_b [[buffer(4)]],
    texture2d_array<half, access::read> exposure [[texture(0)]],
    texture2d<half, access::write> record [[texture(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= frame.extent_and_tone.x
        || position.y >= frame.extent_and_tone.y) return;
    uint index = position.y * frame.extent_and_tone.x + position.x;
    float3 working = input[index].xyz * frame.input_gain_and_padding.x;
    record.write(half4(recover_exposure(
        exposure, scene, tone_a, tone_b, working, position, frame)), position);
}

kernel void fotufilm_fast_spectral_head_nv12(
    const device SceneParameters &scene [[buffer(0)]],
    constant CaptureParameters &parameters [[buffer(1)]],
    const device float *tone_a [[buffer(2)]],
    const device float *tone_b [[buffer(3)]],
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    texture2d_array<half, access::read> exposure [[texture(2)]],
    texture2d<half, access::write> record [[texture(3)]],
    texture1d<half, access::sample> decode [[texture(4)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.frame.extent_and_tone.x
        || position.y >= parameters.frame.extent_and_tone.y) return;
    float3 working = fotufilm_decode_nv12_scene(
        luma, chroma, decode, position, parameters.frame.extent_and_tone.xy,
        parameters.transform.yz, parameters.source_and_padding.x,
        parameters.source_and_padding.y)
        * parameters.frame.input_gain_and_padding.x;
    record.write(half4(recover_exposure(
        exposure, scene, tone_a, tone_b, working, position,
        parameters.frame)), position);
}

kernel void fotufilm_fast_spectral_head_x420(
    const device SceneParameters &scene [[buffer(0)]],
    constant CaptureParameters &parameters [[buffer(1)]],
    const device float *tone_a [[buffer(2)]],
    const device float *tone_b [[buffer(3)]],
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    texture2d_array<half, access::read> exposure [[texture(2)]],
    texture2d<half, access::write> record [[texture(3)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.frame.extent_and_tone.x
        || position.y >= parameters.frame.extent_and_tone.y) return;
    float3 working = fotufilm_decode_x420_scene(
        luma, chroma, position, parameters.frame.extent_and_tone.xy,
        parameters.transform.yz, parameters.source_and_padding.x,
        parameters.transform.x) * parameters.frame.input_gain_and_padding.x;
    record.write(half4(recover_exposure(
        exposure, scene, tone_a, tone_b, working, position,
        parameters.frame)), position);
}
