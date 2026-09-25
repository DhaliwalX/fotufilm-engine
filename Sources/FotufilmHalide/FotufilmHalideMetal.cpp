#include "FotufilmHalide.h"

// The schedules below are written against a DeviceAPI rather than against Metal, so the same
// pipeline serves every GPU the engine reaches: Metal on Apple, Vulkan on Android, WebGPU in the
// browser, and CUDA on a Linux box. Only the host-side buffer handling below is per-API.
#if defined(FOTUFILM_HALIDE_ENABLED) \
    && (defined(__APPLE__) || defined(FOTUFILM_HALIDE_CUDA))

#include "Pipeline/Gpu.h"
#include <algorithm>
#include <cmath>
#include <functional>
#if defined(__APPLE__) && !defined(FOTUFILM_HALIDE_AOT_GENERATOR)
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#endif
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>
#include <cstdlib>

using Halide::BoundaryConditions::constant_exterior;
using Halide::Buffer;
using Halide::DeviceAPI;
using Halide::Expr;
using Halide::Float;
using Halide::Func;
using Halide::ImageParam;
using Halide::Param;
using Halide::Pipeline;
using Halide::RDom;
using Halide::Target;
using Halide::UInt;
using Halide::Var;

using namespace fotufilm;
using namespace fotufilm::gpu;
using namespace fotufilm::pipelines;

namespace {


GpuHalationFieldsPipeline *halation_fields_pipeline() {
    static std::unique_ptr<GpuHalationFieldsPipeline> pipeline;
    static std::mutex pipeline_mutex;
    std::lock_guard<std::mutex> lock(pipeline_mutex);
    if (!pipeline) {
        pipeline = std::make_unique<GpuHalationFieldsPipeline>(
            "_metal_fields");
    }
    return pipeline.get();
}

/// The measure pipelines, kept for the life of the process like the frame ones. There are four:
/// the two quantities, each with and without the fast transcendentals, which is the only bit of
/// the frame's feature mask a measurement is sensitive to.
GpuMeasurePipeline *measure_pipeline_for(GpuMeasurePipeline::Quantity quantity,
                                           bool approximate) {
    const int index = (quantity == GpuMeasurePipeline::Quantity::Flare ? 2 : 0)
        + (approximate ? 1 : 0);
    static std::unique_ptr<GpuMeasurePipeline> pipelines[4];
    static std::mutex pipelines_mutex;
    std::lock_guard<std::mutex> lock(pipelines_mutex);
    if (!pipelines[index]) {
        pipelines[index] = std::make_unique<GpuMeasurePipeline>(
            quantity, approximate, "_metal_measure_" + std::to_string(index));
    }
    return pipelines[index].get();
}

/// The colour space is coefficient-driven; only the realtime approximation selects a variant.
GpuDecodePipeline *decode_pipeline(bool approximate) {
    static std::unique_ptr<GpuDecodePipeline> pipelines[2];
    static std::mutex pipeline_mutex;
    std::lock_guard<std::mutex> lock(pipeline_mutex);
    const int index = approximate ? 1 : 0;
    if (!pipelines[index]) {
        pipelines[index] = std::make_unique<GpuDecodePipeline>(
            approximate, "_metal_decode_" + std::to_string(index));
    }
    return pipelines[index].get();
}

std::unordered_map<int32_t, std::unique_ptr<GpuFramePipeline>> &pipelines_registry() {
    static std::unordered_map<int32_t, std::unique_ptr<GpuFramePipeline>> pipelines;
    return pipelines;
}

std::mutex &pipelines_mutex() {
    static std::mutex mutex;
    return mutex;
}

GpuFramePipeline *pipeline_for(int32_t feature_mask) {
    // The enlarger's blur joins the key: it is a stage the pipeline either has or has not, and a
    // GPU frame that skipped it would not match the reference the consistency tests hold it to.
    // Every bit the pipeline branches on has to appear here. A bit the key drops is a bit the
    // pipeline is built without, and the stage then compiles, links, runs and does nothing.
    constexpr int32_t variant_bits =
        FOTUFILM_AOT_VARIANT_BITS | ((FOTUFILM_FRAME_COUPLER_DIFFUSION << 1) - 1)
        | FOTUFILM_FRAME_PRINT_MTF | FOTUFILM_FRAME_GRAIN_MOTTLE
        | FOTUFILM_FRAME_TEXTURE | FOTUFILM_FRAME_DIFFUSION
        | FOTUFILM_FRAME_DONOR_LAYER | FOTUFILM_FRAME_NO_FILM;
    const int32_t requested = feature_mask & variant_bits & ~FOTUFILM_FRAME_REVERSAL;
    // One pipeline per class, not per request: every stage the class can carry is compiled in
    // and the request selects at runtime, so the frame a stock asks for costs what that stock's
    // stages cost and a second stock in the same class compiles nothing. No film needs no
    // stages at all.
    int32_t variant = requested;
    if (!(requested & FOTUFILM_FRAME_NO_FILM)) {
        variant |= FOTUFILM_VARIANT_STAGE_BITS;
    }
    // Keyed by the mask in a map rather than a mask-wide sparse array. The array version cost
    // "nothing but address space" — until FOTUFILM_FRAME_DONOR_LAYER pushed the mask past bit 26
    // and the zerofill grew beyond 2 GB, at which point parts of a statically linked binary's
    // data segment land further from its text than Swift's 32-bit *relative* metadata pointers
    // can reach, and every protocol-conformance scan in the host process is one SIGBUS away.
    // The lock was already here; the map adds one hash to a per-frame lookup.
    std::lock_guard<std::mutex> lock(pipelines_mutex());
    std::unique_ptr<GpuFramePipeline> &slot = pipelines_registry()[variant];
    if (!slot) {
        slot = std::make_unique<GpuFramePipeline>(
            variant, "_metal_variant_" + std::to_string(variant));
    }
    return slot.get();
}

/// Drops the halation grids every class keeps behind its configuration — tens of megabytes a
/// frame at a hundred megapixels, worth nothing once its develop is over.
void release_frame_fields() {
    std::lock_guard<std::mutex> lock(pipelines_mutex());
    for (auto &entry : pipelines_registry()) entry.second->release_fields();
}

template<typename Function>
int32_t translate_metal_exceptions(Function &&function) {
    try {
        function();
        return 0;
    } catch (const Halide::Error &error) {
        std::fprintf(stderr, "Fotufilm Halide Metal error: %s\n", error.what());
        return -1;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Fotufilm Halide Metal error: %s\n", error.what());
        return -1;
    } catch (...) {
        std::fprintf(stderr, "Fotufilm Halide Metal error: unknown exception\n");
        return -2;
    }
}

bool valid_flare_mean(const float *configuration, int32_t feature_mask) {
    if ((feature_mask & FOTUFILM_FRAME_FLARE) == 0) return true;
    if ((feature_mask & FOTUFILM_FRAME_FLARE_MEASURE) != 0) return true;
    for (int channel = 0; channel < 3; ++channel) {
        const float value = configuration[FOTUFILM_CONFIG_FLARE_MEAN + channel];
        if (!std::isfinite(value) || value < 0.0f) return false;
    }
    return true;
}

}

