#if defined(FOTUFILM_HALIDE_IOS_AOT)

#include "fotufilm_halide_ios_color.h"
#include "fotufilm_halide_ios_color_disc.h"
#include "fotufilm_halide_ios_monochrome.h"
#include "fotufilm_halide_ios_monochrome_disc.h"
#include "fotufilm_halide_ios_color_float.h"
#include "fotufilm_halide_ios_color_float_disc.h"
#include "fotufilm_halide_ios_monochrome_float.h"
#include "fotufilm_halide_ios_monochrome_float_disc.h"
#include "fotufilm_halide_ios_color_float_exact.h"
#include "fotufilm_halide_ios_color_float_exact_disc.h"
#include "fotufilm_halide_ios_monochrome_float_exact.h"
#include "fotufilm_halide_ios_monochrome_float_exact_disc.h"
#include "fotufilm_halide_ios_color_float_realtime.h"
#include "fotufilm_halide_ios_color_float_realtime_disc.h"
#include "fotufilm_halide_ios_monochrome_float_realtime.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_disc.h"
#include "fotufilm_halide_ios_color_float_realtime_no_print.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_no_print.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_linear.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_linear_disc.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_linear.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_linear_disc.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_power.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_power_disc.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_power.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_power_disc.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_log.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_log_disc.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_log.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_log_disc.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_linear_no_print.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_linear_no_print.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_power_no_print.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_power_no_print.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_log_no_print.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_log_no_print.h"
#include "fotufilm_halide_ios_color_float_realtime_measure_encode_log.h"
#include "fotufilm_halide_ios_color_float_realtime_measure_encode_log_disc.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_measure_encode_log.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_measure_encode_log_disc.h"
#include "fotufilm_halide_ios_color_float_realtime_measure_encode_log_no_print.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_measure_encode_log_no_print.h"
#include "fotufilm_halide_ios_color_float_realtime_negative.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_negative.h"
#include "fotufilm_halide_ios_color_float_realtime_print.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_print.h"
#include "fotufilm_halide_ios_color_float_realtime_texture.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_texture.h"
#include "fotufilm_halide_ios_color_float_negative.h"
#include "fotufilm_halide_ios_monochrome_float_negative.h"
#include "fotufilm_halide_ios_color_float_print.h"
#include "fotufilm_halide_ios_monochrome_float_print.h"
#include "fotufilm_halide_ios_color_float_texture.h"
#include "fotufilm_halide_ios_monochrome_float_texture.h"
#include "fotufilm_halide_ios_color_float_realtime_texture_flat.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_texture_flat.h"
#include "fotufilm_halide_ios_color_float_texture_flat.h"
#include "fotufilm_halide_ios_monochrome_float_texture_flat.h"
#include "fotufilm_halide_ios_negative.h"
#include "fotufilm_halide_ios_negative_disc.h"
#include "fotufilm_halide_ios_negative_grainless.h"
#include "fotufilm_halide_ios_negative_extended_mtf.h"
#include "fotufilm_halide_ios_negative_no_adjacency_extended_mtf.h"
#include "fotufilm_halide_ios_negative_grainless_extended_mtf.h"
#include "fotufilm_halide_ios_negative_no_adjacency_grainless_extended_mtf.h"
#include "fotufilm_halide_ios_slide.h"
#include "fotufilm_halide_ios_slide_disc.h"
#include "fotufilm_halide_ios_slide_grainless.h"
#include "fotufilm_halide_ios_slide_interimage.h"
#include "fotufilm_halide_ios_slide_interimage_grainless.h"
#include "fotufilm_halide_ios_slide_extended_mtf.h"
#include "fotufilm_halide_ios_slide_no_adjacency_extended_mtf.h"
#include "fotufilm_halide_ios_slide_grainless_extended_mtf.h"
#include "fotufilm_halide_ios_slide_no_adjacency_grainless_extended_mtf.h"
#include "fotufilm_halide_ios_slide_mono.h"
#include "fotufilm_halide_ios_slide_mono_disc.h"
#include "fotufilm_halide_ios_slide_mono_grainless.h"
#include "fotufilm_halide_ios_slide_mono_extended_mtf.h"
#include "fotufilm_halide_ios_slide_mono_extended_mtf_disc.h"
#include "fotufilm_halide_ios_slide_mono_no_adjacency_extended_mtf.h"
#include "fotufilm_halide_ios_slide_mono_grainless_extended_mtf.h"
#include "fotufilm_halide_ios_slide_mono_no_adjacency_grainless_extended_mtf.h"
#include "fotufilm_halide_ios_slide_mono_no_mtf.h"
#include "fotufilm_halide_ios_slide_mono_no_mtf_disc.h"
#include "fotufilm_halide_ios_slide_mono_no_mtf_grainless.h"
#include "fotufilm_halide_ios_color_float_measure.h"
#include "fotufilm_halide_ios_color_float_measure_disc.h"
#include "fotufilm_halide_ios_monochrome_float_measure.h"
#include "fotufilm_halide_ios_monochrome_float_measure_disc.h"
#include "fotufilm_halide_ios_color_flare.h"
#include "fotufilm_halide_ios_color_flare_disc.h"
#include "fotufilm_halide_ios_color_float_flare.h"
#include "fotufilm_halide_ios_color_float_flare_disc.h"
#include "fotufilm_halide_ios_color_float_realtime_flare.h"
#include "fotufilm_halide_ios_color_float_realtime_flare_disc.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_linear_flare.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_linear_flare_disc.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_power_flare.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_power_flare_disc.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_log_flare.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_log_flare_disc.h"
#include "fotufilm_halide_ios_monochrome_flare.h"
#include "fotufilm_halide_ios_monochrome_flare_disc.h"
#include "fotufilm_halide_ios_monochrome_float_flare.h"
#include "fotufilm_halide_ios_monochrome_float_flare_disc.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_flare.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_flare_disc.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_linear_flare.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_linear_flare_disc.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_power_flare.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_power_flare_disc.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_log_flare.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_log_flare_disc.h"
#include "fotufilm_halide_ios_color_float_exact_flare.h"
#include "fotufilm_halide_ios_color_float_exact_flare_disc.h"
#include "fotufilm_halide_ios_monochrome_float_exact_flare.h"
#include "fotufilm_halide_ios_monochrome_float_exact_flare_disc.h"
#include "fotufilm_halide_ios_measure_tone.h"
#include "fotufilm_halide_ios_measure_flare.h"
#include "fotufilm_halide_ios_measure_flare_fast.h"
#include "fotufilm_halide_ios_decode.h"
#include "fotufilm_halide_ios_decode_realtime.h"
#include "fotufilm_halide_ios_color_float_encode.h"
#include "fotufilm_halide_ios_color_float_encode_disc.h"
#include "fotufilm_halide_ios_monochrome_float_encode.h"
#include "fotufilm_halide_ios_monochrome_float_encode_disc.h"
#include "fotufilm_halide_ios_color_float_measure_encode.h"
#include "fotufilm_halide_ios_color_float_measure_encode_disc.h"
#include "fotufilm_halide_ios_monochrome_float_measure_encode.h"
#include "fotufilm_halide_ios_monochrome_float_measure_encode_disc.h"
#include "fotufilm_halide_ios_color_float_light.h"
#include "fotufilm_halide_ios_monochrome_float_light.h"
#include "fotufilm_halide_ios_color_float_fields.h"
#include "fotufilm_halide_ios_color_float_fields_disc.h"
#include "fotufilm_halide_ios_monochrome_float_fields.h"
#include "fotufilm_halide_ios_monochrome_float_fields_disc.h"
#include "fotufilm_halide_ios_halation_fields.h"
#include "fotufilm_halide_ios_color_head.h"
#include "fotufilm_halide_ios_monochrome_head.h"
#include "fotufilm_halide_ios_color_tail.h"
#include "fotufilm_halide_ios_color_tail_disc.h"
#include "fotufilm_halide_ios_monochrome_tail.h"
#include "fotufilm_halide_ios_monochrome_tail_disc.h"
#include "fotufilm_halide_ios_color_donor.h"
#include "fotufilm_halide_ios_color_float_donor.h"
#include "fotufilm_halide_ios_color_float_exact_donor.h"
#include "fotufilm_halide_ios_color_float_realtime_donor.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_linear_donor.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_power_donor.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_log_donor.h"
#include "fotufilm_halide_ios_color_float_realtime_measure_encode_log_donor.h"
#include "fotufilm_halide_ios_color_flare_donor.h"
#include "fotufilm_halide_ios_color_float_flare_donor.h"
#include "fotufilm_halide_ios_color_float_exact_flare_donor.h"
#include "fotufilm_halide_ios_color_float_realtime_flare_donor.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_linear_flare_donor.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_power_flare_donor.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_log_flare_donor.h"
#include "fotufilm_halide_ios_negative_donor.h"
#include "fotufilm_halide_ios_negative_grainless_donor.h"
#include "fotufilm_halide_ios_negative_extended_mtf_donor.h"
#include "fotufilm_halide_ios_negative_no_adjacency_extended_mtf_donor.h"
#include "fotufilm_halide_ios_negative_grainless_extended_mtf_donor.h"
#include "fotufilm_halide_ios_negative_no_adjacency_grainless_extended_mtf_donor.h"
#include "fotufilm_halide_ios_color_float_measure_donor.h"
#include "fotufilm_halide_ios_color_float_encode_donor.h"
#include "fotufilm_halide_ios_color_float_measure_encode_donor.h"
#include "fotufilm_halide_ios_color_float_fields_donor.h"
#include "fotufilm_halide_ios_color_head_donor.h"
#include "fotufilm_halide_ios_color_float_realtime_negative_donor.h"
#include "fotufilm_halide_ios_color_float_realtime_texture_donor.h"
#include "fotufilm_halide_ios_color_float_negative_donor.h"
#include "fotufilm_halide_ios_color_float_texture_donor.h"
#include "fotufilm_halide_ios_color_float_realtime_texture_flat_donor.h"
#include "fotufilm_halide_ios_color_float_texture_flat_donor.h"
#include "fotufilm_halide_ios_color_mottle.h"
#include "fotufilm_halide_ios_monochrome_mottle.h"
#include "fotufilm_halide_ios_color_float_mottle.h"
#include "fotufilm_halide_ios_monochrome_float_mottle.h"
#include "fotufilm_halide_ios_color_float_realtime_mottle.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_mottle.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_linear_mottle.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_linear_mottle.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_power_mottle.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_power_mottle.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_log_mottle.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_log_mottle.h"
#include "fotufilm_halide_ios_color_float_realtime_measure_encode_log_mottle.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_measure_encode_log_mottle.h"
#include "fotufilm_halide_ios_color_tail_mottle.h"
#include "fotufilm_halide_ios_monochrome_tail_mottle.h"
// No film in the gate.
#include "fotufilm_halide_ios_no_film_float.h"
#include "fotufilm_halide_ios_no_film_float_encode.h"
#include "fotufilm_halide_ios_no_film_float_exact.h"
#include "fotufilm_halide_ios_no_film_float_exact_encode.h"
#include "fotufilm_halide_ios_color_float_realtime_basic.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_linear_basic.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_power_basic.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_log_basic.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_basic.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_linear_basic.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_power_basic.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_log_basic.h"
#include "fotufilm_halide_ios_color_float_realtime_basic_windowed.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_linear_basic_windowed.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_power_basic_windowed.h"
#include "fotufilm_halide_ios_color_float_realtime_encode_log_basic_windowed.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_basic_windowed.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_linear_basic_windowed.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_power_basic_windowed.h"
#include "fotufilm_halide_ios_monochrome_float_realtime_encode_log_basic_windowed.h"
#include <HalideBuffer.h>
#include <HalideRuntimeMetal.h>

