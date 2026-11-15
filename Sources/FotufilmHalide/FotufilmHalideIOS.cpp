#if defined(FOTUFILM_HALIDE_IOS_AOT)

#ifndef FOTUFILM_AOT_WINDOWED_HOST
#define FOTUFILM_AOT_WINDOWED_HOST 0
#endif

#include "FotufilmHalideIOSVariants.h"
#include "FotufilmAotFrame.h"
#include "FotufilmFilmTileBuild.h"
#include "FotufilmNegativeScan.h"
#include "fotufilm_halide_ios_negative_cpu.h"
#include "fotufilm_halide_ios_negative_metal.h"
#include "fotufilm_halide_ios_scan_prepare_cpu.h"
#include "fotufilm_halide_ios_trichromatic_layer_cpu.h"
#include "fotufilm_halide_ios_trichromatic_merge_cpu.h"
#include "FotufilmTrichromaticMeasure.h"
#include "fotufilm_halide_ios_transport_cpu.h"
#include "fotufilm_halide_ios_transport_metal.h"
#include "fotufilm_halide_ios_transport_scene_cpu.h"
#include "fotufilm_halide_ios_transport_domain_cpu.h"
#include "fotufilm_halide_ios_transport_scene_metal.h"
#include "fotufilm_halide_ios_transport_domain_metal.h"
#include "TransportFrameAot.h"
#include "FotufilmTransport.h"
#include <HalideBuffer.h>
#include <HalideRuntimeMetal.h>

#include "FotufilmHalide.h"
#include "FotufilmHalideDevelop.h"
#include "FotufilmHalideGeometry.h"
#include "FotufilmResolvedFrameParams.h"
#include "Pipeline/FilmTileStore.h"

#include <TargetConditionals.h>
#include <dispatch/dispatch.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>

#include <algorithm>
#include <iterator>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <new>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

using Halide::Runtime::Buffer;

// Device and simulator byte-input kernels are generated with a half exposure LUT. Float-input
// kernels retain a float LUT, including the realtime HDR path; run_aot selects the matching copy
// by feature mask.
#if TARGET_OS_IPHONE
#define FOTUFILM_AOT_HALF_EXPOSURE_LUT 1
#else
#define FOTUFILM_AOT_HALF_EXPOSURE_LUT 0
#endif

/// The kStillFast* bits the AOT kernels of this build were generated with. The default must
/// equal `still_fast_default()` in tools/generate_halide_ios.cpp for device targets; a build
/// experimenting through FOTUFILM_STILL_FAST overrides both together.
#ifndef FOTUFILM_STILL_FAST_BITS
#define FOTUFILM_STILL_FAST_BITS 0
#endif

namespace {

constexpr int kLutDimension = 33;
constexpr int kLutValueCount = kLutDimension * kLutDimension * kLutDimension * 4;
constexpr int kHalationRadiusOffset = FOTUFILM_CONFIG_HALATION_RADIUS;

struct SpectralCache {
    Buffer<float> exposure;
    Buffer<float> film;
    Buffer<float> paper;
#if FOTUFILM_AOT_HALF_EXPOSURE_LUT
    Buffer<void> exposure_half;
#endif
    uint64_t identifier = 0;

    int ensure(const float *exposure_values, const float *film_values,
               const float *paper_values, int32_t dimension, uint64_t cache_id) {
        if (dimension != kLutDimension || !exposure_values ||
            !film_values || !paper_values) return -1;
        if (identifier == cache_id && exposure.data() != nullptr) return 0;
        exposure = Buffer<float>(kLutValueCount);
        film = Buffer<float>(kLutValueCount);
        paper = Buffer<float>(kLutValueCount);
        std::memcpy(exposure.data(), exposure_values, kLutValueCount * sizeof(float));
        std::memcpy(film.data(), film_values, kLutValueCount * sizeof(float));
        std::memcpy(paper.data(), paper_values, kLutValueCount * sizeof(float));
        exposure.set_host_dirty();
        film.set_host_dirty();
        paper.set_host_dirty();
        const halide_device_interface_t *metal = halide_metal_device_interface();
        int error = exposure.copy_to_device(metal);
        if (!error) error = film.copy_to_device(metal);
        if (!error) error = paper.copy_to_device(metal);
#if FOTUFILM_AOT_HALF_EXPOSURE_LUT
        if (!error) {
            exposure_half = Buffer<void>(
                halide_type_t(halide_type_float, 16), kLutValueCount);
            uint16_t *half_values =
                reinterpret_cast<uint16_t *>(exposure_half.data());
            for (int index = 0; index < kLutValueCount; ++index) {
                half_values[index] = fotufilm_float_to_half(exposure_values[index]);
            }
            exposure_half.set_host_dirty();
            error = exposure_half.copy_to_device(metal);
        }
#endif
        if (!error) identifier = cache_id;
        return error;
    }
};

/// Mutable AOT argument and LUT storage for one independent renderer. Resolve binds one of these
/// for each OFX instance, so generated kernels receive per-instance buffers without a process-wide
/// render lock. Callers outside Resolve fall back to one state per calling thread.
struct ExecutionState {
    SpectralCache spectral_cache;
    Buffer<float> extended_configuration;
    uint64_t extended_configuration_id = 0;
    int32_t extended_configuration_floats = 0;
    int32_t last_windowed_trace_mask = 0;
    Buffer<float> unused_measure_exposure{kLutValueCount};