// The generator never runs a pipeline, and is linked without the Objective-C runtime.
#if defined(__APPLE__) && !defined(FOTUFILM_HALIDE_AOT_GENERATOR)
namespace {

/// How many command buffers the runtime's queue may have in flight, and why it is bounded.
///
/// Halide commits one command buffer per kernel and never waits, and frees an intermediate the
/// moment the host passes its last consumer — but Metal keeps a buffer alive until the command
/// buffers that read it complete. The host runs through a forty-stage tile in a few
/// milliseconds while the device takes hundreds, so without a bound every intermediate of the
/// tile is allocated before the first is released, and a tile's footprint is the sum of its
/// stages rather than the largest few. A queue that blocks the host at this many outstanding
/// command buffers keeps it that close behind the device, so the early frees land. Four is
/// enough to keep the device fed across a launch gap; the AOT shim bounds its queue the same
/// way (see halide_metal_acquire_context there).
constexpr unsigned long kMetalQueueDepth = 4;

id bounded_new_command_queue(id device, SEL) {
    return ((id (*)(id, SEL, unsigned long))objc_msgSend)(
        device, sel_getUid("newCommandQueueWithMaxCommandBufferCount:"), kMetalQueueDepth);
}

/// Has the JIT runtime create its queue bounded. The runtime asks the default device for
/// `newCommandQueue` the first time a pipeline runs, and offers no way to hand it a queue, so
/// that method answers with a bounded queue for the one call that creates it, and is put back.
void bound_metal_queue() {
    static std::once_flag once;
    std::call_once(once, [] {
        void *metal = dlopen("/System/Library/Frameworks/Metal.framework/Metal", RTLD_LAZY);
        auto create = reinterpret_cast<id (*)(void)>(
            metal ? dlsym(metal, "MTLCreateSystemDefaultDevice") : nullptr);
        if (!create) return;
        id system = create();
        if (!system) return;
        Method method = class_getInstanceMethod(object_getClass(system),
                                                sel_getUid("newCommandQueue"));
        if (!method) return;
        const IMP original = method_setImplementation(
            method, reinterpret_cast<IMP>(bounded_new_command_queue));
        // A trivial realization, so the runtime makes its context now.
        try {
            Func probe("fotufilm_metal_probe");
            Var x("x");
            probe(x) = x;
            Var block, thread;
            probe.gpu_tile(x, block, thread, 8, Halide::TailStrategy::GuardWithIf,
                           default_gpu_configuration().device);
            Buffer<int32_t> out = probe.realize({8}, default_gpu_configuration().target());
            out.copy_to_host();
        } catch (...) {
        }
        method_setImplementation(method, original);
        ((void (*)(id, SEL))objc_msgSend)(system, sel_getUid("release"));
    });
}

}
#endif

