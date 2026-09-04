#include <metal_stdlib>
using namespace metal;

constant uint kReductionThreads = FOTUFILM_MEASUREMENT_REDUCTION_THREADS;
constant uint kFlareItems = FOTUFILM_MEASUREMENT_FLARE_ITEMS;
constant uint kDecodeSamples = 256u;

struct ToneParameters {
    uint width;
    uint height;
    uint grid_width;
    uint grid_height;
    float weight_r;
    float weight_g;
    float weight_b;
    uint radius;
};

struct FlareParameters {
    uint width;
    uint height;
    uint input_count;
    uint pixel_count;
};

struct CaptureToneParameters {
    ToneParameters tone;
    float4 transform;
    uint4 source;
};

static inline float decode_srgb(float value) {
    return value <= 0.04045f
        ? value / 12.92f
        : pow((value + 0.055f) / 1.055f, 2.4f);
}

static inline float3 p3_to_rec2020(float3 p3) {
    return float3(
        0.753833034f * p3.x + 0.198597369f * p3.y + 0.047569597f * p3.z,
        0.045743849f * p3.x + 0.941777220f * p3.y + 0.012478931f * p3.z,
       -0.001210340f * p3.x + 0.017601717f * p3.y + 0.983608623f * p3.z);
}

static inline float3 decode_premultiplied_p3(uchar4 encoded) {
    float denominator = encoded.w > 0u && encoded.w < 255u
        ? float(encoded.w) : 255.0f;
    float3 coded = min(float3(encoded.xyz) / denominator, 1.0f);
    return p3_to_rec2020(float3(
        decode_srgb(coded.x), decode_srgb(coded.y), decode_srgb(coded.z)));
}

static inline float decode_transfer(
    texture1d<half, access::sample> table, float encoded) {
    constexpr sampler linear_table(
        coord::normalized, address::clamp_to_edge, filter::linear);
    float q = clamp(encoded, 0.0f, 1.0f) * float(kDecodeSamples - 1u);
    return float(table.sample(
        linear_table, (q + 0.5f) / float(kDecodeSamples)).r);
}

static inline float3 encoded_to_working(
    texture1d<half, access::sample> decode, float3 encoded,
    uint primaries) {
    float3 linear = float3(
        decode_transfer(decode, encoded.x),
        decode_transfer(decode, encoded.y),
        decode_transfer(decode, encoded.z));
    if (primaries == 0u) return p3_to_rec2020(linear);
    return float3(
        0.627403896f * linear.x + 0.329283038f * linear.y
            + 0.043313066f * linear.z,
        0.069097289f * linear.x + 0.919540395f * linear.y
            + 0.011362316f * linear.z,
        0.016391439f * linear.x + 0.088013308f * linear.y
            + 0.895595253f * linear.z);
}

#include "HandwrittenCameraSceneTransfer.metalinc"

static inline float capture_scene_light(float signal, uint transfer) {
    return transfer == 0u ? hlg_scene_light(signal)
        : apple_log_to_linear(clamp(signal, 0.0f, 1.0f));
}

#include "HandwrittenCameraYCbCr.metalinc"

