#include <metal_stdlib>
using namespace metal;

constant int SPECIALIZED_RADIUS [[function_constant(0)]];
constant bool MTF_WIDE [[function_constant(1)]];
constant bool MTF_EXTENDED [[function_constant(2)]];
constant bool DEVELOP_GRAIN [[function_constant(3)]];
constant bool DEVELOP_MOTTLE [[function_constant(4)]];
constant bool DEVELOP_MONOCHROME [[function_constant(5)]];
constant bool DEVELOP_PRINT_TRANSMITTANCE [[function_constant(6)]];
constant bool MTF_DOWNSAMPLE [[function_constant(7)]];
constant int PRINT_RADIUS [[function_constant(8)]];
constant bool DEVELOP_INPUT_LOG [[function_constant(9)]];
constant bool USE_HALF_RESPONSE_LUT [[function_constant(10)]];
constant bool DEVELOP_CACHE_FIELDS [[function_constant(11)]];
constant bool MTF_PACKED_PRIMARY [[function_constant(12)]];
constant bool DEVELOP_DYE_CLOUD [[function_constant(13)]];
constant bool DEVELOP_DONOR [[function_constant(14)]];
constant bool DEVELOP_NONLINEAR_WARP [[function_constant(15)]];
constant bool DEVELOP_COMPLEMENT [[function_constant(16)]];
constant int FIELD_COUPLER_RADIUS [[function_constant(17)]];
constant int FIELD_ADJACENCY_RADIUS [[function_constant(18)]];
constant bool DEVELOP_MULTIRES [[function_constant(19)]];

// Optional specialization: analytic, complete cubic cache, or general sampled lookup.
constant uint FILM_CURVE_MODE [[function_constant(20)]];

constant uint kFeatureCouplers = 1u << 3;
constant uint kFeatureDonor = 1u << 27;

constant uint kCurves = 0u;
constant uint kSampledCurves = FOTUFILM_CFG_SAMPLED_CURVES;
constant uint kSampledCurveStride = FOTUFILM_SAMPLED_CURVE_STRIDE;
constant uint kCoupler = 21u;
constant uint kGrain = 30u;
constant uint kCouplerScale = 58u;
constant uint kAdjacencyStrength = 59u;
constant uint kCouplerWarp = 66u;
constant uint kHalationKernel = 457u;
constant uint kMottle = 8684u;
constant uint kGrainLaw = 8701u;
constant uint kGrainAnchor = 8702u;
constant uint kGrainFog = 8705u;
constant uint kDonorCurve = 8747u;
constant uint kDonorRelease = 8753u;
constant uint kHalationMatrix = 8759u;
constant uint kCurveSecondary = 8768u;
constant uint kCouplerReleaseGamma = 8792u;
constant uint kDonorReleaseGamma = 8795u;
constant uint kDiffusionDirect = 8734u;
constant uint kDiffusionKernel = 8735u;
constant uint kDonorDiffusionKernel = 8796u;
constant uint kDevelopComplement = FOTUFILM_CFG_DEVELOP_COMPLEMENT;
constant uint kGrainDensityProfile = 8800u;

constant float kInverseLn10 = 1.0f / 2.3025851f;
constant float kLn10 = 2.3025851f;

struct SpatialParameters { uint4 extent; uint4 geometry; };
struct CopyParameters { uint4 extent; float4 mean; };
struct PyramidParameters {
    uint4 extent;
    uint4 grid0;
    uint4 grid1;
    uint4 grid2;
    uint4 strides;
    float4 rings;
};
struct FastFinishParameters {
    uint4 extent;
    uint4 grid0;
    uint4 grid1;
    uint4 grid2;
    uint4 strides;
    uint4 coupler;
    uint4 adjacency;
};
struct MultiresFieldParameters {
    uint4 activationExtent;
    uint4 couplerExtent;
};
struct MTFParameters { uint4 extent; float4 mean; float4 shares; };
struct DevelopParameters {
    uint4 extent;
    uint4 state;
    uint4 coupler;
    uint4 adjacency;
    uint4 phases;
    float4 grain;
};
struct PrintParameters { uint4 extent; float4 values; };

static inline float film_curve_range(const device float *configuration, uint channel) {
    uint base = kCurves + channel * 6u;
    uint secondary = kCurveSecondary + channel * 5u;
    return configuration[base + 1u]
            * (configuration[base + 4u] - configuration[base + 2u])
        + configuration[secondary]
            * (configuration[secondary + 3u] - configuration[secondary + 1u]);
}

static inline float sample_curve(
    texture2d<float, access::read> curves, float exposure, uint channel) {
    float q = clamp((exposure + 8.0f) * (2047.0f / 16.0f), 0.0f, 2047.0f);
    uint index = min(uint(q), 2046u);
    float fraction = q - float(index);
    float low = curves.read(uint2(index, channel)).r;
    return mix(low, curves.read(uint2(index + 1u, channel)).r, fraction);
}

static inline float inhibitor_release(float activation, float gamma) {
    float a = clamp(activation, 0.0f, 1.0f);
    if (gamma == 1.0f) return a;
    float released = pow(a, gamma);
    float retained = pow(1.0f - a, gamma);
    return released / max(released + retained, 1.0e-8f);
}

static inline float sample_film_curve(
    const device float *configuration, texture2d<float, access::read> curves,
    float exposure, uint channel) {
    if (is_function_constant_defined(FILM_CURVE_MODE)) {
        if (FILM_CURVE_MODE == 0u) return sample_curve(curves, exposure, channel);
    } else if (curves.get_height() == 4u) return sample_curve(curves, exposure, channel);
    float x = clamp(exposure, -8.0f, 8.0f);
    uint width = curves.get_width();
    uint bin = min(uint((x + 8.0f) * (float(width) / 16.0f)), width - 1u);
    float4 anchor = curves.read(uint2(bin, 4u + 2u * channel));
    if ((is_function_constant_defined(FILM_CURVE_MODE) && FILM_CURVE_MODE == 1u)
        || (exposure >= -8.0f && exposure <= 8.0f
            && as_type<uint>(anchor.x) != 0x7fc00000u)) {
        float4 pair = curves.read(uint2(bin, 5u + 2u * channel));
        float dx = x - anchor.x;
        float2 cubic = dx < 0.0f ? pair.xy : pair.zw;
        return anchor.y + dx * (anchor.z + dx * (cubic.x + dx * cubic.y));
    }
    uint base = kSampledCurves + channel * kSampledCurveStride;
    uint count = uint(configuration[base]);
    if (count < 2u) return sample_curve(curves, exposure, channel);
    if (exposure <= configuration[base + 1u]) return configuration[base + 2u];
    uint end = base + 1u + (count - 1u) * 3u;
    if (exposure >= configuration[end]) return configuration[end + 1u];
    uint low = 0u, high = count - 1u;
    while (high - low > 1u) {
        uint mid = (low + high) / 2u;
        if (configuration[base + 1u + mid * 3u] <= exposure) low = mid;
        else high = mid;
    }
    uint i = base + 1u + low * 3u;
    float h = configuration[i + 3u] - configuration[i];
    float t = clamp((exposure - configuration[i]) / h, 0.0f, 1.0f);
    float delta = configuration[i + 4u] - configuration[i + 1u];
    float a = h * configuration[i + 2u], b = h * configuration[i + 5u];
    return configuration[i + 1u] + t * (a + t * (3.0f * delta - 2.0f * a - b
        + t * (-2.0f * delta + a + b)));

}

static inline float4 stored_log_exposure(float4 light) {
    // The AOT schedule deliberately materializes log exposure in f16. Development,
    // activation, adjacency, and inhibitor release must all observe this same seam.
    return float4(half4(log(max(light, 1.0e-6f)) * kInverseLn10));
}

static inline float4 activation_from_log(
    float4 logarithmic, const device float *configuration,
    texture2d<float, access::read> curves) {
    float4 activation;
    for (uint channel = 0; channel < 3u; ++channel) {
        float formed = sample_film_curve(configuration, curves, logarithmic[channel], channel);
        activation[channel] = (formed - configuration[kCurves + channel * 6u])
            / max(film_curve_range(configuration, channel), 1.0e-6f);
    }
    float donor = sample_curve(curves, logarithmic.w, 3u);
    float donorRange = configuration[kDonorCurve + 1u]
        * (configuration[kDonorCurve + 4u] - configuration[kDonorCurve + 2u]);
    activation.w = (donor - configuration[kDonorCurve]) / max(donorRange, 1.0e-6f);
    return activation;
}

static inline float2 half_response(
    texture2d_array<float, access::read> table, half logarithmic, uint channel) {
    ushort bits = as_type<ushort>(logarithmic);
    return table.read(uint2(uint(bits) & 255u, uint(bits) >> 8u), channel).rg;
}

kernel void fotufilm_spatial_bake_half_response(
    texture2d<float, access::read> curves [[texture(0)]],
    texture2d_array<float, access::write> table [[texture(1)]],
    const device float *configuration [[buffer(0)]],
    uint3 position [[thread_position_in_grid]]) {
    if (position.x >= 256u || position.y >= 256u || position.z >= 4u) return;
    ushort bits = ushort(position.x | (position.y << 8u));
    float logarithmic = float(as_type<half>(bits));
    float activation = 0.0f;
    float release = 0.0f;
    if (isfinite(logarithmic)) {
        if (position.z < 3u) {
            uint base = kCurves + position.z * 6u;
            float formed = sample_film_curve(configuration, curves, logarithmic, position.z);
            activation = (formed - configuration[base])
                / max(film_curve_range(configuration, position.z), 1.0e-6f);
            release = inhibitor_release(
                activation, configuration[kCouplerReleaseGamma + position.z]);
        } else {
            float formed = sample_curve(curves, logarithmic, 3u);
            float range = configuration[kDonorCurve + 1u]
                * (configuration[kDonorCurve + 4u]
                    - configuration[kDonorCurve + 2u]);
            activation = (formed - configuration[kDonorCurve])
                / max(range, 1.0e-6f);
            release = inhibitor_release(
                activation, configuration[kDonorReleaseGamma]);
        }
    }
    table.write(float4(activation, release, 0.0f, 0.0f), position.xy, position.z);
}

static inline float4 activation_from_light(
    float4 light, const device float *configuration,
    texture2d<float, access::read> curves) {
    return activation_from_log(stored_log_exposure(light), configuration, curves);
}

// transform: 0 identity, 1 activation, 2 released inhibitor, 3 transmittance.
static inline float4 transformed(
    float4 value, uint transform, const device float *configuration,
    texture2d<float, access::read> curves) {
    if (transform == 0u) return value;
    if (transform == 3u) return float4(exp(-value.rgb * kLn10), value.a);
    float4 activation = activation_from_light(value, configuration, curves);
    if (transform == 1u) return activation;
    // Released inhibitor is another explicit f16 store in the canonical graph. Preserve it
    // even when transform and consumer are fused into one kernel.
    return float4(half4(
        inhibitor_release(activation.x, configuration[kCouplerReleaseGamma]),
        inhibitor_release(activation.y, configuration[kCouplerReleaseGamma + 1u]),
        inhibitor_release(activation.z, configuration[kCouplerReleaseGamma + 2u]),
        inhibitor_release(activation.w, configuration[kDonorReleaseGamma])));
}