extern "C" int32_t fotufilm_halide_metal_available(void) {
    const bool available = Halide::host_supports_target_device(default_gpu_configuration().target());
#if defined(__APPLE__) && !defined(FOTUFILM_HALIDE_AOT_GENERATOR)
    if (available) bound_metal_queue();
#endif
    return available ? 1 : 0;
}

extern "C" int32_t fotufilm_halide_metal_variant_exists(int32_t) {
    // A JIT build compiles whatever mask it is handed, so there is no such thing here as a
    // feature the build does not carry.
    return 1;
}

extern "C" void fotufilm_halide_metal_report_profile(void) {}

extern "C" int32_t fotufilm_halide_metal_still_fast_bits(void) {
    return default_gpu_configuration().still_fast;
}

extern "C" int32_t fotufilm_halide_metal_prepare(
    int32_t feature_mask, const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id) {
    if (!fotufilm_halide_metal_available() || !exposure_lut ||
        !film_output_lut || !paper_output_lut) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask)->prepare_luts(
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id);
    });
}

extern "C" int32_t fotufilm_halide_metal_process_srgb8(
    const uint8_t *input, uint8_t *output, int32_t width, int32_t height,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, uint64_t spectral_cache_id,
    int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_metal_available() || !input || !output || !configuration ||
        !exposure_lut || !film_output_lut || !paper_output_lut ||
        width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask)->run_host(
            input, output, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask));
    });
}

extern "C" int32_t fotufilm_halide_metal_process_linear_float_rows(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t out_y, int32_t out_rows,
    int32_t origin_x, int32_t origin_y, const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_metal_available() || !input || !output || !configuration ||
        !exposure_lut || !film_output_lut || !paper_output_lut ||
        width <= 0 || height <= 0 ||
        out_y < 0 || out_rows <= 0 || out_y + out_rows > height ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask | FOTUFILM_FRAME_FLOAT_IO)->run_host(
            input, output, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask | FOTUFILM_FRAME_FLOAT_IO),
            origin_x, origin_y, out_y, out_rows);
    });
}

extern "C" int32_t fotufilm_halide_metal_process_linear_float(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t origin_x, int32_t origin_y, const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (height <= 0) return -1;
    return fotufilm_halide_metal_process_linear_float_rows(
        input, output, width, height, 0, height, origin_x, origin_y,
        configuration, exposure_lut, film_output_lut, paper_output_lut,
        lut_dimension, spectral_cache_id, feature_mask, seed);
}