#include "FotufilmHalide.h"

#include <TargetConditionals.h>

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
constexpr int kMtfSigmaOffset = FOTUFILM_CONFIG_MTF_SIGMA;
constexpr int kMtfRadiusOffset = FOTUFILM_CONFIG_MTF_RADIUS;
constexpr int kMtfLumaSigmaOffset = FOTUFILM_CONFIG_MTF_LUMA_SIGMA;
constexpr int kMtfLumaRadiusOffset = FOTUFILM_CONFIG_MTF_LUMA_RADIUS;
constexpr int kHalationRadiusOffset = FOTUFILM_CONFIG_HALATION_RADIUS;
constexpr int kCouplerSigmaOffset = FOTUFILM_CONFIG_COUPLER_SIGMA;
constexpr int kCouplerRadiusOffset = FOTUFILM_CONFIG_COUPLER_RADIUS;
constexpr int kAdjacencySigmaOffset = FOTUFILM_CONFIG_ADJACENCY_SIGMA;
constexpr int kAdjacencyRadiusOffset = FOTUFILM_CONFIG_ADJACENCY_RADIUS;
constexpr int kGrainSigmaOffset = FOTUFILM_CONFIG_GRAIN_SIGMA;
constexpr int kGrainRadiusOffset = FOTUFILM_CONFIG_GRAIN_RADIUS;
constexpr int kGrainLambdaOffset = FOTUFILM_CONFIG_GRAIN_LAMBDA;

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

