#include <metal_stdlib>
using namespace metal;

constant uint kCurveSamples = 2048u;
constant uint kTransferSamples = FOTUFILM_POINTWISE_TRANSFER_SAMPLES;
constant uint kDecodeSamples = FOTUFILM_POINTWISE_DECODE_SAMPLES;
constant uint kCurves = 0u;
constant uint kCoupler = 21u;
constant uint kCouplerScale = 58u;
constant uint kCouplerWarp = 66u;
constant uint kCouplerWarpSamples = 128u;
// FilmEngineInvocation's append-only configuration ABI. Tests pin these against the Swift
// declarations so a future layout change cannot silently corrupt the shader.
constant uint kCurveSecondary = FOTUFILM_CFG_CURVE_SECONDARY;
constant uint kCouplerReleaseGamma = FOTUFILM_CFG_COUPLER_RELEASE_GAMMA;
constant uint kDonorReleaseGamma = FOTUFILM_CFG_DONOR_RELEASE_GAMMA;
constant uint kDonorCurve = FOTUFILM_CFG_DONOR_CURVE;
constant uint kDonorRelease = FOTUFILM_CFG_DONOR_RELEASE;
constant uint kExposureGain = FOTUFILM_CFG_EXPOSURE_GAIN;
constant uint kWhiteBalance = FOTUFILM_CFG_WHITE_BALANCE;
constant uint kSceneAdjust = FOTUFILM_CFG_SCENE_ADJUST;
constant uint kFrameSize = FOTUFILM_CFG_FRAME_SIZE;
constant uint kToneGridSize = FOTUFILM_CFG_TONE_GRID_SIZE;
constant uint kToneGridA = FOTUFILM_CFG_TONE_GRID_A;
constant uint kToneGridB = FOTUFILM_CFG_TONE_GRID_B;
constant bool kTemporalPrint [[function_constant(0)]];

struct FrameParameters {
    uint width;
    uint height;
    uint frame_width;
    uint origin_x;
    uint origin_y;
    uint seed;
    uint reversal;
    uint nonlinear_warp;
    uint donor;
    uint tone_adjust;
    uint chroma_adjust;
    uint dither_salt_0;
    uint dither_salt_1;
    uint dither_salt_2;
};

struct HDRFrameParameters {
    FrameParameters frame;
    float input_gain;
    float3 padding;
};