namespace {

/// The common body of the tile entry points: validates the window, appends the halation grids
/// behind the configuration for a FIELDS_IN develop, and runs the class the mask names.
int32_t process_tile(GpuFramePipeline::Tile tile, const float *fields, int32_t fields_floats,
                     uint64_t fields_id, int32_t feature_mask) {
    if (!fotufilm_halide_metal_available() || (!tile.input_host && !tile.input_handle)
        || (!tile.output_host && !tile.output_handle) || !tile.configuration
        || !tile.exposure || !tile.film || !tile.paper
        || tile.width <= 0 || tile.height <= 0
        || tile.out_x < 0 || tile.out_columns <= 0
        || tile.out_x + tile.out_columns > tile.width
        || tile.out_y < 0 || tile.out_rows <= 0 || tile.out_y + tile.out_rows > tile.height
        || (fields && fields_floats <= 11)
        || !valid_flare_mean(tile.configuration, feature_mask)) return -1;
    int32_t mask = feature_mask | FOTUFILM_FRAME_FLOAT_IO;
    if (fields) mask |= FOTUFILM_FRAME_FIELDS_IN;
    tile.requested = mask;
    return translate_metal_exceptions([&] {
        std::vector<float> combined;
        if (fields) {
            tile.configuration_floats = FOTUFILM_FRAME_CONFIGURATION_COUNT + fields_floats;
            tile.configuration_id = fields_id;
            if (fields == tile.configuration + FOTUFILM_FRAME_CONFIGURATION_COUNT) {
                // One blob, the caller's, read in place for as long as its id stands.
                tile.configuration_stable = true;
            } else {
                combined.resize(size_t(tile.configuration_floats));
                std::memcpy(combined.data(), tile.configuration,
                            FOTUFILM_FRAME_CONFIGURATION_COUNT * sizeof(float));
                std::memcpy(combined.data() + FOTUFILM_FRAME_CONFIGURATION_COUNT, fields,
                            size_t(fields_floats) * sizeof(float));
                tile.configuration = combined.data();
            }
        }
        pipeline_for(mask)->run_tile<float, float>(tile);
    });
}

GpuFramePipeline::Tile frame_tile(
    int32_t width, int32_t height, int32_t out_x, int32_t out_columns, int32_t out_y,
    int32_t out_rows, int32_t origin_x, int32_t origin_y, const float *configuration,
    const float *exposure_lut, const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, uint64_t spectral_cache_id, uint32_t seed) {
    GpuFramePipeline::Tile tile;
    tile.width = width;
    tile.height = height;
    tile.out_x = out_x;
    tile.out_columns = out_columns;
    tile.out_y = out_y;
    tile.out_rows = out_rows;
    tile.origin_x = origin_x;
    tile.origin_y = origin_y;
    tile.configuration = configuration;
    tile.exposure = exposure_lut;
    tile.film = film_output_lut;
    tile.paper = paper_output_lut;
    tile.dimension = lut_dimension;
    tile.cache_id = spectral_cache_id;
    tile.seed = seed;
    return tile;
}

/// The light-grid entry points' body: the window is in cells of the strip's own grid.
int32_t process_light_grid(GpuFramePipeline::Tile tile, int32_t feature_mask) {
    const int32_t stride = fotufilm_halation_stride(
        std::max(0, int32_t(tile.configuration[FOTUFILM_CONFIG_HALATION_RADIUS])));
    const int32_t grid_height = (tile.height + tile.origin_y % stride + stride - 1) / stride;
    if (!fotufilm_halide_metal_available() || (!tile.input_host && !tile.input_handle)
        || !tile.output_host || !tile.configuration
        || !tile.exposure || !tile.film || !tile.paper
        || tile.width <= 0 || tile.height <= 0
        || tile.out_y < 0 || tile.out_rows <= 0 || tile.out_y + tile.out_rows > grid_height
        || !valid_flare_mean(tile.configuration, feature_mask)) return -1;
    const int32_t mask = (feature_mask | FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_LIGHT_OUT)
        & ~FOTUFILM_FRAME_FIELDS_IN;
    tile.requested = mask;
    tile.out_x = 0;
    tile.out_columns = (tile.width + stride - 1) / stride;
    return translate_metal_exceptions([&] {
        pipeline_for(mask)->run_tile<float, float>(tile);
    });
}

}

extern "C" int32_t fotufilm_halide_metal_process_linear_float_tile(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t out_x, int32_t out_columns, int32_t out_y, int32_t out_rows,
    int32_t origin_x, int32_t origin_y, const float *configuration,
    const float *fields, int32_t fields_floats, uint64_t fields_id,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    GpuFramePipeline::Tile tile = frame_tile(
        width, height, out_x, out_columns, out_y, out_rows, origin_x, origin_y,
        configuration, exposure_lut, film_output_lut, paper_output_lut, lut_dimension,
        spectral_cache_id, seed);
    tile.input_host = input;
    tile.output_host = output;
    return process_tile(tile, fields, fields_floats, fields_id, feature_mask);
}

extern "C" int32_t fotufilm_halide_metal_process_light_grid(
    const float *input, float *grid_out, int32_t width, int32_t height,
    int32_t out_y, int32_t out_rows, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!configuration) return -1;
    GpuFramePipeline::Tile tile = frame_tile(
        width, height, 0, 0, out_y, out_rows, origin_x, origin_y,
        configuration, exposure_lut, film_output_lut, paper_output_lut, lut_dimension,
        spectral_cache_id, seed);
    tile.input_host = input;
    tile.output_host = grid_out;
    return process_light_grid(tile, feature_mask);
}

