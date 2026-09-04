
#if __has_include("HalideRuntime.h")

#import <Metal/Metal.h>

#include "HalideRuntime.h"

#include <algorithm>
#include <cstdio>
#include <mutex>

struct halide_metal_device;
struct halide_metal_command_queue;

namespace {
bool runtime_shares_context = false;

int grain_context(halide_metal_device **device_ret,
                  halide_metal_command_queue **queue_ret, bool create) {
    static id<MTLDevice> device = nil;
    static id<MTLCommandQueue> queue = nil;
    static std::once_flag once;
    std::call_once(once, [] {
        device = MTLCreateSystemDefaultDevice();
        queue = [device newCommandQueue];
    });
    if (!device || !queue) {
        *device_ret = nullptr;
        *queue_ret = nullptr;
        return create ? halide_error_code_generic_error : 0;
    }
    *device_ret = (__bridge halide_metal_device *)device;
    *queue_ret = (__bridge halide_metal_command_queue *)queue;
    return 0;
}
}

extern "C" __attribute__((visibility("default"))) int
halide_metal_acquire_context(void *user_context,
                             halide_metal_device **device_ret,
                             halide_metal_command_queue **queue_ret,
                             bool create) {
    runtime_shares_context = true;
    return grain_context(device_ret, queue_ret, create);
}

extern "C" __attribute__((visibility("default"))) int
halide_metal_release_context(void *user_context) {
    return 0;
}

namespace {
struct MetalDeviceHandle {
    void *metal_buffer;
    uint64_t offset;
};

id<MTLBuffer> buffer_of(halide_buffer_t *buffer) {
    if (!buffer->device) return nil;
    return (__bridge id<MTLBuffer>)(
        reinterpret_cast<MetalDeviceHandle *>(buffer->device)->metal_buffer);
}

uint64_t crop_offset_of(halide_buffer_t *buffer) {
    if (!buffer->device) return 0;
    return reinterpret_cast<MetalDeviceHandle *>(buffer->device)->offset;
}
}