static inline uint pcg(uint value) {
    uint state = value * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
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
    // Tetrahedral weights are [1-L, L-M, M-S, S]. The first two and last
    // two vertices each share a cube edge, so two hardware-linear samples
    // plus one mix are the same weighted sum (modulo sampler rounding).
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

// The exact tetrahedron is a mixture of two linearly filtered cube edges. Video can draw one
// edge with that mixture's probability: every frame then costs one filtered lookup and the
// temporal expectation is the exact tetrahedral result. Selecting coordinates before the
// texture instruction avoids divergent branches executing both samples across a SIMD-group.
static inline float4 temporal_tetrahedral(
    texture3d<half, access::sample> cube, float3 point, uint random) {
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
    float threshold = float(random >> 8u) * (1.0f / 16777216.0f);
    float3 selected = select(first_coordinate, second_coordinate,
                             threshold < middle);
    constexpr sampler linear_cube(
        coord::normalized, address::clamp_to_edge, filter::linear);
    return float4(cube.sample(linear_cube, selected));
}

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

static inline float3 sample_curve(
    texture2d<half, access::sample> curves, float3 log_exposure,
    uint row) {
    float3 q = clamp((log_exposure + 8.0f)
                     * (float(kCurveSamples - 1u) / 16.0f),
                     0.0f, float(kCurveSamples - 1u));
    constexpr sampler linear_table(
        coord::normalized, address::clamp_to_edge, filter::linear);
    float inverse_width = 1.0f / float(kCurveSamples);
    float y = (float(row) + 0.5f) / 2.0f;
    return float3(
        curves.sample(linear_table, float2((q.x + 0.5f) * inverse_width, y)).x,
        curves.sample(linear_table, float2((q.y + 0.5f) * inverse_width, y)).y,
        curves.sample(linear_table, float2((q.z + 0.5f) * inverse_width, y)).z);
}

static inline float sample_donor_curve(
    texture2d<half, access::sample> curves, float log_exposure,
    uint row) {
    float q = clamp((log_exposure + 8.0f)
                    * (float(kCurveSamples - 1u) / 16.0f),
                    0.0f, float(kCurveSamples - 1u));
    constexpr sampler linear_table(
        coord::normalized, address::clamp_to_edge, filter::linear);
    return float(curves.sample(
        linear_table,
        float2((q + 0.5f) / float(kCurveSamples),
               (float(row) + 0.5f) / 2.0f)).w);
}

static inline float decode_transfer(
    texture1d<half, access::sample> table, float encoded) {
    constexpr sampler linear_table(
        coord::normalized, address::clamp_to_edge, filter::linear);
    float q = clamp(encoded, 0.0f, 1.0f) * float(kDecodeSamples - 1u);
    return float(table.sample(linear_table, (q + 0.5f) / float(kDecodeSamples)).r);
}

static inline float tone_base(
    const device float *configuration, float stops, uint2 position) {
    int grid_width = max(int(configuration[kToneGridSize]), 1);
    int grid_height = max(int(configuration[kToneGridSize + 1u]), 1);
    float frame_width = max(configuration[kFrameSize], 1.0f);
    float frame_height = max(configuration[kFrameSize + 1u], 1.0f);
    float gx = clamp((float(position.x) + 0.5f) * float(grid_width)
                     / frame_width - 0.5f,
                     0.0f, float(grid_width - 1));
    float gy = clamp((float(position.y) + 0.5f) * float(grid_height)
                     / frame_height - 0.5f,
                     0.0f, float(grid_height - 1));
    int x0 = clamp(int(gx), 0, max(grid_width - 2, 0));
    int y0 = clamp(int(gy), 0, max(grid_height - 2, 0));
    int x1 = min(x0 + 1, grid_width - 1);
    int y1 = min(y0 + 1, grid_height - 1);
    float fx = clamp(gx - float(x0), 0.0f, 1.0f);
    float fy = clamp(gy - float(y0), 0.0f, 1.0f);
    auto bilinear = [&](uint plane) {
        float c00 = configuration[plane + uint(y0 * grid_width + x0)];
        float c10 = configuration[plane + uint(y0 * grid_width + x1)];
        float c01 = configuration[plane + uint(y1 * grid_width + x0)];
        float c11 = configuration[plane + uint(y1 * grid_width + x1)];
        return mix(mix(c00, c10, fx), mix(c01, c11, fx), fy);
    };
    return bilinear(kToneGridA) * stops + bilinear(kToneGridB);
}

static inline float3 creative_exposure(
    const device float *configuration, float3 scene,
    constant FrameParameters &params) {
    constexpr float3 luma = float3(0.2627002f, 0.6779981f, 0.0593017f);
    float3 balance = float3(
        configuration[kWhiteBalance], configuration[kWhiteBalance + 1u],
        configuration[kWhiteBalance + 2u]);
    // Balance first: the metering, the luminance and the colourfulness below
    // all read the adapted scene, matching creative_exposure in the shared header.
    float3 toned = scene * balance;
    if (params.tone_adjust != 0u) {
        float metered = dot(luma, toned)
            * configuration[kExposureGain] * (1.0f / 0.18f);
        // Active local tone is rejected by prepare until the handwritten
        // measurement pass supplies a solved grid, so the canonical base is stops.
        float keyed = log2(max(metered, 1.0e-6f));
        float high = clamp(keyed * (1.0f / 6.0f), 0.0f, 1.0f);
        float low = clamp(-keyed * (1.0f / 6.0f), 0.0f, 1.0f);
        float highlight_mask = high * high * (3.0f - 2.0f * high);
        float shadow_mask = low * low * (3.0f - 2.0f * low);
        float tone_ev = 3.0f
            * (configuration[kSceneAdjust] * highlight_mask
               + configuration[kSceneAdjust + 1u] * shadow_mask);
        toned *= exp2(tone_ev);
    }
    if (params.chroma_adjust != 0u) {
        float luminance = dot(luma, toned);
        float peak = max(toned.x, max(toned.y, toned.z));
        float colourfulness = (peak - min(toned.x, min(toned.y, toned.z)))
            / max(peak, 1.0e-6f);
        float chroma = configuration[kSceneAdjust + 2u]
            * (1.0f + configuration[kSceneAdjust + 3u]
                         * (1.0f - colourfulness));
        toned = luminance + chroma * (toned - luminance);
    }
    return toned;
}

static inline float4 recover_exposure(
    texture2d_array<half, access::read> exposure_faces,
    const device float *configuration, float3 scene, uint2 position,
    constant FrameParameters &params) {
    constexpr float3 luma = float3(0.2627002f, 0.6779981f, 0.0593017f);
    // `position` remains part of the seam for the measured local-tone variant.
    float3 adjusted = creative_exposure(configuration, scene, params);
    // The exposure table is indexed in a basis whose cube encloses the spectral locus; this
    // seam mirrors kRec2020ToExposureDomain in FotufilmHalideShared.h digit for digit.
    float3 domain = float3(
        0.670231843f * adjusted.x + 0.152168745f * adjusted.y + 0.177599412f * adjusted.z,
        0.044501114f * adjusted.x + 0.854482372f * adjusted.y + 0.101016514f * adjusted.z,
        0.025777047f * adjusted.y + 0.974222953f * adjusted.z);
    float3 physical = domain;
    float y = dot(luma, adjusted);
    if (y <= 0.0f) {
        physical = 0.0f;
    } else if (any(domain < 0.0f)) {
        float3 ratio = select(
            float3(1.0f), y / (y - domain), domain < 0.0f);
        float saturation = min(ratio.x, min(ratio.y, ratio.z));
        physical = y + saturation * (domain - y);
    }
    physical = max(physical, 0.0f);
    float radiance = max(physical.x, max(physical.y, physical.z));
    if (radiance <= 1.0e-6f) return 0.0f;
    return max(exposure_face(exposure_faces, physical / radiance)
               * (radiance * configuration[kExposureGain] / 0.18f),
               0.0f);
}

static inline float3 curve_minimum(const device float *configuration) {
    return float3(configuration[kCurves], configuration[kCurves + 6u],
                  configuration[kCurves + 12u]);
}

static inline float3 curve_range(const device float *configuration) {
    float3 result;
    for (uint channel = 0; channel < 3; ++channel) {
        uint primary = kCurves + channel * 6u;
        uint secondary = kCurveSecondary + channel * 5u;
        result[channel] = configuration[primary + 1u]
            * (configuration[primary + 4u] - configuration[primary + 2u])
            + configuration[secondary]
            * (configuration[secondary + 3u] - configuration[secondary + 1u]);
    }
    return result;
}

static inline float release(float activation, float gamma) {
    float a = clamp(activation, 0.0f, 1.0f);
    if (gamma == 1.0f) return a;
    float formed = pow(a, gamma);
    float retained = pow(1.0f - a, gamma);
    return formed / max(formed + retained, 1.0e-8f);
}

static inline float warp(
    const device float *configuration, uint channel, float value,
    bool nonlinear) {
    float q = clamp((value + 4.0f) * (127.0f / 8.0f), 0.0f, 127.0f);
    uint index = min(uint(q), 126u);
    float fraction = q - float(index);
    uint base = kCouplerWarp + channel * kCouplerWarpSamples;
    float low = configuration[base + index];
    float high = configuration[base + index + 1u];
    if (!nonlinear) return mix(low, high, fraction);
    uint previous_index = index > 0u ? index - 1u : 0u;
    float previous = configuration[base + previous_index];
    float following = configuration[base + min(index + 2u, 127u)];
    float delta = max(high - low, 0.0f);
    float low_slope = clamp(0.5f * (high - previous), 0.0f, 3.0f * delta);
    float high_slope = clamp(0.5f * (following - low), 0.0f, 3.0f * delta);
    float f2 = fraction * fraction;
    float f3 = f2 * fraction;
    return (2.0f * f3 - 3.0f * f2 + 1.0f) * low
        + (f3 - 2.0f * f2 + fraction) * low_slope
        + (-2.0f * f3 + 3.0f * f2) * high
        + (f3 - f2) * high_slope;
}

static inline float display_shoulder(float value, uint reversal) {
    float knee = reversal != 0u ? 0.7f : 0.9f;
    float over = value - knee;
    float room = 1.0f - knee;
    return value > knee ? knee + room * over / (over + room) : value;
}

static inline float transfer(
    texture1d<half, access::sample> table, float linear) {
    float q = sqrt(clamp(linear, 0.0f, 1.0f))
        * float(kTransferSamples - 1u);
    constexpr sampler linear_table(
        coord::normalized, address::clamp_to_edge, filter::linear);
    return float(table.sample(
        linear_table, (q + 0.5f) / float(kTransferSamples)).r);
}

static inline float3 pointwise_develop(
    texture2d_array<half, access::read> exposure_faces,
    texture3d<half, access::sample> print_cube,
    texture2d<half, access::sample> curves,
    const device float *configuration,
    float3 scene, uint2 position, uint random,
    constant FrameParameters &params) {
    float4 records = recover_exposure(
        exposure_faces, configuration, scene, position, params);
    float3 layer_exposure = max(records.rgb, 1.0e-6f);
    float3 log_exposure = log10(layer_exposure);
    float3 released = sample_curve(curves, log_exposure, 0u);
    float donor_released = 0.0f;
    if (params.donor != 0u) {
        float donor_log = log10(max(records.w, 1.0e-6f));
        donor_released = sample_donor_curve(curves, donor_log, 0u);
    }
    float3 inhibited_log;
    for (uint channel = 0; channel < 3; ++channel) {
        uint row = kCoupler + channel * 3u;
        float inhibition = (dot(
            float3(configuration[row], configuration[row + 1u],
                   configuration[row + 2u]), released)
            + (params.donor != 0u
                ? configuration[kDonorRelease + channel] * donor_released
                : 0.0f))
            * configuration[kCouplerScale];
        inhibited_log[channel] = log_exposure[channel] - inhibition;
    }
    float3 density_coordinate = sample_curve(curves, inhibited_log, 1u);
    return (kTemporalPrint
        ? temporal_tetrahedral(print_cube, density_coordinate, random)
        : tetrahedral(print_cube, density_coordinate)).rgb;
}

kernel void fotufilm_handwritten_pointwise_sdr(
    const device uchar4 *input [[buffer(0)]],
    device uchar4 *output [[buffer(1)]],
    const device float *configuration [[buffer(2)]],
    constant FrameParameters &params [[buffer(3)]],
    texture2d_array<half, access::read> exposure_faces [[texture(0)]],
    texture3d<half, access::sample> print_cube [[texture(1)]],
    texture2d<half, access::sample> curves [[texture(2)]],
    texture1d<half, access::sample> transfer_table [[texture(3)]],
    texture1d<half, access::sample> decode_table [[texture(4)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= params.width || position.y >= params.height) return;
    uint offset = position.y * params.width + position.x;
    uchar4 pixel = input[offset];
    float denominator = pixel.w > 0u && pixel.w < 255u
        ? float(pixel.w) : 255.0f;
    float3 encoded = clamp(float3(pixel.xyz) / denominator, 0.0f, 1.0f);
    float3 p3 = float3(
        decode_transfer(decode_table, encoded.x),
        decode_transfer(decode_table, encoded.y),
        decode_transfer(decode_table, encoded.z));
    float3 scene = float3(
        dot(float3(0.753833034f, 0.198597369f, 0.047569597f), p3),
        dot(float3(0.045743849f, 0.941777220f, 0.012478931f), p3),
        dot(float3(-0.001210340f, 0.017601717f, 0.983608623f), p3));
    uint2 frame_position = position + uint2(params.origin_x, params.origin_y);
    uint absolute_index = frame_position.y * params.frame_width
        + frame_position.x;
    uint print_random = pcg(absolute_index ^ pcg(params.seed));
    float3 printed = pointwise_develop(
        exposure_faces, print_cube, curves, configuration,
        scene, frame_position, print_random, params);
    float3 encoded_output;
    for (uint channel = 0; channel < 3; ++channel) {
        encoded_output[channel] = transfer(
            transfer_table,
            clamp(display_shoulder(printed[channel], params.reversal), 0.0f, 1.0f));
    }
    uint3 salts = uint3(
        params.dither_salt_0, params.dither_salt_1,
        params.dither_salt_2);
    for (uint channel = 0; channel < 3; ++channel) {
        uint hash1 = pcg(absolute_index ^ salts[channel]);
        uint hash2 = pcg(hash1);
        float dither = float(hash1 >> 8u) * (1.0f / 16777216.0f)
            + float(hash2 >> 8u) * (1.0f / 16777216.0f) - 1.0f;
        encoded_output[channel] = floor(
            encoded_output[channel] * 255.0f + 0.5f + dither);
    }
    output[offset] = uchar4(
        uchar3(clamp(encoded_output, 0.0f, 255.0f)), pixel.w);
}

kernel void fotufilm_handwritten_pointwise_hdr(
    const device half4 *input [[buffer(0)]],
    device half4 *output [[buffer(1)]],
    const device float *configuration [[buffer(2)]],
    constant HDRFrameParameters &params [[buffer(3)]],
    texture2d_array<half, access::read> exposure_faces [[texture(0)]],
    texture3d<half, access::sample> print_cube [[texture(1)]],
    texture2d<half, access::sample> curves [[texture(2)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= params.frame.width
        || position.y >= params.frame.height) return;
    uint offset = position.y * params.frame.width + position.x;
    float4 pixel = float4(input[offset]);
    float3 scene = pixel.xyz * params.input_gain;
    uint2 frame_position = position
        + uint2(params.frame.origin_x, params.frame.origin_y);
    uint absolute_index = frame_position.y * params.frame.frame_width
        + frame_position.x;
    uint print_random = pcg(absolute_index ^ pcg(params.frame.seed));
    float3 printed = pointwise_develop(
        exposure_faces, print_cube, curves, configuration,
        scene, frame_position, print_random, params.frame);
    output[offset] = half4(half3(max(printed, 0.0f)), half(pixel.w));
}