extern "C" int32_t fotufilm_halide_metal_halation_fields_floats(
    int32_t width, int32_t height, const int32_t *halation_radii) {
    if (width <= 0 || height <= 0 || !halation_radii) return -1;
    int32_t total = 11;
    for (int scale = 0; scale < 3; ++scale) {
        const int32_t stride = fotufilm_halation_stride(
            std::max(0, halation_radii[scale]));
        total += ((width + stride - 1) / stride)
            * ((height + stride - 1) / stride) * 3;
    }
    return total;
}

extern "C" int32_t fotufilm_halide_metal_halation_fields(
    const float *grid, int32_t width, int32_t height,
    const int32_t *halation_radii, float *fields, int32_t fields_floats) {
    if (!fotufilm_halide_metal_available() || !grid || !halation_radii ||
        !fields || width <= 0 || height <= 0 ||
        fields_floats != fotufilm_halide_metal_halation_fields_floats(
            width, height, halation_radii)) return -1;
    return translate_metal_exceptions([&] {
        int32_t strides[3], strided[3];
        int32_t grid_floats[3];
        for (int scale = 0; scale < 3; ++scale) {
            const int32_t radius = std::max(0, halation_radii[scale]);
            strides[scale] = fotufilm_halation_stride(radius);
            strided[scale] = fotufilm_halation_strided_radius(
                radius, strides[scale]);
            grid_floats[scale] =
                ((width + strides[scale] - 1) / strides[scale])
                * ((height + strides[scale] - 1) / strides[scale]) * 3;
        }
        fields[0] = float(width);
        fields[1] = float(height);
        int32_t offset = 0;
        for (int scale = 0; scale < 3; ++scale) {
            fields[2 + scale * 3] =
                float((width + strides[scale] - 1) / strides[scale]);
            fields[3 + scale * 3] =
                float((height + strides[scale] - 1) / strides[scale]);
            fields[4 + scale * 3] = float(offset);
            offset += grid_floats[scale];
        }
        halation_fields_pipeline()->run_host(
            grid, width, height, strides, strided,
            fields + 11,
            fields + 11 + grid_floats[0],
            fields + 11 + grid_floats[0] + grid_floats[1]);
    });
}

extern "C" void fotufilm_halide_metal_release_fields(void) {
    release_frame_fields();
}

// Wrapping a caller's texture is Metal-only: the CUDA host talks to the pipeline through the
// host-buffer entry points below, where Halide owns the device allocation.
#if defined(__APPLE__)

extern "C" int32_t fotufilm_halide_metal_process_buffers(
    uint64_t input_mtl_buffer, uint64_t output_mtl_buffer,
    int32_t width, int32_t height, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_metal_available() || input_mtl_buffer == 0 ||
        output_mtl_buffer == 0 || !configuration || !exposure_lut ||
        !film_output_lut || !paper_output_lut || width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask)->run_wrapped<uint8_t>(
            input_mtl_buffer, output_mtl_buffer, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask),
            origin_x, origin_y);
    });
}

extern "C" int32_t fotufilm_halide_metal_process_buffers_float(
    uint64_t input_mtl_buffer, uint64_t output_mtl_buffer,
    int32_t width, int32_t height, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_metal_available() || input_mtl_buffer == 0 ||
        output_mtl_buffer == 0 || !configuration || !exposure_lut ||
        !film_output_lut || !paper_output_lut || width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask | FOTUFILM_FRAME_FLOAT_IO)->run_wrapped<float>(
            input_mtl_buffer, output_mtl_buffer, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask | FOTUFILM_FRAME_FLOAT_IO),
            origin_x, origin_y);
    });
}

extern "C" int32_t fotufilm_halide_metal_process_buffers_float_tile(
    uint64_t input_mtl_buffer, uint64_t output_mtl_buffer,
    int32_t width, int32_t height,
    int32_t out_x, int32_t out_columns, int32_t out_y, int32_t out_rows,
    int32_t origin_x, int32_t origin_y, const float *configuration,
    const float *fields, int32_t fields_floats, uint64_t fields_id,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    GpuFramePipeline::Tile tile = frame_tile(
        width, height, out_x, out_columns, out_y, out_rows, origin_x, origin_y,
        configuration, exposure_lut, film_output_lut, paper_output_lut, lut_dimension,
        spectral_cache_id, seed);
    tile.input_handle = input_mtl_buffer;
    tile.output_handle = output_mtl_buffer;
    return process_tile(tile, fields, fields_floats, fields_id, feature_mask);
}

