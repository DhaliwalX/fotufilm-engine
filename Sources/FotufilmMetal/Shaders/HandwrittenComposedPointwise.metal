#include <metal_stdlib>
using namespace metal;

struct ComposedPointwiseParameters {
    uint width;
    uint height;
    float input_knee;
    float shaper_scale;
};

static inline float3 composed_cube_coordinate(
    float3 scene, constant ComposedPointwiseParameters &parameters,
    uint edge
) {
    float3 grid = min(
        log2(max(scene, 0.0f) / parameters.input_knee + 1.0f)
            * parameters.shaper_scale,
        float(edge - 1u));
    return (grid + 0.5f) / float(edge);
}

static inline float4 composed_tetrahedral(
    texture3d<half, access::sample> cube, float3 point
) {
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

kernel void fotufilm_handwritten_composed_pointwise_trilinear(
    const device half4 *input [[buffer(0)]],
    device half4 *output [[buffer(1)]],
    texture3d<half, access::sample> cube [[texture(0)]],
    constant ComposedPointwiseParameters &parameters [[buffer(2)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    uint offset = position.y * parameters.width + position.x;
    float4 pixel = float4(input[offset]);
    float3 coordinate = composed_cube_coordinate(
        pixel.rgb, parameters, cube.get_width());
    constexpr sampler linear_cube(
        coord::normalized, address::clamp_to_edge, filter::linear);
    float3 developed = float3(cube.sample(linear_cube, coordinate).rgb);
    output[offset] = half4(half3(max(developed, 0.0f)), half(pixel.a));
}

kernel void fotufilm_handwritten_composed_pointwise_tetrahedral(
    const device half4 *input [[buffer(0)]],
    device half4 *output [[buffer(1)]],
    texture3d<half, access::sample> cube [[texture(0)]],
    constant ComposedPointwiseParameters &parameters [[buffer(2)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    uint offset = position.y * parameters.width + position.x;
    float4 pixel = float4(input[offset]);
    float3 positive = max(pixel.rgb, 0.0f);
    float3 grid = min(
        log2(positive / parameters.input_knee + 1.0f)
            * parameters.shaper_scale,
        float(cube.get_width() - 1u));
    float3 developed = composed_tetrahedral(
        cube, grid / float(cube.get_width() - 1u)).rgb;
    output[offset] = half4(half3(max(developed, 0.0f)), half(pixel.a));
}
