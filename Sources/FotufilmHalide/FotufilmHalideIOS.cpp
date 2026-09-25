#if defined(FOTUFILM_HALIDE_IOS_AOT)

#ifndef FOTUFILM_AOT_WINDOWED_HOST
#define FOTUFILM_AOT_WINDOWED_HOST 0
#endif

#include "FotufilmHalideIOSVariants.h"
#include "FotufilmFilmTileBuild.h"
#include "FotufilmNegativeScan.h"
#include "fotufilm_halide_ios_negative_cpu.h"
#include "fotufilm_halide_ios_negative_metal.h"
#include <HalideBuffer.h>
#include <HalideRuntimeMetal.h>

#include "FotufilmHalide.h"
#include "FotufilmHalideGeometry.h"
#include "FotufilmResolvedFrameParams.h"
#include "Pipeline/FilmTileStore.h"

#include <TargetConditionals.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <new>
#include <set>
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
/// experimenting through FOTUFILM_STILL_FAST overrides both together (ios/build-device.sh).
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
    Buffer<float> configuration{FOTUFILM_FRAME_CONFIGURATION_COUNT};
    Buffer<float> extended_configuration;
    uint64_t extended_configuration_id = 0;
    int32_t extended_configuration_floats = 0;
    int32_t last_windowed_trace_mask = 0;
    Buffer<float> measure_configuration{FOTUFILM_FRAME_CONFIGURATION_COUNT};
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

/// The shape every generated variant shares: the u8 and float libraries differ only in the element
/// type inside the buffers, which does not reach the signature.
using FrameFunction = int (*)(
    halide_buffer_t *, halide_buffer_t *, halide_buffer_t *, halide_buffer_t *,
    halide_buffer_t *, int32_t, int32_t, float, float, float, float, int32_t,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, float, int32_t,
    float, int32_t, float, int32_t, float, int32_t, float, int32_t, float, float, int32_t, int32_t, uint32_t,
    int32_t, int32_t,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    halide_buffer_t *, int32_t, halide_buffer_t *);

struct AotVariant {
    int32_t mask;
    FrameFunction function;
    const char *name;
};