static inline float reduce_scalar(threadgroup float *values, uint tid) {
    for (uint stride = kReductionThreads >> 1u; stride > 0u; stride >>= 1u) {
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (tid < stride) values[tid] += values[tid + stride];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    return values[0];
}

static inline float4 reduce_vector(threadgroup float4 *values, uint tid) {
    for (uint stride = kReductionThreads >> 1u; stride > 0u; stride >>= 1u) {
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (tid < stride) values[tid] += values[tid + stride];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    return values[0];
}

static inline uint4 tone_cell_bounds(uint2 cell, constant ToneParameters &p) {
    return uint4(
        (cell.x * p.width + p.grid_width - 1u) / p.grid_width,
        ((cell.x + 1u) * p.width + p.grid_width - 1u) / p.grid_width,
        (cell.y * p.height + p.grid_height - 1u) / p.grid_height,
        ((cell.y + 1u) * p.height + p.grid_height - 1u) / p.grid_height);
}

static inline float metered_log(float3 rgb, constant ToneParameters &p) {
    float metered = p.weight_r * max(rgb.x, 0.0f)
        + p.weight_g * max(rgb.y, 0.0f)
        + p.weight_b * max(rgb.z, 0.0f);
    return log2(max(metered, 1.0e-6f));
}

static inline void finish_tone_cell(
    float sum, uint count, uint2 cell, uint tid,
    constant ToneParameters &p, device float2 *moments,
    threadgroup float *shared_sum
) {
    shared_sum[tid] = sum;
    float total = reduce_scalar(shared_sum, tid);
    if (tid == 0u) {
        float g = total / float(count);
        moments[cell.y * p.grid_width + cell.x] = float2(g, g * g);
    }
}

template <typename Input, bool Encoded>
static inline void measure_tone_cell(
    const device Input *input, device float2 *moments,
    constant ToneParameters &p, uint2 cell, uint tid,
    threadgroup float *shared_sum
) {
    uint x0 = (cell.x * p.width + p.grid_width - 1u) / p.grid_width;
    uint x1 = ((cell.x + 1u) * p.width + p.grid_width - 1u) / p.grid_width;
    uint y0 = (cell.y * p.height + p.grid_height - 1u) / p.grid_height;
    uint y1 = ((cell.y + 1u) * p.height + p.grid_height - 1u) / p.grid_height;
    uint cell_width = x1 - x0;
    uint cell_height = y1 - y0;
    uint count = cell_width * cell_height;
    float sum = 0.0f;
    for (uint local = tid; local < count; local += kReductionThreads) {
        uint x = x0 + local % cell_width;
        uint y = y0 + local / cell_width;
        float3 rgb;
        if constexpr (Encoded) {
            rgb = decode_premultiplied_p3(input[y * p.width + x]);
        } else {
            rgb = float3(input[y * p.width + x].xyz);
        }
        float metered = p.weight_r * max(rgb.x, 0.0f)
            + p.weight_g * max(rgb.y, 0.0f)
            + p.weight_b * max(rgb.z, 0.0f);
        sum += log2(max(metered, 1.0e-6f));
    }
    shared_sum[tid] = sum;
    float total = reduce_scalar(shared_sum, tid);
    if (tid == 0u) {
        float g = total / float(count);
        moments[cell.y * p.grid_width + cell.x] = float2(g, g * g);
    }
}

kernel void fotufilm_measure_tone_sdr(
    const device uchar4 *input [[buffer(0)]],
    device float2 *moments [[buffer(1)]],
    constant ToneParameters &p [[buffer(2)]],
    texture1d<half, access::sample> decode [[texture(0)]],
    uint2 cell [[threadgroup_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]]
) {
    threadgroup float shared_sum[kReductionThreads];
    uint4 bounds = tone_cell_bounds(cell, p);
    uint cell_width = bounds.y - bounds.x;
    uint count = cell_width * (bounds.w - bounds.z);
    float sum = 0.0f;
    for (uint local = tid; local < count; local += kReductionThreads) {
        uint x = bounds.x + local % cell_width;
        uint y = bounds.z + local / cell_width;
        uchar4 pixel = input[y * p.width + x];
        float denominator = pixel.w > 0u && pixel.w < 255u
            ? float(pixel.w) : 255.0f;
        float3 encoded = clamp(
            float3(pixel.xyz) / denominator, 0.0f, 1.0f);
        sum += metered_log(encoded_to_working(decode, encoded, 0u), p);
    }
    finish_tone_cell(sum, count, cell, tid, p, moments, shared_sum);
}

kernel void fotufilm_measure_tone_hdr(
    const device half4 *input [[buffer(0)]],
    device float2 *moments [[buffer(1)]],
    constant ToneParameters &p [[buffer(2)]],
    uint2 cell [[threadgroup_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]]
) {
    threadgroup float shared_sum[kReductionThreads];
    measure_tone_cell<half4, false>(input, moments, p, cell, tid, shared_sum);
}

kernel void fotufilm_measure_tone_hdr_float(
    const device float4 *input [[buffer(0)]],
    device float2 *moments [[buffer(1)]],
    constant ToneParameters &p [[buffer(2)]],
    uint2 cell [[threadgroup_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]]
) {
    threadgroup float shared_sum[kReductionThreads];
    measure_tone_cell<float4, false>(input, moments, p, cell, tid, shared_sum);
}

kernel void fotufilm_measure_tone_nv12(
    device float2 *moments [[buffer(0)]],
    constant CaptureToneParameters &parameters [[buffer(1)]],
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    texture1d<half, access::sample> decode [[texture(2)]],
    uint2 cell [[threadgroup_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]]
) {
    threadgroup float shared_sum[kReductionThreads];
    constant ToneParameters &p = parameters.tone;
    uint4 bounds = tone_cell_bounds(cell, p);
    uint cell_width = bounds.y - bounds.x;
    uint count = cell_width * (bounds.w - bounds.z);
    float sum = 0.0f;
    for (uint local = tid; local < count; local += kReductionThreads) {
        uint x = bounds.x + local % cell_width;
        uint y = bounds.z + local / cell_width;
        float3 working = fotufilm_decode_nv12_scene(
            luma, chroma, decode, uint2(x, y), uint2(p.width, p.height),
            parameters.transform.yz, parameters.source.x, parameters.source.y)
            * parameters.transform.w;
        sum += metered_log(working, p);
    }
    finish_tone_cell(sum, count, cell, tid, p, moments, shared_sum);
}

kernel void fotufilm_measure_tone_x420(
    device float2 *moments [[buffer(0)]],
    constant CaptureToneParameters &parameters [[buffer(1)]],
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    uint2 cell [[threadgroup_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]]
) {
    threadgroup float shared_sum[kReductionThreads];
    constant ToneParameters &p = parameters.tone;
    uint4 bounds = tone_cell_bounds(cell, p);
    uint cell_width = bounds.y - bounds.x;
    uint count = cell_width * (bounds.w - bounds.z);
    float sum = 0.0f;
    for (uint local = tid; local < count; local += kReductionThreads) {
        uint x = bounds.x + local % cell_width;
        uint y = bounds.z + local / cell_width;
        float3 working = fotufilm_decode_x420_scene(
            luma, chroma, uint2(x, y), uint2(p.width, p.height),
            parameters.transform.yz, parameters.source.x,
            parameters.transform.x) * parameters.transform.w;
        sum += metered_log(working, p);
    }
    finish_tone_cell(sum, count, cell, tid, p, moments, shared_sum);
}

static inline float2 box_sum(
    const device float2 *values, uint x, uint y,
    constant ToneParameters &p
) {
    uint x0 = x > p.radius ? x - p.radius : 0u;
    uint y0 = y > p.radius ? y - p.radius : 0u;
    uint x1 = min(p.grid_width - 1u, x + p.radius);
    uint y1 = min(p.grid_height - 1u, y + p.radius);
    float2 sum = 0.0f;
    for (uint py = y0; py <= y1; ++py) {
        for (uint px = x0; px <= x1; ++px) {
            sum += values[py * p.grid_width + px];
        }
    }
    return sum / float((x1 - x0 + 1u) * (y1 - y0 + 1u));
}

kernel void fotufilm_measure_tone_model(
    const device float2 *moments [[buffer(0)]],
    device float2 *model [[buffer(1)]],
    constant ToneParameters &p [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    uint cells = p.grid_width * p.grid_height;
    if (index >= cells) return;
    uint x = index % p.grid_width;
    uint y = index / p.grid_width;
    float2 mean = box_sum(moments, x, y, p);
    float variance = max(0.0f, mean.y - mean.x * mean.x);
    float a = variance / (variance + 0.25f);
    model[index] = float2(a, (1.0f - a) * mean.x);
}

kernel void fotufilm_measure_tone_smooth(
    const device float2 *model [[buffer(0)]],
    device float *coefficients [[buffer(1)]],
    constant ToneParameters &p [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    uint cells = p.grid_width * p.grid_height;
    if (index >= cells) return;
    uint x = index % p.grid_width;
    uint y = index / p.grid_width;
    float2 smooth = box_sum(model, x, y, p);
    coefficients[index] = smooth.x;
    coefficients[cells + index] = smooth.y;
}

kernel void fotufilm_measure_flare_first(
    texture2d<float, access::read> exposure [[texture(0)]],
    device float4 *partials [[buffer(0)]],
    constant FlareParameters &p [[buffer(1)]],
    uint group [[threadgroup_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]]
) {
    threadgroup float4 shared_sum[kReductionThreads];
    uint begin = group * kReductionThreads * kFlareItems;
    uint end = min(p.input_count, begin + kReductionThreads * kFlareItems);
    float4 sum = 0.0f;
    for (uint index = begin + tid; index < end; index += kReductionThreads) {
        uint2 position = uint2(index % p.width, index / p.width);
        sum.xyz += exposure.read(position).xyz;
    }
    shared_sum[tid] = sum;
    float4 total = reduce_vector(shared_sum, tid);
    if (tid == 0u) partials[group] = total;
}

kernel void fotufilm_measure_flare_reduce(
    const device float4 *input [[buffer(0)]],
    device float4 *output [[buffer(1)]],
    constant FlareParameters &p [[buffer(2)]],
    uint group [[threadgroup_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]]
) {
    threadgroup float4 shared_sum[kReductionThreads];
    uint begin = group * kReductionThreads * kFlareItems;
    uint end = min(p.input_count, begin + kReductionThreads * kFlareItems);
    float4 sum = 0.0f;
    for (uint index = begin + tid; index < end; index += kReductionThreads) {
        sum += input[index];
    }
    shared_sum[tid] = sum;
    float4 total = reduce_vector(shared_sum, tid);
    if (tid == 0u) output[group] = total;
}

kernel void fotufilm_measure_flare_finish(
    const device float4 *total [[buffer(0)]],
    device float4 *mean [[buffer(1)]],
    constant FlareParameters &p [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    if (index == 0u) mean[0] = float4(total[0].xyz / float(p.pixel_count), 1.0f);
}
