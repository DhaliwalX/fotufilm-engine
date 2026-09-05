#include <metal_stdlib>
using namespace metal;

constant bool kTailReversal [[function_constant(0)]];
constant bool kTailMonochrome [[function_constant(1)]];
constant bool kTailGrade [[function_constant(2)]];
constant bool kTailEncodedGrade [[function_constant(3)]];
constant bool kHeadTone [[function_constant(4)]];
constant bool kHeadChroma [[function_constant(5)]];

constant uint kCurveSamples = FOTUFILM_ENDPOINT_CURVE_SAMPLES;
constant uint kTransferSamples = FOTUFILM_ENDPOINT_TRANSFER_SAMPLES;
constant uint kCurves = 0u;
constant uint kPaper = 33u;
constant uint kMasking = 39u;
constant uint kPaperMidpoint = 62u;
constant uint kExposureGain = FOTUFILM_CFG_EXPOSURE_GAIN;
constant uint kWhiteBalance = FOTUFILM_CFG_WHITE_BALANCE;
constant uint kSceneAdjust = FOTUFILM_CFG_SCENE_ADJUST;
constant uint kGrade = FOTUFILM_CFG_GRADE;
constant uint kFrameSize = FOTUFILM_CFG_FRAME_SIZE;
constant uint kToneGridSize = FOTUFILM_CFG_TONE_GRID_SIZE;
constant uint kToneGridA = FOTUFILM_CFG_TONE_GRID_A;
constant uint kToneGridB = FOTUFILM_CFG_TONE_GRID_B;
constant uint kPaperRed = FOTUFILM_CFG_PAPER_RED;
constant uint kPaperBlue = FOTUFILM_CFG_PAPER_BLUE;
constant uint kPaperMidpointRed = FOTUFILM_CFG_PAPER_MIDPOINT_RED;
constant uint kPaperMidpointBlue = FOTUFILM_CFG_PAPER_MIDPOINT_BLUE;
constant uint kCurveSecondary = FOTUFILM_CFG_CURVE_SECONDARY;

struct FrameParameters {
    uint width;
    uint height;
    uint frame_width;
    uint seed;
    float input_gain;
    uint padding0;
    uint padding1;
    uint padding2;
};

static inline float table1d(texture1d<float, access::read> table, float position) {
    float q = clamp(position, 0.0f, 1.0f) * float(table.get_width() - 1u);
    uint index = min(uint(q), table.get_width() - 2u);
    float low = table.read(index).r;
    return low + (q - float(index)) * (table.read(index + 1u).r - low);
}

// Recovery normalizes by the largest physical-light component. Every non-black lookup is
// therefore on one upper cube face. This is the exact triangular restriction of the same
// tetrahedral walk, including its >= diagonal tie.
static inline float4 exposure_face(
    texture2d_array<float, access::read> faces, float3 point) {
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
    float4 c00 = faces.read(low, face);
    float4 c11 = faces.read(low + 1u, face);
    if (f.x >= f.y) {
        float4 c10 = faces.read(low + uint2(1u, 0u), face);
        return c00 + f.x * (c10 - c00) + f.y * (c11 - c10);
    }
    float4 c01 = faces.read(low + uint2(0u, 1u), face);
    return c00 + f.y * (c01 - c00) + f.x * (c11 - c01);
}

