#include <metal_stdlib>
using namespace metal;

struct FrameParameters {
    uint width;
    uint height;
    uint frame_width;
    uint seed;
    float4 minimum;
    float4 inverse_range;
    float4 grade_lift;
    float4 grade_gain;
    float4 grade_exponent;
    uint4 flags;
};

static inline float table1d(
    texture1d<half, access::read> table, float position) {
    float q = clamp(position, 0.0f, 1.0f) * float(table.get_width() - 1u);
    uint index = min(uint(q), table.get_width() - 2u);
    float low = float(table.read(index).r);
    return low + (q - float(index))
        * (float(table.read(index + 1u).r) - low);
}

static inline uint pcg(uint value) {
    uint state = value * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// Tetrahedral weights are [1-L, L-M, M-S, S]. Each adjacent pair lies on one cube edge,
// making two hardware-linear samples followed by one mix the exact four-vertex sum (apart
// from sampler rounding). The comparisons preserve the canonical >= tie ordering.
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
    constexpr sampler linear_cube(
        coord::normalized, address::clamp_to_edge, filter::linear);
    float3 first_coordinate = (float3(low) + 0.5f
        + first_fraction * float3(near_step)) * inverse_edge;
    uint3 far = low + far_step;
    float3 second_coordinate = (float3(far) + 0.5f
        + second_fraction * float3(1u - far_step)) * inverse_edge;
    float4 first = float4(cube.sample(linear_cube, first_coordinate));
    float4 second = float4(cube.sample(linear_cube, second_coordinate));
    return mix(first, second, middle);
}

static inline float4 oriented_edge(
    texture2d_array<half, access::sample> cube, uint3 start,
    uint axis, float fraction) {
    uint edge = cube.get_width();
    float inverse_edge = 1.0f / float(edge);
    float2 coordinate;
    uint slice;
    if (axis == 0u) {
        coordinate = (float2(start.xy) + float2(0.5f + fraction, 0.5f))
            * inverse_edge;
        slice = start.z;
    } else if (axis == 1u) {
        coordinate = (float2(start.yz) + float2(0.5f + fraction, 0.5f))
            * inverse_edge;
        slice = edge + start.x;
    } else {
        coordinate = (float2(start.zx) + float2(0.5f + fraction, 0.5f))
            * inverse_edge;
        slice = 2u * edge + start.y;
    }
    constexpr sampler linear_array(
        coord::normalized, address::clamp_to_edge, filter::linear);
    return float4(cube.sample(linear_array, coordinate, slice));
}

static inline float4 tetrahedral_oriented(
    texture2d_array<half, access::sample> cube, float3 point) {
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
    uint near_axis = x_largest ? 0u : (y_largest ? 1u : 2u);
    uint smallest_axis = x_smallest ? 0u : (y_smallest ? 1u : 2u);
    uint3 far_step = uint3(!x_smallest, !y_smallest,
                           x_smallest || y_smallest);
    float first_fraction = middle < 1.0f
        ? (largest - middle) / (1.0f - middle) : 0.0f;
    float second_fraction = middle > 0.0f
        ? smallest / middle : 0.0f;
    float4 first = oriented_edge(cube, low, near_axis, first_fraction);
    float4 second = oriented_edge(
        cube, low + far_step, smallest_axis, second_fraction);
    return mix(first, second, middle);
}