kernel void fotufilm_spatial_copy(
    texture2d<half, access::read> source [[texture(0)]],
    texture2d<half, access::write> destination [[texture(1)]],
    constant CopyParameters &p [[buffer(0)]],
    constant float4 &flare_mean [[buffer(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (any(position >= p.extent.xy)) return;
    float4 value = float4(source.read(position));
    float flare = as_type<float>(p.extent.z);
    value.rgb = (1.0f - flare) * value.rgb + flare * flare_mean.rgb;
    destination.write(half4(value), position);
}

kernel void fotufilm_spatial_transform(
    texture2d<half, access::read> source [[texture(0)]],
    texture2d<half, access::write> destination [[texture(1)]],
    texture2d<float, access::read> curves [[texture(2)]],
    const device float *configuration [[buffer(0)]],
    constant SpatialParameters &p [[buffer(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (any(position >= p.extent.xy)) return;
    destination.write(half4(transformed(
        float4(source.read(position)), p.geometry.x, configuration, curves)), position);
}

kernel void fotufilm_spatial_downsample(
    texture2d<half, access::read> source [[texture(0)]],
    texture2d<half, access::write> destination [[texture(1)]],
    texture2d<float, access::read> curves [[texture(2)]],
    const device float *configuration [[buffer(0)]],
    constant SpatialParameters &p [[buffer(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (any(position >= p.extent.zw)) return;
    int stride = int(p.geometry.x);
    int2 start = int2(position) * stride - int2(p.geometry.yz);
    float4 sum = 0.0f;
    uint count = 0u;
    for (int y = 0; y < stride; ++y) {
        for (int x = 0; x < stride; ++x) {
            int2 sample = start + int2(x, y);
            if (all(sample >= 0) && all(uint2(sample) < p.extent.xy)) {
                sum += transformed(float4(source.read(uint2(sample))), p.geometry.w,
                                   configuration, curves);
                ++count;
            }
        }
    }
    destination.write(half4(sum / float(max(count, 1u))), position);
}

kernel void fotufilm_spatial_pyramid_down_pair(
    texture2d<half, access::read> source [[texture(0)]],
    texture2d<half, access::write> destination0 [[texture(1)]],
    texture2d<half, access::write> destination1 [[texture(2)]],
    constant SpatialParameters &p [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]) {
    if (any(position >= p.extent.zw)) return;
    int factor = int(p.geometry.x);
    int2 start = int2(position) * factor;
    float4 sum = 0.0f;
    uint count = 0u;
    for (int y = 0; y < factor; ++y) {
        for (int x = 0; x < factor; ++x) {
            int2 sample = start + int2(x, y);
            if (all(sample >= 0) && all(uint2(sample) < p.extent.xy)) {
                sum += float4(source.read(uint2(sample)));
                ++count;
            }
        }
    }
    half4 stored = half4(sum / float(max(count, 1u)));
    destination0.write(stored, position);
    destination1.write(stored, position);
}

kernel void fotufilm_spatial_blur_horizontal(
    texture2d<half, access::read> source [[texture(0)]],
    texture2d<half, access::write> destination [[texture(1)]],
    texture2d<float, access::read> curves [[texture(2)]],
    const device half4 *weights [[buffer(0)]],
    const device float *configuration [[buffer(1)]],
    constant SpatialParameters &p [[buffer(2)]],
    uint2 position [[thread_position_in_grid]]) {
    if (any(position >= p.extent.xy)) return;
    int radius = int(p.geometry.x);
    float4 sum = 0.0f;
    float4 normalization = 0.0f;
    for (int tap = -radius; tap <= radius; ++tap) {
        int x = int(position.x) + tap;
        if (x < 0 || x >= int(p.extent.x)) continue;
        float4 weight = float4(weights[tap + radius]);
        float4 value = transformed(float4(source.read(uint2(x, position.y))),
                                   p.geometry.y, configuration, curves);
        sum += value * weight;
        normalization += weight;
    }
    destination.write(half4(sum / max(normalization, 1.0e-12f)), position);
}

kernel void fotufilm_spatial_blur_vertical(
    texture2d<half, access::read> source [[texture(0)]],
    texture2d<half, access::write> destination [[texture(1)]],
    const device half4 *weights [[buffer(0)]],
    constant SpatialParameters &p [[buffer(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (any(position >= p.extent.xy)) return;
    int radius = int(p.geometry.x);
    float4 sum = 0.0f;
    float4 normalization = 0.0f;
    for (int tap = -radius; tap <= radius; ++tap) {
        int y = int(position.y) + tap;
        if (y < 0 || y >= int(p.extent.y)) continue;
        float4 weight = float4(weights[tap + radius]);
        sum += float4(source.read(uint2(position.x, y))) * weight;
        normalization += weight;
    }
    destination.write(half4(sum / max(normalization, 1.0e-12f)), position);
}

/// Exact horizontal half-accumulator pass for large reduced-radius filters. Unlike the fused
/// square tile, its threadgroup footprint grows in only one dimension with the radius.
kernel void fotufilm_spatial_tiled_blur_horizontal(
    texture2d<half, access::read> source [[texture(0)]],
    texture2d<half, access::write> destination [[texture(1)]],
    const device half4 *weights [[buffer(0)]],
    constant SpatialParameters &p [[buffer(1)]],
    threadgroup half4 *sourceRows [[threadgroup(0)]],
    uint2 group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]]) {
    constexpr int tileSize = 16;
    constexpr int threadCount = tileSize * tileSize;
    const int paddedWidth = tileSize + 2 * SPECIALIZED_RADIUS;
    int2 tileOrigin = int2(group) * tileSize;

    for (int cell = int(lane); cell < paddedWidth * tileSize;
         cell += threadCount) {
        int2 local = int2(cell % paddedWidth, cell / paddedWidth);
        int2 frame = tileOrigin + int2(local.x - SPECIALIZED_RADIUS, local.y);
        sourceRows[cell] = all(frame >= 0) && all(uint2(frame) < p.extent.xy)
            ? source.read(uint2(frame)) : half4(0.0h);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int localX = int(lane) % tileSize;
    int localY = int(lane) / tileSize;
    uint2 position = uint2(tileOrigin + int2(localX, localY));
    if (any(position >= p.extent.xy)) return;
    half4 sum = 0.0h;
    float4 normalization = 0.0f;
    for (int tap = -SPECIALIZED_RADIUS; tap <= SPECIALIZED_RADIUS; ++tap) {
        int sampleX = int(position.x) + tap;
        if (sampleX < 0 || sampleX >= int(p.extent.x)) continue;
        half4 weight = weights[tap + SPECIALIZED_RADIUS];
        sum += sourceRows[localY * paddedWidth
            + localX + SPECIALIZED_RADIUS + tap] * weight;
        normalization += float4(weight);
    }
    destination.write(
        half4(float4(sum) / max(normalization, 1.0e-12f)), position);
}

/// Exact vertical half-accumulator pass paired with the horizontal kernel above. The
/// intermediate texture write is intentional: it preserves the canonical f16 seam.
kernel void fotufilm_spatial_tiled_blur_vertical(
    texture2d<half, access::read> source [[texture(0)]],
    texture2d<half, access::write> destination [[texture(1)]],
    const device half4 *weights [[buffer(0)]],
    constant SpatialParameters &p [[buffer(1)]],
    threadgroup half4 *sourceColumns [[threadgroup(0)]],
    uint2 group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]]) {
    constexpr int tileSize = 16;
    constexpr int threadCount = tileSize * tileSize;
    const int paddedHeight = tileSize + 2 * SPECIALIZED_RADIUS;
    int2 tileOrigin = int2(group) * tileSize;

    for (int cell = int(lane); cell < tileSize * paddedHeight;
         cell += threadCount) {
        int2 local = int2(cell % tileSize, cell / tileSize);
        int2 frame = tileOrigin + int2(local.x, local.y - SPECIALIZED_RADIUS);
        sourceColumns[cell] = all(frame >= 0) && all(uint2(frame) < p.extent.xy)
            ? source.read(uint2(frame)) : half4(0.0h);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int localX = int(lane) % tileSize;
    int localY = int(lane) / tileSize;
    uint2 position = uint2(tileOrigin + int2(localX, localY));
    if (any(position >= p.extent.xy)) return;
    half4 sum = 0.0h;
    float4 normalization = 0.0f;
    for (int tap = -SPECIALIZED_RADIUS; tap <= SPECIALIZED_RADIUS; ++tap) {
        int sampleY = int(position.y) + tap;
        if (sampleY < 0 || sampleY >= int(p.extent.y)) continue;
        half4 weight = weights[tap + SPECIALIZED_RADIUS];
        sum += sourceColumns[(localY + SPECIALIZED_RADIUS + tap) * tileSize
            + localX] * weight;
        normalization += float4(weight);
    }
    destination.write(
        half4(float4(sum) / max(normalization, 1.0e-12f)), position);
}

kernel void fotufilm_spatial_fused_blur(
    texture2d<half, access::read> source [[texture(0)]],
    texture2d<half, access::write> destination [[texture(1)]],
    const device half4 *weights [[buffer(0)]],
    constant SpatialParameters &p [[buffer(1)]],
    threadgroup half4 *scratch [[threadgroup(0)]],
    uint2 group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]]) {
    constexpr int tileSize = 16;
    const int padded = tileSize + 2 * SPECIALIZED_RADIUS;
    threadgroup half4 *sourceTile = scratch;
    threadgroup half4 *horizontalRows = sourceTile + padded * padded;
    int2 tileOrigin = int2(group) * tileSize;

    for (int cell = int(lane); cell < padded * padded;
         cell += tileSize * tileSize) {
        int2 local = int2(cell % padded, cell / padded);
        int2 frame = tileOrigin - SPECIALIZED_RADIUS + local;
        sourceTile[cell] = all(frame >= 0) && all(uint2(frame) < p.extent.xy)
            ? source.read(uint2(frame)) : half4(0.0h);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (int cell = int(lane); cell < tileSize * padded;
         cell += tileSize * tileSize) {
        int localX = cell % tileSize;
        int localY = cell / tileSize;
        int frameX = tileOrigin.x + localX;
        int frameY = tileOrigin.y - SPECIALIZED_RADIUS + localY;
        half4 sum = 0.0h;
        float4 normalization = 0.0f;
        if (frameX >= 0 && frameX < int(p.extent.x)
                && frameY >= 0 && frameY < int(p.extent.y)) {
            for (int tap = -SPECIALIZED_RADIUS;
                 tap <= SPECIALIZED_RADIUS; ++tap) {
                int sampleX = frameX + tap;
                if (sampleX < 0 || sampleX >= int(p.extent.x)) continue;
                half4 weight = weights[tap + SPECIALIZED_RADIUS];
                sum += sourceTile[localY * padded
                    + localX + SPECIALIZED_RADIUS + tap] * weight;
                normalization += float4(weight);
            }
        }
        horizontalRows[cell] = half4(
            float4(sum) / max(normalization, 1.0e-12f));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int localX = int(lane) % tileSize;
    int localY = int(lane) / tileSize;
    uint2 position = uint2(tileOrigin + int2(localX, localY));
    if (any(position >= p.extent.xy)) return;
    half4 sum = 0.0h;
    float4 normalization = 0.0f;
    for (int tap = -SPECIALIZED_RADIUS; tap <= SPECIALIZED_RADIUS; ++tap) {
        int sampleY = int(position.y) + tap;
        if (sampleY < 0 || sampleY >= int(p.extent.y)) continue;
        half4 weight = weights[tap + SPECIALIZED_RADIUS];
        sum += horizontalRows[(localY + SPECIALIZED_RADIUS + tap) * tileSize
            + localX] * weight;
        normalization += float4(weight);
    }
    destination.write(
        half4(float4(sum) / max(normalization, 1.0e-12f)), position);
}

/// Compact variant for the PRO grids: all source reads finish before the horizontal results
/// overwrite the first 15 cells of each captured row. Radius 15 then consumes 16,200 bytes,
/// small enough for two resident allocations in a 32 KiB threadgroup-memory budget.
kernel void fotufilm_spatial_fused_blur_compact15(
    texture2d<half, access::read> source [[texture(0)]],
    texture2d<half, access::write> destination [[texture(1)]],
    const device half4 *weights [[buffer(0)]],
    constant SpatialParameters &p [[buffer(1)]],
    threadgroup half4 *sourceTile [[threadgroup(0)]],
    uint2 group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]]) {
    constexpr int tileSize = 15;
    constexpr int threadCount = tileSize * tileSize;
    const int padded = tileSize + 2 * SPECIALIZED_RADIUS;
    int2 tileOrigin = int2(group) * tileSize;

    for (int cell = int(lane); cell < padded * padded; cell += threadCount) {
        int2 local = int2(cell % padded, cell / padded);
        int2 frame = tileOrigin - SPECIALIZED_RADIUS + local;
        sourceTile[cell] = all(frame >= 0) && all(uint2(frame) < p.extent.xy)
            ? source.read(uint2(frame)) : half4(0.0h);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // No supported compact radius needs more than eight row results per lane under the
    // device-memory guard in preparation (padded <= 64 on a 32 KiB device).
    half4 rowResult[8];
    int resultCount = 0;
    const int horizontalCells = tileSize * padded;
    for (int cell = int(lane); cell < horizontalCells; cell += threadCount) {
        int localX = cell % tileSize;
        int localY = cell / tileSize;
        int frameX = tileOrigin.x + localX;
        int frameY = tileOrigin.y - SPECIALIZED_RADIUS + localY;
        half4 sum = 0.0h;
        float4 normalization = 0.0f;
        if (frameX >= 0 && frameX < int(p.extent.x)
                && frameY >= 0 && frameY < int(p.extent.y)) {
            for (int tap = -SPECIALIZED_RADIUS;
                 tap <= SPECIALIZED_RADIUS; ++tap) {
                int sampleX = frameX + tap;
                if (sampleX < 0 || sampleX >= int(p.extent.x)) continue;
                half4 weight = weights[tap + SPECIALIZED_RADIUS];
                sum += sourceTile[localY * padded
                    + localX + SPECIALIZED_RADIUS + tap] * weight;
                normalization += float4(weight);
            }
        }
        rowResult[resultCount++] = half4(
            float4(sum) / max(normalization, 1.0e-12f));
    }
    // Every source cell is dead after this point. The barrier is what makes overwriting rows
    // independent of SIMD-group progress.
    threadgroup_barrier(mem_flags::mem_threadgroup);
    resultCount = 0;
    for (int cell = int(lane); cell < horizontalCells; cell += threadCount) {
        int localX = cell % tileSize;
        int localY = cell / tileSize;
        sourceTile[localY * padded + localX] = rowResult[resultCount++];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int localX = int(lane) % tileSize;
    int localY = int(lane) / tileSize;
    uint2 position = uint2(tileOrigin + int2(localX, localY));
    if (any(position >= p.extent.xy)) return;
    half4 sum = 0.0h;
    float4 normalization = 0.0f;
    for (int tap = -SPECIALIZED_RADIUS; tap <= SPECIALIZED_RADIUS; ++tap) {
        int sampleY = int(position.y) + tap;
        if (sampleY < 0 || sampleY >= int(p.extent.y)) continue;
        half4 weight = weights[tap + SPECIALIZED_RADIUS];
        sum += sourceTile[(localY + SPECIALIZED_RADIUS + tap) * padded + localX]
            * weight;
        normalization += float4(weight);
    }
    destination.write(
        half4(float4(sum) / max(normalization, 1.0e-12f)), position);
}

static inline float4 grid_read(
    texture2d<half, access::read> grid, int2 coordinate, uint2 extent,
    thread float &valid) {
    if (any(coordinate < 0) || any(uint2(coordinate) >= extent)) {
        valid = 0.0f;
        return 0.0f;
    }
    valid = 1.0f;
    return float4(grid.read(uint2(coordinate)));
}

static inline float4 grid_sample_sum(
    texture2d<half, access::read> grid, float2 coordinate, uint2 extent,
    thread float &normalization) {
    int2 low = int2(floor(coordinate));
    float2 f = coordinate - floor(coordinate);
    float weights[4] = {
        (1.0f - f.x) * (1.0f - f.y), f.x * (1.0f - f.y),
        (1.0f - f.x) * f.y, f.x * f.y
    };
    int2 offsets[4] = { int2(0), int2(1, 0), int2(0, 1), int2(1) };
    float4 sum = 0.0f;
    normalization = 0.0f;
    for (uint index = 0; index < 4u; ++index) {
        float valid;
        sum += grid_read(grid, low + offsets[index], extent, valid) * weights[index];
        normalization += valid * weights[index];
    }
    return sum;
}

static inline float4 grid_sample(
    texture2d<half, access::read> grid, float2 coordinate, uint2 extent) {
    float normalization;
    float4 sum = grid_sample_sum(grid, coordinate, extent, normalization);
    return sum / max(normalization, 1.0e-12f);
}

static inline float4 annular_sample(
    texture2d<half, access::read> grid, float2 coordinate, uint2 extent,
    float radius) {
    if (radius <= 1.0e-4f) return grid_sample(grid, coordinate, extent);
    constexpr float2 direction[16] = {
        float2(1,0), float2(0.923879533f,0.382683432f),
        float2(0.707106781f,0.707106781f), float2(0.382683432f,0.923879533f),
        float2(0,1), float2(-0.382683432f,0.923879533f),
        float2(-0.707106781f,0.707106781f), float2(-0.923879533f,0.382683432f),
        float2(-1,0), float2(-0.923879533f,-0.382683432f),
        float2(-0.707106781f,-0.707106781f), float2(-0.382683432f,-0.923879533f),
        float2(0,-1), float2(0.382683432f,-0.923879533f),
        float2(0.707106781f,-0.707106781f), float2(0.923879533f,-0.382683432f)
    };
    float4 sum = 0.0f;
    float normalization = 0.0f;
    for (uint index = 0; index < 16u; ++index) {
        float sampleNormalization;
        sum += grid_sample_sum(
            grid, coordinate + radius * direction[index], extent,
            sampleNormalization);
        normalization += sampleNormalization;
    }
    return sum / max(normalization, 1.0e-12f);
}

kernel void fotufilm_spatial_finish_pyramid(
    texture2d<half, access::read> source [[texture(0)]],
    texture2d<half, access::read> scale0 [[texture(1)]],
    texture2d<half, access::read> scale1 [[texture(2)]],
    texture2d<half, access::read> scale2 [[texture(3)]],
    texture2d<half, access::write> destination [[texture(4)]],
    const device float *configuration [[buffer(0)]],
    constant PyramidParameters &p [[buffer(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (any(position >= p.extent.xy)) return;
    float2 point = float2(position) + 0.5f;
    float2 coordinate0 = point / float(p.strides.x) - 0.5f;
    float2 coordinate1 = point / float(p.strides.y) - 0.5f;
    float2 coordinate2 = point / float(p.strides.z) - 0.5f;
    bool annular = p.strides.w != 0u;
    float4 blurred0 = annular
        ? annular_sample(scale0, coordinate0, p.grid0.xy,
                         p.rings.x / float(p.strides.x))
        : grid_sample(scale0, coordinate0, p.grid0.xy);
    float4 blurred1 = annular
        ? annular_sample(scale1, coordinate1, p.grid1.xy,
                         p.rings.y / float(p.strides.y))
        : grid_sample(scale1, coordinate1, p.grid1.xy);
    float4 blurred2 = annular
        ? annular_sample(scale2, coordinate2, p.grid2.xy,
                         p.rings.z / float(p.strides.z))
        : grid_sample(scale2, coordinate2, p.grid2.xy);
    float4 direct = float4(source.read(position));
    if (p.extent.z == 0u) {
        float4 diffused;
        for (uint channel = 0u; channel < 4u; ++channel) {
            if (channel == 3u && p.extent.w == 0u) {
                diffused.w = direct.w;
                continue;
            }
            uint kernelBase = channel == 3u
                ? kDonorDiffusionKernel : kDiffusionKernel + channel * 3u;
            diffused[channel] = configuration[kDiffusionDirect] * direct[channel]
                + configuration[kernelBase] * blurred0[channel]
                + configuration[kernelBase + 1u] * blurred1[channel]
                + configuration[kernelBase + 2u] * blurred2[channel];
        }
        destination.write(half4(diffused), position);
        return;
    }
    float3 returned;
    for (uint channel = 0u; channel < 3u; ++channel) {
        uint kernelBase = kHalationKernel + channel * 3u;
        returned[channel] = configuration[kernelBase] * blurred0[channel]
            + configuration[kernelBase + 1u] * blurred1[channel]
            + configuration[kernelBase + 2u] * blurred2[channel]
            - direct[channel];
    }
    // The canonical graph materializes the returned-light field in half storage before the
    // 3x3 channel matrix. Preserve that seam while fusing the two full-frame dispatches.
    float3 returnedStored = float3(half3(returned));
    float3 halated;
    for (uint channel = 0u; channel < 3u; ++channel) {
        uint row = kHalationMatrix + channel * 3u;
        halated[channel] = direct[channel]
            + dot(float3(configuration[row], configuration[row + 1u],
                         configuration[row + 2u]), returnedStored);
    }
    destination.write(half4(half3(max(halated, 0.0f)), half(direct.w)), position);
}

static inline float4 threadgroup_grid_sample(
    threadgroup half4 *tile, int span, int2 base,
    float2 coordinate, uint2 extent) {
    int2 low = int2(floor(coordinate));
    float2 fraction = coordinate - floor(coordinate);
    float weights[4] = {
        (1.0f - fraction.x) * (1.0f - fraction.y),
        fraction.x * (1.0f - fraction.y),
        (1.0f - fraction.x) * fraction.y,
        fraction.x * fraction.y
    };
    constexpr int2 offsets[4] = {
        int2(0), int2(1, 0), int2(0, 1), int2(1)
    };
    float4 sum = 0.0f;
    float normalization = 0.0f;
    for (uint index = 0u; index < 4u; ++index) {
        int2 sample = low + offsets[index];
        if (any(sample < 0) || any(uint2(sample) >= extent)) continue;
        int2 local = sample - base;
        if (any(local < 0) || any(local >= span)) continue;
        sum += float4(tile[local.y * span + local.x]) * weights[index];
        normalization += weights[index];
    }
    return sum / max(normalization, 1.0e-12f);
}

kernel void fotufilm_spatial_finish_fields(
    texture2d<half, access::read_write> directLog [[texture(0)]],
    texture2d<half, access::read> scale0 [[texture(1)]],
    texture2d<half, access::read> scale1 [[texture(2)]],
    texture2d<half, access::read> scale2 [[texture(3)]],
    texture2d<half, access::write> couplerRaw [[texture(4)]],
    texture2d<half, access::write> adjacencyRaw [[texture(5)]],
    texture2d<float, access::read> curves [[texture(6)]],
    texture2d_array<float, access::read> halfResponse [[texture(7)]],
    const device float *configuration [[buffer(0)]],
    constant FastFinishParameters &p [[buffer(1)]],
    threadgroup float4 *scratch [[threadgroup(0)]],
    uint2 group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]]) {
    constexpr int tileSize = 16;
    constexpr int scale0Span = 6;
    constexpr int scale1Span = 4;
    constexpr int scale2Span = 4;
    threadgroup float4 *activationTile = scratch;
    threadgroup half4 *releasedTile =
        reinterpret_cast<threadgroup half4 *>(activationTile + tileSize * tileSize);
    threadgroup half4 *scale0Tile = releasedTile + tileSize * tileSize;
    threadgroup half4 *scale1Tile = scale0Tile + scale0Span * scale0Span;
    threadgroup half4 *scale2Tile = scale1Tile + scale1Span * scale1Span;
    int2 tileOrigin = int2(group) * tileSize;
    int2 scale0Base = int2(group) * (tileSize / int(p.strides.x)) - 1;
    int2 scale1Base = int2(group) * (tileSize / int(p.strides.y)) - 1;
    int2 scale2Base = int2(group) * (tileSize / int(p.strides.z)) - 1;

    for (int cell = int(lane); cell < scale0Span * scale0Span;
         cell += tileSize * tileSize) {
        int2 local = int2(cell % scale0Span, cell / scale0Span);
        int2 sample = scale0Base + local;
        scale0Tile[cell] = all(sample >= 0) && all(uint2(sample) < p.grid0.xy)
            ? scale0.read(uint2(sample)) : half4(0.0h);
    }
    for (int cell = int(lane); cell < scale1Span * scale1Span;
         cell += tileSize * tileSize) {
        int2 local = int2(cell % scale1Span, cell / scale1Span);
        int2 sample = scale1Base + local;
        scale1Tile[cell] = all(sample >= 0) && all(uint2(sample) < p.grid1.xy)
            ? scale1.read(uint2(sample)) : half4(0.0h);
    }
    for (int cell = int(lane); cell < scale2Span * scale2Span;
         cell += tileSize * tileSize) {
        int2 local = int2(cell % scale2Span, cell / scale2Span);
        int2 sample = scale2Base + local;
        scale2Tile[cell] = all(sample >= 0) && all(uint2(sample) < p.grid2.xy)
            ? scale2.read(uint2(sample)) : half4(0.0h);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int localX = int(lane) % tileSize;
    int localY = int(lane) / tileSize;
    uint2 position = uint2(tileOrigin + int2(localX, localY));
    bool valid = all(position < p.extent.xy);
    float4 activation = 0.0f;
    half4 released = 0.0h;
    if (valid) {
        float2 point = float2(position) + 0.5f;
        float4 blurred0 = threadgroup_grid_sample(
            scale0Tile, scale0Span, scale0Base,
            point / float(p.strides.x) - 0.5f, p.grid0.xy);
        float4 blurred1 = threadgroup_grid_sample(
            scale1Tile, scale1Span, scale1Base,
            point / float(p.strides.y) - 0.5f, p.grid1.xy);
        float4 blurred2 = threadgroup_grid_sample(
            scale2Tile, scale2Span, scale2Base,
            point / float(p.strides.z) - 0.5f, p.grid2.xy);
        float4 direct = float4(directLog.read(position));
        float3 returned;
        for (uint channel = 0u; channel < 3u; ++channel) {
            uint kernelBase = kHalationKernel + channel * 3u;
            returned[channel] = configuration[kernelBase] * blurred0[channel]
                + configuration[kernelBase + 1u] * blurred1[channel]
                + configuration[kernelBase + 2u] * blurred2[channel]
                - direct[channel];
        }
        float3 returnedStored = float3(half3(returned));
        float3 halated;
        for (uint channel = 0u; channel < 3u; ++channel) {
            uint row = kHalationMatrix + channel * 3u;
            halated[channel] = direct[channel]
                + dot(float3(configuration[row], configuration[row + 1u],
                             configuration[row + 2u]), returnedStored);
        }
        float4 logarithmic = stored_log_exposure(
            float4(max(halated, 0.0f), direct.w));
        half4 logarithmicStored = half4(logarithmic);
        directLog.write(logarithmicStored, position);
        if (USE_HALF_RESPONSE_LUT) {
            float2 red = half_response(halfResponse, logarithmicStored.x, 0u);
            float2 green = half_response(halfResponse, logarithmicStored.y, 1u);
            float2 blue = half_response(halfResponse, logarithmicStored.z, 2u);
            float2 donor = half_response(halfResponse, logarithmicStored.w, 3u);
            activation = float4(red.x, green.x, blue.x, donor.x);
            released = half4(red.y, green.y, blue.y, donor.y);
        } else {
            activation = activation_from_log(logarithmic, configuration, curves);
            released = half4(
                inhibitor_release(activation.x, configuration[kCouplerReleaseGamma]),
                inhibitor_release(activation.y, configuration[kCouplerReleaseGamma + 1u]),
                inhibitor_release(activation.z, configuration[kCouplerReleaseGamma + 2u]),
                inhibitor_release(activation.w, configuration[kDonorReleaseGamma]));
        }
    }
    activationTile[lane] = activation;
    releasedTile[lane] = released;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int couplerStride = int(p.coupler.z);
    int couplerTile = tileSize / couplerStride;
    if (localX < couplerTile && localY < couplerTile) {
        uint2 output = group * uint(couplerTile) + uint2(localX, localY);
        if (all(output < p.coupler.xy)) {
            float4 sum = 0.0f;
            uint count = 0u;
            for (int y = 0; y < couplerStride; ++y) {
                for (int x = 0; x < couplerStride; ++x) {
                    int sourceX = localX * couplerStride + x;
                    int sourceY = localY * couplerStride + y;
                    uint2 frame = uint2(tileOrigin + int2(sourceX, sourceY));
                    if (all(frame < p.extent.xy)) {
                        sum += float4(releasedTile[sourceY * tileSize + sourceX]);
                        ++count;
                    }
                }
            }
            couplerRaw.write(half4(sum / float(max(count, 1u))), output);
        }
    }

    int adjacencyStride = int(p.adjacency.z);
    int adjacencyTile = tileSize / adjacencyStride;
    if (localX < adjacencyTile && localY < adjacencyTile) {
        uint2 output = group * uint(adjacencyTile) + uint2(localX, localY);
        if (all(output < p.adjacency.xy)) {
            float4 sum = 0.0f;
            uint count = 0u;
            for (int y = 0; y < adjacencyStride; ++y) {
                for (int x = 0; x < adjacencyStride; ++x) {
                    int sourceX = localX * adjacencyStride + x;
                    int sourceY = localY * adjacencyStride + y;
                    uint2 frame = uint2(tileOrigin + int2(sourceX, sourceY));
                    if (all(frame < p.extent.xy)) {
                        sum += activationTile[sourceY * tileSize + sourceX];
                        ++count;
                    }
                }
            }
            adjacencyRaw.write(half4(sum / float(max(count, 1u))), output);
        }
    }
}

/// Halation is an additive light field whose narrowest authored support is wider than the
/// half-grid reconstruction filter. Store only that smooth correction here; full-rate direct
/// light is deliberately left untouched for the final developer. Activation and release are
/// still evaluated for all four covered pixels before their independent half stores.
kernel void fotufilm_spatial_multires_finish(
    texture2d<half, access::read> directLight [[texture(0)]],
    texture2d<half, access::read> scale0 [[texture(1)]],
    texture2d<half, access::read> scale1 [[texture(2)]],
    texture2d<half, access::read> scale2 [[texture(3)]],
    texture2d<half, access::write> correction [[texture(4)]],
    texture2d<half, access::write> activation [[texture(5)]],
    texture2d_array<float, access::read> halfResponse [[texture(6)]],
    texture2d<half, access::write> released [[texture(7)]],
    const device float *configuration [[buffer(0)]],
    constant FastFinishParameters &p [[buffer(1)]],
    threadgroup half4 *scratch [[threadgroup(0)]],
    uint2 group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]]) {
    constexpr int tileSize = 16;
    constexpr int scale0Span = 10;
    constexpr int scale1Span = 6;
    constexpr int scale2Span = 6;
    threadgroup half4 *scale0Tile = scratch;
    threadgroup half4 *scale1Tile = scale0Tile + scale0Span * scale0Span;
    threadgroup half4 *scale2Tile = scale1Tile + scale1Span * scale1Span;
    int2 scale0Base = int2(group)
        * (tileSize * int(p.adjacency.z) / int(p.strides.x)) - 1;
    int2 scale1Base = int2(group)
        * (tileSize * int(p.adjacency.z) / int(p.strides.y)) - 1;
    int2 scale2Base = int2(group)
        * (tileSize * int(p.adjacency.z) / int(p.strides.z)) - 1;

    for (int cell = int(lane); cell < scale0Span * scale0Span;
         cell += tileSize * tileSize) {
        int2 local = int2(cell % scale0Span, cell / scale0Span);
        int2 source = scale0Base + local;
        scale0Tile[cell] = all(source >= 0) && all(uint2(source) < p.grid0.xy)
            ? scale0.read(uint2(source)) : half4(0.0h);
    }
    for (int cell = int(lane); cell < scale1Span * scale1Span;
         cell += tileSize * tileSize) {
        int2 local = int2(cell % scale1Span, cell / scale1Span);
        int2 source = scale1Base + local;
        scale1Tile[cell] = all(source >= 0) && all(uint2(source) < p.grid1.xy)
            ? scale1.read(uint2(source)) : half4(0.0h);
    }
    for (int cell = int(lane); cell < scale2Span * scale2Span;
         cell += tileSize * tileSize) {
        int2 local = int2(cell % scale2Span, cell / scale2Span);
        int2 source = scale2Base + local;
        scale2Tile[cell] = all(source >= 0) && all(uint2(source) < p.grid2.xy)
            ? scale2.read(uint2(source)) : half4(0.0h);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int localX = int(lane) % tileSize;
    int localY = int(lane) / tileSize;
    uint2 position = group * uint(tileSize) + uint2(localX, localY);
    if (any(position >= p.adjacency.xy)) return;

    uint stride = p.adjacency.z;
    uint2 first = position * stride;
    constexpr uint2 sampleOffsets[4] = {
        uint2(0u, 0u), uint2(1u, 0u), uint2(0u, 1u), uint2(1u, 1u)
    };
    float4 directSamples[4];
    for (uint sample = 0u; sample < 4u; ++sample) {
        directSamples[sample] = float4(
            directLight.read(first + sampleOffsets[sample]));
    }

    // The point is the centre of the covered full-resolution block. Scale zero therefore
    // lands on an integer sample; the two stride-eight bands retain canonical bilinear phase.
    float2 point = float2(first) + 0.5f * float(stride);
    float4 blurred0 = threadgroup_grid_sample(
        scale0Tile, scale0Span, scale0Base,
        point / float(p.strides.x) - 0.5f, p.grid0.xy);
    float4 blurred1 = threadgroup_grid_sample(
        scale1Tile, scale1Span, scale1Base,
        point / float(p.strides.y) - 0.5f, p.grid1.xy);
    float4 blurred2 = threadgroup_grid_sample(
        scale2Tile, scale2Span, scale2Base,
        point / float(p.strides.z) - 0.5f, p.grid2.xy);
    float3 weighted;
    for (uint channel = 0u; channel < 3u; ++channel) {
        uint base = kHalationKernel + channel * 3u;
        weighted[channel] = configuration[base] * blurred0[channel]
            + configuration[base + 1u] * blurred1[channel]
            + configuration[base + 2u] * blurred2[channel];
    }
    // Preserve the smooth pre-return light, not an already mixed correction. The developer
    // subtracts each full-rate direct pixel before the canonical half seam, so the local
    // `-matrix * direct` term never gets blurred by reduced-grid reconstruction.
    correction.write(half4(half3(weighted), 0.0h), position);

    float4 activationSum = 0.0f;
    float4 releasedSum = 0.0f;
    for (uint sample = 0u; sample < 4u; ++sample) {
        float2 samplePoint = float2(first + sampleOffsets[sample]) + 0.5f;
        float4 sampleBlurred0 = threadgroup_grid_sample(
            scale0Tile, scale0Span, scale0Base,
            samplePoint / float(p.strides.x) - 0.5f, p.grid0.xy);
        float4 sampleBlurred1 = threadgroup_grid_sample(
            scale1Tile, scale1Span, scale1Base,
            samplePoint / float(p.strides.y) - 0.5f, p.grid1.xy);
        float4 sampleBlurred2 = threadgroup_grid_sample(
            scale2Tile, scale2Span, scale2Base,
            samplePoint / float(p.strides.z) - 0.5f, p.grid2.xy);
        float3 sampleWeighted;
        for (uint channel = 0u; channel < 3u; ++channel) {
            uint base = kHalationKernel + channel * 3u;
            sampleWeighted[channel] =
                configuration[base] * sampleBlurred0[channel]
                + configuration[base + 1u] * sampleBlurred1[channel]
                + configuration[base + 2u] * sampleBlurred2[channel];
        }
        float3 returnedStored = float3(half3(
            sampleWeighted - directSamples[sample].rgb));
        float3 halated;
        for (uint channel = 0u; channel < 3u; ++channel) {
            uint row = kHalationMatrix + channel * 3u;
            halated[channel] = directSamples[sample][channel]
                + dot(float3(configuration[row], configuration[row + 1u],
                             configuration[row + 2u]), returnedStored);
        }
        half4 logarithmic = half4(stored_log_exposure(float4(
            max(halated, 0.0f), directSamples[sample].w)));
        float2 red = half_response(halfResponse, logarithmic.x, 0u);
        float2 green = half_response(halfResponse, logarithmic.y, 1u);
        float2 blue = half_response(halfResponse, logarithmic.z, 2u);
        float2 donor = half_response(halfResponse, logarithmic.w, 3u);
        activationSum += float4(red.x, green.x, blue.x, donor.x);
        releasedSum += float4(red.y, green.y, blue.y, donor.y);
    }
    activation.write(half4(activationSum * 0.25f), position);
    released.write(half4(releasedSum * 0.25f), position);
}

/// Blur half-rate activation and released inhibitor together. The coupler arm performs the
/// exact 2x2 reduction into its quarter grid inside each ordered convolution; adjacency stays
/// on its authored half grid. Both retain horizontal and vertical f16 seams.
kernel void fotufilm_spatial_multires_joint_fields(
    texture2d<half, access::read> activation [[texture(0)]],
    texture2d<half, access::read> released [[texture(1)]],
    texture2d<half, access::write> couplerField [[texture(2)]],
    texture2d<half, access::write> adjacencyField [[texture(3)]],
    const device half4 *couplerWeights [[buffer(0)]],
    const device half4 *adjacencyWeights [[buffer(1)]],
    const device float *configuration [[buffer(2)]],
    constant MultiresFieldParameters &p [[buffer(3)]],
    threadgroup half4 *scratch [[threadgroup(0)]],
    uint2 group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]]) {
    constexpr int tileSize = 16;
    constexpr int couplerTile = tileSize / 2;
    const int releaseRadius = 2 * FIELD_COUPLER_RADIUS;
    const int releasePadded = tileSize + 2 * releaseRadius;
    const int activationPadded = tileSize + 2 * FIELD_ADJACENCY_RADIUS;
    threadgroup half4 *releaseTile = scratch;
    threadgroup half4 *activationTile =
        releaseTile + releasePadded * releasePadded;
    threadgroup half4 *couplerRows =
        activationTile + activationPadded * activationPadded;
    threadgroup half4 *adjacencyRows =
        couplerRows + couplerTile * releasePadded;
    int2 tileOrigin = int2(group) * tileSize;

    for (int cell = int(lane); cell < releasePadded * releasePadded;
         cell += tileSize * tileSize) {
        int2 local = int2(cell % releasePadded, cell / releasePadded);
        int2 source = tileOrigin - releaseRadius + local;
        releaseTile[cell] = all(source >= 0)
                && all(uint2(source) < p.activationExtent.xy)
            ? released.read(uint2(source)) : half4(0.0h);
    }
    for (int cell = int(lane); cell < activationPadded * activationPadded;
         cell += tileSize * tileSize) {
        int2 local = int2(cell % activationPadded, cell / activationPadded);
        int2 source = tileOrigin - FIELD_ADJACENCY_RADIUS + local;
        activationTile[cell] = all(source >= 0)
                && all(uint2(source) < p.activationExtent.xy)
            ? activation.read(uint2(source)) : half4(0.0h);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (int cell = int(lane); cell < couplerTile * releasePadded;
         cell += tileSize * tileSize) {
        int localX = cell % couplerTile;
        int localY = cell / couplerTile;
        int quarterX = tileOrigin.x / 2 + localX;
        int frameY = tileOrigin.y - releaseRadius + localY;
        half4 couplerSum = 0.0h;
        float4 couplerNormalization = 0.0f;
        if (quarterX >= 0 && quarterX < int(p.couplerExtent.x)
                && frameY >= 0 && frameY < int(p.activationExtent.y)) {
            for (int tap = -FIELD_COUPLER_RADIUS;
                 tap <= FIELD_COUPLER_RADIUS; ++tap) {
                int sampleX = quarterX + tap;
                if (sampleX < 0 || sampleX >= int(p.couplerExtent.x)) continue;
                int sourceX = 2 * localX + releaseRadius + 2 * tap;
                half4 reduced = half4(0.5h) * (
                    releaseTile[localY * releasePadded + sourceX]
                    + releaseTile[localY * releasePadded + sourceX + 1]);
                half4 weight = couplerWeights[tap + FIELD_COUPLER_RADIUS];
                couplerSum += reduced * weight;
                couplerNormalization += float4(weight);
            }
        }
        couplerRows[cell] = half4(
            float4(couplerSum) / max(couplerNormalization, 1.0e-12f));
    }
    for (int cell = int(lane); cell < tileSize * activationPadded;
         cell += tileSize * tileSize) {
        int localX = cell % tileSize;
        int localY = cell / tileSize;
        int frameX = tileOrigin.x + localX;
        int frameY = tileOrigin.y - FIELD_ADJACENCY_RADIUS + localY;
        half4 adjacencySum = 0.0h;
        float4 adjacencyNormalization = 0.0f;
        if (frameX >= 0 && frameX < int(p.activationExtent.x)
                && frameY >= 0 && frameY < int(p.activationExtent.y)) {
            for (int tap = -FIELD_ADJACENCY_RADIUS;
                 tap <= FIELD_ADJACENCY_RADIUS; ++tap) {
                int sampleX = frameX + tap;
                if (sampleX < 0 || sampleX >= int(p.activationExtent.x)) continue;
                half4 weight = adjacencyWeights[tap + FIELD_ADJACENCY_RADIUS];
                adjacencySum += activationTile[
                    localY * activationPadded + localX
                        + FIELD_ADJACENCY_RADIUS + tap] * weight;
                adjacencyNormalization += float4(weight);
            }
        }
        adjacencyRows[cell] = half4(
            float4(adjacencySum) / max(adjacencyNormalization, 1.0e-12f));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int localX = int(lane) % tileSize;
    int localY = int(lane) / tileSize;
    uint2 position = uint2(tileOrigin + int2(localX, localY));
    if (all(position < p.activationExtent.xy)) {
        half4 adjacencySum = 0.0h;
        float4 adjacencyNormalization = 0.0f;
        for (int tap = -FIELD_ADJACENCY_RADIUS;
             tap <= FIELD_ADJACENCY_RADIUS; ++tap) {
            int sampleY = int(position.y) + tap;
            if (sampleY < 0 || sampleY >= int(p.activationExtent.y)) continue;
            half4 weight = adjacencyWeights[tap + FIELD_ADJACENCY_RADIUS];
            adjacencySum += adjacencyRows[
                (localY + FIELD_ADJACENCY_RADIUS + tap) * tileSize + localX]
                * weight;
            adjacencyNormalization += float4(weight);
        }
        adjacencyField.write(half4(
            float4(adjacencySum)
                / max(adjacencyNormalization, 1.0e-12f)), position);
    }
    if (localX < couplerTile && localY < couplerTile) {
        uint2 quarterPosition = uint2(tileOrigin / 2 + int2(localX, localY));
        if (all(quarterPosition < p.couplerExtent.xy)) {
            half4 couplerSum = 0.0h;
            float4 couplerNormalization = 0.0f;
            for (int tap = -FIELD_COUPLER_RADIUS;
                 tap <= FIELD_COUPLER_RADIUS; ++tap) {
                int sampleY = int(quarterPosition.y) + tap;
                if (sampleY < 0 || sampleY >= int(p.couplerExtent.y)) continue;
                int sourceY = 2 * localY + releaseRadius + 2 * tap;
                half4 reduced = half4(0.5h) * (
                    couplerRows[sourceY * couplerTile + localX]
                    + couplerRows[(sourceY + 1) * couplerTile + localX]);
                half4 weight = couplerWeights[tap + FIELD_COUPLER_RADIUS];
                couplerSum += reduced * weight;
                couplerNormalization += float4(weight);
            }
            couplerField.write(half4(
                float4(couplerSum)
                    / max(couplerNormalization, 1.0e-12f)), quarterPosition);
        }
    }
}

kernel void fotufilm_spatial_mtf(
    texture2d<half, access::read> light [[texture(0)]],
    texture2d<half, access::write> field [[texture(1)]],
    texture2d<half, access::write> scale0 [[texture(2)]],
    const device half *weights [[buffer(0)]],
    constant MTFParameters &p [[buffer(1)]],
    constant float4 &flare_mean [[buffer(2)]],
    threadgroup half *scratch [[threadgroup(0)]],
    uint2 group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]]) {
    const int tileSize = 16;
    const int padded = tileSize + 2 * SPECIALIZED_RADIUS;
    threadgroup half4 *tile = reinterpret_cast<threadgroup half4 *>(scratch);
    threadgroup half *rows = MTF_WIDE ? scratch
        : scratch + padded * padded * 4;
    threadgroup half4 *packedRows = reinterpret_cast<threadgroup half4 *>(rows);
    const device half4 *packedWeights =
        reinterpret_cast<const device half4 *>(weights);
    int2 tileOrigin = int2(group) * tileSize;
    float flare = as_type<float>(p.extent.z);
    const int channelCount = MTF_EXTENDED ? 7 : 3;

    if (!MTF_WIDE) {
        for (int cell = int(lane); cell < padded * padded; cell += tileSize * tileSize) {
            int2 cellPosition = int2(cell % padded, cell / padded);
            int2 frame = clamp(tileOrigin - SPECIALIZED_RADIUS + cellPosition,
                               int2(0), int2(p.extent.xy) - 1);
            float4 value = float4(light.read(uint2(frame)));
            value.rgb = (1.0f - flare) * value.rgb + flare * flare_mean.rgb;
            half fourth = MTF_EXTENDED
                ? half((value.x + value.y + value.z) / 3.0f)
                : half(value.a);
            tile[cell] = half4(half3(value.rgb), fourth);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int weightStride = 2 * SPECIALIZED_RADIUS + 1;
    for (int cell = int(lane); cell < tileSize * padded; cell += tileSize * tileSize) {
        int x = cell % tileSize;
        int y = cell / tileSize;
        int frameY = clamp(tileOrigin.y - SPECIALIZED_RADIUS + y, 0, int(p.extent.y) - 1);
        if (MTF_PACKED_PRIMARY) {
            half4 accumulated = 0.0h;
            for (int tap = -SPECIALIZED_RADIUS; tap <= SPECIALIZED_RADIUS; ++tap) {
                accumulated += tile[
                    y * padded + x + SPECIALIZED_RADIUS + tap]
                    * packedWeights[tap + SPECIALIZED_RADIUS];
            }
            packedRows[cell] = accumulated;
        } else {
            for (int channel = 0; channel < channelCount; ++channel) {
                int sourceChannel = channel < 4 ? channel : channel - 4;
                half accumulated = 0.0h;
                for (int tap = -SPECIALIZED_RADIUS; tap <= SPECIALIZED_RADIUS; ++tap) {
                    half value;
                    if (MTF_WIDE) {
                        int frameX = clamp(tileOrigin.x + x + tap, 0, int(p.extent.x) - 1);
                        float4 pixel = float4(light.read(uint2(frameX, frameY)));
                        pixel.rgb = (1.0f - flare) * pixel.rgb + flare * flare_mean.rgb;
                        value = sourceChannel == 3
                            ? half((pixel.x + pixel.y + pixel.z) / 3.0f)
                            : half(pixel[sourceChannel]);
                    } else {
                        value = tile[y * padded + x + SPECIALIZED_RADIUS][sourceChannel];
                    }
                    accumulated += value
                        * weights[(tap + SPECIALIZED_RADIUS) + channel * weightStride];
                }
                rows[(y * tileSize + x) * channelCount + channel] = accumulated;
            }
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int x = int(lane) % tileSize;
    int y = int(lane) / tileSize;
    uint2 output = uint2(tileOrigin + int2(x, y));
    bool outputValid = all(output < p.extent.xy);
    half4 storedOutput = 0.0h;
    if (outputValid) {
        float3 primary;
        if (MTF_PACKED_PRIMARY) {
            half4 accumulated = 0.0h;
            for (int tap = -SPECIALIZED_RADIUS; tap <= SPECIALIZED_RADIUS; ++tap) {
                accumulated += packedRows[
                    (y + SPECIALIZED_RADIUS + tap) * tileSize + x]
                    * packedWeights[tap + SPECIALIZED_RADIUS];
            }
            primary = float3(accumulated.rgb);
            if (MTF_EXTENDED) {
                float correction = p.shares.x
                    * (float(accumulated.w)
                        - (primary.x + primary.y + primary.z) / 3.0f);
                primary += correction;
            }
        } else {
            half blurred[7];
            for (int channel = 0; channel < channelCount; ++channel) {
                half accumulated = 0.0h;
                for (int tap = -SPECIALIZED_RADIUS; tap <= SPECIALIZED_RADIUS; ++tap) {
                    accumulated += rows[
                        ((y + SPECIALIZED_RADIUS + tap) * tileSize + x)
                            * channelCount + channel]
                        * weights[(tap + SPECIALIZED_RADIUS)
                            + channel * weightStride];
                }
                blurred[channel] = accumulated;
            }
            primary = float3(blurred[0], blurred[1], blurred[2]);
            if (MTF_EXTENDED) {
                float3 share = p.shares.yzw;
                primary = share * primary + (1.0f - share)
                    * float3(blurred[4], blurred[5], blurred[6]);
                float correction = p.shares.x
                    * (float(blurred[3])
                        - (primary.x + primary.y + primary.z) / 3.0f);
                primary += correction;
            }
        }
        half alpha = MTF_EXTENDED
            ? light.read(output).a
            : tile[(y + SPECIALIZED_RADIUS) * padded
                + x + SPECIALIZED_RADIUS].a;
        storedOutput = half4(half3(primary), alpha);
        field.write(storedOutput, output);
    }
    if (!MTF_DOWNSAMPLE) return;

    // The non-wide fast specialization no longer needs its source tile after the vertical
    // result. Reuse its first 16x16 cells for an exact row-major 4x4 reduction.
    threadgroup_barrier(mem_flags::mem_threadgroup);
    tile[lane] = storedOutput;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (x >= 4 || y >= 4) return;
    uint2 gridPosition = group * 4u + uint2(x, y);
    uint2 gridExtent = (p.extent.xy + 3u) / 4u;
    if (any(gridPosition >= gridExtent)) return;
    float4 sum = 0.0f;
    uint count = 0u;
    for (int row = 0; row < 4; ++row) {
        for (int column = 0; column < 4; ++column) {
            int localX = x * 4 + column;
            int localY = y * 4 + row;
            uint2 frame = uint2(tileOrigin + int2(localX, localY));
            if (all(frame < p.extent.xy)) {
                sum += float4(tile[localY * tileSize + localX]);
                ++count;
            }
        }
    }
    scale0.write(half4(sum / float(max(count, 1u))), gridPosition);
}

static inline uint pcg(uint value) {
    uint state = value * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

static inline uint4 pcg4(uint4 value) {
    uint4 state = value * 747796405u + 2891336453u;
    uint4 word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

static inline uint pixel_hash(uint x, uint y, uint seed, uint layer) {
    return pcg(x ^ pcg(y ^ pcg(seed ^ (layer * 0x9E3779B9u))));
}

static inline uint4 pixel_hash4(uint x, uint y, uint seed, uint firstLayer) {
    uint4 layers = uint4(firstLayer) + uint4(0u, 1u, 2u, 3u);
    return pcg4(uint4(x) ^ pcg4(
        uint4(y) ^ pcg4(uint4(seed) ^ (layers * 0x9E3779B9u))));
}

static inline float offline_monochrome_grain_draw(
    uint hash, float lambda, const device float *poisson,
    const device float *normal) {
    // A silver clump is a correlation length, not a countable dye cloud. Match the full-quality
    // Halide path's normal draw so sparse high-resolution impulses do not resolve as dots. Keep
    // the table arguments in the ABI for prepared states and older simulator builds.
    (void)lambda;
    (void)poisson;
    (void)normal;
    uint hash2 = pcg(hash);
    float uniform1 = float(hash >> 8u) * (1.0f / 16777216.0f) + 1.0e-7f;
    float uniform2 = float(hash2 >> 8u) * (1.0f / 16777216.0f);
    return sqrt(-2.0f * log(uniform1))
        * cos(2.0f * M_PI_F * uniform2);
}

// Colour negatives consume four adjacent hash streams: RGB records and their shared component.
// Walking them together cuts grain's control and integer overhead without changing any lane's
// PCG sequence. The early exit is exact because inactive products and trial counts never change in
// the reference loop; only hashes whose values are no longer observed would have advanced.
static inline float4 offline_grain_draw4(
    uint4 hash, float lambda, const device float *poisson,
    const device float *normal) {
    (void)poisson;
    (void)normal;
    if (lambda >= 16.0f) {
        uint4 hash2 = pcg4(hash);
        float4 uniform1 = float4(hash >> 8u) * (1.0f / 16777216.0f) + 1.0e-7f;
        float4 uniform2 = float4(hash2 >> 8u) * (1.0f / 16777216.0f);
        return sqrt(-2.0f * log(uniform1))
            * cos(2.0f * M_PI_F * uniform2);
    }

    uint4 state = hash;
    float4 product = 1.0f;
    uint4 trials = 0u;
    float limit = exp(-lambda);
    for (uint iteration = 0u; iteration < 32u; ++iteration) {
        bool4 active = product > limit;
        if (!any(active)) break;
        state = pcg4(state);
        float4 uniform = float4(state >> 8u) * (1.0f / 16777216.0f);
        product = select(product, product * uniform, active);
        trials += select(uint4(0u), uint4(1u), active);
    }
    float4 count = float4(select(uint4(0u), trials - 1u, trials > 0u));
    return (count - lambda) / sqrt(max(lambda, 1.0e-4f));
}

static inline float4 sample_develop_grid(
    texture2d<half, access::read> grid, uint2 position,
    uint4 geometry, uint phaseY) {
    if (geometry.z == 1u) return float4(grid.read(position));
    float2 coordinate = (float2(position) + float2(geometry.w, phaseY) + 0.5f)
        / float(max(geometry.z, 1u)) - 0.5f;
    return grid_sample(grid, coordinate, geometry.xy);
}

static inline float coupler_warp(
    const device float *configuration, uint channel, float value) {
    constexpr float low = -4.0f;
    constexpr float high = 4.0f;
    float q = clamp((value - low) * (127.0f / (high - low)), 0.0f, 127.0f);
    uint index = min(uint(q), 126u);
    float fraction = q - float(index);
    uint base = kCouplerWarp + channel * 128u;
    float lowSample = configuration[base + index];
    float highSample = configuration[base + index + 1u];
    bool nonlinear = DEVELOP_CACHE_FIELDS
        ? DEVELOP_NONLINEAR_WARP
        : configuration[kCouplerReleaseGamma] != 1.0f
            || configuration[kCouplerReleaseGamma + 1u] != 1.0f
            || configuration[kCouplerReleaseGamma + 2u] != 1.0f
            || configuration[kDonorReleaseGamma] != 1.0f;
    if (!nonlinear) return mix(lowSample, highSample, fraction);
    float previous = configuration[base + (index > 0u ? index - 1u : 0u)];
    float following = configuration[base + min(index + 2u, 127u)];
    float delta = max(highSample - lowSample, 0.0f);
    float lowSlope = clamp(0.5f * (highSample - previous), 0.0f, 3.0f * delta);
    float highSlope = clamp(0.5f * (following - lowSample), 0.0f, 3.0f * delta);
    float f2 = fraction * fraction;
    float f3 = f2 * fraction;
    return (2.0f * f3 - 3.0f * f2 + 1.0f) * lowSample
        + (f3 - 2.0f * f2 + fraction) * lowSlope
        + (-2.0f * f3 + 3.0f * f2) * highSample
        + (f3 - f2) * highSlope;
}

// Mirrors `dye_cloud_granularity_variance` and `silver_granularity_variance` in
// FotufilmHalideShared.h; the provenance of both shapes is stated there.
static inline float dye_cloud_variance(
    const device float *configuration, float density) {
    float amplitude = configuration[kGrainDensityProfile];
    float toe = max(configuration[kGrainDensityProfile + 1u], 1.0e-4f);
    float decay = max(configuration[kGrainDensityProfile + 2u], 1.0e-4f);
    return (1.0f - exp(-density / toe))
        * (1.0f + amplitude * exp(-density / decay));
}

static inline float silver_variance(float density) {
    return density * pow(10.0f,
                         0.21004f * density + 0.06114f * density * density);
}

static inline float grain_modulation(
    const device float *configuration, uint channel, float netDensity) {
    float fog = configuration[kGrainFog + channel];
    float anchor = max(configuration[kGrainAnchor + channel] + fog, 1.0e-4f);
    float here = max(netDensity, 0.0f) + fog;
    // DEVELOP_DYE_CLOUD is only meaningful on the specialized path that sets it; elsewhere the
    // law is read from the configuration, where 2 is the reversal that keeps Selwyn's √D.
    if (DEVELOP_CACHE_FIELDS && DEVELOP_DYE_CLOUD) {
        return sqrt(max(dye_cloud_variance(configuration, here)
                            / max(dye_cloud_variance(configuration, anchor), 1.0e-6f),
                        0.0f));
    }
    float law = configuration[kGrainLaw];
    if (!DEVELOP_CACHE_FIELDS && law < 0.5f) {
        return sqrt(max(dye_cloud_variance(configuration, here)
                            / max(dye_cloud_variance(configuration, anchor), 1.0e-6f),
                        0.0f));
    }
    if (law > 1.5f) return sqrt(max(here / anchor, 0.0f));
    return sqrt(max(silver_variance(here)
                        / max(silver_variance(anchor), 1.0e-6f), 0.0f));
}

kernel void fotufilm_spatial_develop(
    texture2d<float, access::read> curves [[texture(0)]],
    texture2d<half, access::read> couplerGrid [[texture(1)]],
    texture2d<half, access::read> adjacencyGrid [[texture(2)]],
    texture2d<half, access::read_write> io [[texture(3)]],
    texture2d<half, access::write> printOutput [[texture(4)]],
    texture2d_array<float, access::read> halfResponse [[texture(5)]],
    texture2d<half, access::read> multiresCorrection [[texture(6)]],
    const device float *configuration [[buffer(0)]],
    const device float *finePoisson [[buffer(1)]],
    const device float *fineNormal [[buffer(2)]],
    const device float *mottlePoisson [[buffer(3)]],
    const device float *mottleNormal [[buffer(4)]],
    const device half4 *fineWeights [[buffer(5)]],
    const device half4 *mottleWeights [[buffer(6)]],
    constant DevelopParameters &p [[buffer(7)]],
    threadgroup half4 *scratch [[threadgroup(0)]],
    uint2 group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]]) {
    const int tileSize = 16;
    const int padded = tileSize + 2 * SPECIALIZED_RADIUS;
    threadgroup half4 *fineNoise = scratch;
    threadgroup half4 *fineRows = fineNoise + padded * padded;
    threadgroup half4 *mottleNoise = DEVELOP_MOTTLE
        ? fineRows + tileSize * padded : fineNoise;
    threadgroup half4 *mottleRows = DEVELOP_MOTTLE
        ? mottleNoise + padded * padded : fineRows;
    threadgroup half4 *fieldScratch = DEVELOP_GRAIN
        ? (DEVELOP_MOTTLE
            ? mottleRows + tileSize * padded
            : fineRows + tileSize * padded)
        : scratch;
    constexpr int couplerSpan = 6;
    // Both exact and multires graphs carry adjacency at its authored stride of two. A
    // 16-pixel developer tile consequently needs eight field cells plus the bilinear halo
    // on each side. Keeping the complete 10x10 footprint is required for tile-independent
    // reconstruction; a quarter-grid-sized 6x6 cache truncates the field at every tile edge.
    constexpr int adjacencySpan = 10;
    threadgroup half4 *couplerTile = fieldScratch;
    threadgroup half4 *adjacencyTile = couplerTile + couplerSpan * couplerSpan;
    int2 tileOrigin = int2(group) * tileSize;
    int2 couplerBase = int2(group)
        * (tileSize / int(p.coupler.z)) - 1;
    int2 adjacencyBase = int2(group)
        * (tileSize / int(p.adjacency.z)) - 1;
    float rho = clamp(p.grain.z, 0.0f, 1.0f);
    float ownScale = sqrt(1.0f - rho);
    float sharedScale = sqrt(rho);

    if (DEVELOP_CACHE_FIELDS) {
        for (int cell = int(lane); cell < couplerSpan * couplerSpan;
             cell += tileSize * tileSize) {
            int2 local = int2(cell % couplerSpan, cell / couplerSpan);
            int2 sample = couplerBase + local;
            couplerTile[cell] = all(sample >= 0)
                    && all(uint2(sample) < p.coupler.xy)
                ? couplerGrid.read(uint2(sample)) : half4(0.0h);
        }
        for (int cell = int(lane); cell < adjacencySpan * adjacencySpan;
             cell += tileSize * tileSize) {
            int2 local = int2(cell % adjacencySpan, cell / adjacencySpan);
            int2 sample = adjacencyBase + local;
            adjacencyTile[cell] = all(sample >= 0)
                    && all(uint2(sample) < p.adjacency.xy)
                ? adjacencyGrid.read(uint2(sample)) : half4(0.0h);
        }
    }

    if (DEVELOP_GRAIN) {
        for (int cell = int(lane); cell < padded * padded;
             cell += tileSize * tileSize) {
            int2 local = int2(cell % padded, cell / padded);
            int2 frame = clamp(tileOrigin - SPECIALIZED_RADIUS + local,
                               int2(0), int2(p.extent.xy) - 1);
            uint x = uint(frame.x) + p.extent.z;
            uint y = uint(frame.y) + p.extent.w;
            float3 fine;
            if (DEVELOP_MONOCHROME) {
                fine = offline_monochrome_grain_draw(
                    pixel_hash(x, y, p.state.x, 3u), p.grain.x,
                    finePoisson, fineNormal);
            } else {
                float4 draws = offline_grain_draw4(
                    pixel_hash4(x, y, p.state.x, 0u), p.grain.x,
                    finePoisson, fineNormal);
                fine = ownScale * draws.xyz + sharedScale * draws.w;
            }
            fineNoise[cell] = half4(half3(fine), 0.0h);
            if (DEVELOP_MOTTLE) {
                float3 coarse;
                if (DEVELOP_MONOCHROME) {
                    coarse = offline_monochrome_grain_draw(
                        pixel_hash(x, y, p.state.x, 7u), p.grain.y,
                        mottlePoisson, mottleNormal);
                } else {
                    float4 draws = offline_grain_draw4(
                        pixel_hash4(x, y, p.state.x, 4u), p.grain.y,
                        mottlePoisson, mottleNormal);
                    coarse = ownScale * draws.xyz + sharedScale * draws.w;
                }
                mottleNoise[cell] = half4(half3(coarse), 0.0h);
            }
        }
    }
    if (DEVELOP_GRAIN || DEVELOP_CACHE_FIELDS) {
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (DEVELOP_GRAIN) {
        for (int cell = int(lane); cell < tileSize * padded;
             cell += tileSize * tileSize) {
            int x = cell % tileSize;
            int y = cell / tileSize;
            half4 fineSum = 0.0h;
            half4 mottleSum = 0.0h;
            for (int tap = -SPECIALIZED_RADIUS; tap <= SPECIALIZED_RADIUS; ++tap) {
                int index = y * padded + x + SPECIALIZED_RADIUS + tap;
                fineSum += fineNoise[index] * fineWeights[tap + SPECIALIZED_RADIUS];
                if (DEVELOP_MOTTLE) {
                    mottleSum += mottleNoise[index]
                        * mottleWeights[tap + SPECIALIZED_RADIUS];
                }
            }
            fineRows[cell] = fineSum;
            if (DEVELOP_MOTTLE) mottleRows[cell] = mottleSum;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    int x = int(lane) % tileSize;
    int y = int(lane) / tileSize;
    uint2 position = uint2(tileOrigin + int2(x, y));
    half4 fineField = 0.0h;
    half4 mottleField = 0.0h;
    if (DEVELOP_GRAIN) {
        for (int tap = -SPECIALIZED_RADIUS; tap <= SPECIALIZED_RADIUS; ++tap) {
            int index = (y + SPECIALIZED_RADIUS + tap) * tileSize + x;
            fineField += fineRows[index] * fineWeights[tap + SPECIALIZED_RADIUS];
            if (DEVELOP_MOTTLE) {
                mottleField += mottleRows[index]
                    * mottleWeights[tap + SPECIALIZED_RADIUS];
            }
        }
    }
    if (any(position >= p.extent.xy)) return;

    half4 lightStored = io.read(position);
    float4 light = float4(lightStored);
    float4 logarithmicStored;
    half4 logarithmicHalf;
    if (DEVELOP_MULTIRES) {
        float2 coordinate = (float2(position) + 0.5f)
            / float(max(p.adjacency.z, 1u)) - 0.5f;
        float3 weighted = grid_sample(
            multiresCorrection, coordinate, p.adjacency.xy).rgb;
        float3 returnedStored = float3(half3(weighted - light.rgb));
        float3 halated;
        for (uint channel = 0u; channel < 3u; ++channel) {
            uint row = kHalationMatrix + channel * 3u;
            halated[channel] = light[channel]
                + dot(float3(configuration[row], configuration[row + 1u],
                             configuration[row + 2u]), returnedStored);
        }
        logarithmicHalf = half4(stored_log_exposure(
            float4(max(halated, 0.0f), light.w)));
        // The exact path materializes logarithmic exposure in rgba16f before development.
        // Preserve that seam even though the smooth correction itself is reconstructed here.
        logarithmicStored = float4(logarithmicHalf);
    } else {
        logarithmicStored = DEVELOP_INPUT_LOG
            ? light : stored_log_exposure(light);
        logarithmicHalf = DEVELOP_INPUT_LOG
            ? lightStored : half4(logarithmicStored);
    }
    float4 activation;
    if (USE_HALF_RESPONSE_LUT) {
        activation = float4(
            half_response(halfResponse, logarithmicHalf.x, 0u).x,
            half_response(halfResponse, logarithmicHalf.y, 1u).x,
            half_response(halfResponse, logarithmicHalf.z, 2u).x,
            0.0f);
    } else {
        activation = activation_from_log(logarithmicStored, configuration, curves);
    }
    float3 logarithmic = logarithmicStored.rgb;
    bool couplers = DEVELOP_CACHE_FIELDS
        || (p.state.y & kFeatureCouplers) != 0u;
    bool donor = DEVELOP_CACHE_FIELDS
        ? DEVELOP_DONOR : (p.state.y & kFeatureDonor) != 0u;
    bool diffused = DEVELOP_CACHE_FIELDS || p.state.z != 0u;
    float4 released;
    if (DEVELOP_CACHE_FIELDS) {
        float2 coordinate = (float2(position)
                + float2(p.coupler.w, p.phases.x) + 0.5f)
            / float(max(p.coupler.z, 1u)) - 0.5f;
        released = threadgroup_grid_sample(
            couplerTile, couplerSpan, couplerBase,
            coordinate, p.coupler.xy);
    } else if (diffused) {
        released = sample_develop_grid(
            couplerGrid, position, p.coupler, p.phases.x);
    } else {
        released = float4(half4(
            inhibitor_release(activation.x, configuration[kCouplerReleaseGamma]),
            inhibitor_release(activation.y, configuration[kCouplerReleaseGamma + 1u]),
            inhibitor_release(activation.z, configuration[kCouplerReleaseGamma + 2u]),
            inhibitor_release(activation.w, configuration[kDonorReleaseGamma])));
    }
    float3 effective = logarithmic;
    if (couplers || donor) {
        for (uint channel = 0u; channel < 3u; ++channel) {
            float inhibition = 0.0f;
            if (couplers) {
                uint row = kCoupler + channel * 3u;
                inhibition += dot(float3(configuration[row], configuration[row + 1u],
                                          configuration[row + 2u]), released.rgb)
                    * configuration[kCouplerScale];
            }
            if (donor) {
                inhibition += configuration[kDonorRelease + channel] * released.w
                    * configuration[kCouplerScale];
            }
            float shifted = logarithmic[channel] - inhibition;
            effective[channel] = shifted + coupler_warp(configuration, channel, shifted);
        }
    }
    if (DEVELOP_CACHE_FIELDS) {
        float2 coordinate = (float2(position)
                + float2(p.adjacency.w, p.phases.y) + 0.5f)
            / float(max(p.adjacency.z, 1u)) - 0.5f;
        float3 adjacent = threadgroup_grid_sample(
            adjacencyTile, adjacencySpan, adjacencyBase,
            coordinate, p.adjacency.xy).rgb;
        effective -= configuration[kAdjacencyStrength] * (adjacent - activation.rgb);
    } else if (p.state.w != 0u) {
        float3 adjacent = sample_develop_grid(
            adjacencyGrid, position, p.adjacency, p.phases.y).rgb;
        effective -= configuration[kAdjacencyStrength] * (adjacent - activation.rgb);
    }

    float3 density;
    // Only a genuine reversal stock complements; a negative on a light box or scanner carries the
    // same feature bit but is developed as a negative. See FOTUFILM_CONFIG_DEVELOP_COMPLEMENT.
    bool complement = DEVELOP_CACHE_FIELDS
        ? DEVELOP_COMPLEMENT : configuration[kDevelopComplement] > 0.5f;
    for (uint channel = 0u; channel < 3u; ++channel) {
        float formed = sample_film_curve(configuration, curves, effective[channel], channel);
        float dMin = configuration[kCurves + channel * 6u];
        float range = film_curve_range(configuration, channel);
        density[channel] = complement ? dMin + range - (formed - dMin) : formed;
        if (DEVELOP_GRAIN) {
            float amount = clamp((density[channel] - dMin) / max(range, 1.0e-6f),
                                 0.0f, 1.0f);
            uint fieldChannel = DEVELOP_MONOCHROME ? 0u : channel;
            float modulation = grain_modulation(
                configuration, channel, amount * range);
            density[channel] += configuration[kGrain + channel] * modulation
                * float(fineField[fieldChannel]);
            if (DEVELOP_MOTTLE) {
                density[channel] += configuration[kMottle + channel] * modulation
                    * float(mottleField[fieldChannel]);
            }
        }
    }
    if (DEVELOP_PRINT_TRANSMITTANCE) {
        printOutput.write(
            half4(half3(exp(-density * kLn10)), 1.0h), position);
    } else {
        io.write(half4(half3(density), 1.0h), position);
    }
}

static inline float3 developed_density_from_log(
    float4 logarithmic, float4 released, float3 adjacent,
    half4 fineField, half4 mottleField,
    const device float *configuration,
    texture2d<float, access::read> curves,
    constant DevelopParameters &p) {
    float4 activation = activation_from_log(logarithmic, configuration, curves);
    bool couplers = (p.state.y & kFeatureCouplers) != 0u;
    bool donor = (p.state.y & kFeatureDonor) != 0u;
    float3 effective = logarithmic.rgb;
    if (couplers || donor) {
        for (uint channel = 0u; channel < 3u; ++channel) {
            float inhibition = 0.0f;
            if (couplers) {
                uint row = kCoupler + channel * 3u;
                inhibition += dot(float3(configuration[row], configuration[row + 1u],
                                          configuration[row + 2u]), released.rgb)
                    * configuration[kCouplerScale];
            }
            if (donor) {
                inhibition += configuration[kDonorRelease + channel] * released.w
                    * configuration[kCouplerScale];
            }
            float shifted = logarithmic[channel] - inhibition;
            effective[channel] = shifted + coupler_warp(configuration, channel, shifted);
        }
    }
    effective -= configuration[kAdjacencyStrength] * (adjacent - activation.rgb);

    float3 density;
    bool complement = configuration[kDevelopComplement] > 0.5f;
    for (uint channel = 0u; channel < 3u; ++channel) {
        float formed = sample_film_curve(configuration, curves, effective[channel], channel);
        float dMin = configuration[kCurves + channel * 6u];
        float range = film_curve_range(configuration, channel);
        density[channel] = complement ? dMin + range - (formed - dMin) : formed;
        if (DEVELOP_GRAIN) {
            float amount = clamp((density[channel] - dMin) / max(range, 1.0e-6f),
                                 0.0f, 1.0f);
            uint fieldChannel = DEVELOP_MONOCHROME ? 0u : channel;
            float modulation = grain_modulation(
                configuration, channel, amount * range);
            density[channel] += configuration[kGrain + channel] * modulation
                * float(fineField[fieldChannel]);
            if (DEVELOP_MOTTLE) {
                density[channel] += configuration[kMottle + channel] * modulation
                    * float(mottleField[fieldChannel]);
            }
        }
    }
    return density;
}

kernel void fotufilm_spatial_develop_print(
    texture2d<float, access::read> curves [[texture(0)]],
    texture2d<half, access::read> couplerGrid [[texture(1)]],
    texture2d<half, access::read> adjacencyGrid [[texture(2)]],
    texture2d<half, access::read_write> io [[texture(3)]],
    const device float *configuration [[buffer(0)]],
    const device float *finePoisson [[buffer(1)]],
    const device float *fineNormal [[buffer(2)]],
    const device float *mottlePoisson [[buffer(3)]],
    const device float *mottleNormal [[buffer(4)]],
    const device half4 *fineWeights [[buffer(5)]],
    const device half4 *mottleWeights [[buffer(6)]],
    const device half4 *printWeights [[buffer(7)]],
    constant DevelopParameters &p [[buffer(8)]],
    threadgroup float4 *scratch [[threadgroup(0)]],
    uint2 group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]]) {
    constexpr int tileSize = 16;
    const int developSize = tileSize + 2 * PRINT_RADIUS;
    const int noiseSize = developSize + 2 * SPECIALIZED_RADIUS;
    int couplerStride = int(p.coupler.z);
    int adjacencyStride = int(p.adjacency.z);
    int couplerSpan = (developSize + couplerStride - 1) / couplerStride + 3;
    int adjacencySpan = (developSize + adjacencyStride - 1) / adjacencyStride + 3;

    threadgroup float4 *directTile = scratch;
    threadgroup half4 *cursor = reinterpret_cast<threadgroup half4 *>(
        directTile + developSize * developSize);
    threadgroup half4 *fineNoise = cursor;
    threadgroup half4 *fineRows = fineNoise;
    if (DEVELOP_GRAIN) {
        fineRows = fineNoise + noiseSize * noiseSize;
        cursor = fineRows + developSize * noiseSize;
    }
    threadgroup half4 *mottleNoise = cursor;
    threadgroup half4 *mottleRows = mottleNoise;
    if (DEVELOP_MOTTLE) {
        mottleRows = mottleNoise + noiseSize * noiseSize;
        cursor = mottleRows + developSize * noiseSize;
    }
    threadgroup half4 *couplerTile = cursor;
    threadgroup half4 *adjacencyTile = couplerTile + couplerSpan * couplerSpan;
    threadgroup half4 *printRows =
        adjacencyTile + adjacencySpan * adjacencySpan;

    int2 tileOrigin = int2(group) * tileSize;
    int2 developOrigin = tileOrigin - PRINT_RADIUS;
    float2 couplerFirst = (float2(developOrigin)
            + float2(p.coupler.w, p.phases.x) + 0.5f)
        / float(couplerStride) - 0.5f;
    float2 adjacencyFirst = (float2(developOrigin)
            + float2(p.adjacency.w, p.phases.y) + 0.5f)
        / float(adjacencyStride) - 0.5f;
    int2 couplerBase = int2(floor(couplerFirst));
    int2 adjacencyBase = int2(floor(adjacencyFirst));

    for (int cell = int(lane); cell < couplerSpan * couplerSpan;
         cell += tileSize * tileSize) {
        int2 local = int2(cell % couplerSpan, cell / couplerSpan);
        int2 sample = couplerBase + local;
        couplerTile[cell] = all(sample >= 0) && all(uint2(sample) < p.coupler.xy)
            ? couplerGrid.read(uint2(sample)) : half4(0.0h);
    }
    for (int cell = int(lane); cell < adjacencySpan * adjacencySpan;
         cell += tileSize * tileSize) {
        int2 local = int2(cell % adjacencySpan, cell / adjacencySpan);
        int2 sample = adjacencyBase + local;
        adjacencyTile[cell] = all(sample >= 0)
                && all(uint2(sample) < p.adjacency.xy)
            ? adjacencyGrid.read(uint2(sample)) : half4(0.0h);
    }

    float rho = clamp(p.grain.z, 0.0f, 1.0f);
    float ownScale = sqrt(1.0f - rho);
    float sharedScale = sqrt(rho);
    if (DEVELOP_GRAIN) {
        for (int cell = int(lane); cell < noiseSize * noiseSize;
             cell += tileSize * tileSize) {
            int2 local = int2(cell % noiseSize, cell / noiseSize);
            int2 frame = clamp(
                developOrigin - SPECIALIZED_RADIUS + local,
                int2(0), int2(p.extent.xy) - 1);
            uint hashX = uint(frame.x) + p.extent.z;
            uint hashY = uint(frame.y) + p.extent.w;
            float3 fine;
            if (DEVELOP_MONOCHROME) {
                fine = offline_monochrome_grain_draw(
                    pixel_hash(hashX, hashY, p.state.x, 3u), p.grain.x,
                    finePoisson, fineNormal);
            } else {
                float4 draws = offline_grain_draw4(
                    pixel_hash4(hashX, hashY, p.state.x, 0u), p.grain.x,
                    finePoisson, fineNormal);
                fine = ownScale * draws.xyz + sharedScale * draws.w;
            }
            fineNoise[cell] = half4(half3(fine), 0.0h);
            if (DEVELOP_MOTTLE) {
                float3 coarse;
                if (DEVELOP_MONOCHROME) {
                    coarse = offline_monochrome_grain_draw(
                        pixel_hash(hashX, hashY, p.state.x, 7u), p.grain.y,
                        mottlePoisson, mottleNormal);
                } else {
                    float4 draws = offline_grain_draw4(
                        pixel_hash4(hashX, hashY, p.state.x, 4u), p.grain.y,
                        mottlePoisson, mottleNormal);
                    coarse = ownScale * draws.xyz + sharedScale * draws.w;
                }
                mottleNoise[cell] = half4(half3(coarse), 0.0h);
            }
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (DEVELOP_GRAIN) {
        for (int cell = int(lane); cell < developSize * noiseSize;
             cell += tileSize * tileSize) {
            int localX = cell % developSize;
            int localY = cell / developSize;
            half4 fineSum = 0.0h;
            half4 mottleSum = 0.0h;
            for (int tap = -SPECIALIZED_RADIUS;
                 tap <= SPECIALIZED_RADIUS; ++tap) {
                int sourceIndex = localY * noiseSize
                    + localX + SPECIALIZED_RADIUS + tap;
                fineSum += fineNoise[sourceIndex]
                    * fineWeights[tap + SPECIALIZED_RADIUS];
                if (DEVELOP_MOTTLE) {
                    mottleSum += mottleNoise[sourceIndex]
                        * mottleWeights[tap + SPECIALIZED_RADIUS];
                }
            }
            fineRows[cell] = fineSum;
            if (DEVELOP_MOTTLE) mottleRows[cell] = mottleSum;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (int cell = int(lane); cell < developSize * developSize;
         cell += tileSize * tileSize) {
        int2 local = int2(cell % developSize, cell / developSize);
        int2 frame = developOrigin + local;
        bool valid = all(frame >= 0) && all(uint2(frame) < p.extent.xy);
        float4 transmittance = 0.0f;
        if (valid) {
            half4 fineField = 0.0h;
            half4 mottleField = 0.0h;
            if (DEVELOP_GRAIN) {
                for (int tap = -SPECIALIZED_RADIUS;
                     tap <= SPECIALIZED_RADIUS; ++tap) {
                    int sourceIndex = (local.y + SPECIALIZED_RADIUS + tap)
                        * developSize + local.x;
                    fineField += fineRows[sourceIndex]
                        * fineWeights[tap + SPECIALIZED_RADIUS];
                    if (DEVELOP_MOTTLE) {
                        mottleField += mottleRows[sourceIndex]
                            * mottleWeights[tap + SPECIALIZED_RADIUS];
                    }
                }
            }
            float2 couplerCoordinate = (float2(frame)
                    + float2(p.coupler.w, p.phases.x) + 0.5f)
                / float(couplerStride) - 0.5f;
            float2 adjacencyCoordinate = (float2(frame)
                    + float2(p.adjacency.w, p.phases.y) + 0.5f)
                / float(adjacencyStride) - 0.5f;
            float4 released = threadgroup_grid_sample(
                couplerTile, couplerSpan, couplerBase,
                couplerCoordinate, p.coupler.xy);
            float3 adjacent = threadgroup_grid_sample(
                adjacencyTile, adjacencySpan, adjacencyBase,
                adjacencyCoordinate, p.adjacency.xy).rgb;
            float4 logarithmic = float4(io.read(uint2(frame)));
            float3 density = developed_density_from_log(
                logarithmic, released, adjacent, fineField, mottleField,
                configuration, curves, p);
            transmittance = float4(exp(-density * kLn10), 1.0f);
        }
        // Keep this full float for the direct unsharp arm. Only the blur source crosses the
        // canonical transmittance store below.
        directTile[cell] = transmittance;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (int cell = int(lane); cell < tileSize * developSize;
         cell += tileSize * tileSize) {
        int localX = cell % tileSize;
        int localY = cell / tileSize;
        int frameX = tileOrigin.x + localX;
        int frameY = developOrigin.y + localY;
        half4 sum = 0.0h;
        float4 normalization = 0.0f;
        if (frameX >= 0 && frameX < int(p.extent.x)
                && frameY >= 0 && frameY < int(p.extent.y)) {
            for (int tap = -PRINT_RADIUS; tap <= PRINT_RADIUS; ++tap) {
                int sampleX = frameX + tap;
                if (sampleX < 0 || sampleX >= int(p.extent.x)) continue;
                half4 weight = printWeights[tap + PRINT_RADIUS];
                int sourceIndex = localY * developSize
                    + localX + PRINT_RADIUS + tap;
                sum += half4(directTile[sourceIndex]) * weight;
                normalization += float4(weight);
            }
        }
        printRows[cell] = half4(
            float4(sum) / max(normalization, 1.0e-12f));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int localX = int(lane) % tileSize;
    int localY = int(lane) / tileSize;
    uint2 position = uint2(tileOrigin + int2(localX, localY));
    if (any(position >= p.extent.xy)) return;
    half4 sum = 0.0h;
    float4 normalization = 0.0f;
    for (int tap = -PRINT_RADIUS; tap <= PRINT_RADIUS; ++tap) {
        int sampleY = int(position.y) + tap;
        if (sampleY < 0 || sampleY >= int(p.extent.y)) continue;
        half4 weight = printWeights[tap + PRINT_RADIUS];
        sum += printRows[(localY + PRINT_RADIUS + tap) * tileSize + localX]
            * weight;
        normalization += float4(weight);
    }
    float3 blurred = float3(half4(
        float4(sum) / max(normalization, 1.0e-12f)).rgb);
    float3 direct = directTile[(localY + PRINT_RADIUS) * developSize
        + localX + PRINT_RADIUS].rgb;
    float keep = p.grain.w;
    float3 read = keep > 0.0f
        ? blurred + keep * (direct - blurred) : blurred;
    float3 density = -log(max(read, 1.0e-6f)) * kInverseLn10;
    // This store is the dispatch-9 handoff. A fused composite-tail specialization consumes
    // `density` here directly and does not require another full-resolution texture copy.
    io.write(half4(half3(density), 1.0h), position);
}

kernel void fotufilm_spatial_fused_print_mtf(
    texture2d<half, access::read> transmittance [[texture(0)]],
    texture2d<half, access::write> density [[texture(1)]],
    const device half4 *weights [[buffer(0)]],
    constant PrintParameters &p [[buffer(1)]],
    threadgroup half4 *scratch [[threadgroup(0)]],
    uint2 group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]]) {
    constexpr int tileSize = 16;
    const int padded = tileSize + 2 * SPECIALIZED_RADIUS;
    threadgroup half4 *sourceTile = scratch;
    threadgroup half4 *horizontalRows = sourceTile + padded * padded;
    int2 tileOrigin = int2(group) * tileSize;

    // Every neighborhood value is captured before any group writes its disjoint output
    // texture. Out-of-frame cells remain zero; the two passes renormalize them away exactly
    // as the standalone Gaussian kernels do.
    for (int cell = int(lane); cell < padded * padded;
         cell += tileSize * tileSize) {
        int2 local = int2(cell % padded, cell / padded);
        int2 frame = tileOrigin - SPECIALIZED_RADIUS + local;
        bool valid = all(frame >= 0) && all(uint2(frame) < p.extent.xy);
        sourceTile[cell] = valid
            ? transmittance.read(uint2(frame)) : half4(0.0h);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (int cell = int(lane); cell < tileSize * padded;
         cell += tileSize * tileSize) {
        int localX = cell % tileSize;
        int localY = cell / tileSize;
        int frameX = tileOrigin.x + localX;
        int frameY = tileOrigin.y - SPECIALIZED_RADIUS + localY;
        float4 sum = 0.0f;
        float4 normalization = 0.0f;
        if (frameX >= 0 && frameX < int(p.extent.x)
                && frameY >= 0 && frameY < int(p.extent.y)) {
            for (int tap = -SPECIALIZED_RADIUS;
                 tap <= SPECIALIZED_RADIUS; ++tap) {
                int sampleX = frameX + tap;
                if (sampleX < 0 || sampleX >= int(p.extent.x)) continue;
                float4 weight = float4(weights[tap + SPECIALIZED_RADIUS]);
                int sourceIndex = localY * padded
                    + localX + SPECIALIZED_RADIUS + tap;
                sum += float4(sourceTile[sourceIndex]) * weight;
                normalization += weight;
            }
        }
        horizontalRows[cell] = half4(
            sum / max(normalization, 1.0e-12f));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int localX = int(lane) % tileSize;
    int localY = int(lane) / tileSize;
    uint2 position = uint2(tileOrigin + int2(localX, localY));
    if (any(position >= p.extent.xy)) return;
    float4 sum = 0.0f;
    float4 normalization = 0.0f;
    for (int tap = -SPECIALIZED_RADIUS;
         tap <= SPECIALIZED_RADIUS; ++tap) {
        int sampleY = int(position.y) + tap;
        if (sampleY < 0 || sampleY >= int(p.extent.y)) continue;
        float4 weight = float4(weights[tap + SPECIALIZED_RADIUS]);
        int rowIndex = (localY + SPECIALIZED_RADIUS + tap) * tileSize
            + localX;
        sum += float4(horizontalRows[rowIndex]) * weight;
        normalization += weight;
    }
    // Preserve the vertical half-store seam before the pointwise print reconstruction.
    float4 blurred = float4(half4(sum / max(normalization, 1.0e-12f)));
    int directIndex = (localY + SPECIALIZED_RADIUS) * padded
        + localX + SPECIALIZED_RADIUS;
    float4 directTransmittance = float4(sourceTile[directIndex]);
    float3 direct = directTransmittance.rgb;
    float3 read = p.values.x > 0.0f
        ? blurred.rgb + p.values.x * (direct - blurred.rgb) : blurred.rgb;
    float3 result = -log(max(read, 1.0e-6f)) * kInverseLn10;
    density.write(
        half4(half3(result), half(directTransmittance.a)), position);
}

kernel void fotufilm_spatial_finish_print_mtf(
    texture2d<half, access::read_write> density [[texture(0)]],
    texture2d<half, access::read> spread [[texture(1)]],
    constant PrintParameters &p [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]) {
    if (any(position >= p.extent.xy)) return;
    float4 directTransmittance = float4(density.read(position));
    float3 direct = directTransmittance.rgb;
    float3 blurred = float3(spread.read(position).rgb);
    float3 read = p.values.x > 0.0f
        ? blurred + p.values.x * (direct - blurred) : blurred;
    float3 result = -log(max(read, 1.0e-6f)) * kInverseLn10;
    density.write(half4(half3(result), half(directTransmittance.a)), position);
}

#include "HandwrittenExactCameraTail.metal"