extern "C" int32_t fotufilm_halide_metal_process_buffers_light_grid(
    uint64_t input_mtl_buffer, float *grid_out, int32_t width, int32_t height,
    int32_t out_y, int32_t out_rows, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!configuration) return -1;
    GpuFramePipeline::Tile tile = frame_tile(
        width, height, 0, 0, out_y, out_rows, origin_x, origin_y,
        configuration, exposure_lut, film_output_lut, paper_output_lut, lut_dimension,
        spectral_cache_id, seed);
    tile.input_handle = input_mtl_buffer;
    tile.output_host = grid_out;
    return process_light_grid(tile, feature_mask);
}

extern "C" int32_t fotufilm_halide_metal_process_buffers_head(
    uint64_t input_mtl_buffer, uint64_t density_mtl_buffer,
    int32_t width, int32_t height, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_metal_available() || input_mtl_buffer == 0 ||
        density_mtl_buffer == 0 || !configuration || !exposure_lut ||
        !film_output_lut || !paper_output_lut || width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        // Exactly FOTUFILM_AOT_HEAD, which is what the head variants were compiled
        // from: everything up to the cut, and nothing that belongs after it. The
        // enlarger belongs after it — it images a negative that already has grain
        // in it — so stripping it here is what keeps the split path's print the
        // same picture the unsplit path makes.
        const int32_t head_mask = (feature_mask
            & ~(FOTUFILM_FRAME_GRAIN | FOTUFILM_FRAME_GRAIN_MOTTLE | FOTUFILM_FRAME_PRINT_MTF))
            | FOTUFILM_FRAME_DENSITY_OUT;
        pipeline_for(head_mask)->run_wrapped<uint8_t, Halide::float16_t>(
            input_mtl_buffer, density_mtl_buffer, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (head_mask),
            origin_x, origin_y);
    });
}

extern "C" int32_t fotufilm_halide_metal_process_buffers_tail(
    uint64_t density_mtl_buffer, uint64_t output_mtl_buffer,
    int32_t width, int32_t height,
    int32_t density_width, int32_t density_height,
    int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_metal_available() || density_mtl_buffer == 0 ||
        output_mtl_buffer == 0 || !configuration || !exposure_lut ||
        !film_output_lut || !paper_output_lut || width <= 0 || height <= 0) return -1;
    return translate_metal_exceptions([&] {
        // The grain mixture rides the tail with the grain it belongs to: the host has
        // already split the published granularity's variance between the two fields, so a
        // tail that dropped the bit would render the quiet half of the mixture.
        // Exactly FOTUFILM_AOT_TAIL: grain and the enlarger that images it, in that
        // order. Both the grain model and the mixture ride through, so the tail
        // lays the field the frame actually asked for.
        const int32_t tail_mask = (feature_mask
            & (FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_REVERSAL
               | FOTUFILM_FRAME_GRAIN_MOTTLE | FOTUFILM_FRAME_PRINT_MTF))
            | FOTUFILM_FRAME_GRAIN | FOTUFILM_FRAME_DENSITY_IN;
        pipeline_for(tail_mask)->run_wrapped<Halide::float16_t, uint8_t>(
            density_mtl_buffer, output_mtl_buffer, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (tail_mask),
            origin_x, origin_y, density_width, density_height);
    });
}

extern "C" int32_t fotufilm_halide_metal_measure_tone_rows(
    uint64_t input_mtl_buffer, const float *input_rows, float *rows_out,
    int32_t grid_width, int32_t width, int32_t rows,
    const float *configuration) {
    if (!fotufilm_halide_metal_available() ||
        (input_mtl_buffer == 0) == (input_rows == nullptr) ||
        !rows_out || !configuration || width <= 0 || rows <= 0 ||
        grid_width <= 0 || grid_width > width) return -1;
    return translate_metal_exceptions([&] {
        // No spectral recovery in this one, so no cube to cache; the exposure LUT is bound only
        // because the pipeline shares its parameter list with the glare pass.
        static const std::vector<float> unused(kLutValueCount, 0.0f);
        measure_pipeline_for(GpuMeasurePipeline::Quantity::Tone, false)
            ->run_metal(input_mtl_buffer, input_rows, rows_out, grid_width,
                        width, rows, 0, grid_width, configuration,
                        unused.data(), kLutDimension, 1);
    });
}