// The final paper transform is kept as its canonical float cube. Four explicit reads retain
// its piecewise tetrahedral transitions; filtering a composed density cube cannot do so when
// a transition falls wholly inside one density-grid cell.
static inline float4 tetrahedral_float(
    texture3d<float, access::read> table, float3 point) {
    uint edge = table.get_width();
    float3 q = clamp(point, 0.0f, 1.0f) * float(edge - 1u);
    uint3 low = min(uint3(q), uint3(edge - 2u));
    float3 f = q - float3(low);
    float4 c000 = table.read(low);
    float4 c111 = table.read(low + 1u);
    if (f.x >= f.y) {
        if (f.y >= f.z) {
            float4 c100 = table.read(low + uint3(1u, 0u, 0u));
            float4 c110 = table.read(low + uint3(1u, 1u, 0u));
            return c000 + f.x * (c100 - c000) + f.y * (c110 - c100)
                + f.z * (c111 - c110);
        } else if (f.x >= f.z) {
            float4 c100 = table.read(low + uint3(1u, 0u, 0u));
            float4 c101 = table.read(low + uint3(1u, 0u, 1u));
            return c000 + f.x * (c100 - c000) + f.z * (c101 - c100)
                + f.y * (c111 - c101);
        } else {
            float4 c001 = table.read(low + uint3(0u, 0u, 1u));
            float4 c101 = table.read(low + uint3(1u, 0u, 1u));
            return c000 + f.z * (c001 - c000) + f.x * (c101 - c001)
                + f.y * (c111 - c101);
        }
    } else if (f.x >= f.z) {
        float4 c010 = table.read(low + uint3(0u, 1u, 0u));
        float4 c110 = table.read(low + uint3(1u, 1u, 0u));
        return c000 + f.y * (c010 - c000) + f.x * (c110 - c010)
            + f.z * (c111 - c110);
    } else if (f.y >= f.z) {
        float4 c010 = table.read(low + uint3(0u, 1u, 0u));
        float4 c011 = table.read(low + uint3(0u, 1u, 1u));
        return c000 + f.y * (c010 - c000) + f.z * (c011 - c010)
            + f.x * (c111 - c011);
    } else {
        float4 c001 = table.read(low + uint3(0u, 0u, 1u));
        float4 c011 = table.read(low + uint3(0u, 1u, 1u));
        return c000 + f.z * (c001 - c000) + f.y * (c011 - c001)
            + f.x * (c111 - c011);
    }
}

static inline float3 composite_print(
    texture2d<half, access::read> density,
    texture3d<half, access::sample> print_cube,
    constant FrameParameters &parameters, uint2 position) {
    float3 developed = float3(density.read(position).rgb);
    float3 coordinate = (developed - parameters.minimum.xyz)
        * parameters.inverse_range.xyz;
    return tetrahedral(print_cube, coordinate).rgb;
}

static inline float grading_encode(float value) {
    if (value <= 0.0031308f) return value * 12.92f;
    if (value >= 1.0f) return 1.0f + (value - 1.0f) * (1.055f / 2.4f);
    return 1.055f * pow(value, 1.0f / 2.4f) - 0.055f;
}

static inline float grading_decode(float value) {
    if (value <= 0.04045f) return value / 12.92f;
    if (value >= 1.0f) return 1.0f + (value - 1.0f) / (1.055f / 2.4f);
    return pow((value + 0.055f) / 1.055f, 2.4f);
}

static inline float grade(
    float value, uint channel, constant FrameParameters &parameters) {
    if (parameters.flags.z == 0u) return value;
    float working = parameters.flags.w != 0u ? grading_encode(value) : value;
    float lift = parameters.grade_lift[channel];
    float gain = parameters.grade_gain[channel];
    float exponent = parameters.grade_exponent[channel];
    float lifted = working * (gain - lift) + lift;
    float graded = exponent == 1.0f
        ? lifted : pow(max(lifted, 0.0f), exponent);
    return parameters.flags.w != 0u ? grading_decode(graded) : graded;
}

static inline float dither(
    uint2 position, uint channel, uint width, uint seed) {
    uint index = position.y * width + position.x;
    uint hash1 = pcg(index ^ pcg(channel + seed * 0x9E3779B9u));
    uint hash2 = pcg(hash1);
    return float(hash1 >> 8u) * (1.0f / 16777216.0f)
        + float(hash2 >> 8u) * (1.0f / 16777216.0f) - 1.0f;
}

static inline float display_shoulder(float value, float knee) {
    float over = value - knee;
    float room = 1.0f - knee;
    return value > knee ? knee + room * over / (over + room) : value;
}