namespace {

constexpr int kTile = 16;
constexpr int kMaxRadius = 8;

const char *kGrainKernelSource = R"MSL(
#include <metal_stdlib>
using namespace metal;

constant int CHANNELS [[function_constant(0)]];
constant int RADIUS   [[function_constant(1)]];

struct Params {
    int width, height;
    int out_min_x, out_min_y;
    int out_extent_x, out_extent_y;
    int out_stride_y, out_stride_c;
    int weight_stride_c;
    uint seed;
    float lambda;
    float correlation;
    int origin_x, origin_y;
};

static inline uint pcg(uint value) {
    uint state = value * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// Both tables arrive centered and unit-variance from normalized_quantile_table, so a draw is one
// load and lambda only picks which table to read.
static inline float draw_at(uint hash, bool gaussian,
                            const device float *poisson_table,
                            const device float *normal_table) {
    uint quantile = hash % 1024u;
    return gaussian ? normal_table[quantile] : poisson_table[quantile];
}

kernel void fotufilm_grain_field(
    const device float *poisson_table [[buffer(0)]],
    const device float *normal_table  [[buffer(1)]],
    const device half *weights        [[buffer(2)]],
    device half *field                [[buffer(3)]],
    constant Params &p                [[buffer(4)]],
    threadgroup half *scratch         [[threadgroup(0)]],
    uint2 group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]])
{
    const int padded = kTileSize + 2 * RADIUS;
    threadgroup half *noise = scratch;
    threadgroup half *rows = scratch + padded * padded * CHANNELS;

    const int tile_x = p.out_min_x + int(group.x) * kTileSize;
    const int tile_y = p.out_min_y + int(group.y) * kTileSize;
    // One-channel fields are silver clumps, whose size is a correlation length rather than a
    // countable dye-cloud event. Always use the continuous draw so sparse impulses cannot resolve
    // as dots at high output resolutions.
    const bool gaussian = CHANNELS == 1 || p.lambda >= 16.0f;
    const float scale_own = sqrt(1.0f - p.correlation);
    const float scale_shared = sqrt(p.correlation);

    uint layer_seed[4];
    if (CHANNELS == 1) {
        layer_seed[0] = pcg(p.seed ^ (3u * 0x9E3779B9u));
    } else {
        for (uint layer = 0; layer < 4; ++layer)
            layer_seed[layer] = pcg(p.seed ^ (layer * 0x9E3779B9u));
    }

    for (int cell = int(lane); cell < padded * padded;
         cell += kTileSize * kTileSize) {
        const int cell_x = cell % padded;
        const int cell_y = cell / padded;
        const int frame_x = clamp(tile_x - RADIUS + cell_x, 0, p.width - 1);
        const int frame_y = clamp(tile_y - RADIUS + cell_y, 0, p.height - 1);
        const uint hash_x = uint(frame_x + p.origin_x);
        const uint hash_y = uint(frame_y + p.origin_y);
        if (CHANNELS == 1) {
            uint hash = pcg(hash_x ^ pcg(hash_y ^ layer_seed[0]));
            float value = draw_at(hash, gaussian, poisson_table, normal_table);
            noise[cell] = half(value);
        } else {
            float draws[4];
            for (uint layer = 0; layer < 4; ++layer) {
                uint hash = pcg(hash_x ^ pcg(hash_y ^ layer_seed[layer]));
                draws[layer] = draw_at(hash, gaussian, poisson_table,
                                       normal_table);
            }
            for (int c = 0; c < CHANNELS; ++c)
                noise[cell * CHANNELS + c] =
                    half(scale_own * draws[c] + scale_shared * draws[3]);
        }
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (int cell = int(lane); cell < kTileSize * padded;
         cell += kTileSize * kTileSize) {
        const int x = cell % kTileSize;
        const int y = cell / kTileSize;
        for (int c = 0; c < CHANNELS; ++c) {
            half accumulated = half(0.0f);
            for (int k = -RADIUS; k <= RADIUS; ++k) {
                accumulated += noise[(y * padded + x + RADIUS + k) * CHANNELS + c]
                    * weights[(k + RADIUS) + c * p.weight_stride_c];
            }
            rows[(y * kTileSize + x) * CHANNELS + c] = accumulated;
        }
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    const int x = int(lane) % kTileSize;
    const int y = int(lane) / kTileSize;
    const int out_x = int(group.x) * kTileSize + x;
    const int out_y = int(group.y) * kTileSize + y;
    if (out_x >= p.out_extent_x || out_y >= p.out_extent_y) return;
    for (int c = 0; c < CHANNELS; ++c) {
        half accumulated = half(0.0f);
        for (int k = -RADIUS; k <= RADIUS; ++k) {
            accumulated += rows[((y + RADIUS + k) * kTileSize + x) * CHANNELS + c]
                * weights[(k + RADIUS) + c * p.weight_stride_c];
        }
        field[out_x + out_y * p.out_stride_y + c * p.out_stride_c] = accumulated;
    }
}
)MSL";

struct GrainParams {
    int32_t width, height;
    int32_t out_min_x, out_min_y;
    int32_t out_extent_x, out_extent_y;
    int32_t out_stride_y, out_stride_c;
    int32_t weight_stride_c;
    uint32_t seed;
    float lambda;
    float correlation;
    int32_t origin_x, origin_y;
};

id<MTLComputePipelineState> pipeline_for(id<MTLDevice> device, int channels,
                                         int radius) {
    static std::mutex mutex;
    static NSMutableDictionary<NSNumber *, id<MTLComputePipelineState>> *cache;
    std::lock_guard<std::mutex> lock(mutex);
    if (!cache) cache = [NSMutableDictionary new];
    NSNumber *key = @(channels * 100 + radius);
    if (id<MTLComputePipelineState> hit = cache[key]) return hit;

    NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = YES;
    options.preprocessorMacros = @{@"kTileSize" : @(kTile)};
    id<MTLLibrary> library = [device
        newLibraryWithSource:[NSString stringWithUTF8String:kGrainKernelSource]
                     options:options
                       error:&error];
    if (!library) return nil;
    MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
    int32_t channels32 = channels, radius32 = radius;
    [constants setConstantValue:&channels32 type:MTLDataTypeInt atIndex:0];
    [constants setConstantValue:&radius32 type:MTLDataTypeInt atIndex:1];
    id<MTLFunction> function = [library newFunctionWithName:@"fotufilm_grain_field"
                                             constantValues:constants
                                                      error:&error];
    if (!function) return nil;
    id<MTLComputePipelineState> pipeline =
        [device newComputePipelineStateWithFunction:function error:&error];
    if (pipeline) cache[key] = pipeline;
    return pipeline;
}

void fill_bounds_query(halide_buffer_t *buffer, int extent) {
    if (buffer && buffer->is_bounds_query()) {
        buffer->dim[0].min = 0;
        buffer->dim[0].extent = extent;
    }
}

}

