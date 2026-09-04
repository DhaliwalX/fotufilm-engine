#include <metal_stdlib>
using namespace metal;

constant uint kDecodeSamples = FOTUFILM_CAMERA_DECODE_SAMPLES;

struct CameraPassThroughParameters {
    uint4 extent_and_source;
    float4 scale_and_chroma;
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

// The shared camera-plane decoder works in linear Rec.2020. P3 and sRGB sources both enter that
// space here before the common exit below, keeping this no-film endpoint on the same matrices as
// the spectral head.
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

static inline float3 working_to_display_p3(float3 rgb) {
    return float3(
        dot(float3(1.343578253f, -0.282179671f, -0.061398582f), rgb),
        dot(float3(-0.065297453f, 1.075787916f, -0.010490463f), rgb),
        dot(float3(0.002821787f, -0.019598495f, 1.016776707f), rgb));
}

kernel void fotufilm_camera_passthrough_nv12(
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    texture1d<half, access::sample> decode [[texture(2)]],
    texture2d<half, access::write> output [[texture(3)]],
    constant CameraPassThroughParameters &parameters [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]) {
    uint2 extent = parameters.extent_and_source.xy;
    if (any(position >= extent)) return;
    float3 scene = fotufilm_decode_nv12_scene(
        luma, chroma, decode, position, extent,
        parameters.scale_and_chroma.yz,
        parameters.extent_and_source.z,
        parameters.extent_and_source.w);
    output.write(half4(half3(working_to_display_p3(scene)), half(1.0f)), position);
}

kernel void fotufilm_camera_passthrough_x420(
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    texture2d<half, access::write> output [[texture(3)]],
    constant CameraPassThroughParameters &parameters [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]) {
    uint2 extent = parameters.extent_and_source.xy;
    if (any(position >= extent)) return;
    float3 scene = fotufilm_decode_x420_scene(
        luma, chroma, position, extent,
        parameters.scale_and_chroma.yz,
        parameters.extent_and_source.z,
        parameters.scale_and_chroma.x);
    output.write(half4(half3(working_to_display_p3(scene)), half(1.0f)), position);
}