kernel void fotufilm_composite_tail_sdr_baseline(
    const device uchar4 *original [[buffer(0)]],
    device uchar4 *output [[buffer(1)]],
    constant FrameParameters &parameters [[buffer(2)]],
    texture2d<half, access::read> density [[texture(0)]],
    texture3d<half, access::sample> print_cube [[texture(1)]],
    texture3d<float, access::read> paper_cube [[texture(2)]],
    texture1d<half, access::read> transfer_table [[texture(3)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    uint index = position.y * parameters.width + position.x;
    float3 mapped = composite_print(density, print_cube, parameters, position);
    float3 printed = parameters.flags.x != 0u
        ? mapped : tetrahedral_float(paper_cube, mapped).rgb;
    if (parameters.flags.y != 0u) {
        printed = float3((printed.x + printed.y + printed.z) / 3.0f);
    }
    float3 encoded;
    for (uint channel = 0u; channel < 3u; ++channel) {
        float linear = grade(printed[channel], channel, parameters);
        float knee = parameters.flags.x != 0u ? 0.7f : 0.9f;
        float delivered = clamp(display_shoulder(linear, knee), 0.0f, 1.0f);
        float signal = table1d(transfer_table, sqrt(delivered));
        encoded[channel] = floor(signal * 255.0f + 0.5f
                                 + dither(position, channel,
                                          parameters.frame_width,
                                          parameters.seed));
    }
    output[index] = uchar4(uchar3(clamp(encoded, 0.0f, 255.0f)), original[index].w);
}

kernel void fotufilm_composite_tail_hdr_baseline(
    const device half4 *original [[buffer(0)]],
    device half4 *output [[buffer(1)]],
    constant FrameParameters &parameters [[buffer(2)]],
    texture2d<half, access::read> density [[texture(0)]],
    texture3d<half, access::sample> print_cube [[texture(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    uint index = position.y * parameters.width + position.x;
    float3 linear = composite_print(density, print_cube, parameters, position);
    output[index] = half4(half3(max(linear, 0.0f)), original[index].w);
}

kernel void fotufilm_composite_tail_hdr_texture_baseline(
    constant FrameParameters &parameters [[buffer(2)]],
    texture2d<half, access::read> density [[texture(0)]],
    texture3d<half, access::sample> print_cube [[texture(1)]],
    texture2d<half, access::write> output [[texture(2)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    half alpha = density.read(position).w;
    float3 linear = composite_print(density, print_cube, parameters, position);
    output.write(half4(half3(max(linear, 0.0f)), alpha), position);
}

static inline float3 composite_print_oriented(
    texture2d<half, access::read> density,
    texture2d_array<half, access::sample> print_cube,
    constant FrameParameters &parameters, uint2 position) {
    float3 developed = float3(density.read(position).rgb);
    float3 coordinate = (developed - parameters.minimum.xyz)
        * parameters.inverse_range.xyz;
    return tetrahedral_oriented(print_cube, coordinate).rgb;
}

kernel void fotufilm_composite_tail_sdr_oriented(
    const device uchar4 *original [[buffer(0)]],
    device uchar4 *output [[buffer(1)]],
    constant FrameParameters &parameters [[buffer(2)]],
    texture2d<half, access::read> density [[texture(0)]],
    texture2d_array<half, access::sample> activation_cube [[texture(1)]],
    texture2d_array<half, access::sample> signal_cube [[texture(2)]],
    texture1d<half, access::read> transfer_table [[texture(3)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    uint index = position.y * parameters.width + position.x;
    float3 mapped = composite_print_oriented(
        density, activation_cube, parameters, position);
    float3 printed = parameters.flags.x != 0u
        ? mapped : tetrahedral_oriented(signal_cube, mapped).rgb;
    if (parameters.flags.y != 0u) {
        printed = float3((printed.x + printed.y + printed.z) / 3.0f);
    }
    float3 signal;
    for (uint channel = 0u; channel < 3u; ++channel) {
        float linear = grade(printed[channel], channel, parameters);
        float knee = parameters.flags.x != 0u ? 0.7f : 0.9f;
        float delivered = clamp(display_shoulder(linear, knee), 0.0f, 1.0f);
        signal[channel] = table1d(transfer_table, sqrt(delivered));
    }
    float3 encoded;
    for (uint channel = 0u; channel < 3u; ++channel) {
        encoded[channel] = floor(signal[channel] * 255.0f + 0.5f
                                 + dither(position, channel,
                                          parameters.frame_width,
                                          parameters.seed));
    }
    output[index] = uchar4(
        uchar3(clamp(encoded, 0.0f, 255.0f)), original[index].w);
}

kernel void fotufilm_composite_tail_hdr_oriented(
    const device half4 *original [[buffer(0)]],
    device half4 *output [[buffer(1)]],
    constant FrameParameters &parameters [[buffer(2)]],
    texture2d<half, access::read> density [[texture(0)]],
    texture2d_array<half, access::sample> print_cube [[texture(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    uint index = position.y * parameters.width + position.x;
    float3 linear = composite_print_oriented(
        density, print_cube, parameters, position);
    output[index] = half4(half3(max(linear, 0.0f)), original[index].w);
}

kernel void fotufilm_composite_tail_hdr_texture_oriented(
    constant FrameParameters &parameters [[buffer(2)]],
    texture2d<half, access::read> density [[texture(0)]],
    texture2d_array<half, access::sample> print_cube [[texture(1)]],
    texture2d<half, access::write> output [[texture(2)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    half alpha = density.read(position).w;
    float3 linear = composite_print_oriented(
        density, print_cube, parameters, position);
    output.write(half4(half3(max(linear, 0.0f)), alpha), position);
}

static inline float warp_coordinate(
    float value, uint channel, constant float *knots) {
    value = clamp(value, 0.0f, 1.0f);
    uint base = channel * 17u;
    uint segment = value < knots[base + 8u] ? 0u : 8u;
    if (value >= knots[base + segment + 4u]) segment += 4u;
    if (value >= knots[base + segment + 2u]) segment += 2u;
    if (value >= knots[base + segment + 1u]) segment += 1u;
    float low = knots[base + segment];
    float high = knots[base + segment + 1u];
    float fraction = (value - low) / max(high - low, 1.0e-7f);
    return (float(segment) + clamp(fraction, 0.0f, 1.0f)) * (1.0f / 16.0f);
}

static inline float3 composed_coordinate(
    texture2d<half, access::read> density,
    constant FrameParameters &parameters, constant float *knots,
    uint2 position) {
    float3 developed = float3(density.read(position).rgb);
    float3 unit = (developed - parameters.minimum.xyz)
        * parameters.inverse_range.xyz;
    return float3(warp_coordinate(unit.x, 0u, knots),
                  warp_coordinate(unit.y, 1u, knots),
                  warp_coordinate(unit.z, 2u, knots));
}

static inline float3 composed_tetrahedral(
    texture2d<half, access::read> density,
    texture3d<half, access::sample> cube,
    constant FrameParameters &parameters, constant float *knots,
    uint2 position) {
    return tetrahedral(
        cube, composed_coordinate(density, parameters, knots, position)).rgb;
}

static inline float3 composed_trilinear(
    texture2d<half, access::read> density,
    texture3d<half, access::sample> cube,
    constant FrameParameters &parameters, constant float *knots,
    uint2 position) {
    float3 coordinate = composed_coordinate(
        density, parameters, knots, position);
    float edge = float(cube.get_width());
    float3 sample_coordinate = (coordinate * (edge - 1.0f) + 0.5f) / edge;
    constexpr sampler trilinear_cube(
        coord::normalized, address::clamp_to_edge, filter::linear);
    return float3(cube.sample(trilinear_cube, sample_coordinate).rgb);
}

kernel void fotufilm_composite_tail_sdr_composed_tetrahedral(
    const device uchar4 *original [[buffer(0)]],
    device uchar4 *output [[buffer(1)]],
    constant FrameParameters &parameters [[buffer(2)]],
    constant float *knots [[buffer(3)]],
    texture2d<half, access::read> density [[texture(0)]],
    texture3d<half, access::sample> cube [[texture(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    uint index = position.y * parameters.width + position.x;
    float3 signal = clamp(composed_tetrahedral(
        density, cube, parameters, knots, position), 0.0f, 1.0f);
    float3 encoded;
    for (uint channel = 0u; channel < 3u; ++channel) {
        encoded[channel] = floor(signal[channel] * 255.0f + 0.5f
                                 + dither(position, channel,
                                          parameters.frame_width,
                                          parameters.seed));
    }
    output[index] = uchar4(
        uchar3(clamp(encoded, 0.0f, 255.0f)), original[index].w);
}

kernel void fotufilm_composite_tail_sdr_composed_trilinear(
    const device uchar4 *original [[buffer(0)]],
    device uchar4 *output [[buffer(1)]],
    constant FrameParameters &parameters [[buffer(2)]],
    constant float *knots [[buffer(3)]],
    texture2d<half, access::read> density [[texture(0)]],
    texture3d<half, access::sample> cube [[texture(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    uint index = position.y * parameters.width + position.x;
    float3 signal = clamp(composed_trilinear(
        density, cube, parameters, knots, position), 0.0f, 1.0f);
    float3 encoded;
    for (uint channel = 0u; channel < 3u; ++channel) {
        encoded[channel] = floor(signal[channel] * 255.0f + 0.5f
                                 + dither(position, channel,
                                          parameters.frame_width,
                                          parameters.seed));
    }
    output[index] = uchar4(
        uchar3(clamp(encoded, 0.0f, 255.0f)), original[index].w);
}

kernel void fotufilm_composite_tail_hdr_composed_tetrahedral(
    const device half4 *original [[buffer(0)]],
    device half4 *output [[buffer(1)]],
    constant FrameParameters &parameters [[buffer(2)]],
    constant float *knots [[buffer(3)]],
    texture2d<half, access::read> density [[texture(0)]],
    texture3d<half, access::sample> cube [[texture(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    uint index = position.y * parameters.width + position.x;
    float3 linear = composed_tetrahedral(
        density, cube, parameters, knots, position);
    output[index] = half4(half3(max(linear, 0.0f)), original[index].w);
}

kernel void fotufilm_composite_tail_hdr_texture_composed_tetrahedral(
    constant FrameParameters &parameters [[buffer(2)]],
    constant float *knots [[buffer(3)]],
    texture2d<half, access::read> density [[texture(0)]],
    texture3d<half, access::sample> cube [[texture(1)]],
    texture2d<half, access::write> output [[texture(2)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    half alpha = density.read(position).w;
    float3 linear = composed_tetrahedral(
        density, cube, parameters, knots, position);
    output.write(half4(half3(max(linear, 0.0f)), alpha), position);
}

kernel void fotufilm_composite_tail_hdr_composed_trilinear(
    const device half4 *original [[buffer(0)]],
    device half4 *output [[buffer(1)]],
    constant FrameParameters &parameters [[buffer(2)]],
    constant float *knots [[buffer(3)]],
    texture2d<half, access::read> density [[texture(0)]],
    texture3d<half, access::sample> cube [[texture(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    uint index = position.y * parameters.width + position.x;
    float3 linear = composed_trilinear(
        density, cube, parameters, knots, position);
    output[index] = half4(half3(max(linear, 0.0f)), original[index].w);
}

kernel void fotufilm_composite_tail_hdr_texture_composed_trilinear(
    constant FrameParameters &parameters [[buffer(2)]],
    constant float *knots [[buffer(3)]],
    texture2d<half, access::read> density [[texture(0)]],
    texture3d<half, access::sample> cube [[texture(1)]],
    texture2d<half, access::write> output [[texture(2)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    half alpha = density.read(position).w;
    float3 linear = composed_trilinear(
        density, cube, parameters, knots, position);
    output.write(half4(half3(max(linear, 0.0f)), alpha), position);
}