extern "C" __attribute__((visibility("default"))) int fotufilm_metal_grain_field(
    halide_buffer_t *poisson_table, halide_buffer_t *normal_table,
    halide_buffer_t *weights, int32_t frame_width, int32_t frame_height,
    uint32_t seed, float lambda, float correlation, int32_t radius,
    int32_t origin_x, int32_t origin_y, halide_buffer_t *field) {
    if (field->is_bounds_query() || poisson_table->is_bounds_query() ||
        normal_table->is_bounds_query() || weights->is_bounds_query()) {
        fill_bounds_query(poisson_table, 1024);
        fill_bounds_query(normal_table, 1024);
        if (weights->is_bounds_query()) {
            weights->dim[0].min = -radius;
            weights->dim[0].extent = 2 * radius + 1;
            weights->dim[1].min = 0;
            weights->dim[1].extent = field->dim[2].extent;
        }
        return 0;
    }
    const int channels = field->dim[2].extent;
    if (radius < 0 || radius > kMaxRadius || (channels != 1 && channels != 3))
        return halide_error_code_generic_error;

    const bool shared = runtime_shares_context;
    if (!shared && poisson_table->device_interface) {
        int sync_error = poisson_table->device_interface->device_sync(
            nullptr, poisson_table);
        if (sync_error) return sync_error;
    }

    halide_metal_device *raw_device = nullptr;
    halide_metal_command_queue *raw_queue = nullptr;
    int error = grain_context(&raw_device, &raw_queue, false);
    if (error) return error;
    id<MTLDevice> device = (__bridge id<MTLDevice>)raw_device;
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)raw_queue;

    int result = 0;
    @autoreleasepool {
        id<MTLComputePipelineState> pipeline =
            pipeline_for(device, channels, radius);
        id<MTLBuffer> poisson = buffer_of(poisson_table);
        id<MTLBuffer> normal = buffer_of(normal_table);
        id<MTLBuffer> weight_buffer = buffer_of(weights);
        id<MTLBuffer> output = buffer_of(field);
        if (!pipeline || !poisson || !normal || !weight_buffer || !output) {
            halide_metal_release_context(nullptr);
            return halide_error_code_generic_error;
        }

        GrainParams params;
        params.width = frame_width;
        params.height = frame_height;
        params.out_min_x = field->dim[0].min;
        params.out_min_y = field->dim[1].min;
        params.out_extent_x = field->dim[0].extent;
        params.out_extent_y = field->dim[1].extent;
        params.out_stride_y = field->dim[1].stride;
        params.out_stride_c = field->dim[2].stride;
        params.weight_stride_c = weights->dim[1].stride;
        params.seed = seed;
        params.lambda = lambda;
        params.correlation = correlation;
        params.origin_x = origin_x;
        params.origin_y = origin_y;

        id<MTLCommandBuffer> commands = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:poisson
                    offset:crop_offset_of(poisson_table)
                   atIndex:0];
        [encoder setBuffer:normal
                    offset:crop_offset_of(normal_table)
                   atIndex:1];
        [encoder setBuffer:weight_buffer
                    offset:crop_offset_of(weights)
                   atIndex:2];
        [encoder setBuffer:output offset:crop_offset_of(field) atIndex:3];
        [encoder setBytes:&params length:sizeof(params) atIndex:4];
        const int padded = kTile + 2 * radius;
        [encoder setThreadgroupMemoryLength:((padded * padded + kTile * padded)
                                             * channels * sizeof(uint16_t) + 15)
                                            / 16 * 16
                                    atIndex:0];
        MTLSize groups = MTLSizeMake((params.out_extent_x + kTile - 1) / kTile,
                                     (params.out_extent_y + kTile - 1) / kTile,
                                     1);
        [encoder dispatchThreadgroups:groups
                threadsPerThreadgroup:MTLSizeMake(kTile, kTile, 1)];
        [encoder endEncoding];
        [commands commit];
        if (!shared) [commands waitUntilCompleted];
        field->set_device_dirty(true);

        static const bool debug = getenv("FOTUFILM_METAL_GRAIN_DEBUG") != nullptr;
        if (debug) {
            [commands waitUntilCompleted];
            fprintf(stderr,
                    "[grain] device=%p ch=%d r=%d seed=%u lambda=%g rho=%g "
                    "out=[%d+%d, %d+%d] strides y=%d c=%d wstride=%d\n",
                    (__bridge void *)device, channels, radius, seed, lambda,
                    correlation,
                    params.out_min_x, params.out_extent_x, params.out_min_y,
                    params.out_extent_y, params.out_stride_y, params.out_stride_c,
                    params.weight_stride_c);
            const int *ptable = (const int *)((char *)poisson.contents
                                              + crop_offset_of(poisson_table));
            const float *ntable = (const float *)((char *)normal.contents
                                                  + crop_offset_of(normal_table));
            const uint16_t *wtable = (const uint16_t *)((char *)weight_buffer.contents
                                                        + crop_offset_of(weights));
            const uint16_t *ftable = (const uint16_t *)((char *)output.contents
                                                        + crop_offset_of(field));
            fprintf(stderr,
                    "[grain] poisson[0,1,512,1023]=%d,%d,%d,%d "
                    "normal[0,512,1023]=%g,%g,%g weights[0..4]=%x,%x,%x,%x,%x "
                    "field[0..3]=%x,%x,%x,%x mid=%x\n",
                    ptable[0], ptable[1], ptable[512], ptable[1023], ntable[0],
                    ntable[512], ntable[1023], wtable[0], wtable[1], wtable[2],
                    wtable[3], wtable[4], ftable[0], ftable[1], ftable[2],
                    ftable[3],
                    ftable[params.out_extent_y / 2 * params.out_stride_y
                           + params.out_extent_x / 2]);
        }
    }
    halide_metal_release_context(nullptr);
    return result;
}