extern "C" int32_t fotufilm_halide_metal_measure_flare_rows(
    uint64_t input_mtl_buffer, const float *input_rows, float *rows_out,
    int32_t width, int32_t rows, int32_t origin_y,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, uint64_t spectral_cache_id, int32_t feature_mask) {
    if (!fotufilm_halide_metal_available() ||
        (input_mtl_buffer == 0) == (input_rows == nullptr) ||
        !rows_out || !configuration || !exposure_lut || !film_output_lut ||
        !paper_output_lut || width <= 0 || rows <= 0 || origin_y < 0) return -1;
    return translate_metal_exceptions([&] {
        const bool approximate = (feature_mask & FOTUFILM_FRAME_EXACT_MATH) == 0;
        measure_pipeline_for(GpuMeasurePipeline::Quantity::Flare, approximate)
            ->run_metal(input_mtl_buffer, input_rows, rows_out, 3, width, rows,
                        origin_y, 1, configuration, exposure_lut, lut_dimension,
                        spectral_cache_id);
    });
}

extern "C" int32_t fotufilm_halide_metal_decode_rows(
    uint64_t input_mtl_buffer, const float *input_rows,
    uint64_t output_mtl_buffer, float *output_rows, float *report_out,
    int32_t width, int32_t rows, const float *parameters) {
    if (!fotufilm_halide_metal_available() ||
        (input_mtl_buffer == 0) == (input_rows == nullptr) ||
        (output_mtl_buffer == 0) == (output_rows == nullptr) ||
        !report_out || !parameters || width <= 0 || rows <= 0) return -1;
    return translate_metal_exceptions([&] {
        decode_pipeline(false)->run_metal(input_mtl_buffer, input_rows, output_mtl_buffer,
                                          output_rows, report_out, width, rows, parameters);
    });
}

extern "C" int32_t fotufilm_halide_metal_decode_rows_realtime(
    uint64_t input_mtl_buffer, const float *input_rows,
    uint64_t output_mtl_buffer, float *output_rows, float *report_out,
    int32_t width, int32_t rows, const float *parameters) {
    if (!fotufilm_halide_metal_available() ||
        (input_mtl_buffer == 0) == (input_rows == nullptr) ||
        (output_mtl_buffer == 0) == (output_rows == nullptr) ||
        !report_out || !parameters || width <= 0 || rows <= 0) return -1;
    return translate_metal_exceptions([&] {
        decode_pipeline(true)->run_metal(input_mtl_buffer, input_rows, output_mtl_buffer,
                                         output_rows, report_out, width, rows, parameters);
    });
}

#endif  // __APPLE__

#if defined(FOTUFILM_HALIDE_CUDA)

// The CUDA surface is deliberately the host-buffer subset: a frame in, a frame out, with the
// spectral cubes cached on the device between calls exactly as they are on Metal.
extern "C" int32_t fotufilm_halide_cuda_available(void) {
    return Halide::host_supports_target_device(default_gpu_configuration().target()) ? 1 : 0;
}

extern "C" int32_t fotufilm_halide_cuda_prepare(
    int32_t feature_mask, const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id) {
    if (!fotufilm_halide_cuda_available() || !exposure_lut ||
        !film_output_lut || !paper_output_lut) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask)->prepare_luts(
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id);
    });
}

extern "C" int32_t fotufilm_halide_cuda_process_srgb8(
    const uint8_t *input, uint8_t *output, int32_t width, int32_t height,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, uint64_t spectral_cache_id,
    int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_cuda_available() || !input || !output || !configuration ||
        !exposure_lut || !film_output_lut || !paper_output_lut ||
        width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask)->run_host(
            input, output, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask));
    });
}

extern "C" int32_t fotufilm_halide_cuda_process_linear_float(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t origin_x, int32_t origin_y, const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_cuda_available() || !input || !output || !configuration ||
        !exposure_lut || !film_output_lut || !paper_output_lut ||
        width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask | FOTUFILM_FRAME_FLOAT_IO)->run_host(
            input, output, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask | FOTUFILM_FRAME_FLOAT_IO),
            origin_x, origin_y);
    });
}