// Four reads per branch, with the same tie ordering as SpectralLUT.sample and the canonical
// Halide LUT helper. Neither hardware trilinear filtering nor an eight-corner eager load is
// allowed at the density/print seam.
static inline float4 tetrahedral(
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

static inline float tone_grid_bilinear(
    const device float *configuration, uint plane, int grid_width,
    int x0, int y0, int x1, int y1, float fx, float fy) {
    float c00 = configuration[plane + uint(y0 * grid_width + x0)];
    float c10 = configuration[plane + uint(y0 * grid_width + x1)];
    float c01 = configuration[plane + uint(y1 * grid_width + x0)];
    float c11 = configuration[plane + uint(y1 * grid_width + x1)];
    return (1.0f - fy) * ((1.0f - fx) * c00 + fx * c10)
        + fy * ((1.0f - fx) * c01 + fx * c11);
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
    return tone_grid_bilinear(configuration, kToneGridA, grid_width,
                              x0, y0, x1, y1, fx, fy) * stops
        + tone_grid_bilinear(configuration, kToneGridB, grid_width,
                             x0, y0, x1, y1, fx, fy);
}

static inline float4 recover_exposure(
    texture2d_array<float, access::read> faces,
    const device float *configuration, float3 scene, uint2 position) {
    constexpr float3 luma = float3(0.2627002f, 0.6779981f, 0.0593017f);
    float3 balance = float3(
        configuration[kWhiteBalance], configuration[kWhiteBalance + 1u],
        configuration[kWhiteBalance + 2u]);
    // Balance first: the metering, the luminance and the colourfulness below
    // all read the adapted scene, matching creative_exposure in the shared header.
    float3 adjusted = scene * balance;
    if (kHeadTone) {
        float metered = dot(luma, adjusted)
            * configuration[kExposureGain] * (1.0f / 0.18f);
        float stops = log2(max(metered, 1.0e-6f));
        float keyed = tone_base(configuration, stops, position);
        float high = clamp(keyed * (1.0f / 6.0f), 0.0f, 1.0f);
        float low = clamp(-keyed * (1.0f / 6.0f), 0.0f, 1.0f);
        float high_mask = high * high * (3.0f - 2.0f * high);
        float low_mask = low * low * (3.0f - 2.0f * low);
        float tone_ev = 3.0f
            * (configuration[kSceneAdjust] * high_mask
               + configuration[kSceneAdjust + 1u] * low_mask);
        adjusted *= exp2(tone_ev);
    }
    if (kHeadChroma) {
        float luminance = dot(luma, adjusted);
        float peak = max(adjusted.x, max(adjusted.y, adjusted.z));
        float colourfulness = (peak - min(adjusted.x, min(adjusted.y, adjusted.z)))
            / max(peak, 1.0e-6f);
        float chroma = configuration[kSceneAdjust + 2u]
            * (1.0f + configuration[kSceneAdjust + 3u]
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
    // Darkness is darkness. The face textures have no origin cell: a zero chromaticity lands
    // on a face's corner, the exposure of a pure domain primary, and the radiance floor would
    // leak a millionth of that into every black pixel.
    if (radiance <= 1.0e-6f) return 0.0f;
    return max(exposure_face(faces, physical / radiance)
               * (radiance * configuration[kExposureGain] / 0.18f), 0.0f);
}

kernel void fotufilm_endpoint_head_sdr(
    const device uchar4 *input [[buffer(0)]],
    const device float *configuration [[buffer(1)]],
    constant FrameParameters &parameters [[buffer(2)]],
    texture2d_array<float, access::read> exposure [[texture(0)]],
    texture2d<float, access::write> record [[texture(1)]],
    texture1d<float, access::read> decode [[texture(2)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    uint index = position.y * parameters.width + position.x;
    uchar4 pixel = input[index];
    float denominator = pixel.w > 0u && pixel.w < 255u
        ? float(pixel.w) : 255.0f;
    float3 encoded = clamp(float3(pixel.xyz) / denominator, 0.0f, 1.0f);
    float3 p3 = float3(
        table1d(decode, encoded.x), table1d(decode, encoded.y),
        table1d(decode, encoded.z));
    float3 scene = float3(
        dot(float3(0.753833034f, 0.198597369f, 0.047569597f), p3),
        dot(float3(0.045743849f, 0.941777220f, 0.012478931f), p3),
        dot(float3(-0.001210340f, 0.017601717f, 0.983608623f), p3));
    record.write(recover_exposure(exposure, configuration, scene, position), position);
}

kernel void fotufilm_endpoint_head_hdr(
    const device half4 *input [[buffer(0)]],
    const device float *configuration [[buffer(1)]],
    constant FrameParameters &parameters [[buffer(2)]],
    texture2d_array<float, access::read> exposure [[texture(0)]],
    texture2d<float, access::write> record [[texture(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    uint index = position.y * parameters.width + position.x;
    float3 scene = float3(input[index].xyz) * parameters.input_gain;
    record.write(recover_exposure(exposure, configuration, scene, position), position);
}

static inline float film_curve_range(
    const device float *configuration, uint channel) {
    uint primary = kCurves + channel * 6u;
    uint secondary = kCurveSecondary + channel * 5u;
    return configuration[primary + 1u]
            * (configuration[primary + 4u] - configuration[primary + 2u])
        + configuration[secondary]
            * (configuration[secondary + 3u] - configuration[secondary + 1u]);
}

static inline uint paper_base(uint channel) {
    return channel == 0u ? kPaperRed : (channel == 1u ? kPaper : kPaperBlue);
}

static inline float paper_midpoint(
    const device float *configuration, uint channel) {
    return channel == 0u ? configuration[kPaperMidpointRed]
        : (channel == 1u ? configuration[kPaperMidpoint]
                         : configuration[kPaperMidpointBlue]);
}

static inline float sample_paper_curve(
    texture2d<float, access::read> curves, float exposure, uint channel) {
    float q = clamp((exposure + 8.0f) * (float(kCurveSamples - 1u) / 16.0f),
                    0.0f, float(kCurveSamples - 1u));
    uint index = min(uint(q), kCurveSamples - 2u);
    float low = curves.read(uint2(index, channel)).r;
    float high = curves.read(uint2(index + 1u, channel)).r;
    return low + (q - float(index)) * (high - low);
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
    const device float *configuration, float value, uint channel) {
    if (!kTailGrade) return value;
    float working = kTailEncodedGrade ? grading_encode(value) : value;
    float lift = configuration[kGrade + channel];
    float gain = configuration[kGrade + 3u + channel];
    float exponent = configuration[kGrade + 6u + channel];
    float lifted = working * (gain - lift) + lift;
    float graded = exponent == 1.0f
        ? lifted : pow(max(lifted, 0.0f), exponent);
    return kTailEncodedGrade ? grading_decode(graded) : graded;
}

static inline float3 print_density(
    texture2d<float, access::read> density,
    texture3d<float, access::read> film,
    texture2d<float, access::read> paper_curves,
    texture3d<float, access::read> paper,
    const device float *configuration, uint2 position) {
    float3 developed = density.read(position).rgb;
    float3 activation;
    for (uint channel = 0u; channel < 3u; ++channel) {
        activation[channel] = (developed[channel]
            - configuration[kCurves + channel * 6u])
            / max(film_curve_range(configuration, channel), 1.0e-6f);
    }
    float3 relative = tetrahedral(film, activation).rgb;
    float3 printed;
    if (kTailReversal) {
        printed = relative;
    } else {
        float3 paper_activation;
        for (uint channel = 0u; channel < 3u; ++channel) {
            uint base = paper_base(channel);
            float exposure = paper_midpoint(configuration, channel)
                + configuration[kMasking + channel] * relative[channel];
            float range = configuration[base + 1u]
                * (configuration[base + 4u] - configuration[base + 2u]);
            paper_activation[channel] =
                (sample_paper_curve(paper_curves, exposure, channel)
                 - configuration[base]) / max(range, 1.0e-6f);
        }
        printed = tetrahedral(paper, paper_activation).rgb;
    }
    if (kTailMonochrome) printed = float3((printed.x + printed.y + printed.z) / 3.0f);
    return float3(grade(configuration, printed.x, 0u),
                  grade(configuration, printed.y, 1u),
                  grade(configuration, printed.z, 2u));
}

static inline uint pcg(uint value) {
    uint state = value * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

static inline float dither(
    uint2 position, uint channel, uint width, uint seed) {
    uint index = position.y * width + position.x;
    uint hash1 = pcg(index ^ pcg(channel + seed * 0x9E3779B9u));
    uint hash2 = pcg(hash1);
    return float(hash1 >> 8u) * (1.0f / 16777216.0f)
        + float(hash2 >> 8u) * (1.0f / 16777216.0f) - 1.0f;
}

static inline float display_shoulder(float value) {
    const float knee = kTailReversal ? 0.7f : 0.9f;
    float over = value - knee;
    float room = 1.0f - knee;
    return value > knee ? knee + room * over / (over + room) : value;
}

kernel void fotufilm_endpoint_tail_sdr(
    const device uchar4 *original [[buffer(0)]],
    device uchar4 *output [[buffer(1)]],
    const device float *configuration [[buffer(2)]],
    constant FrameParameters &parameters [[buffer(3)]],
    texture2d<float, access::read> density [[texture(0)]],
    texture3d<float, access::read> film [[texture(1)]],
    texture2d<float, access::read> paper_curves [[texture(2)]],
    texture3d<float, access::read> paper [[texture(3)]],
    texture1d<float, access::read> transfer_table [[texture(4)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    uint index = position.y * parameters.width + position.x;
    float3 linear = print_density(
        density, film, paper_curves, paper, configuration, position);
    float3 encoded;
    for (uint channel = 0u; channel < 3u; ++channel) {
        float delivered = clamp(display_shoulder(linear[channel]), 0.0f, 1.0f);
        float signal = table1d(transfer_table, sqrt(delivered));
        encoded[channel] = floor(signal * 255.0f + 0.5f
                                 + dither(position, channel,
                                          parameters.frame_width,
                                          parameters.seed));
    }
    output[index] = uchar4(uchar3(clamp(encoded, 0.0f, 255.0f)), original[index].w);
}

kernel void fotufilm_endpoint_tail_hdr(
    const device half4 *original [[buffer(0)]],
    device half4 *output [[buffer(1)]],
    const device float *configuration [[buffer(2)]],
    constant FrameParameters &parameters [[buffer(3)]],
    texture2d<float, access::read> density [[texture(0)]],
    texture3d<float, access::read> film [[texture(1)]],
    texture2d<float, access::read> paper_curves [[texture(2)]],
    texture3d<float, access::read> paper [[texture(3)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= parameters.width || position.y >= parameters.height) return;
    uint index = position.y * parameters.width + position.x;
    float3 linear = print_density(
        density, film, paper_curves, paper, configuration, position);
    // The float contract has no display-white ceiling. As in the canonical print schedule,
    // only non-light below zero is floored before conversion to the caller's half storage.
    output[index] = half4(half3(max(linear, 0.0f)), original[index].w);
}