namespace {

constexpr int kMaxTiledMtfRadius = 20;
constexpr int kMaxMtfRadius = 119;

const char *kMtfKernelSource = R"MSL(
#include <metal_stdlib>
using namespace metal;

constant int RADIUS [[function_constant(0)]];
constant bool WIDE [[function_constant(1)]];

struct MtfParams {
    int width, height;
    int in_min_x, in_min_y;
    int in_stride_y, in_stride_c;
    int out_min_x, out_min_y;
    int out_extent_x, out_extent_y;
    int out_stride_y, out_stride_c;
    int weight_stride_c;
    float flare;
    float luma_share;
    float primary_share0, primary_share1, primary_share2;
};

constant float kRecordNeutralWeight = 1.0f / 3.0f;

kernel void fotufilm_mtf_field(
    const device half *light   [[buffer(0)]],
    const device float *mean   [[buffer(1)]],
    const device half *weights [[buffer(2)]],
    device half *field         [[buffer(3)]],
    constant MtfParams &p      [[buffer(4)]],
    threadgroup half *scratch  [[threadgroup(0)]],
    uint2 group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]])
{
    const int padded = kTileSize + 2 * RADIUS;
    threadgroup half *tile = scratch;
    threadgroup half *rows =
        WIDE ? scratch : scratch + padded * padded * 4;

    const int tile_x = p.out_min_x + int(group.x) * kTileSize;
    const int tile_y = p.out_min_y + int(group.y) * kTileSize;

    if (!WIDE) {
        for (int cell = int(lane); cell < padded * padded;
             cell += kTileSize * kTileSize) {
            const int cell_x = cell % padded;
            const int cell_y = cell / padded;
            const int frame_x = clamp(tile_x - RADIUS + cell_x, 0, p.width - 1);
            const int frame_y = clamp(tile_y - RADIUS + cell_y, 0, p.height - 1);
            const int base = (frame_x - p.in_min_x)
                + (frame_y - p.in_min_y) * p.in_stride_y;
            for (int c = 0; c < 4; ++c) {
                float value = float(light[base + c * p.in_stride_c]);
                tile[cell * 4 + c] =
                    half((1.0f - p.flare) * value + p.flare * mean[c]);
            }
        }
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (int cell = int(lane); cell < kTileSize * padded;
         cell += kTileSize * kTileSize) {
        const int x = cell % kTileSize;
        const int y = cell / kTileSize;
        const int frame_y = clamp(tile_y - RADIUS + y, 0, p.height - 1);
        for (int c = 0; c < 7; ++c) {
            const int source_c = c < 4 ? c : c - 4;
            half accumulated = half(0.0f);
            for (int k = -RADIUS; k <= RADIUS; ++k) {
                half tap;
                if (WIDE) {
                    const int frame_x = clamp(tile_x + x + k, 0, p.width - 1);
                    const int base = (frame_x - p.in_min_x)
                        + (frame_y - p.in_min_y) * p.in_stride_y;
                    float value = float(light[base + source_c * p.in_stride_c]);
                    tap = half((1.0f - p.flare) * value
                               + p.flare * mean[source_c]);
                } else {
                    tap = tile[(y * padded + x + RADIUS + k) * 4 + source_c];
                }
                accumulated += tap
                    * weights[(k + RADIUS) + c * p.weight_stride_c];
            }
            rows[(y * kTileSize + x) * 7 + c] = accumulated;
        }
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    const int x = int(lane) % kTileSize;
    const int y = int(lane) / kTileSize;
    const int out_x = int(group.x) * kTileSize + x;
    const int out_y = int(group.y) * kTileSize + y;
    if (out_x >= p.out_extent_x || out_y >= p.out_extent_y) return;
    half blurred[7];
    for (int c = 0; c < 7; ++c) {
        half accumulated = half(0.0f);
        for (int k = -RADIUS; k <= RADIUS; ++k) {
            accumulated += rows[((y + RADIUS + k) * kTileSize + x) * 7 + c]
                * weights[(k + RADIUS) + c * p.weight_stride_c];
        }
        blurred[c] = accumulated;
    }
    const float layer0 = p.primary_share0 * float(blurred[0])
        + (1.0f - p.primary_share0) * float(blurred[4]);
    const float layer1 = p.primary_share1 * float(blurred[1])
        + (1.0f - p.primary_share1) * float(blurred[5]);
    const float layer2 = p.primary_share2 * float(blurred[2])
        + (1.0f - p.primary_share2) * float(blurred[6]);
    const float per_layer_luma =
        kRecordNeutralWeight * (layer0 + layer1 + layer2);
    const float luma_blurred = float(blurred[3]);
    const float correction = p.luma_share * (luma_blurred - per_layer_luma);
    const int out_base = out_x + out_y * p.out_stride_y;
    field[out_base] = half(layer0 + correction);
    field[out_base + p.out_stride_c] = half(layer1 + correction);
    field[out_base + 2 * p.out_stride_c] = half(layer2 + correction);
}
)MSL";

struct MtfParams {
    int32_t width, height;
    int32_t in_min_x, in_min_y;
    int32_t in_stride_y, in_stride_c;
    int32_t out_min_x, out_min_y;
    int32_t out_extent_x, out_extent_y;
    int32_t out_stride_y, out_stride_c;
    int32_t weight_stride_c;
    float flare;
    float luma_share;
    float primary_share0, primary_share1, primary_share2;
};

id<MTLComputePipelineState> mtf_pipeline_for(id<MTLDevice> device, int radius) {
    static std::mutex mutex;
    static NSMutableDictionary<NSNumber *, id<MTLComputePipelineState>> *cache;
    std::lock_guard<std::mutex> lock(mutex);
    if (!cache) cache = [NSMutableDictionary new];
    NSNumber *key = @(radius);
    if (id<MTLComputePipelineState> hit = cache[key]) return hit;

    NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = YES;
    options.preprocessorMacros = @{@"kTileSize" : @(kTile)};
    id<MTLLibrary> library = [device
        newLibraryWithSource:[NSString stringWithUTF8String:kMtfKernelSource]
                     options:options
                       error:&error];
    if (!library) return nil;
    MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
    int32_t radius32 = radius;
    [constants setConstantValue:&radius32 type:MTLDataTypeInt atIndex:0];
    bool wide = radius > kMaxTiledMtfRadius;
    [constants setConstantValue:&wide type:MTLDataTypeBool atIndex:1];
    id<MTLFunction> function = [library newFunctionWithName:@"fotufilm_mtf_field"
                                             constantValues:constants
                                                      error:&error];
    if (!function) return nil;
    id<MTLComputePipelineState> pipeline =
        [device newComputePipelineStateWithFunction:function error:&error];
    if (pipeline) cache[key] = pipeline;
    return pipeline;
}

}