// The device-pointer pair. On a discrete GPU the host round trip above is not a detail of the
// entry point, it is the frame budget: a 4K RGBA float frame is 132 MB each way, which costs
// about 21 ms on a 4090 against the 1.6 ms the whole simulation takes. A video pipeline whose
// frames are decoded and encoded on the device never needs that trip, and these are the entry
// points that let it keep them there — the CUDA counterpart of the MTLBuffer pair on Apple.
//
// The pointers are plain CUdeviceptr values, interleaved RGBA and tightly packed, and the caller
// keeps ownership: nothing here allocates, frees, or caches them.
extern "C" int32_t fotufilm_halide_cuda_process_device_srgb8(
    uint64_t input_device_pointer, uint64_t output_device_pointer,
    int32_t width, int32_t height, const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_cuda_available() || !input_device_pointer ||
        !output_device_pointer || !configuration ||
        !exposure_lut || !film_output_lut || !paper_output_lut ||
        width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask)->run_wrapped<uint8_t>(
            input_device_pointer, output_device_pointer, width, height,
            configuration, exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask));
    });
}

extern "C" int32_t fotufilm_halide_cuda_process_device_linear_float(
    uint64_t input_device_pointer, uint64_t output_device_pointer,
    int32_t width, int32_t height, int32_t origin_x, int32_t origin_y,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, uint64_t spectral_cache_id,
    int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_cuda_available() || !input_device_pointer ||
        !output_device_pointer || !configuration ||
        !exposure_lut || !film_output_lut || !paper_output_lut ||
        width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask | FOTUFILM_FRAME_FLOAT_IO)->run_wrapped<float>(
            input_device_pointer, output_device_pointer, width, height,
            configuration, exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask | FOTUFILM_FRAME_FLOAT_IO),
            origin_x, origin_y);
    });
}

#endif  // FOTUFILM_HALIDE_CUDA

#else

extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_available(void) { return 0; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_variant_exists(int32_t) { return 0; }
extern "C" FOTUFILM_FALLBACK void fotufilm_halide_metal_report_profile(void) {}
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_still_fast_bits(void) { return 0; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_prepare(
    int32_t, const float *, const float *, const float *, int32_t, uint64_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_srgb8(
    const uint8_t *, uint8_t *, int32_t, int32_t, const float *, const float *,
    const float *, const float *, int32_t, uint64_t, int32_t, uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_linear_float(
    const float *, float *, int32_t, int32_t, int32_t, int32_t, const float *,
    const float *, const float *, const float *, int32_t, uint64_t, int32_t,
    uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_linear_float_rows(
    const float *, float *, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, const float *, const float *, const float *, const float *,
    int32_t, uint64_t, int32_t, uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_linear_float_tile(
    const float *, float *, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, int32_t, const float *, const float *, int32_t, uint64_t,
    const float *, const float *, const float *, int32_t, uint64_t, int32_t,
    uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_light_grid(
    const float *, float *, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, const float *, const float *, const float *, const float *,
    int32_t, uint64_t, int32_t, uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_halation_fields_floats(
    int32_t, int32_t, const int32_t *) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_halation_fields(
    const float *, int32_t, int32_t, const int32_t *, float *,
    int32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK void fotufilm_halide_metal_release_fields(void) {}
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_buffers(
    uint64_t, uint64_t, int32_t, int32_t, int32_t, int32_t,
    const float *, const float *,
    const float *, const float *, int32_t, uint64_t, int32_t, uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_measure_tone_rows(
    uint64_t, const float *, float *, int32_t, int32_t, int32_t,
    const float *) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_measure_flare_rows(
    uint64_t, const float *, float *, int32_t, int32_t, int32_t, const float *,
    const float *, const float *, const float *, int32_t, uint64_t,
    int32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_decode_rows(
    uint64_t, const float *, uint64_t, float *, float *, int32_t, int32_t,
    const float *) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_decode_rows_realtime(
    uint64_t, const float *, uint64_t, float *, float *, int32_t, int32_t,
    const float *) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_buffers_float(
    uint64_t, uint64_t, int32_t, int32_t, int32_t, int32_t, const float *,
    const float *, const float *, const float *, int32_t, uint64_t, int32_t,
    uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_buffers_float_tile(
    uint64_t, uint64_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, int32_t, const float *, const float *, int32_t, uint64_t,
    const float *, const float *, const float *, int32_t, uint64_t, int32_t,
    uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_buffers_light_grid(
    uint64_t, float *, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, const float *, const float *, const float *, const float *,
    int32_t, uint64_t, int32_t, uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_buffers_head(
    uint64_t, uint64_t, int32_t, int32_t, int32_t, int32_t, const float *,
    const float *, const float *, const float *, int32_t, uint64_t, int32_t,
    uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_buffers_tail(
    uint64_t, uint64_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    const float *, const float *, const float *, const float *, int32_t,
    uint64_t, int32_t, uint32_t) { return -1; }

#endif
