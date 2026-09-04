#include <metal_stdlib>
using namespace metal;

// RGB still delivery shares the transfer equations with x420 video but keeps full 4:4:4 samples.
// ImageIO receives this shader-readable half-float surface and performs only 10-bit HEIF packing.

#include "HandwrittenDigitalDeliveryTransfer.metalinc"

kernel void fotufilm_deliver_hdr_hlg_rgb(
    texture2d<half, access::read> master [[texture(0)]],
    texture2d<half, access::write> output [[texture(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= master.get_width() || position.y >= master.get_height()) return;
    const float3 encoded = fotufilm_delivery_encode_hdr_rgb(
        fotufilm_delivery_master_light(master.read(position)));
    output.write(half4(half3(encoded), half(1.0f)), position);
}

kernel void fotufilm_deliver_sdr_rec709_rgb(
    texture2d<half, access::read> master [[texture(0)]],
    texture2d<half, access::write> output [[texture(1)]],
    constant float &shoulder_knee [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= master.get_width() || position.y >= master.get_height()) return;
    const float3 encoded = fotufilm_delivery_encode_sdr_rgb(
        fotufilm_delivery_master_light(master.read(position)), shoulder_knee);
    output.write(half4(half3(encoded), half(1.0f)), position);
}