    ExecutionState() {
        unused_measure_exposure.fill(0.0f);
        unused_measure_exposure.set_host_dirty();
    }
};

// Generated kernels return an error code after reporting a failure. Keep that recoverable:
// Halide's default handler aborts the app before Swift can retain the standing preview.
void configure_error_handler() {
    static const auto previous = halide_set_error_handler([](void *, const char *message) {
        std::fprintf(stderr, "Fotufilm Halide iOS runtime error: %s\n", message);
    });
    (void)previous;
}

thread_local ExecutionState *bound_execution_state = nullptr;

ExecutionState &execution_state() {
    configure_error_handler();
    static thread_local ExecutionState fallback;
    return bound_execution_state ? *bound_execution_state : fallback;
}

/// The film grain model's tiles, uploaded to the Metal device once as the host registers them.
using FilmTileStore = fotufilm::BasicFilmTileStore<Buffer<float>>;

FilmTileStore &film_tile_store() {
    static FilmTileStore &store = [] () -> FilmTileStore & {
        FilmTileStore &shared = FilmTileStore::shared();
        shared.upload_with([](Buffer<float> &tiles) {
            tiles.set_host_dirty();
            return tiles.copy_to_device(halide_metal_device_interface());
        });
        return shared;
    }();
    return store;
}

using fotufilm::aot::AotVariant;
using fotufilm::aot::FrameFunction;

const AotVariant kVariants[] = {
#define FOTUFILM_AOT_SHIM_ENTRY(variant_name, variant_mask) \
    {(variant_mask), fotufilm_halide_ios_##variant_name, #variant_name},
    FOTUFILM_AOT_VARIANTS(FOTUFILM_AOT_SHIM_ENTRY)
#undef FOTUFILM_AOT_SHIM_ENTRY
};

FrameFunction select_variant(int32_t feature_mask) {
    return fotufilm::aot::select_variant(kVariants, std::size(kVariants), feature_mask);
}

/// Pools the device buffers a frame pipeline allocates while it is alive; defined beside the
/// Metal context below.
struct FrameScope {
    FrameScope();
    ~FrameScope();
};

void flush_internal_cb_on_error();

int run_aot(ExecutionState &state, halide_buffer_t *in, halide_buffer_t *out,
            int32_t width, int32_t height, const float *configuration,
            int32_t feature_mask, uint32_t seed,
            int32_t origin_x = 0, int32_t origin_y = 0,
            int32_t configuration_floats = FOTUFILM_FRAME_CONFIGURATION_COUNT,
            uint64_t configuration_id = 0, bool configuration_stable = false) {
    FrameScope frame_scope;
    // A FIELDS_IN frame rides its halation grids behind the configuration, so its buffer is
    // frame-sized rather than slider-sized; it is cached by the caller's id so the tiles of one
    // frame upload it once — and read in place when the caller keeps it (`configuration_stable`),
    // since a copy would be a second frame of grids.
    const bool wants_extended =
        configuration_floats > FOTUFILM_FRAME_CONFIGURATION_COUNT;
    if (wants_extended) {
        if (state.extended_configuration.data() == nullptr
            || state.extended_configuration_floats != configuration_floats
            || state.extended_configuration_id != configuration_id) {
            if (configuration_stable) {
                state.extended_configuration = Buffer<float>(
                    const_cast<float *>(configuration), configuration_floats);
            } else {
                state.extended_configuration = Buffer<float>(configuration_floats);
                std::memcpy(state.extended_configuration.data(), configuration,
                            size_t(configuration_floats) * sizeof(float));
            }
            state.extended_configuration.set_host_dirty();
            state.extended_configuration_id = configuration_id;
            state.extended_configuration_floats = configuration_floats;
        }
    }
    Buffer<float> local_configuration;
    if (!wants_extended) {
        local_configuration = Buffer<float>(FOTUFILM_FRAME_CONFIGURATION_COUNT);
        std::memcpy(local_configuration.data(), configuration,
                    FOTUFILM_FRAME_CONFIGURATION_COUNT * sizeof(float));
        local_configuration.set_host_dirty();
    }
    const fotufilm::ResolvedFrameParams frame(configuration, width, height, seed,
        (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0, origin_x, origin_y);

    auto *cfg = wants_extended ? state.extended_configuration.raw_buffer()
                               : local_configuration.raw_buffer();
    auto *exposure = state.spectral_cache.exposure.raw_buffer();
#if FOTUFILM_AOT_HALF_EXPOSURE_LUT
    const bool byte_input = (feature_mask & FOTUFILM_FRAME_FLOAT_IO) == 0;
    // Must mirror the generator's per-variant choice exactly: the approximate-math float still
    // variants read a half LUT only when they were generated with kStillFastHalfLut (bit 2 of
    // FOTUFILM_STILL_FAST, baked in here as FOTUFILM_STILL_FAST_BITS by the build).
    const bool still_half_lut = (FOTUFILM_STILL_FAST_BITS & (1 << 2)) != 0
        && (feature_mask & FOTUFILM_FRAME_FLOAT_IO) != 0
        && (feature_mask & FOTUFILM_FRAME_REALTIME) == 0
        && (feature_mask & FOTUFILM_FRAME_EXACT_MATH) == 0;
    if (byte_input || still_half_lut) {
        exposure = state.spectral_cache.exposure_half.raw_buffer();
    }
#endif
    auto *film = state.spectral_cache.film.raw_buffer();
    auto *paper = state.spectral_cache.paper.raw_buffer();
    // Held for the call, so tiles the host forgets meanwhile stay alive until the kernel is done.
    bool film_on = false;
    Buffer<float> film_tiles = film_tile_store().tiles_for(configuration, film_on);
#define FOTUFILM_ARGUMENTS \
    FOTUFILM_AOT_FRAME_ARGUMENTS(in, cfg, exposure, film, paper, width, height, frame, seed, \
                                 origin_x, origin_y, feature_mask, configuration, \
                                 film_tiles.raw_buffer(), film_on ? 1 : 0)
    FrameFunction pipeline = select_variant(feature_mask);
    if (!pipeline) return -3;
#if FOTUFILM_AOT_WINDOWED_HOST
    const FrameFunction general_pipeline = pipeline;
    FrameFunction exact = nullptr;
    // Each full-resolution field needs a window's output rows plus its spatial apron.
    // Decimated fields need fewer rows. Two grid samples cover box alignment and
    // bilinear interpolation; the three-box halation kernel spans 3*r samples.
    const int32_t stride[] = {frame.halation_stride_0, frame.halation_stride_1, frame.halation_stride_2};
    const int32_t strided_radius[] = {frame.halation_strided_radius_0, frame.halation_strided_radius_1, frame.halation_strided_radius_2};
    int64_t halo_reach = 0;
    for (int scale = 0; scale < 3; ++scale) {
        halo_reach = std::max(halo_reach,
            fotufilm::resampled_grid_reach(
                fotufilm::kTripleBoxPasses * int64_t(strided_radius[scale]), stride[scale]));
    }
    // The luminance MTF and its secondary spread blur beside the per-layer MTF, out to
    // `mtf_luma_radius`. A donor layer adds no reach of its own: its record rides the light
    // through the same blurs, and its release diffuses through the coupler kernel.
    int64_t mtf_reach = std::max({frame.mtf_radius_0, frame.mtf_radius_1, frame.mtf_radius_2});
    if (feature_mask & FOTUFILM_FRAME_MTF_LUMA) {
        mtf_reach = std::max<int64_t>(mtf_reach, frame.mtf_luma_radius);
    }
    const int64_t image_reach = mtf_reach
        + halo_reach
        + std::max({fotufilm::gaussian_grid_reach(frame.coupler_sigma, frame.coupler_radius),
                    fotufilm::gaussian_grid_reach(frame.adjacency_sigma, frame.adjacency_radius),
                    fotufilm::gaussian_grid_reach(
                        std::max(configuration[FOTUFILM_CONFIG_ADJACENCY_SECONDARY_SIGMA], 0.151f),
                        std::max(0, int32_t(configuration[FOTUFILM_CONFIG_ADJACENCY_SECONDARY_RADIUS]))),
                    fotufilm::gaussian_grid_reach(frame.fringe_sigma, frame.fringe_radius)})
        + int64_t(frame.print_mtf_radius);
    const int64_t grain_reach = int64_t(frame.grain_radius) + frame.print_mtf_radius;
    static const bool windowed_enabled = [] {
        const char *setting = std::getenv("FOTUFILM_AOT_WINDOWED");
        return !setting || std::strcmp(setting, "0") != 0;
    }();
    // The row-window schedule carries the original single-field adjacency only.
    // Screened adjacency and broad inter-layer transport use the general spatial graph.
    const bool supports_windowed_transport = configuration[FOTUFILM_CONFIG_ADJACENCY_MODEL] < 0.5f
        && configuration[FOTUFILM_CONFIG_CHROMATIC_FRINGE_AMOUNT] == 0;
    // A twin is compiled from the stage set the reach above bounds, so a request that asks for
    // a stage outside it — one whose reach this shim does not know — stays on the full-frame
    // variant.
    const int32_t wanted_stages = feature_mask & FOTUFILM_VARIANT_STAGE_BITS;
    // A row-window graph never sees the whole frame, so a request that asks the kernel to measure
    // its own glare stays on the full-frame variant.
    const bool measures = (feature_mask & FOTUFILM_FRAME_FLARE_MEASURE) != 0;
    const bool fits_window_reach = height <= fotufilm::kWindowMinimumHeight
        || std::max(image_reach, grain_reach) <= fotufilm::kWindowMaximumReach;
    if (windowed_enabled && supports_windowed_transport && !measures
        && width >= 32 && height >= fotufilm::kWindowMinimumHeight
        && origin_x == 0 && origin_y == 0 && !wants_extended
        && in->dim[0].min == 0 && in->dim[1].min == 0
        && out->dim[0].min == 0 && out->dim[1].min == 0
        && in->dim[0].extent == width && in->dim[1].extent == height
        && out->dim[0].extent == width && out->dim[1].extent == height
        && fits_window_reach) {
        // A twin compiled for exactly the request's stages runs them with nothing gated, so it
        // serves the request ahead of the gated twin; it can serve no other. One compiled without
        // couplers or a donor applies no coupler warp, where a graph that gates them off still
        // applies the warp the frame carries; the host sends one only with either running, so
        // such a twin serves only a frame without one.
        bool carries_warp = configuration[FOTUFILM_CONFIG_COUPLER_MODEL] != 0.0f
            && (wanted_stages & (FOTUFILM_FRAME_COUPLERS | FOTUFILM_FRAME_DONOR_LAYER)) != 0;
        for (int i = 0; i < 3 * FOTUFILM_COUPLER_WARP_SAMPLES && !carries_warp; ++i) {
            carries_warp = configuration[FOTUFILM_CONFIG_COUPLER_WARP + i] != 0.0f;
        }
#define FOTUFILM_PICK_EXACT_WINDOWED(variant_name, stages_name, variant_mask, parity_flag) \
        if (pipeline == fotufilm_halide_ios_##variant_name \
            && wanted_stages == ((variant_mask) & FOTUFILM_VARIANT_STAGE_BITS) \
            && (((variant_mask) & (FOTUFILM_FRAME_COUPLERS | FOTUFILM_FRAME_DONOR_LAYER)) != 0 \
                || !carries_warp)) \
            exact = fotufilm_halide_ios_##variant_name##_windowed_##stages_name;
        FOTUFILM_AOT_EXACT_WINDOWED_VARIANTS(FOTUFILM_PICK_EXACT_WINDOWED)
#undef FOTUFILM_PICK_EXACT_WINDOWED
#define FOTUFILM_PICK_WINDOWED(variant_name, variant_mask) \
        if (pipeline == fotufilm_halide_ios_##variant_name \
            && (wanted_stages & ~(variant_mask)) == 0) \
            pipeline = fotufilm_halide_ios_##variant_name##_windowed;
        FOTUFILM_AOT_WINDOWED_VARIANTS(FOTUFILM_PICK_WINDOWED)
#undef FOTUFILM_PICK_WINDOWED
        if (exact && pipeline != general_pipeline) pipeline = exact;
    }
    const int32_t trace_mask = feature_mask & 0x7fffffff;
    if (pipeline != general_pipeline && state.last_windowed_trace_mask != trace_mask) {
        state.last_windowed_trace_mask = trace_mask;
        const char *tracing = std::getenv("FOTUFILM_TRACE_VARIANT");
        if (tracing && std::atoi(tracing)) {
            std::fprintf(stderr, "Fotufilm AOT: %d-row windows%s, spatial reach %lld pixels\n",
                         fotufilm::kWindowRows, pipeline == exact ? " for exactly its stages" : "",
                         static_cast<long long>(std::max(image_reach, grain_reach)));
        }
    }
#endif
    const int result = pipeline(FOTUFILM_ARGUMENTS, out);
    if (result != 0) flush_internal_cb_on_error();
    return result;
#undef FOTUFILM_ARGUMENTS
}

template<typename Function>
int32_t translate_exceptions(Function &&function) {
    try {
        return function();
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Fotufilm Halide iOS error: %s\n", error.what());
        return -1;
    } catch (...) {
        std::fprintf(stderr, "Fotufilm Halide iOS error: unknown exception\n");
        return -2;
    }
}

bool valid_flare_mean(const float *configuration, int32_t feature_mask) {
    if ((feature_mask & FOTUFILM_FRAME_DONOR_LAYER) != 0
        && (feature_mask & (FOTUFILM_FRAME_NO_FILM | FOTUFILM_FRAME_DENSITY_IN | FOTUFILM_FRAME_LIGHT_OUT)) == 0) {
        const float count = configuration[FOTUFILM_CONFIG_DONOR_COUNT];
        if (!std::isfinite(count) || count < 0.0f || int32_t(count) > 1) return false;
    }
    if ((feature_mask & FOTUFILM_FRAME_FLARE) == 0) return true;
    // A measuring variant reaches its own mean, so the unset sentinel is what this slot is
    // supposed to hold — not the sign of a caller who forgot to measure.
    if ((feature_mask & FOTUFILM_FRAME_FLARE_MEASURE) != 0) return true;
    for (int channel = 0; channel < 3; ++channel) {
        const float value = configuration[FOTUFILM_CONFIG_FLARE_MEAN + channel];
        if (!std::isfinite(value) || value < 0.0f) return false;
    }
    return true;
}

/// Refuse the backend before a generated-kernel ABI mismatch can reach Halide's aborting default
/// error handler. The byte-input colour variant represents every byte-input realtime kernel's
/// exposure LUT contract; generated argument order is not stable, so identify the buffer by name.
bool exposure_lut_contract_matches(const halide_filter_metadata_t *metadata,
                                   uint8_t expected_bits) {
    if (!metadata || metadata->version != halide_filter_metadata_t::VERSION
        || !metadata->arguments) return false;
    for (int32_t index = 0; index < metadata->num_arguments; ++index) {
        const halide_filter_argument_t &argument = metadata->arguments[index];
        if (argument.name
            && std::strstr(argument.name, "frame_exposure_lut") != nullptr) {
            return argument.kind == halide_argument_kind_input_buffer
                && argument.dimensions == 1
                && argument.type.code == halide_type_float
                && argument.type.bits == expected_bits;
        }
    }
    return false;
}

bool valid_exposure_lut_contracts() {
    const uint8_t byte_bits = FOTUFILM_AOT_HALF_EXPOSURE_LUT ? 16 : 32;
    return exposure_lut_contract_matches(
               fotufilm_halide_ios_color_metadata(), byte_bits)
        && exposure_lut_contract_matches(
               fotufilm_halide_ios_color_float_realtime_metadata(), 32);
}

}

extern "C" void *MTLCreateSystemDefaultDevice(void);
extern "C" void *_NSConcreteGlobalBlock[];
extern "C" void *objc_autoreleasePoolPush(void);
extern "C" void objc_autoreleasePoolPop(void *);

struct halide_metal_device;
struct halide_metal_command_queue;
struct halide_metal_command_buffer;

namespace {

struct ScopedAutoreleasePool {
    void *pool;
    ScopedAutoreleasePool() : pool(objc_autoreleasePoolPush()) {}
    ~ScopedAutoreleasePool() { objc_autoreleasePoolPop(pool); }
    ScopedAutoreleasePool(const ScopedAutoreleasePool &) = delete;
    ScopedAutoreleasePool &operator=(const ScopedAutoreleasePool &) = delete;
};

/// How many command buffers the runtime's internal queue may have in flight.
/// On the row-window host, coalescing packs an entire pipeline invocation into a single
/// command buffer and 64 gives headroom across concurrent worker threads; non-windowed
/// targets (iOS and Intel Mac) keep the 4-buffer cap.
#if FOTUFILM_AOT_WINDOWED_HOST
constexpr unsigned long kMetalQueueDepth = 64;
#else
constexpr unsigned long kMetalQueueDepth = 4;
#endif

// The runtime's own context is a system default device and an unbounded queue; the override
// below is the documented seam (HalideRuntimeMetal.h) for handing it another. Held from an
// acquire to its release on the same thread, as the runtime's own lock is. A pthread mutex
// rather than a std::mutex because it has no destructor to run: a device free from a static
// or thread-local buffer's destructor still acquires the context after `exit` has begun.
pthread_mutex_t context_mutex = PTHREAD_MUTEX_INITIALIZER;
halide_metal_device *context_device = nullptr;
halide_metal_command_queue *context_queue = nullptr;

id send(id object, const char *selector) {
    return ((id(*)(id, SEL))objc_msgSend)(object, sel_getUid(selector));
}

// Device allocations made while a frame pipeline runs are pooled by size. The runtime has no
// allocation cache on Metal, so every row window of every frame asked for fresh buffers, and
// fresh shared memory is zero-filled and mapped for the device on submission: measured at 4K,
// that held each frame's command buffers back ~25 ms before the device started them. A buffer
// the runtime lets go returns to the pool only once the last command buffer that could have used
// it has completed, so neither the host nor a later kernel can reach it while one is still
// reading. The runtime retains and releases a buffer through its crops too, so the pool counts
// those itself and treats the buffer as released when the count reaches zero.

/// How much idle device memory the pool may hold. FOTUFILM_METAL_POOL sets it in megabytes; 0
/// turns pooling off. The row-window host, whose frames are the large ones, pools by default.
int pool_megabytes() {
    static const int megabytes = [] {
        const char *setting = std::getenv("FOTUFILM_METAL_POOL");
        return setting ? std::max(0, std::atoi(setting))
                       : (FOTUFILM_AOT_WINDOWED_HOST ? 1024 : 0);
    }();
    return megabytes;
}

int frame_depth = 0;  // Guarded by context_mutex.

constexpr size_t kExactBelow = size_t(1) << 16;  // 64 KB threshold for intra/inter-CB GPU reuse.

struct PooledBuffer {
    size_t length = 0;
    int references = 0;
    bool host_written = false;
    bool gpu_in_flight = false;
};
// A pthread mutex and leaked containers, for the reason context_mutex is one: the runtime still
// frees buffers from static destructors after `exit` has begun.
pthread_mutex_t pool_mutex = PTHREAD_MUTEX_INITIALIZER;
struct PoolLock {
    PoolLock() { pthread_mutex_lock(&pool_mutex); }
    ~PoolLock() { pthread_mutex_unlock(&pool_mutex); }
};
// Every buffer the pool made and still owns.
auto &pooled = *new std::unordered_map<void *, PooledBuffer>();
// Free for reuse (`status >= 4`).
auto &idle = *new std::unordered_multimap<size_t, void *>();
struct Returned {
    void *buffer;
    id fence;            // Retained (+1); primary fence.
    id secondary_fence;  // Retained (+1); optional 2nd queue fence when released outside an open CB.
    id queue;            // Unretained queue token for GPU-only >= 64 KB reuse, or nullptr.
    bool committed;      // True once `fence` has been committed on `queue`.
};
auto &returning = *new std::vector<Returned>();
size_t idle_bytes = 0;
id newest_internal_fence = nullptr;  // Retained (+1): most recent CB committed on context_queue.
id newest_host_fence = nullptr;      // Retained (+1): most recent CB committed on a host queue.

inline bool fence_completed(id fence) {
    constexpr unsigned long kCompleted = 4;  // MTLCommandBufferStatusCompleted; 5 is Error.
    return !fence ||
        ((unsigned long (*)(id, SEL))objc_msgSend)(fence, sel_getUid("status")) >= kCompleted;
}

/// The size a pooled buffer is made at: within 1/16 of the next power of two above the request,
/// so the row windows of a frame, whose aprons differ by a few rows, share their buffers.
size_t pooled_length(size_t requested) {
    if (requested < kExactBelow) return requested;
    size_t power = kExactBelow;
    while (power < requested) power <<= 1;
    const size_t step = power / 16;
    return (requested + step - 1) / step * step;
}

/// Moves returned buffers whose fence has completed to the idle set, preserving strict FIFO order
/// for surviving entries. Holds pool_mutex.
void reclaim_returned() {
    size_t write = 0;
    for (size_t read = 0; read < returning.size(); ++read) {
        Returned &entry = returning[read];
        if (!fence_completed(entry.fence) || !fence_completed(entry.secondary_fence)) {
            if (write != read) {
                returning[write] = entry;
            }
            ++write;
            continue;
        }
        if (entry.fence) send(entry.fence, "release");
        if (entry.secondary_fence) send(entry.secondary_fence, "release");
        auto it = pooled.find(entry.buffer);
        if (it != pooled.end()) {
            const size_t length = it->second.length;
            if (idle_bytes + length <= size_t(pool_megabytes()) << 20) {
                it->second.host_written = false;
                it->second.gpu_in_flight = false;
                idle.emplace(length, entry.buffer);
                idle_bytes += length;
            } else {
                pooled.erase(it);
                send(static_cast<id>(entry.buffer), "release");
            }
        }
    }
    returning.resize(write);
}

inline void record_pool_fence(id cb, id queue) {
    if (!cb || pool_megabytes() == 0) return;
    PoolLock held;
    send(cb, "retain");
    id &slot = (queue == reinterpret_cast<id>(context_queue))
        ? newest_internal_fence
        : newest_host_fence;
    if (slot) send(slot, "release");
    slot = cb;
    for (auto &entry : returning) {
        if (entry.fence == cb && entry.secondary_fence == nullptr) {
            entry.committed = true;
        }
    }
}

inline Returned make_returned_entry(void *object, size_t length, bool host_written,
                                    id active_cb, id active_queue) {
    if (active_cb != nullptr) {
        send(active_cb, "retain");
        id queue = (length >= kExactBelow && !host_written) ? active_queue : nullptr;
        return Returned{object, active_cb, nullptr, queue, false};
    }
    id primary = newest_internal_fence ? newest_internal_fence : newest_host_fence;
    id secondary = (newest_internal_fence && newest_host_fence &&
                    newest_host_fence != newest_internal_fence)
        ? newest_host_fence
        : nullptr;
    if (primary) send(primary, "retain");
    if (secondary) send(secondary, "retain");
    return Returned{object, primary, secondary, nullptr, false};
}

FrameScope::FrameScope() {
    pthread_mutex_lock(&context_mutex);
    ++frame_depth;
    pthread_mutex_unlock(&context_mutex);
}

FrameScope::~FrameScope() {
    pthread_mutex_lock(&context_mutex);
    --frame_depth;
    pthread_mutex_unlock(&context_mutex);
}

// ---------------------------------------------------------------------------
// Per-thread command buffer & serial compute encoder coalescing state.
//
// Coalesces consecutive compute dispatches into one MTLCommandBuffer and one
// serial MTLComputeCommandEncoder on both the internal `context_queue` and an
// external host `MTLCommandQueue` bound via `fotufilm_halide_metal_host_queue_begin`.
// When `host_queue_async` is true, end-of-call CPU syncs are skipped so an
// entire OFX gpuFrames scope (copyFrameIn + decode + develop + copyFrameOut)
// encodes into ONE MTLCommandBuffer on Resolve's metalQueue without CPU stalls.
// ---------------------------------------------------------------------------

struct HostQueueState {
    // Caller-supplied queue, retained (+1) for the lifetime of the scope.
    id host_queue = nullptr;
    bool host_queue_async = false;

    // Open command buffer (+1 retained) and the queue it was created on.
    id active_cb = nullptr;
    id active_queue = nullptr;
    // Open serial compute encoder (+1 retained) on active_cb, or nullptr.
    id active_compute_encoder = nullptr;
    // Open blit encoder (+1 retained) on active_cb, or nullptr.
    id active_blit_encoder = nullptr;
    // Whether we have already attached one completion handler to active_cb.
    bool cb_has_handler = false;

    // Immediately preceding async CB committed on this thread (unretained tokens),
    // skipped during 2-slot inter-CB reuse so Frame N and Frame N-1 keep disjoint slots.
    uintptr_t prev_cb_id = 0;
    id prev_queue = nullptr;

    // Zero-copy vertical row-flip state for bottom-up host MTLBuffers (OFX gpuFrames).
    int32_t flip_decode_input_y = 0;
    int32_t flip_frame_output_y = 0;
    int32_t full_frame_height = 0;

    ~HostQueueState();
};

thread_local HostQueueState hq;

struct HqCompletionDescriptor {
    unsigned long reserved;
    unsigned long block_size;
};

struct HqCompletionBlock {
    void *isa;
    int flags;
    int reserved;
    void (*invoke)(HqCompletionBlock *, id);
    HqCompletionDescriptor *descriptor;
};

HqCompletionDescriptor hq_completion_descriptor = {0, sizeof(HqCompletionBlock)};

void hq_completion_invoke(HqCompletionBlock *, id cb) {
    id err = send(cb, "error");
    if (err) {
        std::fprintf(stderr, "Fotufilm Halide iOS Metal command buffer error\n");
    }
}

// Global block (BLOCK_IS_GLOBAL = 1 << 28) — _Block_copy is a zero-allocation no-op.
HqCompletionBlock hq_completion_block_global = {
    _NSConcreteGlobalBlock, (1 << 28), 0,
    hq_completion_invoke, &hq_completion_descriptor
};

inline void attach_fallback_handler(id cb) {
    if (!cb) return;
    ((void(*)(id, SEL, void *))objc_msgSend)(
        cb, sel_getUid("addCompletedHandler:"), &hq_completion_block_global);
}

constexpr int64_t kHostQueueWaitNs = 4LL * NSEC_PER_SEC;

struct DispatchSemaphoreRef {
    dispatch_semaphore_t sem;
    DispatchSemaphoreRef() : sem(dispatch_semaphore_create(0)) {}
    DispatchSemaphoreRef(const DispatchSemaphoreRef &o) : sem(o.sem) {
        if (sem) dispatch_retain(sem);
    }
    DispatchSemaphoreRef &operator=(const DispatchSemaphoreRef &) = delete;
    ~DispatchSemaphoreRef() {
        if (sem) dispatch_release(sem);
    }
};

// Commits `cb` on an external host queue and waits up to 4 seconds for completion via a
// refcounted libdispatch semaphore rather than an unbounded `waitUntilCompleted`, so a host
// holding an uncommitted earlier command buffer on that queue fails cleanly instead of hanging.
inline bool commit_and_wait_host_cb(id cb, id queue, bool had_handler, bool &timed_out) {
    timed_out = false;
    DispatchSemaphoreRef waiter;
    if (!waiter.sem) {
        if (!had_handler) attach_fallback_handler(cb);
        send(cb, "commit");
        record_pool_fence(cb, queue);
        return false;
    }
    void (^handler)(id) = ^(id finished) {
        if (!had_handler && send(finished, "error")) {
            std::fprintf(stderr, "Fotufilm Halide iOS Metal command buffer error\n");
        }
        dispatch_semaphore_signal(waiter.sem);
    };
    ((void(*)(id, SEL, void (^)(id)))objc_msgSend)(
        cb, sel_getUid("addCompletedHandler:"), handler);
    send(cb, "commit");
    record_pool_fence(cb, queue);
    const dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, kHostQueueWaitNs);
    if (dispatch_semaphore_wait(waiter.sem, deadline) != 0) {
        timed_out = true;
        std::fprintf(stderr,
                     "Fotufilm Halide iOS error: host Metal queue timed out waiting for command buffer\n");
        return false;
    }
    return send(cb, "error") == nullptr;
}

inline bool coalescing_enabled() {
    return hq.host_queue_async || (pool_megabytes() > 0 && frame_depth > 0);
}

HostQueueState::~HostQueueState() {
    if (active_compute_encoder) {
        id enc = active_compute_encoder;
        active_compute_encoder = nullptr;
        send(enc, "endEncoding");
        send(enc, "release");
    }
    if (active_blit_encoder) {
        id enc = active_blit_encoder;
        active_blit_encoder = nullptr;
        send(enc, "endEncoding");
        send(enc, "release");
    }
    if (active_cb) {
        id cb = active_cb;
        id queue = active_queue;
        active_cb = nullptr;
        active_queue = nullptr;
        const bool had_handler = cb_has_handler;
        cb_has_handler = false;
        if (!had_handler) {
            attach_fallback_handler(cb);
        }
        send(cb, "commit");
        record_pool_fence(cb, queue);
        send(cb, "release");
    }
    if (host_queue) {
        id q = host_queue;
        host_queue = nullptr;
        send(q, "release");
    }
    prev_cb_id = 0;
    prev_queue = nullptr;
    flip_decode_input_y = 0;
    flip_frame_output_y = 0;
    full_frame_height = 0;
    host_queue_async = false;
}

inline void close_blit_encoder() {
    if (hq.active_blit_encoder) {
        id enc = hq.active_blit_encoder;
        hq.active_blit_encoder = nullptr;
        send(enc, "endEncoding");
        send(enc, "release");
    }
}

inline void close_compute_encoder() {
    if (hq.active_compute_encoder) {
        id enc = hq.active_compute_encoder;
        hq.active_compute_encoder = nullptr;
        send(enc, "endEncoding");
        send(enc, "release");
    }
}

inline void close_all_encoders() {
    close_compute_encoder();
    close_blit_encoder();
}

// Ends open encoders, commits active_cb, optionally waits for GPU completion,
// updates the pool fence, and releases active_cb's +1 ownership. Preserves
// host_queue / host_queue_async so mid-scope syncs (e.g. FOTUFILM_REALTIME=0
// flare measurement) can open a fresh CB on the same host_queue afterwards.
inline bool flush_active_cb(bool wait) {
    if (!hq.active_cb) return true;
    close_all_encoders();
    id cb = hq.active_cb;
    id queue = hq.active_queue;
    hq.active_cb = nullptr;
    hq.active_queue = nullptr;
    const bool had_handler = hq.cb_has_handler;
    hq.cb_has_handler = false;
    bool ok = true;
    if (wait && (hq.host_queue_async || (hq.host_queue && queue == hq.host_queue))) {
        bool timed_out = false;
        ok = commit_and_wait_host_cb(cb, queue, had_handler, timed_out);
        if (timed_out) {
            hq.prev_cb_id = reinterpret_cast<uintptr_t>(cb);
            hq.prev_queue = queue;
        } else if (hq.prev_queue == queue) {
            hq.prev_cb_id = 0;
            hq.prev_queue = nullptr;
        }
    } else {
        if (!had_handler) {
            attach_fallback_handler(cb);
        }
        send(cb, "commit");
        record_pool_fence(cb, queue);
        if (wait) {
            send(cb, "waitUntilCompleted");
            ok = (send(cb, "error") == nullptr);
            if (hq.prev_queue == queue) {
                hq.prev_cb_id = 0;
                hq.prev_queue = nullptr;
            }
        } else {
            hq.prev_cb_id = reinterpret_cast<uintptr_t>(cb);
            hq.prev_queue = queue;
        }
    }
    send(cb, "release");
    return ok;
}

void flush_internal_cb_on_error() {
    if (!hq.host_queue_async) {
        (void)flush_active_cb(true);
    }
}

inline id ensure_active_cb(id queue) {
    if (hq.active_cb && hq.active_queue != queue) {
        (void)flush_active_cb(false);
    }
    if (!hq.active_cb && queue) {
        ScopedAutoreleasePool pool;
        id cb = send(queue, "commandBuffer");
        if (cb) send(cb, "retain");
        hq.active_cb = cb;
        hq.active_queue = queue;
        hq.cb_has_handler = false;
    }
    return hq.active_cb;
}

inline id ensure_compute_encoder(id cb) {
    close_blit_encoder();
    if (!hq.active_compute_encoder && cb) {
        ScopedAutoreleasePool pool;
        id enc = send(cb, "computeCommandEncoder");
        if (enc) send(enc, "retain");
        hq.active_compute_encoder = enc;
    }
    return hq.active_compute_encoder;
}

inline id ensure_blit_encoder(id cb) {
    close_compute_encoder();
    if (!hq.active_blit_encoder && cb) {
        ScopedAutoreleasePool pool;
        id enc = send(cb, "blitCommandEncoder");
        if (enc) send(enc, "retain");
        hq.active_blit_encoder = enc;
    }
    return hq.active_blit_encoder;
}

inline bool is_metal_buffer_managed(id metal_buf) {
    if (!metal_buf) return false;
    typedef bool (*rts_method)(id, SEL, SEL);
    const SEL storage_sel = sel_getUid("storageMode");
    if (!((rts_method)objc_msgSend)(
            metal_buf, sel_getUid("respondsToSelector:"), storage_sel)) {
        return false;
    }
    return ((int(*)(id, SEL))objc_msgSend)(metal_buf, storage_sel) == 1;
}

void copy_strided_chunks(const uint8_t *src, uint8_t *dst,
                         const uint64_t *extents, const uint64_t *strides,
                         int first_dim, int dim, size_t chunk_size) {
    if (dim < first_dim) {
        std::memcpy(dst, src, chunk_size);
        return;
    }
    const uint64_t count = extents[dim];
    const uint64_t step = strides[dim];
    for (uint64_t i = 0; i < count; ++i) {
        copy_strided_chunks(src + i * step, dst + i * step,
                            extents, strides, first_dim, dim - 1, chunk_size);
    }
}

bool copy_host_to_metal_buffer(const halide_buffer_t *buf, uint8_t *dst) {
    if (!buf || !buf->host || !dst || buf->dimensions < 0 || buf->dimensions > 16) {
        return false;
    }
    const size_t elem_bytes = buf->type.bytes();
    if (elem_bytes == 0) return true;

    uint64_t extents[16];
    uint64_t strides[16];
    int ndims = 0;
    for (int i = 0; i < buf->dimensions; ++i) {
        const int32_t ext = buf->dim[i].extent;
        const int32_t st = buf->dim[i].stride;
        if (ext <= 0) return true;
        if (st < 0) return false;
        if (ext == 1) continue;
        const uint64_t stride_bytes = uint64_t(st) * elem_bytes;
        int insert = ndims;
        if (stride_bytes != 0) {
            for (int k = 0; k < ndims; ++k) {
                if (strides[k] == 0 || stride_bytes < strides[k]) {
                    insert = k;
                    break;
                }
            }
        }
        for (int k = ndims; k > insert; --k) {
            extents[k] = extents[k - 1];
            strides[k] = strides[k - 1];
        }
        extents[insert] = uint64_t(ext);
        strides[insert] = stride_bytes;
        ++ndims;
    }

    size_t chunk_size = elem_bytes;
    int first_unfolded = 0;
    while (first_unfolded < ndims && strides[first_unfolded] == chunk_size) {
        chunk_size *= size_t(extents[first_unfolded]);
        ++first_unfolded;
    }

    if (dst != buf->host) {
        copy_strided_chunks(buf->host, dst, extents, strides,
                            first_unfolded, ndims - 1, chunk_size);
    }
    return true;
}

// ---------------------------------------------------------------------------
// Permanent PSO cache: (device, library, name) -> MTLComputePipelineState.
//
// Ownership contract (matches Halide's halide_metal_run):
//   new_compute_pipeline_state_with_function returns +1 (Obj-C "new*" rule).
//   halide_metal_run calls release_ns_object(pipeline_state) at exit.
//   The cache holds its own +1 retain; callers receive an additional +1 retain.
// ---------------------------------------------------------------------------

struct PsoCacheKey {
    void *device = nullptr;
    void *library = nullptr;
    std::string name;

    bool operator==(const PsoCacheKey &o) const {
        return device == o.device && library == o.library && name == o.name;
    }
};

struct PsoCacheKeyHash {
    size_t operator()(const PsoCacheKey &k) const {
        size_t h = 14695981039346656037ull;
        auto mix = [&](size_t v) {
            for (size_t i = 0; i < sizeof(v); ++i) {
                h ^= static_cast<uint8_t>(v >> (8 * i));
                h *= 1099511628211ull;
            }
        };
        mix(reinterpret_cast<size_t>(k.device));
        mix(reinterpret_cast<size_t>(k.library));
        for (unsigned char c : k.name) {
            h = (h ^ c) * 1099511628211ull;
        }
        return h;
    }
};

pthread_mutex_t pso_mutex = PTHREAD_MUTEX_INITIALIZER;
struct PsoLock {
    PsoLock() { pthread_mutex_lock(&pso_mutex); }
    ~PsoLock() { pthread_mutex_unlock(&pso_mutex); }
};
auto &pso_cache = *new std::unordered_map<PsoCacheKey, void *, PsoCacheKeyHash>();
thread_local PsoCacheKey tls_pso_key;
thread_local bool tls_skip_decode_report = false;

}  // namespace

extern "C" int halide_metal_acquire_context(void *, halide_metal_device **device_ret,
                                            halide_metal_command_queue **queue_ret,
                                            bool create) {
    pthread_mutex_lock(&context_mutex);
    if (!context_device && create) {
        auto *device = static_cast<halide_metal_device *>(MTLCreateSystemDefaultDevice());
        halide_metal_command_queue *queue = nullptr;
        if (device) {
            queue = ((halide_metal_command_queue *(*)(id, SEL, unsigned long))objc_msgSend)(
                reinterpret_cast<id>(device),
                sel_getUid("newCommandQueueWithMaxCommandBufferCount:"), kMetalQueueDepth);
            if (!queue) {
                send(reinterpret_cast<id>(device), "release");
                device = nullptr;
            }
        }
        if (!device) {
            pthread_mutex_unlock(&context_mutex);
            std::fprintf(stderr, "Fotufilm Halide iOS error: no Metal device or queue\n");
            return halide_error_code_generic_error;
        }
        context_device = device;
        context_queue = queue;
    }
    *device_ret = context_device;
    *queue_ret = hq.host_queue_async
        ? reinterpret_cast<halide_metal_command_queue *>(hq.host_queue)
        : context_queue;
    return halide_error_code_success;
}

extern "C" int halide_metal_release_context(void *) {
    pthread_mutex_unlock(&context_mutex);
    return halide_error_code_success;
}

// ---------------------------------------------------------------------------
// Halide Metal runtime overrides
// ---------------------------------------------------------------------------

namespace Halide {
namespace Runtime {
namespace Internal {
namespace Metal {

// Match third_party/Halide/src/runtime/metal.cpp typedefs so C++ name mangling
// matches the weak symbols in the generated AOT archives identically.
using mtl_device = ::halide_metal_device;
using mtl_command_queue = ::halide_metal_command_queue;
using mtl_command_buffer = ::halide_metal_command_buffer;
struct mtl_buffer;
struct mtl_compute_command_encoder;
struct mtl_blit_command_encoder;
struct mtl_compute_pipeline_state;
struct mtl_library;
struct mtl_function;
struct command_buffer_completed_handler_block_literal;

mtl_command_buffer *new_command_buffer(
    mtl_command_queue *queue, const char *, size_t) {
    id target_queue = hq.host_queue_async
        ? hq.host_queue
        : (queue ? reinterpret_cast<id>(queue) : reinterpret_cast<id>(context_queue));
    if (!coalescing_enabled()) {
        if (hq.active_cb) {
            (void)flush_active_cb(false);
        }
        return reinterpret_cast<mtl_command_buffer *>(send(target_queue, "commandBuffer"));
    }
    return reinterpret_cast<mtl_command_buffer *>(ensure_active_cb(target_queue));
}

mtl_compute_command_encoder *new_compute_command_encoder(
    mtl_command_buffer *cb_raw) {
    id cb = reinterpret_cast<id>(cb_raw);
    if (cb == hq.active_cb) {
        return reinterpret_cast<mtl_compute_command_encoder *>(
            ensure_compute_encoder(cb));
    }
    return reinterpret_cast<mtl_compute_command_encoder *>(
        send(cb, "computeCommandEncoder"));
}

mtl_blit_command_encoder *new_blit_command_encoder(
    mtl_command_buffer *cb_raw) {
    id cb = reinterpret_cast<id>(cb_raw);
    if (cb == hq.active_cb) {
        return reinterpret_cast<mtl_blit_command_encoder *>(
            ensure_blit_encoder(cb));
    }
    return reinterpret_cast<mtl_blit_command_encoder *>(
        send(cb, "blitCommandEncoder"));
}

void end_encoding(mtl_compute_command_encoder *enc) {
    if (reinterpret_cast<id>(enc) == hq.active_compute_encoder) {
        return;
    }
    send(reinterpret_cast<id>(enc), "endEncoding");
}

void end_encoding(mtl_blit_command_encoder *enc) {
    if (reinterpret_cast<id>(enc) == hq.active_blit_encoder) {
        return;
    }
    send(reinterpret_cast<id>(enc), "endEncoding");
}

void add_command_buffer_completed_handler(
    mtl_command_buffer *cb_raw,
    command_buffer_completed_handler_block_literal *handler) {
    id cb = reinterpret_cast<id>(cb_raw);
    if (cb == hq.active_cb) {
        if (hq.cb_has_handler) return;
        hq.cb_has_handler = true;
    }
    ((void(*)(id, SEL, void *))objc_msgSend)(
        cb, sel_getUid("addCompletedHandler:"), handler);
}

void commit_command_buffer(mtl_command_buffer *buffer) {
    id cb = reinterpret_cast<id>(buffer);
    if (cb == hq.active_cb) {
        return;
    }
    send(cb, "commit");
    record_pool_fence(cb, hq.host_queue_async ? hq.host_queue : reinterpret_cast<id>(context_queue));
}

void wait_until_completed(mtl_command_buffer *buffer) {
    id cb = reinterpret_cast<id>(buffer);
    if (!cb) return;
    if (cb == hq.active_cb) {
        (void)flush_active_cb(true);
        return;
    }
    send(cb, "waitUntilCompleted");
}

void dispatch_threadgroups(mtl_compute_command_encoder *encoder,
                           int blocks_x, int blocks_y, int blocks_z,
                           int threads_x, int threads_y, int threads_z) {
    if (tls_skip_decode_report) {
        constexpr char kChunkPrefix[] = "_kernel_decode_chunk_";
        constexpr char kReportPrefix[] = "_kernel_decode_report_";
        if (tls_pso_key.name.compare(0, sizeof(kChunkPrefix) - 1, kChunkPrefix) == 0 ||
            tls_pso_key.name.compare(0, sizeof(kReportPrefix) - 1, kReportPrefix) == 0) {
            return;
        }
    }
    struct MtlSize {
        unsigned long width;
        unsigned long height;
        unsigned long depth;
    };
    const MtlSize groups{static_cast<unsigned long>(blocks_x),
                         static_cast<unsigned long>(blocks_y),
                         static_cast<unsigned long>(blocks_z)};
    const MtlSize threads{static_cast<unsigned long>(threads_x),
                          static_cast<unsigned long>(threads_y),
                          static_cast<unsigned long>(threads_z)};
    ((void(*)(id, SEL, MtlSize, MtlSize))objc_msgSend)(
        reinterpret_cast<id>(encoder),
        sel_getUid("dispatchThreadgroups:threadsPerThreadgroup:"),
        groups, threads);
}

mtl_function *new_function_with_name(
    mtl_library *library, const char *name, size_t name_len) {
    if (!library || !name) return nullptr;
    tls_pso_key.library = library;
    tls_pso_key.name.assign(name, name_len);
    return reinterpret_cast<mtl_function *>(uintptr_t(1));
}

mtl_compute_pipeline_state *new_compute_pipeline_state_with_function(
    mtl_device *device, mtl_function *function) {
    if (!device || !function) return nullptr;
    const bool from_sentinel =
        (function == reinterpret_cast<mtl_function *>(uintptr_t(1)));
    if (from_sentinel) {
        tls_pso_key.device = device;
        PsoLock lock;
        auto it = pso_cache.find(tls_pso_key);
        if (it != pso_cache.end()) {
            send(static_cast<id>(it->second), "retain");
            return reinterpret_cast<mtl_compute_pipeline_state *>(it->second);
        }
    }

    id pso = nullptr;
    {
        ScopedAutoreleasePool pool;
        id real_fn = nullptr;
        if (from_sentinel) {
            id str_alloc = send(reinterpret_cast<id>(objc_getClass("NSString")), "alloc");
            id name_str = ((id(*)(id, SEL, const void *, size_t, unsigned long))objc_msgSend)(
                str_alloc, sel_getUid("initWithBytes:length:encoding:"),
                tls_pso_key.name.data(), tls_pso_key.name.size(), 4UL);
            if (!name_str) return nullptr;
            real_fn = ((id(*)(id, SEL, id))objc_msgSend)(
                static_cast<id>(tls_pso_key.library),
                sel_getUid("newFunctionWithName:"), name_str);
            send(name_str, "release");
            if (!real_fn) return nullptr;
        } else {
            real_fn = reinterpret_cast<id>(function);
        }

        id err = nullptr;
        pso = ((id(*)(id, SEL, id, id *))objc_msgSend)(
            reinterpret_cast<id>(device),
            sel_getUid("newComputePipelineStateWithFunction:error:"),
            real_fn, &err);
        if (from_sentinel) {
            send(real_fn, "release");
        }
    }
    if (!pso) return nullptr;

    if (!from_sentinel) {
        return reinterpret_cast<mtl_compute_pipeline_state *>(pso);
    }

    // Retain +1 for permanent cache residency (+1 from new* goes to caller).
    send(pso, "retain");
    {
        PsoLock lock;
        auto [it, inserted] = pso_cache.emplace(tls_pso_key, static_cast<void *>(pso));
        if (!inserted) {
            send(pso, "release");
            send(pso, "release");
            send(static_cast<id>(it->second), "retain");
            return reinterpret_cast<mtl_compute_pipeline_state *>(it->second);
        }
    }
    return reinterpret_cast<mtl_compute_pipeline_state *>(pso);
}

mtl_buffer *new_buffer(mtl_device *device, size_t requested) {
    const bool pooling = pool_megabytes() > 0 && frame_depth > 0;
    const size_t length = pooling ? pooled_length(requested) : requested;
    if (pooling) {
        if (hq.host_queue_async && !hq.active_cb) {
            ensure_active_cb(hq.host_queue);
        }
        PoolLock held;
        reclaim_returned();

        // (a) Intra-CB reuse: within one open command buffer + serial compute encoder,
        // sequential row windows finish reading/writing temporary GPU buffers (>= 64 KB)
        // before the next window's dispatches begin (~2.0 GB -> ~220 MB per 4K frame).
        if (hq.active_cb != nullptr && length >= kExactBelow) {
            for (size_t i = 0; i < returning.size(); ++i) {
                Returned &entry = returning[i];
                if (entry.fence == hq.active_cb && entry.secondary_fence == nullptr &&
                    entry.queue != nullptr) {
                    auto pit = pooled.find(entry.buffer);
                    if (pit != pooled.end() && pit->second.length == length) {
                        void *buffer = entry.buffer;
                        send(entry.fence, "release");
                        returning.erase(returning.begin() + static_cast<std::ptrdiff_t>(i));
                        pit->second.references = 1;
                        pit->second.host_written = false;
                        pit->second.gpu_in_flight = true;
                        return reinterpret_cast<mtl_buffer *>(buffer);
                    }
                }
            }
        }

        // (b) Completed idle pool (`status >= 4`).
        auto found = idle.find(length);
        if (found != idle.end()) {
            void *buffer = found->second;
            idle.erase(found);
            idle_bytes -= length;
            auto &meta = pooled[buffer];
            meta.references = 1;
            meta.host_written = false;
            meta.gpu_in_flight = false;
            return reinterpret_cast<mtl_buffer *>(buffer);
        }

        // (c) 2-slot inter-CB same-queue reuse: skips `prev_cb_id` so Frame N and Frame N-1
        // keep 2 disjoint ~220 MB slots for GPU overlap, while Frame N >= 2 reuses Frame N-2's
        // committed `options: 0` tracked MTLBuffers on `hq.active_queue` without CPU stalls.
        if (hq.active_cb != nullptr && hq.active_queue != nullptr && length >= kExactBelow) {
            for (size_t i = 0; i < returning.size(); ++i) {
                Returned &entry = returning[i];
                if (entry.committed && entry.secondary_fence == nullptr &&
                    entry.queue == hq.active_queue &&
                    entry.fence != hq.active_cb &&
                    (hq.prev_queue != hq.active_queue ||
                     reinterpret_cast<uintptr_t>(entry.fence) != hq.prev_cb_id)) {
                    auto pit = pooled.find(entry.buffer);
                    if (pit != pooled.end() && pit->second.length == length) {
                        void *buffer = entry.buffer;
                        if (entry.fence) send(entry.fence, "release");
                        returning.erase(returning.begin() + static_cast<std::ptrdiff_t>(i));
                        pit->second.references = 1;
                        pit->second.host_written = false;
                        pit->second.gpu_in_flight = true;
                        return reinterpret_cast<mtl_buffer *>(buffer);
                    }
                }
            }
        }
    }
    void *buffer = ((void *(*)(id, SEL, size_t, size_t))objc_msgSend)(
        reinterpret_cast<id>(device), sel_getUid("newBufferWithLength:options:"), length, 0);
    if (buffer && pooling) {
        PoolLock held;
        pooled[buffer] = PooledBuffer{length, 1, false, false};
    }
    return reinterpret_cast<mtl_buffer *>(buffer);
}

}  // namespace Metal

void retain_ns_object(void *object) {
    if (pool_megabytes() > 0) {
        PoolLock held;
        auto found = pooled.find(object);
        if (found != pooled.end()) {
            ++found->second.references;
            return;
        }
    }
    send(static_cast<id>(object), "retain");
}

void release_ns_object(void *object) {
    if (pool_megabytes() > 0) {
        PoolLock held;
        auto found = pooled.find(object);
        if (found != pooled.end()) {
            if (--found->second.references > 0) return;
            // Small (< 64 KB) uniform/LUT buffers and host-copied buffers set `queue = nullptr`
            // so they NEVER recycle until `[fence status] >= 4` (protecting CPU memcpy).
            Returned entry = make_returned_entry(
                object, found->second.length, found->second.host_written,
                hq.active_cb, hq.active_queue);
            if (entry.fence) found->second.gpu_in_flight = true;
            returning.push_back(entry);
            return;
        }
    }
    send(static_cast<id>(object), "release");
}

}  // namespace Internal
}  // namespace Runtime
}  // namespace Halide

/// Lets go of every idle pooled buffer; buffers still in use rejoin the pool as they return.
extern "C" void fotufilm_halide_metal_release_pool(void) {
    PoolLock held;
    reclaim_returned();
    for (auto &entry : idle) {
        pooled.erase(entry.second);
        send(static_cast<id>(entry.second), "release");
    }
    idle.clear();
    idle_bytes = 0;
}

// ---------------------------------------------------------------------------
// Halide runtime entry-point overrides: device_sync_internal, device_sync & copy_to_device
//
// Note: halide_metal_device_sync_internal is called by halide_metal_copy_to_host,
// halide_metal_device_sync, halide_metal_device_release, and halide_metal_buffer_copy
// while `context_mutex` is ALREADY locked — never call halide_metal_acquire_context
// inside it.
// ---------------------------------------------------------------------------

extern "C" int halide_metal_device_sync_internal(
    halide_metal_command_queue *queue, const struct halide_buffer_t *buffer) {
    id metal_buf = nullptr;
    if (buffer && buffer->device) {
        struct device_handle_t { void *buf; uint64_t offset; };
        auto *h = reinterpret_cast<const device_handle_t *>(buffer->device);
        metal_buf = reinterpret_cast<id>(h->buf);
    }
    const bool is_managed = is_metal_buffer_managed(metal_buf);

    if (hq.active_cb) {
        if (is_managed && metal_buf) {
            id blit = ensure_blit_encoder(hq.active_cb);
            if (blit) {
                ((void(*)(id, SEL, id))objc_msgSend)(
                    blit, sel_getUid("synchronizeResource:"), metal_buf);
            }
        }
        return flush_active_cb(true)
            ? halide_error_code_success
            : halide_error_code_device_run_failed;
    }

    id q = hq.host_queue_async
        ? hq.host_queue
        : (queue ? reinterpret_cast<id>(queue) : reinterpret_cast<id>(context_queue));
    if (!q) return halide_error_code_success;

    ScopedAutoreleasePool pool;
    id sync_cb = send(q, "commandBuffer");
    if (!sync_cb) return halide_error_code_device_run_failed;
    if (is_managed && metal_buf) {
        id blit = send(sync_cb, "blitCommandEncoder");
        if (blit) {
            ((void(*)(id, SEL, id))objc_msgSend)(
                blit, sel_getUid("synchronizeResource:"), metal_buf);
            send(blit, "endEncoding");
        }
    }
    if (hq.host_queue_async || (hq.host_queue && q == hq.host_queue)) {
        bool timed_out = false;
        return commit_and_wait_host_cb(sync_cb, q, /*had_handler=*/false, timed_out)
            ? halide_error_code_success
            : halide_error_code_device_run_failed;
    }
    attach_fallback_handler(sync_cb);
    send(sync_cb, "commit");
    record_pool_fence(sync_cb, q);
    send(sync_cb, "waitUntilCompleted");
    return (send(sync_cb, "error") == nullptr)
        ? halide_error_code_success
        : halide_error_code_device_run_failed;
}

extern "C" int halide_metal_device_sync(void *user_context,
                                        struct halide_buffer_t *buffer) {
    halide_metal_device *dev = nullptr;
    halide_metal_command_queue *que = nullptr;
    int err = halide_metal_acquire_context(user_context, &dev, &que, true);
    if (err) return err;
    int sync_err = halide_metal_device_sync_internal(que, buffer);
    halide_metal_release_context(user_context);
    return sync_err;
}

extern "C" int halide_metal_copy_to_device(void *user_context,
                                           halide_buffer_t *buffer) {
    halide_metal_device *dev = nullptr;
    halide_metal_command_queue *que = nullptr;
    int err = halide_metal_acquire_context(user_context, &dev, &que, true);
    if (err) return err;

    if (!buffer || !(buffer->host && buffer->device)) {
        halide_metal_release_context(user_context);
        return halide_error_code_generic_error;
    }

    struct device_handle_t { void *buf; uint64_t offset; };
    auto *handle = reinterpret_cast<device_handle_t *>(buffer->device);
    id metal_buf = reinterpret_cast<id>(handle->buf);

    // Defense-in-depth against CPU memcpy clobbering a pooled buffer still referenced by
    // uncommitted/in-flight GPU dispatches (e.g. if an AOT archive ever copies host data into
    // a >= 64 KB buffer obtained via intra/inter-CB reuse).
    bool rebind_host_to_contents = false;
    if (pool_megabytes() > 0 && metal_buf) {
        bool need_sync_fallback = false;
        {
            PoolLock held;
            auto it = pooled.find(handle->buf);
            if (it != pooled.end()) {
                if (it->second.gpu_in_flight) {
                    if (it->second.references == 1 && handle->offset == 0) {
                        void *old_buf = handle->buf;
                        uint8_t *old_contents = reinterpret_cast<uint8_t *>(
                            ((void *(*)(id, SEL))objc_msgSend)(
                                reinterpret_cast<id>(old_buf), sel_getUid("contents")));
                        if (old_contents && buffer->host == old_contents + handle->offset) {
                            rebind_host_to_contents = true;
                        }
                        const size_t length = it->second.length;
                        const bool old_host_written = it->second.host_written;

                        reclaim_returned();
                        void *replacement = nullptr;
                        auto idle_it = idle.find(length);
                        if (idle_it != idle.end()) {
                            replacement = idle_it->second;
                            idle.erase(idle_it);
                            idle_bytes -= length;
                        } else {
                            replacement = ((void *(*)(id, SEL, size_t, size_t))objc_msgSend)(
                                reinterpret_cast<id>(dev),
                                sel_getUid("newBufferWithLength:options:"), length, 0);
                        }
                        if (!replacement) {
                            halide_metal_release_context(user_context);
                            return halide_error_code_out_of_memory;
                        }

                        Returned old_entry = make_returned_entry(
                            old_buf, length, old_host_written,
                            hq.active_cb, hq.active_queue);
                        pooled[old_buf].references = 0;
                        returning.push_back(old_entry);

                        pooled[replacement] = PooledBuffer{
                            length, 1, /*host_written=*/true, /*gpu_in_flight=*/false};
                        handle->buf = replacement;
                        metal_buf = reinterpret_cast<id>(replacement);
                    } else {
                        need_sync_fallback = true;
                    }
                } else {
                    it->second.host_written = true;
                }
            }
        }
        if (need_sync_fallback) {
            int sync_err = halide_metal_device_sync_internal(que, nullptr);
            if (sync_err) {
                halide_metal_release_context(user_context);
                return sync_err;
            }
            PoolLock held;
            auto it = pooled.find(handle->buf);
            if (it != pooled.end()) {
                it->second.gpu_in_flight = false;
                it->second.host_written = true;
            }
        }
    }

    uint8_t *dst_base = reinterpret_cast<uint8_t *>(
        ((void *(*)(id, SEL))objc_msgSend)(metal_buf, sel_getUid("contents")));
    if (!dst_base || !copy_host_to_metal_buffer(buffer, dst_base + handle->offset)) {
        halide_metal_release_context(user_context);
        return halide_error_code_generic_error;
    }
    if (rebind_host_to_contents) {
        buffer->host = dst_base + handle->offset;
    }

    int sync_err = halide_error_code_success;
    if (is_metal_buffer_managed(metal_buf)) {
        struct NSRange { size_t location; size_t length; };
        const size_t total_bytes = buffer->size_in_bytes();
        if (total_bytes > 0) {
            NSRange r{0, total_bytes};
            ((void(*)(id, SEL, NSRange))objc_msgSend)(
                metal_buf, sel_getUid("didModifyRange:"), r);
        }
        sync_err = halide_metal_device_sync_internal(que, buffer);
    }
    // MTLStorageModeShared: CPU memcpy is coherent on unified/shared memory once
    // the subsequent command buffer commits — do NOT flush or stall the queue.

    halide_metal_release_context(user_context);
    return sync_err;
}

// ---------------------------------------------------------------------------
// Host-queue async scope public API
// ---------------------------------------------------------------------------

extern "C" void fotufilm_halide_metal_host_queue_begin(void *mtl_command_queue) {
    // Flush any open command buffer from a prior call before switching queues.
    (void)flush_active_cb(!hq.host_queue_async);
    hq.flip_decode_input_y = 0;
    hq.flip_frame_output_y = 0;
    hq.full_frame_height = 0;

    if (hq.host_queue) {
        send(hq.host_queue, "release");
        hq.host_queue = nullptr;
    }

    if (mtl_command_queue) {
        hq.host_queue = reinterpret_cast<id>(mtl_command_queue);
        send(hq.host_queue, "retain");
        hq.host_queue_async = true;

        // Ensure context_device is initialised and open active_cb immediately so
        // FrameScope pooled buffers inside this scope always see a live active_cb.
        halide_metal_device *dev = nullptr;
        halide_metal_command_queue *que = nullptr;
        if (halide_metal_acquire_context(nullptr, &dev, &que, true) == 0) {
            halide_metal_release_context(nullptr);
        }
        ensure_active_cb(hq.host_queue);
    } else {
        hq.host_queue_async = false;
    }
}

extern "C" void *fotufilm_halide_metal_host_compute_encoder(void) {
    if (!hq.host_queue_async || !hq.host_queue) return nullptr;
    id cb = ensure_active_cb(hq.host_queue);
    return static_cast<void *>(ensure_compute_encoder(cb));
}

extern "C" void *fotufilm_halide_metal_host_queue_end(void) {
    hq.flip_decode_input_y = 0;
    hq.flip_frame_output_y = 0;
    hq.full_frame_height = 0;
    if (!hq.host_queue_async || !hq.active_cb) {
        if (hq.active_cb) {
            (void)flush_active_cb(false);
        } else {
            close_all_encoders();
        }
        if (hq.host_queue) {
            send(hq.host_queue, "release");
            hq.host_queue = nullptr;
        }
        hq.active_cb = nullptr;
        hq.active_queue = nullptr;
        hq.cb_has_handler = false;
        hq.host_queue_async = false;
        return nullptr;
    }

    close_all_encoders();
    id committed = hq.active_cb;
    id committed_queue = hq.active_queue;
    hq.active_cb = nullptr;
    hq.active_queue = nullptr;
    const bool had_handler = hq.cb_has_handler;
    hq.cb_has_handler = false;
    if (!had_handler) {
        attach_fallback_handler(committed);
    }

    // Commit without waiting on CPU, then record as the committed pool fence (+1 retained
    // by newest_host_fence) and remember `prev_cb_id` for 2-slot inter-CB buffer pipelining.
    send(committed, "commit");
    record_pool_fence(committed, committed_queue);
    hq.prev_cb_id = reinterpret_cast<uintptr_t>(committed);
    hq.prev_queue = committed_queue;

    if (hq.host_queue) {
        send(hq.host_queue, "release");
        hq.host_queue = nullptr;
    }
    hq.host_queue_async = false;

    // Transfer ensure_active_cb's +1 retain directly to the caller
    // (adopted by Swift via Unmanaged<MTLCommandBuffer>.takeRetainedValue()).
    return static_cast<void *>(committed);
}

extern "C" int32_t fotufilm_halide_metal_host_queue_active(void) {
    return hq.host_queue_async ? 1 : 0;
}

extern "C" int32_t fotufilm_halide_metal_host_queue_flush_wait(void) {
    hq.flip_decode_input_y = 0;
    hq.flip_frame_output_y = 0;
    hq.full_frame_height = 0;
    const bool ok = flush_active_cb(true);
    if (hq.host_queue) {
        send(hq.host_queue, "release");
        hq.host_queue = nullptr;
    }
    hq.host_queue_async = false;
    return ok ? 1 : 0;
}

extern "C" void fotufilm_halide_metal_set_io_flip(int32_t flip_decode_input_y,
                                                  int32_t flip_frame_output_y,
                                                  int32_t full_frame_height) {
    hq.flip_decode_input_y = flip_decode_input_y;
    hq.flip_frame_output_y = flip_frame_output_y;
    hq.full_frame_height = full_frame_height;
}

extern "C" void *fotufilm_halide_metal_context_create(void) {
    return new (std::nothrow) ExecutionState();
}

extern "C" void fotufilm_halide_metal_context_destroy(void *opaque) {
    delete static_cast<ExecutionState *>(opaque);
}

extern "C" void *fotufilm_halide_metal_context_bind(void *opaque) {
    ExecutionState *previous = bound_execution_state;
    bound_execution_state = static_cast<ExecutionState *>(opaque);
    return previous;
}

extern "C" void fotufilm_halide_metal_context_restore(void *opaque) {
    bound_execution_state = static_cast<ExecutionState *>(opaque);
}

extern "C" int32_t fotufilm_halide_metal_available(void) {
    configure_error_handler();
    static const bool valid = [] {
        const bool matches = valid_exposure_lut_contracts();
        if (!matches) {
            std::fprintf(stderr,
                         "Fotufilm Halide iOS error: generated exposure LUT type does not "
                         "match the runtime shim\n");
        }
        return matches;
    }();
    return valid ? 1 : 0;
}

extern "C" int32_t fotufilm_halide_metal_variant_exists(int32_t feature_mask) {
    return select_variant(feature_mask) != nullptr ? 1 : 0;
}

extern "C" int32_t fotufilm_halide_metal_prepare(
    int32_t, const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id) {
    ExecutionState &state = execution_state();
    return translate_exceptions([&] {
        return state.spectral_cache.ensure(
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
    if (!input || !output || !configuration || width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    ExecutionState &state = execution_state();
    return translate_exceptions([&] {
        int error = state.spectral_cache.ensure(
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id);
        if (error) return error;
        Buffer<uint8_t> input_buffer = Buffer<uint8_t>::make_interleaved(
            const_cast<uint8_t *>(input), width, height, 4);
        Buffer<uint8_t> output_buffer = Buffer<uint8_t>::make_interleaved(
            output, width, height, 4);
        input_buffer.set_host_dirty();
        error = run_aot(state, input_buffer.raw_buffer(), output_buffer.raw_buffer(),
                        width, height, configuration, feature_mask, seed);
        if (!error) error = output_buffer.copy_to_host();
        return error;
    });
}

extern "C" int32_t fotufilm_halide_metal_process_linear_float_rows(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t out_y, int32_t out_rows,
    int32_t origin_x, int32_t origin_y, const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!input || !output || !configuration || width <= 0 || height <= 0 ||
        out_y < 0 || out_rows <= 0 || out_y + out_rows > height ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    ExecutionState &state = execution_state();
    return translate_exceptions([&] {
        int error = state.spectral_cache.ensure(
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id);
        if (error) return error;
        Buffer<float> input_buffer = Buffer<float>::make_interleaved(
            const_cast<float *>(input), width, height, 4);
        // The output holds only the delivered rows, placed inside the strip by the buffer's
        // y-min. Bounds inference then walks each apron row through exactly the stages a
        // delivered pixel reads it from — the light chain for a halation neighbour, nothing at
        // all for a row only the blur normalisation touched — instead of developing the whole
        // strip edge to edge. The delivered pixels are the same expressions over the same
        // coordinates as an uncropped strip's, so their values do not move.
        Buffer<float> output_buffer = Buffer<float>::make_interleaved(
            output, width, out_rows, 4);
        output_buffer.translate(1, out_y);
        input_buffer.set_host_dirty();
        error = run_aot(state, input_buffer.raw_buffer(), output_buffer.raw_buffer(),
                        width, height, configuration,
                        feature_mask | FOTUFILM_FRAME_FLOAT_IO, seed,
                        origin_x, origin_y);
        if (!error) error = output_buffer.copy_to_host();
        return error;
    });
}

extern "C" int32_t fotufilm_halide_metal_process_linear_float(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t origin_x, int32_t origin_y, const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    return fotufilm_halide_metal_process_linear_float_rows(
        input, output, width, height, 0, height, origin_x, origin_y,
        configuration, exposure_lut, film_output_lut, paper_output_lut,
        lut_dimension, spectral_cache_id, feature_mask, seed);
}

namespace {

/// One tile through the compiled table, however the tile was handed across: `input_wrap` and
/// `output_wrap` are caller-owned MTLBuffers or 0, `input`/`output` host memory or null. The
/// window [out_x, out_x + out_columns) x [out_y, out_y + out_rows) is what the output holds,
/// packed; a null `fields` develops with the pyramid over the tile, otherwise the grids ride
/// behind the configuration and the mask asks for the FIELDS_IN class.
int32_t run_tile(
    ExecutionState &state, const float *input, uint64_t input_wrap,
    float *output, uint64_t output_wrap, int32_t output_channels,
    int32_t width, int32_t height,
    int32_t out_x, int32_t out_columns, int32_t out_y, int32_t out_rows,
    int32_t origin_x, int32_t origin_y, const float *configuration,
    const float *fields, int32_t fields_floats, uint64_t fields_id,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    return translate_exceptions([&] {
        int error = state.spectral_cache.ensure(
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id);
        if (error) return error;
        int32_t configuration_floats = FOTUFILM_FRAME_CONFIGURATION_COUNT;
        bool stable = false;
        std::vector<float> combined;
        if (fields) {
            configuration_floats += fields_floats;
            feature_mask |= FOTUFILM_FRAME_FIELDS_IN;
            if (fields == configuration + FOTUFILM_FRAME_CONFIGURATION_COUNT) {
                // One blob, the caller's, read in place for as long as its id stands.
                stable = true;
            } else {
                combined.resize(static_cast<size_t>(configuration_floats));
                std::memcpy(combined.data(), configuration,
                            FOTUFILM_FRAME_CONFIGURATION_COUNT * sizeof(float));
                std::memcpy(combined.data() + FOTUFILM_FRAME_CONFIGURATION_COUNT,
                            fields, size_t(fields_floats) * sizeof(float));
                configuration = combined.data();
            }
        }
        Buffer<float> input_buffer = Buffer<float>::make_interleaved(
            input_wrap ? static_cast<float *>(nullptr) : const_cast<float *>(input),
            width, height, 4);
        // The output holds only the delivered window, placed inside the tile by the buffer's
        // mins. Bounds inference then walks each apron pixel through exactly the stages a
        // delivered pixel reads it from — the light chain for a halation neighbour, nothing
        // at all for a pixel only the blur normalisation touched — instead of developing the
        // whole tile edge to edge. The delivered pixels are the same expressions over the
        // same coordinates as an uncropped frame's, so their values do not move.
        Buffer<float> output_buffer = Buffer<float>::make_interleaved(
            output_wrap ? static_cast<float *>(nullptr) : output,
            out_columns, out_rows, output_channels);
        if (out_x != 0) output_buffer.translate(0, out_x);
        if (out_y != 0) output_buffer.translate(1, out_y);
        if (input_wrap) {
            error = halide_metal_wrap_buffer(nullptr, input_buffer.raw_buffer(), input_wrap);
            if (error) return error;
            input_buffer.set_device_dirty();
        } else {
            input_buffer.set_host_dirty();
        }
        if (output_wrap) {
            error = halide_metal_wrap_buffer(nullptr, output_buffer.raw_buffer(), output_wrap);
            if (error) {
                halide_metal_detach_buffer(nullptr, input_buffer.raw_buffer());
                return error;
            }
        }
        error = run_aot(state, input_buffer.raw_buffer(), output_buffer.raw_buffer(),
                        width, height, configuration,
                        feature_mask | FOTUFILM_FRAME_FLOAT_IO, seed,
                        origin_x, origin_y, configuration_floats, fields_id, stable);
        if (!error) {
            if (output_wrap) {
                if (!hq.host_queue_async) error = output_buffer.device_sync();
            } else {
                error = output_buffer.copy_to_host();
            }
        }
        int detach_error = 0;
        if (input_wrap) {
            detach_error = halide_metal_detach_buffer(nullptr, input_buffer.raw_buffer());
        }
        if (output_wrap) {
            const int detached = halide_metal_detach_buffer(
                nullptr, output_buffer.raw_buffer());
            if (!detach_error) detach_error = detached;
        }
        return error ? error : detach_error;
    });
}

bool valid_tile(const float *configuration, int32_t width, int32_t height,
                int32_t out_x, int32_t out_columns, int32_t out_y, int32_t out_rows,
                const float *fields, int32_t fields_floats, int32_t feature_mask) {
    return configuration && width > 0 && height > 0
        && out_x >= 0 && out_columns > 0 && out_x + out_columns <= width
        && out_y >= 0 && out_rows > 0 && out_y + out_rows <= height
        && (!fields || fields_floats > 11)
        && valid_flare_mean(configuration, feature_mask);
}

/// The light-grid entries' window is in cells of the strip's own grid, whose first cell holds
/// the strip rows from `origin_y - origin_y % stride`.
bool valid_light_grid(const float *configuration, int32_t width, int32_t height,
                      int32_t out_y, int32_t out_rows, int32_t origin_y,
                      int32_t feature_mask, int32_t *stride) {
    if (!configuration || width <= 0 || height <= 0) return false;
    *stride = fotufilm_halation_stride(
        std::max(0, int32_t(configuration[kHalationRadiusOffset])));
    const int32_t grid_height = (height + origin_y % *stride + *stride - 1) / *stride;
    return out_y >= 0 && out_rows > 0 && out_y + out_rows <= grid_height
        && valid_flare_mean(configuration, feature_mask);
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
    if (!input || !output
        || !valid_tile(configuration, width, height, out_x, out_columns, out_y, out_rows,
                       fields, fields_floats, feature_mask)) return -1;
    return run_tile(execution_state(), input, 0, output, 0, 4, width, height,
                    out_x, out_columns, out_y, out_rows, origin_x, origin_y,
                    configuration, fields, fields_floats, fields_id,
                    exposure_lut, film_output_lut, paper_output_lut, lut_dimension,
                    spectral_cache_id, feature_mask, seed);
}

extern "C" int32_t fotufilm_halide_metal_process_light_grid(
    const float *input, float *grid_out, int32_t width, int32_t height,
    int32_t out_y, int32_t out_rows, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    int32_t stride = 1;
    if (!input || !grid_out
        || !valid_light_grid(configuration, width, height, out_y, out_rows, origin_y,
                             feature_mask, &stride)) return -1;
    return run_tile(execution_state(), input, 0, grid_out, 0, 3, width, height,
                    0, (width + stride - 1) / stride, out_y, out_rows, origin_x, origin_y,
                    configuration, nullptr, 0, 0,
                    exposure_lut, film_output_lut, paper_output_lut, lut_dimension,
                    spectral_cache_id,
                    (feature_mask | FOTUFILM_FRAME_LIGHT_OUT) & ~FOTUFILM_FRAME_FIELDS_IN,
                    seed);
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
    if (!grid || !halation_radii || !fields || width <= 0 || height <= 0 ||
        fields_floats != fotufilm_halide_metal_halation_fields_floats(
            width, height, halation_radii)) return -1;
    return translate_exceptions([&] {
        int32_t strides[3], strided[3], grid_floats[3];
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
        Buffer<float> grid_buffer = Buffer<float>::make_interleaved(
            const_cast<float *>(grid), (width + strides[0] - 1) / strides[0],
            (height + strides[0] - 1) / strides[0], 3);
        grid_buffer.set_host_dirty();
        float *grid_bases[3] = {
            fields + 11,
            fields + 11 + grid_floats[0],
            fields + 11 + grid_floats[0] + grid_floats[1]};
        Buffer<float> grids[3] = {
            Buffer<float>::make_interleaved(
                grid_bases[0], (width + strides[0] - 1) / strides[0],
                (height + strides[0] - 1) / strides[0], 3),
            Buffer<float>::make_interleaved(
                grid_bases[1], (width + strides[1] - 1) / strides[1],
                (height + strides[1] - 1) / strides[1], 3),
            Buffer<float>::make_interleaved(
                grid_bases[2], (width + strides[2] - 1) / strides[2],
                (height + strides[2] - 1) / strides[2], 3)};
        int error = fotufilm_halide_ios_halation_fields(
            grid_buffer.raw_buffer(), width, height,
            strides[0], strides[1], strides[2],
            strided[0], strided[1], strided[2],
            grids[0].raw_buffer(), grids[1].raw_buffer(),
            grids[2].raw_buffer());
        for (auto &grid_out : grids) {
            if (!error) error = grid_out.copy_to_host();
        }
        if (error) flush_internal_cb_on_error();
        return error;
    });
}

extern "C" void fotufilm_halide_metal_release_fields(void) {
    ExecutionState &state = execution_state();
    state.extended_configuration = Buffer<float>();
    state.extended_configuration_id = 0;
    state.extended_configuration_floats = 0;
}


extern "C" int32_t fotufilm_halide_metal_process_buffers(
    uint64_t input_mtl_buffer, uint64_t output_mtl_buffer,
    int32_t width, int32_t height, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!input_mtl_buffer || !output_mtl_buffer || !configuration ||
        width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    ExecutionState &state = execution_state();
    return translate_exceptions([&] {
        int error = state.spectral_cache.ensure(
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id);
        if (error) return error;
        Buffer<uint8_t> input_buffer = Buffer<uint8_t>::make_interleaved(
            static_cast<uint8_t *>(nullptr), width, height, 4);
        Buffer<uint8_t> output_buffer = Buffer<uint8_t>::make_interleaved(
            static_cast<uint8_t *>(nullptr), width, height, 4);
        error = halide_metal_wrap_buffer(nullptr, input_buffer.raw_buffer(), input_mtl_buffer);
        if (!error) error = halide_metal_wrap_buffer(
            nullptr, output_buffer.raw_buffer(), output_mtl_buffer);
        if (error) return error;
        input_buffer.set_device_dirty();
        error = run_aot(state, input_buffer.raw_buffer(), output_buffer.raw_buffer(),
                        width, height, configuration, feature_mask, seed,
                        origin_x, origin_y);
        static const bool skip_sync = [] {
            const char *env = getenv("FOTUFILM_NOSYNC");
            return env && atoi(env) != 0;
        }();
        if (!error && !hq.host_queue_async) {
            if (skip_sync) {
                (void)flush_active_cb(false);
            } else {
                error = output_buffer.device_sync();
            }
        }
        int detach_error = halide_metal_detach_buffer(nullptr, input_buffer.raw_buffer());
        if (!detach_error) detach_error = halide_metal_detach_buffer(
            nullptr, output_buffer.raw_buffer());
        return error ? error : detach_error;
    });
}

extern "C" int32_t fotufilm_halide_metal_process_buffers_float(
    uint64_t input_mtl_buffer, uint64_t output_mtl_buffer,
    int32_t width, int32_t height, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!input_mtl_buffer || !output_mtl_buffer || !configuration ||
        width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    ExecutionState &state = execution_state();
    return translate_exceptions([&] {
        int error = state.spectral_cache.ensure(
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id);
        if (error) return error;
        Buffer<float> input_buffer = Buffer<float>::make_interleaved(
            static_cast<float *>(nullptr), width, height, 4);
        Buffer<float> output_buffer = Buffer<float>::make_interleaved(
            static_cast<float *>(nullptr), width, height, 4);
        error = halide_metal_wrap_buffer(nullptr, input_buffer.raw_buffer(), input_mtl_buffer);
        if (!error) error = halide_metal_wrap_buffer(
            nullptr, output_buffer.raw_buffer(), output_mtl_buffer);
        if (error) return error;
        int32_t call_mask = feature_mask | FOTUFILM_FRAME_FLOAT_IO;
        if (hq.flip_frame_output_y != 0 && output_buffer.raw_buffer()->device) {
            struct device_handle_t { void *buf; uint64_t offset; };
            auto *out_handle = reinterpret_cast<device_handle_t *>(
                output_buffer.raw_buffer()->device);
            const int32_t full_h = (hq.full_frame_height >= origin_y + height)
                ? hq.full_frame_height
                : (origin_y + height);
            out_handle->offset =
                uint64_t(full_h - 1 - origin_y) * uint64_t(width) * 16u;
            output_buffer.raw_buffer()->dim[1].stride = -4 * width;
        }
        input_buffer.set_device_dirty();
        error = run_aot(state, input_buffer.raw_buffer(), output_buffer.raw_buffer(),
                        width, height, configuration, call_mask,
                        seed, origin_x, origin_y);
        // Skip the CPU sync when a host-queue async scope is active: the caller
        // (OFX gpuFrames) will commit the CB and wait on its own schedule.
        if (!error && !hq.host_queue_async) error = output_buffer.device_sync();
        int detach_error = halide_metal_detach_buffer(nullptr, input_buffer.raw_buffer());
        if (!detach_error) detach_error = halide_metal_detach_buffer(
            nullptr, output_buffer.raw_buffer());
        return error ? error : detach_error;
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
    if (!input_mtl_buffer || !output_mtl_buffer
        || !valid_tile(configuration, width, height, out_x, out_columns, out_y, out_rows,
                       fields, fields_floats, feature_mask)) return -1;
    return run_tile(execution_state(), nullptr, input_mtl_buffer, nullptr, output_mtl_buffer,
                    4, width, height, out_x, out_columns, out_y, out_rows, origin_x, origin_y,
                    configuration, fields, fields_floats, fields_id,
                    exposure_lut, film_output_lut, paper_output_lut, lut_dimension,
                    spectral_cache_id, feature_mask, seed);
}

extern "C" int32_t fotufilm_halide_metal_process_buffers_light_grid(
    uint64_t input_mtl_buffer, float *grid_out, int32_t width, int32_t height,
    int32_t out_y, int32_t out_rows, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    int32_t stride = 1;
    if (!input_mtl_buffer || !grid_out
        || !valid_light_grid(configuration, width, height, out_y, out_rows, origin_y,
                             feature_mask, &stride)) return -1;
    return run_tile(execution_state(), nullptr, input_mtl_buffer, grid_out, 0, 3,
                    width, height, 0, (width + stride - 1) / stride, out_y, out_rows,
                    origin_x, origin_y, configuration, nullptr, 0, 0,
                    exposure_lut, film_output_lut, paper_output_lut, lut_dimension,
                    spectral_cache_id,
                    (feature_mask | FOTUFILM_FRAME_LIGHT_OUT) & ~FOTUFILM_FRAME_FIELDS_IN,
                    seed);
}

namespace {

/// One measure pass over a band, however the band was handed across. `wrap` is a caller-owned
/// MTLBuffer or 0; `rows_in` is host rows or null; exactly one of the two.
int32_t run_measure(
    ExecutionState &,
    Buffer<float> &exposure,
    int32_t (*kernel)(halide_buffer_t *, halide_buffer_t *, halide_buffer_t *,
                      int32_t, int32_t, int32_t, halide_buffer_t *),
    uint64_t wrap, const float *rows_in, float *out, int32_t lanes,
    int32_t width, int32_t rows, int32_t origin_y, int32_t grid_width,
    const float *configuration) {
    FrameScope frame_scope;
    Buffer<float> local_configuration(FOTUFILM_FRAME_CONFIGURATION_COUNT);
    std::memcpy(local_configuration.data(), configuration,
                FOTUFILM_FRAME_CONFIGURATION_COUNT * sizeof(float));
    local_configuration.set_host_dirty();
    Buffer<float> input_buffer = Buffer<float>::make_interleaved(
        wrap ? static_cast<float *>(nullptr) : const_cast<float *>(rows_in),
        width, rows, 4);
    if (wrap) {
        const int error = halide_metal_wrap_buffer(
            nullptr, input_buffer.raw_buffer(), wrap);
        if (error) return error;
        input_buffer.set_device_dirty();
    } else {
        input_buffer.set_host_dirty();
    }
    Buffer<float> out_buffer(out, lanes, rows);
    int error = kernel(input_buffer.raw_buffer(),
                       local_configuration.raw_buffer(),
                       exposure.raw_buffer(),
                       width, grid_width, origin_y, out_buffer.raw_buffer());
    if (!error) {
        error = out_buffer.copy_to_host();
    } else {
        flush_internal_cb_on_error();
    }
    if (wrap) {
        const int detach = halide_metal_detach_buffer(
            nullptr, input_buffer.raw_buffer());
        if (!error) error = detach;
    }
    return error;
}

}

extern "C" int32_t fotufilm_halide_metal_measure_tone_rows(
    uint64_t input_mtl_buffer, const float *input_rows, float *rows_out,
    int32_t grid_width, int32_t width, int32_t rows,
    const float *configuration) {
    if ((input_mtl_buffer == 0) == (input_rows == nullptr) || !rows_out ||
        !configuration || width <= 0 || rows <= 0 || grid_width <= 0 ||
        grid_width > width) return -1;
    ExecutionState &state = execution_state();
    return translate_exceptions([&] {
        return run_measure(state, state.unused_measure_exposure,
                           fotufilm_halide_ios_measure_tone, input_mtl_buffer,
                           input_rows, rows_out, grid_width, width, rows, 0,
                           grid_width, configuration);
    });
}

extern "C" int32_t fotufilm_halide_metal_measure_flare_rows(
    uint64_t input_mtl_buffer, const float *input_rows, float *rows_out,
    int32_t width, int32_t rows, int32_t origin_y,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, uint64_t spectral_cache_id, int32_t feature_mask) {
    if ((input_mtl_buffer == 0) == (input_rows == nullptr) || !rows_out ||
        !configuration || !exposure_lut || !film_output_lut ||
        !paper_output_lut || width <= 0 || rows <= 0 || origin_y < 0) return -1;
    ExecutionState &state = execution_state();
    return translate_exceptions([&] {
        // All three cubes, though only the exposure one is read here. The cache keys the set as
        // one: filling it with anything else under this frame's id leaves the develop that
        // follows convinced it already has the film and paper cubes it does not have.
        const int error = state.spectral_cache.ensure(
            exposure_lut, film_output_lut, paper_output_lut, lut_dimension,
            spectral_cache_id);
        if (error) return error;
        const bool approximate = (feature_mask & FOTUFILM_FRAME_EXACT_MATH) == 0;
        return run_measure(state, state.spectral_cache.exposure,
                           approximate ? fotufilm_halide_ios_measure_flare_fast
                                       : fotufilm_halide_ios_measure_flare,
                           input_mtl_buffer, input_rows, rows_out, 3, width,
                           rows, origin_y, 1, configuration);
    });
}

namespace {

using DecodeFunction = int (*)(halide_buffer_t *, halide_buffer_t *, int32_t,
                               int32_t, int32_t,
                               halide_buffer_t *, halide_buffer_t *);

int32_t run_decode_rows(
    DecodeFunction decode,
    uint64_t input_mtl_buffer, const float *input_rows,
    uint64_t output_mtl_buffer, float *output_rows, float *report_out,
    int32_t width, int32_t rows, const float *parameters) {
    if ((input_mtl_buffer == 0) == (input_rows == nullptr) ||
        (output_mtl_buffer == 0) == (output_rows == nullptr) ||
        !parameters || width <= 0 || rows <= 0) return -1;
    const bool skip_report = hq.host_queue_async || (report_out == nullptr);
    const int32_t flip_y = (hq.flip_decode_input_y != 0) ? 1 : 0;
    const int32_t full_height =
        (flip_y != 0 && hq.full_frame_height > 0) ? hq.full_frame_height : rows;
    return translate_exceptions([&] {
        FrameScope frame_scope;
        Buffer<float> parameter_buffer(FOTUFILM_DECODE_PARAMETER_COUNT);
        std::memcpy(parameter_buffer.data(), parameters,
                    FOTUFILM_DECODE_PARAMETER_COUNT * sizeof(float));
        parameter_buffer.set_host_dirty();
        Buffer<float> input_buffer = Buffer<float>::make_interleaved(
            input_mtl_buffer ? static_cast<float *>(nullptr)
                             : const_cast<float *>(input_rows),
            width, rows, 4);
        Buffer<float> output_buffer = Buffer<float>::make_interleaved(
            output_mtl_buffer ? static_cast<float *>(nullptr) : output_rows,
            width, rows, 4);
        int error = 0;
        if (input_mtl_buffer) {
            error = halide_metal_wrap_buffer(nullptr, input_buffer.raw_buffer(),
                                             input_mtl_buffer);
            if (error) return error;
            input_buffer.set_device_dirty();
        } else {
            input_buffer.set_host_dirty();
        }
        if (output_mtl_buffer) {
            error = halide_metal_wrap_buffer(nullptr, output_buffer.raw_buffer(),
                                             output_mtl_buffer);
            if (error) {
                if (input_mtl_buffer) {
                    halide_metal_detach_buffer(nullptr, input_buffer.raw_buffer());
                }
                return error;
            }
        }
        Buffer<float> report_buffer = skip_report
            ? Buffer<float>(2, rows)
            : Buffer<float>(report_out, 2, rows);
        if (flip_y != 0 && full_height > rows) {
            input_buffer.raw_buffer()->dim[1].extent = full_height;
        }
        struct SkipDecodeReportScope {
            bool prev;
            explicit SkipDecodeReportScope(bool v) : prev(tls_skip_decode_report) {
                tls_skip_decode_report = v;
            }
            ~SkipDecodeReportScope() { tls_skip_decode_report = prev; }
        } report_scope(skip_report);
        error = decode(
            input_buffer.raw_buffer(), parameter_buffer.raw_buffer(), width,
            flip_y, full_height,
            output_buffer.raw_buffer(), report_buffer.raw_buffer());
        // When host_queue_async is active (or report_out == nullptr), skip reading back the
        // report and zero report_out if provided; skip output device_sync when host_queue_async.
        if (!error) {
            if (skip_report) {
                if (report_out) {
                    std::memset(report_out, 0, sizeof(float) * 2 * size_t(rows));
                }
            } else {
                error = report_buffer.copy_to_host();
            }
            if (!error && !output_mtl_buffer) {
                error = output_buffer.copy_to_host();
            } else if (!error && output_mtl_buffer && !hq.host_queue_async) {
                error = output_buffer.device_sync();
            }
        }
        if (error) {
            flush_internal_cb_on_error();
        }
        if (input_mtl_buffer) {
            const int detach = halide_metal_detach_buffer(
                nullptr, input_buffer.raw_buffer());
            if (!error) error = detach;
        }
        if (output_mtl_buffer) {
            const int detach = halide_metal_detach_buffer(
                nullptr, output_buffer.raw_buffer());
            if (!error) error = detach;
        }
        return error;
    });
}

}  // namespace

extern "C" int32_t fotufilm_halide_metal_decode_rows(
    uint64_t input_mtl_buffer, const float *input_rows,
    uint64_t output_mtl_buffer, float *output_rows, float *report_out,
    int32_t width, int32_t rows, const float *parameters) {
    return run_decode_rows(
        fotufilm_halide_ios_decode, input_mtl_buffer, input_rows,
        output_mtl_buffer, output_rows, report_out, width, rows, parameters);
}

extern "C" int32_t fotufilm_halide_metal_decode_rows_realtime(
    uint64_t input_mtl_buffer, const float *input_rows,
    uint64_t output_mtl_buffer, float *output_rows, float *report_out,
    int32_t width, int32_t rows, const float *parameters) {
    return run_decode_rows(
        fotufilm_halide_ios_decode_realtime, input_mtl_buffer, input_rows,
        output_mtl_buffer, output_rows, report_out, width, rows, parameters);
}

extern "C" int32_t fotufilm_halide_metal_process_buffers_head(
    uint64_t input_mtl_buffer, uint64_t density_mtl_buffer,
    int32_t width, int32_t height, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!input_mtl_buffer || !density_mtl_buffer || !configuration ||
        width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    ExecutionState &state = execution_state();
    return translate_exceptions([&] {
        int error = state.spectral_cache.ensure(
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id);
        if (error) return error;
        Buffer<uint8_t> input_buffer = Buffer<uint8_t>::make_interleaved(
            static_cast<uint8_t *>(nullptr), width, height, 4);
        Buffer<> density_buffer = Buffer<>::make_interleaved(
            halide_type_t(halide_type_float, 16), nullptr, width, height, 4);
        error = halide_metal_wrap_buffer(nullptr, input_buffer.raw_buffer(), input_mtl_buffer);
        if (!error) error = halide_metal_wrap_buffer(
            nullptr, density_buffer.raw_buffer(), density_mtl_buffer);
        if (error) return error;
        input_buffer.set_device_dirty();
        // Exactly FOTUFILM_AOT_HEAD, which is what the head variants were compiled
        // from: everything up to the cut, and nothing that belongs after it. The
        // enlarger belongs after it — it images a negative that already has grain
        // in it — so stripping it here is what keeps the split path's print the
        // same picture the unsplit path makes.
        const int32_t head_mask = (feature_mask
            & ~(FOTUFILM_FRAME_GRAIN | FOTUFILM_FRAME_GRAIN_MOTTLE | FOTUFILM_FRAME_PRINT_MTF))
            | FOTUFILM_FRAME_DENSITY_OUT;
        error = run_aot(state, input_buffer.raw_buffer(), density_buffer.raw_buffer(),
                        width, height, configuration, head_mask, seed,
                        origin_x, origin_y);
        if (!error && !hq.host_queue_async) error = density_buffer.device_sync();
        int detach_error = halide_metal_detach_buffer(nullptr, input_buffer.raw_buffer());
        if (!detach_error) detach_error = halide_metal_detach_buffer(
            nullptr, density_buffer.raw_buffer());
        return error ? error : detach_error;
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
    if (!density_mtl_buffer || !output_mtl_buffer || !configuration ||
        width <= 0 || height <= 0) return -1;
    ExecutionState &state = execution_state();
    return translate_exceptions([&] {
        int error = state.spectral_cache.ensure(
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id);
        if (error) return error;
        const int32_t in_w = density_width > 0 ? density_width : width;
        const int32_t in_h = density_height > 0 ? density_height : height;
        Buffer<> density_buffer = Buffer<>::make_interleaved(
            halide_type_t(halide_type_float, 16), nullptr, in_w, in_h, 4);
        Buffer<uint8_t> output_buffer = Buffer<uint8_t>::make_interleaved(
            static_cast<uint8_t *>(nullptr), width, height, 4);
        error = halide_metal_wrap_buffer(nullptr, density_buffer.raw_buffer(), density_mtl_buffer);
        if (!error) error = halide_metal_wrap_buffer(
            nullptr, output_buffer.raw_buffer(), output_mtl_buffer);
        if (error) return error;
        density_buffer.set_device_dirty();
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
        error = run_aot(state, density_buffer.raw_buffer(), output_buffer.raw_buffer(),
                        width, height, configuration, tail_mask, seed,
                        origin_x, origin_y);
        if (!error && !hq.host_queue_async) error = output_buffer.device_sync();
        int detach_error = halide_metal_detach_buffer(nullptr, density_buffer.raw_buffer());
        if (!detach_error) detach_error = halide_metal_detach_buffer(
            nullptr, output_buffer.raw_buffer());
        return error ? error : detach_error;
    });
}

extern "C" void fotufilm_halide_metal_report_profile(void) {
    halide_profiler_report(nullptr);
}

extern "C" int32_t fotufilm_halide_metal_still_fast_bits(void) {
    return FOTUFILM_STILL_FAST_BITS;
}

extern "C" int32_t fotufilm_negative_scan(const float *in, float *out, int32_t w,
    int32_t h, const float *p, int32_t backend) {
    if (!in || !out || !p || w < 1 || h < 1 || w > 40000 || h > 40000
        || int64_t(w)*h > 150000000 || backend < 0 || backend > 1) return -1;
    for (int c = 0; c < 3; ++c)
        if (!std::isfinite(p[c]) || !std::isfinite(p[c+3]) || p[c] < 0 || p[c+3] < p[c]) return -1;
    if (!std::isfinite(p[6]) || p[6] < 0.1f || p[6] > 2.0f || !std::isfinite(p[7])) return -1;
    Buffer<float> input(const_cast<float *>(in), w, h, 3), output(out, w, h, 3);
    Buffer<float> params(const_cast<float *>(p), 8);
    input.set_host_dirty(); params.set_host_dirty();
    int status = backend ? fotufilm_halide_ios_negative_metal(input, params, output)
                         : fotufilm_halide_ios_negative_cpu(input, params, output);
    if (!status) {
        status = output.copy_to_host();
    } else if (backend) {
        flush_internal_cb_on_error();
    }
    return status;
}

// A scanned negative's light-frame division and plain reading (ScanPreparePipeline), in place.
extern "C" int32_t fotufilm_scan_prepare(const float *in, float *out, int32_t w, int32_t h,
    const float *light, int32_t lw, int32_t lh, const float *p) {
    if (!in || !out || !p || w < 1 || h < 1 || w > 40000 || h > 40000
        || int64_t(w) * h > 150000000) return -1;
    for (int i = 0; i < FOTUFILM_SCAN_PREPARE_PARAMETERS; ++i) if (!std::isfinite(p[i])) return -1;
    const bool lit = p[0] > 0.5f;
    if (lit && (!light || lw < 1 || lh < 1 || lw > 4096 || lh > 4096)) return -1;
    static const float none[3] = {1, 1, 1};
    auto input = Buffer<float>::make_interleaved(const_cast<float *>(in), w, h, 4);
    auto output = Buffer<float>::make_interleaved(out, w, h, 4);
    auto cells = Buffer<float>::make_interleaved(const_cast<float *>(lit ? light : none),
                                                 lit ? lw : 1, lit ? lh : 1, 3);
    Buffer<float> params(const_cast<float *>(p), FOTUFILM_SCAN_PREPARE_PARAMETERS);
    return fotufilm_halide_ios_scan_prepare_cpu(input, cells, params, output);
}

// A trichromatic scan's layer and merge (Pipeline/Trichromatic.h); the measuring is shared C++.
extern "C" int32_t fotufilm_trichromatic_layer(const float *rgba, int32_t w, int32_t h,
                                               const float colour[3], float *layer) {
    float weights[3];
    if (!rgba || !layer || !fotufilm::trichromatic::valid_size(w, h)
        || !fotufilm::trichromatic::layer_weights(colour, weights)) return -1;
    auto input = Buffer<float>::make_interleaved(const_cast<float *>(rgba), w, h, 4);
    Buffer<float> output(layer, w, h), params(weights, 3);
    return fotufilm_halide_ios_trichromatic_layer_cpu(input, params, output);
}

extern "C" int32_t fotufilm_trichromatic_merge(const float *red, const float *green,
                                               const float *blue, int32_t w, int32_t h,
                                               const float green_affine[6],
                                               const float blue_affine[6], uint8_t *file,
                                               int64_t size) {
    float p[15];
    if (!fotufilm::trichromatic::merge_header(red, green, blue, w, h, green_affine, blue_affine,
                                               file, size, p)) return -1;
    Buffer<float> r(const_cast<float *>(red), w, h), g(const_cast<float *>(green), w, h),
        b(const_cast<float *>(blue), w, h), params(p, 15);
    auto output = Buffer<uint16_t>::make_interleaved(
        reinterpret_cast<uint16_t *>(file + fotufilm::trichromatic::pixel_offset(h)), w, h, 3);
    return fotufilm_halide_ios_trichromatic_merge_cpu(r, g, b, params, output);
}

// Layered Transport: one component's light spread by its stencil table and added to the sum.
extern "C" int32_t fotufilm_transport_available(int32_t backend) { return backend == 0 || backend == 1; }

extern "C" int32_t fotufilm_transport_component(
    const float *exposure, float *accumulated, int32_t width, int32_t height, int32_t channels,
    const float *stencils, int32_t backend) {
    if (int32_t status = fotufilm_transport_validate(exposure, accumulated, width, height, channels,
                                                     stencils, backend)) return status;
    int32_t r[FOTUFILM_TRANSPORT_LEVELS];
    for (int l = 0; l < FOTUFILM_TRANSPORT_LEVELS; ++l) r[l] = int32_t(stencils[l]);
    Buffer<float> input(const_cast<float *>(exposure), width, height, channels);
    Buffer<float> sum(accumulated, width, height, channels);
    Buffer<float> table(const_cast<float *>(stencils), FOTUFILM_TRANSPORT_TABLE_FLOATS);
    input.set_host_dirty(); sum.set_host_dirty(); table.set_host_dirty();
    auto run = backend ? fotufilm_halide_ios_transport_metal : fotufilm_halide_ios_transport_cpu;
    // The sum is read only at the point written, so the pipeline adds into it in place.
    int status = run(input, sum, table, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9],
                     r[10], r[11], r[12], sum);
    if (!status) {
        status = sum.copy_to_host();
    } else if (backend) {
        flush_internal_cb_on_error();
    }
    return status;
}

extern "C" fotufilm_transport_frame *fotufilm_transport_frame_begin(
    const float *scene, const float *configuration, float *sum, int32_t width, int32_t height,
    int32_t channels, int32_t backend) {
    if (backend < 0 || backend > 1) return nullptr;
    fotufilm_transport_frame *frame = fotufilm::transport_frame::begin(
        backend ? fotufilm_halide_ios_transport_domain_metal : fotufilm_halide_ios_transport_domain_cpu,
        backend ? fotufilm_halide_ios_transport_scene_metal : fotufilm_halide_ios_transport_scene_cpu,
        backend ? halide_metal_device_interface() : nullptr, scene, configuration, sum, width, height,
        channels);
    if (backend == 1) {
        (void)flush_active_cb(true);
    }
    return frame;
}

extern "C" int32_t fotufilm_transport_frame_add(fotufilm_transport_frame *frame,
                                                const float *configuration,
                                                const float *exposure_lut, const float *stencils) {
    const int32_t status = fotufilm::transport_frame::add(
        frame, configuration, exposure_lut, stencils);
    (void)flush_active_cb(true);
    return status;
}

extern "C" int32_t fotufilm_transport_frame_finish(fotufilm_transport_frame *frame, int32_t deliver) {
    if (!deliver) {
        (void)flush_active_cb(true);
    }
    return fotufilm::transport_frame::finish(frame, deliver);
}

extern "C" int32_t fotufilm_halide_available(void) { return 0; }
// The Film tile builder needs the Halide compiler; ahead-of-time hosts build tiles in Metal.
extern "C" int32_t fotufilm_film_tile_build(int32_t, int32_t, int32_t, const float *, int32_t,
    const float *, const float *, int32_t, uint32_t, int32_t, float *) {
    return -3;
}
extern "C" int32_t fotufilm_halide_set_film_tiles(int32_t id, const float *tiles,
                                                  int64_t count) {
    return translate_exceptions([&] {
        return film_tile_store().set(id, tiles, count) ? 0 : -1;
    });
}
extern "C" int32_t fotufilm_halide_set_extra_donor_lut(int32_t, const float *lut,
                                                       int64_t count) {
    if (!lut || count == 0) return 0;
    return count == int64_t(kLutValueCount) ? -2 : -1;
}
extern "C" int32_t fotufilm_halide_develop(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, const float *, const float *, int32_t, int32_t,
    uint32_t) { return -1; }
extern "C" int32_t fotufilm_halide_print(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, const float *, const float *, const float *, int32_t,
    int32_t) { return -1; }
extern "C" int32_t fotufilm_halide_process(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, const float *, const float *, const float *,
    const float *, int32_t, int32_t, uint32_t) { return -1; }
extern "C" int32_t fotufilm_halide_process_strip(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    const float *, const float *, const float *, const float *, int32_t,
    int32_t, uint32_t) { return -1; }
extern "C" int32_t fotufilm_halide_process_tile(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, int32_t, const float *, const float *, const float *, const float *,
    int32_t, int32_t, uint32_t) { return -1; }
extern "C" int32_t fotufilm_halide_process_tile_with_exposure(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, int32_t, const float *, const float *, const float *, const float *,
    int32_t, int32_t, uint32_t, const float *) { return -1; }
extern "C" int32_t fotufilm_halide_gaussian(
    const float *, float *, int32_t, int32_t, float, int32_t) { return -1; }
extern "C" int32_t fotufilm_halide_approximate_gaussian(
    const float *, float *, int32_t, int32_t, int32_t) { return -1; }

#endif
