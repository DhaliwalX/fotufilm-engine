#include <metal_stdlib>
using namespace metal;

// The optical engine ends at one diffuse-white-relative, linear Display P3 HDR master. These
// kernels are delivery transforms only. Each invocation owns one 2x2 source block and therefore
// writes four luma samples plus the single co-sited 4:2:0 chroma sample without an intermediate.

struct encoded_block {
    float4 luma;
    float2 chroma;
};

#include "HandwrittenDigitalDeliveryTransfer.metalinc"

static inline float3 encode_hdr_pixel(float3 signal) {
    const float y = dot(float3(0.2627f, 0.6780f, 0.0593f), signal);
    return float3(y, (signal.z - y) / 1.8814f,
                  (signal.x - y) / 1.4746f);
}

static inline float3 encode_sdr_pixel(float3 signal) {
    const float y = dot(float3(0.2126f, 0.7152f, 0.0722f), signal);
    return float3(y, (signal.z - y) / 1.8556f,
                  (signal.x - y) / 1.5748f);
}

static inline encoded_block quantize_block(
    float3 a, float3 b, float3 c, float3 d) {
    encoded_block result;
    result.luma = floor(clamp(float4(a.x, b.x, c.x, d.x), 0.0f, 1.0f)
        * 876.0f + 64.5f);
    const float2 average_chroma = float2(
        (a.y + b.y + c.y + d.y) * 0.25f,
        (a.z + b.z + c.z + d.z) * 0.25f);
    result.chroma = floor(clamp(average_chroma, -0.5f, 0.5f)
        * 896.0f + 512.5f);
    return result;
}

static inline void write_block(
    encoded_block encoded,
    texture2d<float, access::write> luma,
    texture2d<float, access::write> chroma,
    uint2 top_left, uint2 block) {
    // x420 stores every 10-bit code left-justified in a 16-bit UNORM plane.
    constexpr float stored_scale = 64.0f / 65535.0f;
    luma.write(float4(encoded.luma.x * stored_scale), top_left);
    luma.write(float4(encoded.luma.y * stored_scale), top_left + uint2(1, 0));
    luma.write(float4(encoded.luma.z * stored_scale), top_left + uint2(0, 1));
    luma.write(float4(encoded.luma.w * stored_scale), top_left + uint2(1, 1));
    chroma.write(float4(encoded.chroma * stored_scale, 0.0f, 1.0f), block);
}

kernel void fotufilm_deliver_hdr_hlg_x420(
    texture2d<half, access::read> master [[texture(0)]],
    texture2d<float, access::write> luma [[texture(1)]],
    texture2d<float, access::write> chroma [[texture(2)]],
    uint2 block [[thread_position_in_grid]]) {
    const uint2 top_left = block * 2u;
    if (top_left.x >= master.get_width() || top_left.y >= master.get_height()) return;
    const encoded_block encoded = quantize_block(
        encode_hdr_pixel(fotufilm_delivery_encode_hdr_rgb(
            fotufilm_delivery_master_light(master.read(top_left)))),
        encode_hdr_pixel(fotufilm_delivery_encode_hdr_rgb(
            fotufilm_delivery_master_light(master.read(top_left + uint2(1, 0))))),
        encode_hdr_pixel(fotufilm_delivery_encode_hdr_rgb(
            fotufilm_delivery_master_light(master.read(top_left + uint2(0, 1))))),
        encode_hdr_pixel(fotufilm_delivery_encode_hdr_rgb(
            fotufilm_delivery_master_light(master.read(top_left + uint2(1, 1))))));
    write_block(encoded, luma, chroma, top_left, block);
}

kernel void fotufilm_deliver_sdr_rec709_x420(
    texture2d<half, access::read> master [[texture(0)]],
    texture2d<float, access::write> luma [[texture(1)]],
    texture2d<float, access::write> chroma [[texture(2)]],
    constant float &shoulder_knee [[buffer(0)]],
    uint2 block [[thread_position_in_grid]]) {
    const uint2 top_left = block * 2u;
    if (top_left.x >= master.get_width() || top_left.y >= master.get_height()) return;
    const encoded_block encoded = quantize_block(
        encode_sdr_pixel(fotufilm_delivery_encode_sdr_rgb(
            fotufilm_delivery_master_light(master.read(top_left)), shoulder_knee)),
        encode_sdr_pixel(fotufilm_delivery_encode_sdr_rgb(
            fotufilm_delivery_master_light(master.read(top_left + uint2(1, 0))),
            shoulder_knee)),
        encode_sdr_pixel(fotufilm_delivery_encode_sdr_rgb(
            fotufilm_delivery_master_light(master.read(top_left + uint2(0, 1))),
            shoulder_knee)),
        encode_sdr_pixel(fotufilm_delivery_encode_sdr_rgb(
            fotufilm_delivery_master_light(master.read(top_left + uint2(1, 1))),
            shoulder_knee)));
    write_block(encoded, luma, chroma, top_left, block);
}