thread_local ExecutionState *bound_execution_state = nullptr;

ExecutionState &execution_state() {
    static thread_local ExecutionState fallback;
    return bound_execution_state ? *bound_execution_state : fallback;
}

/// The shape every generated variant shares: the u8 and float libraries differ only in the element
/// type inside the buffers, which does not reach the signature.
using FrameFunction = int (*)(
    halide_buffer_t *, halide_buffer_t *, halide_buffer_t *, halide_buffer_t *,
    halide_buffer_t *, int32_t, int32_t, float, float, float, float, int32_t,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, float, int32_t,
    float, int32_t, float, int32_t, float, float, int32_t, int32_t, uint32_t,
    int32_t, int32_t,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    halide_buffer_t *);

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

/// The cheapest generated variant that can develop `feature_mask`.
FrameFunction select_variant(int32_t feature_mask) {
    const int32_t wanted = feature_mask & FOTUFILM_AOT_VARIANT_BITS;
    // Measuring the glare is not a stage a richer variant can carry for free: a variant that
    // measures cannot stand in for one that was promised the host's mean, nor the other way
    // about, so the bit has to match rather than merely be covered. Carrying the host's output
    // transform is the same kind of bit — it changes what the frame coming back means, not how
    // much of the film model went into it.
    // The span bits belong here for the strongest reason on the list: they say which part of the
    // pipeline the frame goes through, so a variant carrying a different one is not a richer
    // version of what was asked for but a different render entirely.
    const int32_t exact_bits = FOTUFILM_FRAME_MONOCHROME
        | FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME
        | FOTUFILM_FRAME_EXACT_MATH | FOTUFILM_FRAME_DENSITY_OUT
        | FOTUFILM_FRAME_DENSITY_IN | FOTUFILM_FRAME_FLARE_MEASURE
        | FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LINEAR
        | FOTUFILM_FRAME_OUTPUT_POWER | FOTUFILM_FRAME_OUTPUT_LOG
        | FOTUFILM_FRAME_LIGHT_OUT
        | FOTUFILM_FRAME_FIELDS_IN | FOTUFILM_FRAME_TEXTURE
        // For the strongest reason on the list: a variant that develops film is not a richer
        // version of one that develops none. Served by a superset it would put an emulsion,
        // couplers and a paper under a photograph that asked for none of them.
        | FOTUFILM_FRAME_NO_FILM;
    // `FOTUFILM_VARIANT_RANK=n` serves the n-th *acceptable* variant by extra-bit count instead
    // of the narrowest, for measuring whether the narrowest is also the quickest. A superset is
    // supposed to deliver the same frame — that is the whole basis on which the shim already
    // serves requests from wider variants, extra stages collapsing to identity at zero radius —
    // so this is a scheduling question, not a correctness one. Diagnostic; unset in every build
    // that is not being measured.
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
    // A mottle request no twin serves degrades to its sharp-only variant rather than refusing
    // the frame. This is a *lossy* rescue — the host has already moved a share of the grain's
    // variance to the coarse field, and the serving variant lays only the sharp one, so the
    // frame comes back with quieter grain than asked for. The engine keeps every shipping path
    // inside the twin family (full-span realtime, no disc model), so this fires only for a
    // combination nothing forms today; a dead render would hide behind the same rarity and cost
    // a user their frame when it surfaced.
    if (!best && (wanted & FOTUFILM_FRAME_GRAIN_MOTTLE)) {
        return select_variant(feature_mask & ~FOTUFILM_FRAME_GRAIN_MOTTLE);
    }
    // `FOTUFILM_TRACE_VARIANT=1` names what a render actually ran, and how far the served variant
    // overshot what it asked for. Every extra bit is a stage the frame walks through with
    // nothing to do — the generated pipelines carry each stage unconditionally and collapse it
    // to an identity at radius zero, and an identity over a 4K frame is still a pass over a 4K
    // frame. It is printed once per distinct request, not once per frame.
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
            uint64_t configuration_id = 0) {
    // A FIELDS_IN frame rides its halation grids behind the configuration, so its buffer is
    // frame-sized rather than slider-sized; it is cached by the caller's id so the strips of one
    // frame upload it once.
    const bool wants_extended =
        configuration_floats > FOTUFILM_FRAME_CONFIGURATION_COUNT;
    if (wants_extended) {
        if (state.extended_configuration.data() == nullptr
            || state.extended_configuration_floats != configuration_floats
            || state.extended_configuration_id != configuration_id) {
            state.extended_configuration = Buffer<float>(configuration_floats);
            std::memcpy(state.extended_configuration.data(), configuration,
                        size_t(configuration_floats) * sizeof(float));
            state.extended_configuration.set_host_dirty();
            state.extended_configuration_id = configuration_id;
            state.extended_configuration_floats = configuration_floats;
        }
    }
    const size_t configuration_bytes =
        FOTUFILM_FRAME_CONFIGURATION_COUNT * sizeof(float);
    if (!wants_extended &&
        std::memcmp(state.configuration.data(), configuration, configuration_bytes) != 0) {
        std::memcpy(state.configuration.data(), configuration, configuration_bytes);
        state.configuration.set_host_dirty();
    }
    const float sigma0 = std::max(configuration[kMtfSigmaOffset], 0.151f);
    const float sigma1 = std::max(configuration[kMtfSigmaOffset + 1], 0.151f);
    const float sigma2 = std::max(configuration[kMtfSigmaOffset + 2], 0.151f);
    const int32_t radius0 = std::max(0, int32_t(configuration[kMtfRadiusOffset]));
    const int32_t radius1 = std::max(0, int32_t(configuration[kMtfRadiusOffset + 1]));
    const int32_t radius2 = std::max(0, int32_t(configuration[kMtfRadiusOffset + 2]));
    const float luma_sigma = std::max(configuration[kMtfLumaSigmaOffset], 0.151f);
    const int32_t luma_radius = std::max({
        int32_t(0),
        int32_t(configuration[kMtfLumaRadiusOffset]),
        int32_t(configuration[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS]),
        int32_t(configuration[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS + 1]),
        int32_t(configuration[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS + 2]),
    });
    const int32_t halation0 = std::max(0, int32_t(configuration[kHalationRadiusOffset]));
    const int32_t halation1 = std::max(0, int32_t(configuration[kHalationRadiusOffset + 1]));
    const int32_t halation2 = std::max(0, int32_t(configuration[kHalationRadiusOffset + 2]));
    const float coupler_sigma = std::max(configuration[kCouplerSigmaOffset], 0.151f);
    const int32_t coupler_radius = std::max(0, int32_t(configuration[kCouplerRadiusOffset]));
    const float adjacency_sigma = std::max(configuration[kAdjacencySigmaOffset], 0.151f);
    const int32_t adjacency_radius = std::max(0, int32_t(configuration[kAdjacencyRadiusOffset]));
    const float grain_sigma = std::max(configuration[kGrainSigmaOffset], 0.151f);
    const int32_t grain_radius = std::max(0, int32_t(configuration[kGrainRadiusOffset]));
    const float grain_lambda = configuration[kGrainLambdaOffset];
    // Read by the `_mottle` twins alone; every other variant takes them as the harmless unused
    // parameters the shared signature is built from.
    const float mottle_lambda = configuration[FOTUFILM_CONFIG_MOTTLE_LAMBDA];
    const int32_t mottle_radius = std::max(
        0, int32_t(configuration[FOTUFILM_CONFIG_MOTTLE_RADIUS]));
    // Zero when the paper has no blur to give, or when nothing is being printed at all. The
    // compiled variant carries the stage either way; at radius zero its Gaussian is a single unit
    // tap, which is why one variant serves both. See FOTUFILM_AOT_ALL_STAGES.
    const int32_t print_mtf_radius = std::max(
        0, int32_t(configuration[FOTUFILM_CONFIG_PRINT_MTF_RADIUS]));
    const int32_t reversal = (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0;

    int32_t stride[3], strided_radius[3];
    const int32_t halation_radii[3] = {halation0, halation1, halation2};
    for (int scale = 0; scale < 3; ++scale) {
        stride[scale] = fotufilm_halation_stride(halation_radii[scale]);
        strided_radius[scale] = fotufilm_halation_strided_radius(
            halation_radii[scale], stride[scale]);
    }
    // The diffusion filter's pyramid, decimated by the same rule the JIT path uses. The slots
    // hold zero radii whenever no mist is fitted, which collapses the stage to a copy in the
    // variants that carry it.
    int32_t diffusion_stride[3], diffusion_strided_radius[3];
    for (int scale = 0; scale < 3; ++scale) {
        const int32_t radius = std::max(
            0, int32_t(configuration[FOTUFILM_CONFIG_DIFFUSION_RADIUS + scale]));
        diffusion_stride[scale] = fotufilm_diffusion_stride(radius);
        diffusion_strided_radius[scale] =
            fotufilm_halation_strided_radius(radius, diffusion_stride[scale]);
    }

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
#define FOTUFILM_ARGUMENTS                                                   \
    in, cfg, exposure, film, paper, width, height,                          \
    sigma0, sigma1, sigma2, luma_sigma,                                     \
    radius0, radius1, radius2, luma_radius,                                 \
    halation0, halation1, halation2,                                        \
    coupler_sigma, coupler_radius, adjacency_sigma, adjacency_radius,       \
    grain_sigma, grain_radius, grain_lambda,                                \
    mottle_lambda, mottle_radius, print_mtf_radius,                         \
    seed, reversal,                                                         \
    origin_x, origin_y,                                                     \
    stride[0], stride[1], stride[2],                                        \
    strided_radius[0], strided_radius[1], strided_radius[2],                \
    diffusion_stride[0], diffusion_stride[1], diffusion_stride[2],          \
    diffusion_strided_radius[0], diffusion_strided_radius[1],               \
    diffusion_strided_radius[2]
    FrameFunction pipeline = select_variant(feature_mask);
    if (!pipeline) return -3;
    const FrameFunction general_pipeline = pipeline;
    // Each full-resolution field needs 256 output rows plus its spatial apron.
    // Decimated fields need fewer rows. Two grid samples cover box alignment and
    // bilinear interpolation; the three-box halation kernel spans 3*r samples.
    auto gaussian_reach = [](float sigma, int32_t radius) -> int64_t {
        const int64_t scale = sigma >= 8 ? 8 : sigma >= 4 ? 4 : sigma >= 2 ? 2 : 1;
        return scale == 1 ? std::max(radius, 1)
            : scale * (std::max<int64_t>((radius + scale - 1) / scale, 1) + 2);
    };
    int64_t halo_reach = 0;
    for (int scale = 0; scale < 3; ++scale) {
        halo_reach = std::max(halo_reach,
            int64_t(stride[scale]) * (3 * int64_t(strided_radius[scale]) + 2));
    }
    const int64_t image_reach = std::max({radius0, radius1, radius2})
        + halo_reach
        + std::max(gaussian_reach(coupler_sigma, coupler_radius),
                   gaussian_reach(adjacency_sigma, adjacency_radius))
        + int64_t(print_mtf_radius);
    const int64_t grain_reach = int64_t(grain_radius) + print_mtf_radius;
    static const bool windowed_enabled = [] {
        const char *setting = std::getenv("FOTUFILM_AOT_WINDOWED");
        return !setting || std::strcmp(setting, "0") != 0;
    }();
    if (windowed_enabled && width >= 32 && height >= 512
        && origin_x == 0 && origin_y == 0 && !wants_extended
        && in->dim[0].min == 0 && in->dim[1].min == 0
        && out->dim[0].min == 0 && out->dim[1].min == 0
        && in->dim[0].extent == width && in->dim[1].extent == height
        && out->dim[0].extent == width && out->dim[1].extent == height
        && std::max(image_reach, grain_reach) <= 127) {
#define FOTUFILM_PICK_WINDOWED(variant_name, variant_mask) \
        if (pipeline == fotufilm_halide_ios_##variant_name) \
            pipeline = fotufilm_halide_ios_##variant_name##_windowed;
        FOTUFILM_AOT_BASIC_VARIANTS(FOTUFILM_PICK_WINDOWED)
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
/// error handler. The negative variant represents every byte-input realtime kernel's exposure LUT
/// contract; generated argument order is not stable, so identify the buffer by name.
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
               fotufilm_halide_ios_negative_metadata(), byte_bits)
        && exposure_lut_contract_matches(
               fotufilm_halide_ios_color_float_realtime_metadata(), 32);
}

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

extern "C" int32_t fotufilm_halide_metal_process_light_rows(
    const float *input, float *light_out, int32_t width, int32_t height,
    int32_t out_y, int32_t out_rows, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!input || !light_out || !configuration || width <= 0 || height <= 0 ||
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
        Buffer<float> output_buffer = Buffer<float>::make_interleaved(
            light_out, width, out_rows, 4);
        output_buffer.translate(1, out_y);
        input_buffer.set_host_dirty();
        error = run_aot(state, input_buffer.raw_buffer(), output_buffer.raw_buffer(),
                        width, height, configuration,
                        feature_mask | FOTUFILM_FRAME_FLOAT_IO
                            | FOTUFILM_FRAME_LIGHT_OUT,
                        seed, origin_x, origin_y);
        if (!error) error = output_buffer.copy_to_host();
        return error;
    });
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
    const float *light, int32_t width, int32_t height,
    const int32_t *halation_radii, float *fields, int32_t fields_floats) {
    if (!light || !halation_radii || !fields || width <= 0 || height <= 0 ||
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
        Buffer<float> light_buffer = Buffer<float>::make_interleaved(
            const_cast<float *>(light), width, height, 4);
        light_buffer.set_host_dirty();
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
            light_buffer.raw_buffer(), width, height,
            strides[0], strides[1], strides[2],
            strided[0], strided[1], strided[2],
            grids[0].raw_buffer(), grids[1].raw_buffer(),
            grids[2].raw_buffer());
        for (auto &grid : grids) {
            if (!error) error = grid.copy_to_host();
        }
        return error;
    });
}