extern "C" __attribute__((visibility("default"))) int fotufilm_metal_mtf_field(
    halide_buffer_t *light, halide_buffer_t *mean, halide_buffer_t *weights,
    int32_t frame_width, int32_t frame_height, float flare, float luma_share,
    float primary_share0, float primary_share1, float primary_share2,
    int32_t radius, halide_buffer_t *field) {
    if (field->is_bounds_query() || light->is_bounds_query() ||
        mean->is_bounds_query() || weights->is_bounds_query()) {
        if (light->is_bounds_query()) {
            const int32_t min_x = field->dim[0].min;
            const int32_t max_x = min_x + field->dim[0].extent - 1;
            const int32_t min_y = field->dim[1].min;
            const int32_t max_y = min_y + field->dim[1].extent - 1;
            const int32_t lo_x = std::max(0, min_x - radius);
            const int32_t hi_x = std::min(frame_width - 1, max_x + radius);
            const int32_t lo_y = std::max(0, min_y - radius);
            const int32_t hi_y = std::min(frame_height - 1, max_y + radius);
            light->dim[0].min = lo_x;
            light->dim[0].extent = hi_x - lo_x + 1;
            light->dim[1].min = lo_y;
            light->dim[1].extent = hi_y - lo_y + 1;
            light->dim[2].min = 0;
            light->dim[2].extent = 4;
        }
        fill_bounds_query(mean, 4);
        if (weights->is_bounds_query()) {
            weights->dim[0].min = -radius;
            weights->dim[0].extent = 2 * radius + 1;
            weights->dim[1].min = 0;
            weights->dim[1].extent = 7;
        }
        return 0;
    }
    if (radius < 0 || radius > kMaxMtfRadius) {
        fprintf(stderr, "fotufilm_metal_mtf_field: radius %d out of 0...%d "
                        "for a %dx%d frame\n",
                radius, kMaxMtfRadius, frame_width, frame_height);
        return halide_error_code_generic_error;
    }

    const bool shared = runtime_shares_context;
    if (!shared && light->device_interface) {
        int sync_error = light->device_interface->device_sync(nullptr, light);
        if (sync_error) return sync_error;
    }

    halide_metal_device *raw_device = nullptr;
    halide_metal_command_queue *raw_queue = nullptr;
    int error = grain_context(&raw_device, &raw_queue, false);
    if (error) return error;
    id<MTLDevice> device = (__bridge id<MTLDevice>)raw_device;
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)raw_queue;

    int result = 0;
    @autoreleasepool {
        id<MTLComputePipelineState> pipeline = mtf_pipeline_for(device, radius);
        id<MTLBuffer> input = buffer_of(light);
        id<MTLBuffer> mean_buffer = buffer_of(mean);
        id<MTLBuffer> weight_buffer = buffer_of(weights);
        id<MTLBuffer> output = buffer_of(field);
        if (!pipeline || !input || !mean_buffer || !weight_buffer || !output) {
            halide_metal_release_context(nullptr);
            return halide_error_code_generic_error;
        }

        MtfParams params;
        params.width = frame_width;
        params.height = frame_height;
        params.in_min_x = light->dim[0].min;
        params.in_min_y = light->dim[1].min;
        params.in_stride_y = light->dim[1].stride;
        params.in_stride_c = light->dim[2].stride;
        params.out_min_x = field->dim[0].min;
        params.out_min_y = field->dim[1].min;
        params.out_extent_x = field->dim[0].extent;
        params.out_extent_y = field->dim[1].extent;
        params.out_stride_y = field->dim[1].stride;
        params.out_stride_c = field->dim[2].stride;
        params.weight_stride_c = weights->dim[1].stride;
        params.flare = flare;
        params.luma_share = luma_share;
        params.primary_share0 = primary_share0;
        params.primary_share1 = primary_share1;
        params.primary_share2 = primary_share2;

        id<MTLCommandBuffer> commands = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:input offset:crop_offset_of(light) atIndex:0];
        [encoder setBuffer:mean_buffer offset:crop_offset_of(mean) atIndex:1];
        [encoder setBuffer:weight_buffer
                    offset:crop_offset_of(weights)
                   atIndex:2];
        [encoder setBuffer:output offset:crop_offset_of(field) atIndex:3];
        [encoder setBytes:&params length:sizeof(params) atIndex:4];
        const int padded = kTile + 2 * radius;
        const size_t tile_cells = radius > kMaxTiledMtfRadius
            ? 0 : size_t(padded) * padded;
        const size_t row_cells = size_t(kTile) * padded;
        const size_t half_values = tile_cells * 4 + row_cells * 7;
        [encoder setThreadgroupMemoryLength:(half_values * sizeof(uint16_t) + 15)
                                            / 16 * 16
                                    atIndex:0];
        MTLSize groups = MTLSizeMake((params.out_extent_x + kTile - 1) / kTile,
                                     (params.out_extent_y + kTile - 1) / kTile,
                                     1);
        [encoder dispatchThreadgroups:groups
                threadsPerThreadgroup:MTLSizeMake(kTile, kTile, 1)];
        [encoder endEncoding];
        [commands commit];
        if (!shared) [commands waitUntilCompleted];
        field->set_device_dirty(true);
    }
    halide_metal_release_context(nullptr);
    return result;
}

#endif