const AotVariant kVariants[] = {
#define FOTUFILM_AOT_SHIM_ENTRY(variant_name, variant_mask) \
    {(variant_mask), fotufilm_halide_ios_##variant_name, #variant_name},
    FOTUFILM_AOT_VARIANTS(FOTUFILM_AOT_SHIM_ENTRY)
#undef FOTUFILM_AOT_SHIM_ENTRY
};

/// Select a compatible generated variant with the fewest extra compiled stages.
FrameFunction select_variant(int32_t feature_mask) {
    const int32_t wanted = feature_mask & FOTUFILM_AOT_VARIANT_BITS;
    const int32_t exact_bits = FOTUFILM_VARIANT_EXACT_BITS;
    // Diagnostic: choose another compatible variant to compare schedules. Extra compiled
    // stages are bypassed by the request's runtime gates, preserving its requested image.
    static const int wanted_rank = [] {
        const char *env = getenv("FOTUFILM_VARIANT_RANK");
        return env ? atoi(env) : -1;
    }();
    if (wanted_rank >= 0) {
        std::vector<const AotVariant *> acceptable;
        for (const AotVariant &variant : kVariants) {
            if ((variant.mask & exact_bits) != (wanted & exact_bits)) continue;
            if ((variant.mask & wanted) != wanted) continue;
            acceptable.push_back(&variant);
        }
        std::stable_sort(acceptable.begin(), acceptable.end(),
                         [&](const AotVariant *a, const AotVariant *b) {
                             return __builtin_popcount((unsigned)(a->mask & ~wanted))
                                  < __builtin_popcount((unsigned)(b->mask & ~wanted));
                         });
        if (!acceptable.empty()) {
            const AotVariant *picked =
                acceptable[std::min<size_t>(wanted_rank, acceptable.size() - 1)];
            std::fprintf(stderr,
                         "Fotufilm variant rank %d of %zu: %s (+%d bits)\n",
                         wanted_rank, acceptable.size(), picked->name,
                         __builtin_popcount((unsigned)(picked->mask & ~wanted)));
            return picked->function;
        }
    }
    const AotVariant *best = nullptr;
    int best_extra = 0;
    for (const AotVariant &variant : kVariants) {
        if ((variant.mask & exact_bits) != (wanted & exact_bits)) continue;
        if ((variant.mask & wanted) != wanted) continue;
        const int extra = __builtin_popcount(
            (unsigned)(variant.mask & ~wanted));
        if (!best || extra < best_extra) {
            best = &variant;
            best_extra = extra;
            if (extra == 0) break;
        }
    }
    // `FOTUFILM_TRACE_VARIANT=1` names what a render actually ran and how far the served variant
    // overshot what it asked for. The extra bits are stages compiled in and bypassed at run
    // time. It is printed once per distinct request, not once per frame.
    static std::set<int32_t> traced;
    static const bool tracing = [] {
        const char *env = getenv("FOTUFILM_TRACE_VARIANT");
        return env && atoi(env) != 0;
    }();
    if (tracing && best && traced.insert(wanted).second) {
        std::fprintf(stderr,
                     "Fotufilm variant: wanted 0x%x -> %s (0x%x), %d extra bit(s) 0x%x\n",
                     wanted, best->name, best->mask, best_extra,
                     (unsigned)(best->mask & ~wanted));
    }
    return best ? best->function : nullptr;
}

int run_aot(ExecutionState &state, halide_buffer_t *in, halide_buffer_t *out,
            int32_t width, int32_t height, const float *configuration,
            int32_t feature_mask, uint32_t seed,
            int32_t origin_x = 0, int32_t origin_y = 0,
            int32_t configuration_floats = FOTUFILM_FRAME_CONFIGURATION_COUNT,
            uint64_t configuration_id = 0, bool configuration_stable = false) {
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
    const size_t configuration_bytes =
        FOTUFILM_FRAME_CONFIGURATION_COUNT * sizeof(float);
    if (!wants_extended) {
        std::memcpy(state.configuration.data(), configuration, configuration_bytes);
        state.configuration.set_host_dirty();
    }
    const fotufilm::ResolvedFrameParams frame(configuration, width, height, seed,
        (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0, origin_x, origin_y);

    auto *cfg = wants_extended ? state.extended_configuration.raw_buffer()
                               : state.configuration.raw_buffer();
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
    in, cfg, exposure, film, paper, width, height, frame.mtf_sigma_0, frame.mtf_sigma_1, \
    frame.mtf_sigma_2, frame.mtf_luma_sigma, frame.mtf_radius_0, frame.mtf_radius_1, \
    frame.mtf_radius_2, frame.mtf_luma_radius, frame.halation_radius_0, frame.halation_radius_1, \
    frame.halation_radius_2, frame.coupler_sigma, frame.coupler_radius, frame.adjacency_sigma, \
    frame.adjacency_radius, frame.adjacency_secondary_sigma, frame.adjacency_secondary_radius, \
    frame.fringe_sigma, frame.fringe_radius, frame.grain_sigma, frame.grain_radius, \
    frame.grain_lambda, frame.mottle_lambda, frame.mottle_radius, frame.print_mtf_radius, seed, \
    frame.reversal, origin_x, origin_y, frame.halation_stride_0, frame.halation_stride_1, \
    frame.halation_stride_2, frame.halation_strided_radius_0, frame.halation_strided_radius_1, \
    frame.halation_strided_radius_2, frame.diffusion_stride_0, frame.diffusion_stride_1, \
    frame.diffusion_stride_2, frame.diffusion_strided_radius_0, frame.diffusion_strided_radius_1, \
    frame.diffusion_strided_radius_2, feature_mask, fotufilm_byte_basis(configuration), \
    film_tiles.raw_buffer(), film_on ? 1 : 0
    FrameFunction pipeline = select_variant(feature_mask);
    if (!pipeline) return -3;
#if FOTUFILM_AOT_WINDOWED_HOST
    const FrameFunction general_pipeline = pipeline;
    // Each full-resolution field needs 256 output rows plus its spatial apron.
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
    const int64_t image_reach = std::max({frame.mtf_radius_0, frame.mtf_radius_1, frame.mtf_radius_2})
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
    // The optimized folded schedule carries the original single-field adjacency only.
    // Screened adjacency and broad inter-layer transport use the general spatial graph.
    const bool supports_windowed_transport = configuration[FOTUFILM_CONFIG_ADJACENCY_MODEL] < 0.5f
        && configuration[FOTUFILM_CONFIG_CHROMATIC_FRINGE_AMOUNT] == 0;
    // A twin is compiled from the stage set the reach above bounds, so a request that asks for
    // a stage outside it — one whose reach this shim does not know — stays on the full-frame
    // variant.
    const int32_t wanted_stages = feature_mask & FOTUFILM_VARIANT_STAGE_BITS;
    // A folded graph never sees the whole frame, so a request that asks the kernel to measure
    // its own glare stays on the full-frame variant.
    const bool measures = (feature_mask & FOTUFILM_FRAME_FLARE_MEASURE) != 0;
    if (windowed_enabled && supports_windowed_transport && !measures
        && width >= 32 && height >= fotufilm::kWindowStorageRows
        && origin_x == 0 && origin_y == 0 && !wants_extended
        && in->dim[0].min == 0 && in->dim[1].min == 0
        && out->dim[0].min == 0 && out->dim[1].min == 0
        && in->dim[0].extent == width && in->dim[1].extent == height
        && out->dim[0].extent == width && out->dim[1].extent == height
        && std::max(image_reach, grain_reach) <= fotufilm::kWindowMaximumReach) {
#define FOTUFILM_PICK_WINDOWED(variant_name, variant_mask) \
        if (pipeline == fotufilm_halide_ios_##variant_name \
            && (wanted_stages & ~(variant_mask)) == 0) \
            pipeline = fotufilm_halide_ios_##variant_name##_windowed;
        FOTUFILM_AOT_WINDOWED_VARIANTS(FOTUFILM_PICK_WINDOWED)
#undef FOTUFILM_PICK_WINDOWED
    }
    if (pipeline != general_pipeline && state.last_windowed_trace_mask != feature_mask) {
        state.last_windowed_trace_mask = feature_mask;
        const char *tracing = std::getenv("FOTUFILM_TRACE_VARIANT");
        if (tracing && std::atoi(tracing)) {
            std::fprintf(stderr, "Fotufilm AOT: 256-row windows, spatial reach %lld pixels\n",
                         static_cast<long long>(std::max(image_reach, grain_reach)));
        }
    }
#endif
    return pipeline(FOTUFILM_ARGUMENTS, out);
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

namespace {

/// How many command buffers the runtime's queue may have in flight. Twin of `kMetalQueueDepth`
/// in FotufilmHalideMetal.cpp, where the reason is written up: the runtime commits one command
/// buffer per kernel and never waits, so on an unbounded queue every intermediate of a tile is
/// allocated before the first is freed, and the tile's footprint is the sum of its stages.
/// Blocking the host this close behind the device lets the early frees land.
constexpr unsigned long kMetalQueueDepth = 4;

// The runtime's own context is a system default device and an unbounded queue; the override
// below is the documented seam (HalideRuntimeMetal.h) for handing it another. Held from an
// acquire to its release on the same thread, as the runtime's own lock is. A pthread mutex
// rather than a std::mutex because it has no destructor to run: a device free from a static
// or thread-local buffer's destructor still acquires the context after `exit` has begun.
pthread_mutex_t context_mutex = PTHREAD_MUTEX_INITIALIZER;
halide_metal_device *context_device = nullptr;
halide_metal_command_queue *context_queue = nullptr;

}

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
                ((void (*)(id, SEL))objc_msgSend)(reinterpret_cast<id>(device),
                                                  sel_getUid("release"));
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
    *queue_ret = context_queue;
    return halide_error_code_success;
}

extern "C" int halide_metal_release_context(void *) {
    pthread_mutex_unlock(&context_mutex);
    return halide_error_code_success;
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
            error = output_wrap ? output_buffer.device_sync()
                                : output_buffer.copy_to_host();
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
        if (!error && !skip_sync) error = output_buffer.device_sync();
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
        input_buffer.set_device_dirty();
        error = run_aot(state, input_buffer.raw_buffer(), output_buffer.raw_buffer(),
                        width, height, configuration,
                        feature_mask | FOTUFILM_FRAME_FLOAT_IO,
                        seed, origin_x, origin_y);
        if (!error) error = output_buffer.device_sync();
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
    ExecutionState &state,
    Buffer<float> &exposure,
    int32_t (*kernel)(halide_buffer_t *, halide_buffer_t *, halide_buffer_t *,
                      int32_t, int32_t, int32_t, halide_buffer_t *),
    uint64_t wrap, const float *rows_in, float *out, int32_t lanes,
    int32_t width, int32_t rows, int32_t origin_y, int32_t grid_width,
    const float *configuration) {
    const size_t configuration_bytes =
        FOTUFILM_FRAME_CONFIGURATION_COUNT * sizeof(float);
    std::memcpy(state.measure_configuration.data(), configuration,
                configuration_bytes);
    state.measure_configuration.set_host_dirty();
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
                       state.measure_configuration.raw_buffer(),
                       exposure.raw_buffer(),
                       width, grid_width, origin_y, out_buffer.raw_buffer());
    if (!error) error = out_buffer.copy_to_host();
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

using DecodeFunction = int (*)(halide_buffer_t *, halide_buffer_t *, int32_t,
                               halide_buffer_t *, halide_buffer_t *);

int32_t run_decode_rows(
    DecodeFunction decode,
    uint64_t input_mtl_buffer, const float *input_rows,
    uint64_t output_mtl_buffer, float *output_rows, float *report_out,
    int32_t width, int32_t rows, const float *parameters) {
    if ((input_mtl_buffer == 0) == (input_rows == nullptr) ||
        (output_mtl_buffer == 0) == (output_rows == nullptr) ||
        !report_out || !parameters || width <= 0 || rows <= 0) return -1;
    return translate_exceptions([&] {
        Buffer<float> parameter_buffer(const_cast<float *>(parameters),
                                       FOTUFILM_DECODE_PARAMETER_COUNT);
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
        Buffer<float> report_buffer(report_out, 2, rows);
        error = decode(
            input_buffer.raw_buffer(), parameter_buffer.raw_buffer(), width,
            output_buffer.raw_buffer(), report_buffer.raw_buffer());
        // The report is always read on the host; the pixels only when the caller did not hand
        // over a buffer the device already owns.
        if (!error) error = report_buffer.copy_to_host();
        if (!error && !output_mtl_buffer) error = output_buffer.copy_to_host();
        if (!error && output_mtl_buffer) error = output_buffer.device_sync();
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
        if (!error) error = density_buffer.device_sync();
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
        if (!error) error = output_buffer.device_sync();
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
    if (!status) status = output.copy_to_host();
    return status;
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
extern "C" int32_t fotufilm_halide_gaussian(
    const float *, float *, int32_t, int32_t, float, int32_t) { return -1; }
extern "C" int32_t fotufilm_halide_approximate_gaussian(
    const float *, float *, int32_t, int32_t, int32_t) { return -1; }

#endif

// The layered Apple path injects AOT rendering and native Metal convolution.
// Keep the reference ABI linked for the shared portable Swift implementation.
#if defined(FOTUFILM_TRANSPORT_REFERENCE_STUBS)
#include "FotufilmTransport.cpp"
#endif