extern "C" int32_t fotufilm_halide_metal_process_linear_float_fields_rows(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t out_y, int32_t out_rows, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *fields, int32_t fields_floats, uint64_t fields_id,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!input || !output || !configuration || !fields || fields_floats <= 11 ||
        width <= 0 || height <= 0 ||
        out_y < 0 || out_rows <= 0 || out_y + out_rows > height ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    ExecutionState &state = execution_state();
    return translate_exceptions([&] {
        int error = state.spectral_cache.ensure(
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id);
        if (error) return error;
        const int32_t combined_floats =
            FOTUFILM_FRAME_CONFIGURATION_COUNT + fields_floats;
        std::vector<float> combined(static_cast<size_t>(combined_floats));
        std::memcpy(combined.data(), configuration,
                    FOTUFILM_FRAME_CONFIGURATION_COUNT * sizeof(float));
        std::memcpy(combined.data() + FOTUFILM_FRAME_CONFIGURATION_COUNT,
                    fields, size_t(fields_floats) * sizeof(float));
        Buffer<float> input_buffer = Buffer<float>::make_interleaved(
            const_cast<float *>(input), width, height, 4);
        Buffer<float> output_buffer = Buffer<float>::make_interleaved(
            output, width, out_rows, 4);
        output_buffer.translate(1, out_y);
        input_buffer.set_host_dirty();
        error = run_aot(state, input_buffer.raw_buffer(), output_buffer.raw_buffer(),
                        width, height, combined.data(),
                        feature_mask | FOTUFILM_FRAME_FLOAT_IO
                            | FOTUFILM_FRAME_FIELDS_IN,
                        seed, origin_x, origin_y, combined_floats, fields_id);
        if (!error) error = output_buffer.copy_to_host();
        return error;
    });
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
    if (std::memcmp(state.measure_configuration.data(), configuration,
                    configuration_bytes) != 0) {
        std::memcpy(state.measure_configuration.data(), configuration,
                    configuration_bytes);
        state.measure_configuration.set_host_dirty();
    }
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
            & ~(FOTUFILM_FRAME_GRAIN | FOTUFILM_FRAME_GRAIN_MOTTLE
                | FOTUFILM_FRAME_DISC_GRAIN | FOTUFILM_FRAME_PRINT_MTF))
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
        // tail that dropped the bit would render the quiet half of the mixture. Served by
        // the `_tail_mottle` twins.
        // Exactly FOTUFILM_AOT_TAIL: grain and the enlarger that images it, in that
        // order. Both the grain model and the mixture ride through, so the tail
        // lays the field the frame actually asked for.
        const int32_t tail_mask = (feature_mask
            & (FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_REVERSAL
               | FOTUFILM_FRAME_GRAIN_MOTTLE | FOTUFILM_FRAME_DISC_GRAIN
               | FOTUFILM_FRAME_PRINT_MTF))
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

extern "C" int32_t fotufilm_halide_available(void) { return 0; }
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
extern "C" int32_t fotufilm_halide_gaussian(
    const float *, float *, int32_t, int32_t, float, int32_t) { return -1; }
extern "C" int32_t fotufilm_halide_approximate_gaussian(
    const float *, float *, int32_t, int32_t, int32_t) { return -1; }

#endif
