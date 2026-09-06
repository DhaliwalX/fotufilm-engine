// Browser entry point for the frame pipeline.
//
// The AOT kernels take their spatial parameters as loose scalars, but every one of them already
// sits in the packed configuration at a known offset. Deriving them here rather than in
// JavaScript keeps the browser from having to know the layout, and keeps this file's arithmetic
// identical to the native runner in FotufilmHalideMetal.cpp — the two must agree or the same
// frame develops differently on the two paths.

// Built as C++ because Halide's generated headers declare `halide_type_t` without the struct tag
// a C compiler needs; the exports below keep C linkage so the JavaScript side sees plain names.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "FotufilmHalide.h"
#include "color_float.h"
#include "monochrome_float.h"

#include <emscripten/emscripten.h>

extern "C" {

/// Halide's blurs are undefined below the sigma the schedule was built around.
static const float kSigmaFloor = 0.151f;

static float max_f(float a, float b) { return a > b ? a : b; }
static int32_t max_i(int32_t a, int32_t b) { return a > b ? a : b; }

/// Marks a buffer's host side as the fresh copy. Every buffer the kernel reads needs this: the
/// runtime allocates device memory lazily and only uploads what it is told has changed, so a
/// buffer left clean is one the GPU reads as the zeros it was allocated with — which develops to
/// a flat frame with no error anywhere.
static void mark_host_dirty(halide_buffer_t *buffer) {
    buffer->flags |= halide_buffer_flag_host_dirty;
}

/// An interleaved RGBA float image as Halide sees it: x, y, then channel with unit stride.
static void init_interleaved(halide_buffer_t *buffer, halide_dimension_t *dims,
                             float *host, int32_t width, int32_t height) {
    memset(buffer, 0, sizeof(*buffer));
    dims[0].min = 0; dims[0].extent = width;  dims[0].stride = 4; dims[0].flags = 0;
    dims[1].min = 0; dims[1].extent = height; dims[1].stride = 4 * width; dims[1].flags = 0;
    dims[2].min = 0; dims[2].extent = 4;      dims[2].stride = 1; dims[2].flags = 0;
    buffer->host = (uint8_t *)host;
    buffer->dim = dims;
    buffer->dimensions = 3;
    // See the note in fotufilm_wasm_cpu.cpp: Halide 22 dropped `lanes` from halide_type_t, and
    // this ctor is the spelling both versions accept.
    buffer->type = halide_type_t(halide_type_float, 32);
}

static void init_flat(halide_buffer_t *buffer, halide_dimension_t *dim,
                      float *host, int32_t count) {
    memset(buffer, 0, sizeof(*buffer));
    dim[0].min = 0; dim[0].extent = count; dim[0].stride = 1; dim[0].flags = 0;
    buffer->host = (uint8_t *)host;
    buffer->dim = dim;
    buffer->dimensions = 1;
    // See the note in fotufilm_wasm_cpu.cpp: Halide 22 dropped `lanes` from halide_type_t, and
    // this ctor is the spelling both versions accept.
    buffer->type = halide_type_t(halide_type_float, 32);
}

/// Develops one frame, or one tile of a larger one. `input` and `output` are interleaved linear
/// RGBA floats, scene-referred in and print-referred out — the sRGB encode belongs to the caller.
///
/// `width` and `height` are the buffers' own size and `origin_x`, `origin_y` where they sit in
/// the frame, as the native strip path passes them: everything that depends on position — the
/// grain's seed, the decimated pyramids' phase — reads global coordinates, so a tile developed
/// here matches the same pixels developed in one piece once its apron is cut away. The apron a
/// tile needs is the pack's `spatialSupport` for the frame's size.
///
/// `configuration` is the packed buffer: the frame's scalars, then the film cube, then the paper
/// cube, laid out exactly as `fotufilm_wasm_packed_count` describes. WebGPU allows a compute stage
/// only a few storage buffers, and the combine kernel wanted more than this adapter has, so the
/// two cubes travel behind the configuration rather than binding separately. The exposure cube is
/// read by a different, roomier kernel and keeps its own buffer.
///
/// Returns the Halide error code: 0 on success.
EMSCRIPTEN_KEEPALIVE
int fotufilm_wasm_render(float *input, float *output, int32_t width, int32_t height,
                        int32_t origin_x, int32_t origin_y,
                        float *configuration, float *exposure_lut,
                        int32_t feature_mask, uint32_t seed) {
    halide_buffer_t in_buf, out_buf, config_buf, exposure_buf;
    halide_dimension_t in_dims[3], out_dims[3];
    halide_dimension_t config_dim[1], exposure_dim[1];

    const int32_t lut_count = 33 * 33 * 33 * 4;

    init_interleaved(&in_buf, in_dims, input, width, height);
    init_interleaved(&out_buf, out_dims, output, width, height);
    init_flat(&config_buf, config_dim, configuration,
              FOTUFILM_FRAME_CONFIGURATION_COUNT + 2 * lut_count);
    init_flat(&exposure_buf, exposure_dim, exposure_lut, lut_count);

    // The output is left clean: the kernel writes it on the device and marks it device-dirty, and
    // the copy back below is what makes the host side current.
    mark_host_dirty(&in_buf);
    mark_host_dirty(&config_buf);
    mark_host_dirty(&exposure_buf);

    const float *c = configuration;

    // Mirrors MetalFramePipeline::run.
    const float mtf_sigma_0 = max_f(c[FOTUFILM_CONFIG_MTF_SIGMA], kSigmaFloor);
    const float mtf_sigma_1 = max_f(c[FOTUFILM_CONFIG_MTF_SIGMA + 1], kSigmaFloor);
    const float mtf_sigma_2 = max_f(c[FOTUFILM_CONFIG_MTF_SIGMA + 2], kSigmaFloor);
    const float mtf_luma_sigma = max_f(c[FOTUFILM_CONFIG_MTF_LUMA_SIGMA], kSigmaFloor);
    const int32_t mtf_radius_0 = max_i(0, (int32_t)c[FOTUFILM_CONFIG_MTF_RADIUS]);
    const int32_t mtf_radius_1 = max_i(0, (int32_t)c[FOTUFILM_CONFIG_MTF_RADIUS + 1]);
    const int32_t mtf_radius_2 = max_i(0, (int32_t)c[FOTUFILM_CONFIG_MTF_RADIUS + 2]);
    // The luma blur is also the widest of the secondary MTF taps, as in the native runner.
    int32_t mtf_luma_radius = max_i(0, (int32_t)c[FOTUFILM_CONFIG_MTF_LUMA_RADIUS]);
    for (int scale = 0; scale < 3; ++scale) {
        mtf_luma_radius = max_i(
            mtf_luma_radius, (int32_t)c[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS + scale]);
    }

    int32_t halation_radius[3], halation_stride[3], halation_strided_radius[3];
    for (int scale = 0; scale < 3; ++scale) {
        halation_radius[scale] =
            max_i(0, (int32_t)c[FOTUFILM_CONFIG_HALATION_RADIUS + scale]);
        halation_stride[scale] = fotufilm_halation_stride(halation_radius[scale]);
        halation_strided_radius[scale] = fotufilm_halation_strided_radius(
            halation_radius[scale], halation_stride[scale]);
    }

    const float coupler_sigma = max_f(c[FOTUFILM_CONFIG_COUPLER_SIGMA], kSigmaFloor);
    const int32_t coupler_radius = max_i(0, (int32_t)c[FOTUFILM_CONFIG_COUPLER_RADIUS]);
    const float adjacency_sigma = max_f(c[FOTUFILM_CONFIG_ADJACENCY_SIGMA], kSigmaFloor);
    const int32_t adjacency_radius = max_i(0, (int32_t)c[FOTUFILM_CONFIG_ADJACENCY_RADIUS]);
    const float grain_sigma = max_f(c[FOTUFILM_CONFIG_GRAIN_SIGMA], kSigmaFloor);
    const int32_t grain_radius = max_i(0, (int32_t)c[FOTUFILM_CONFIG_GRAIN_RADIUS]);
    const float grain_lambda = c[FOTUFILM_CONFIG_GRAIN_LAMBDA];
    // Read by the `_mottle` twins alone; this kernel takes them as the unused parameters the
    // shared signature is built from.
    const float mottle_lambda = c[FOTUFILM_CONFIG_MOTTLE_LAMBDA];
    const int32_t mottle_radius = max_i(0, (int32_t)c[FOTUFILM_CONFIG_MOTTLE_RADIUS]);
    // Zero when the paper has no blur to give; the stage then collapses to a unit tap.
    const int32_t print_mtf_radius = max_i(0, (int32_t)c[FOTUFILM_CONFIG_PRINT_MTF_RADIUS]);
    const int32_t reversal = (feature_mask & FOTUFILM_FRAME_REVERSAL) ? 1 : 0;

    // The diffusion filter's pyramid, decimated by the same rule the native paths use. The slots
    // hold zero radii whenever no mist is fitted, which collapses the stage to a copy.
    int32_t diffusion_stride[3], diffusion_strided_radius[3];
    for (int scale = 0; scale < 3; ++scale) {
        const int32_t radius = max_i(0, (int32_t)c[FOTUFILM_CONFIG_DIFFUSION_RADIUS + scale]);
        diffusion_stride[scale] = fotufilm_diffusion_stride(radius);
        diffusion_strided_radius[scale] =
            fotufilm_halation_strided_radius(radius, diffusion_stride[scale]);
    }

    // Call kernels directly so Asyncify can instrument the WebGPU adapter and buffer-map waits.
    // Its call-graph analysis cannot trace indirect function-pointer dispatch.
#define FOTUFILM_KERNEL_ARGUMENTS                                                     \
    &in_buf, &config_buf, &exposure_buf, width, height,                              \
        mtf_sigma_0, mtf_sigma_1, mtf_sigma_2, mtf_luma_sigma, mtf_radius_0,         \
        mtf_radius_1, mtf_radius_2, mtf_luma_radius, halation_radius[0],             \
        halation_radius[1], halation_radius[2], coupler_sigma, coupler_radius,       \
        adjacency_sigma, adjacency_radius, grain_sigma, grain_radius, grain_lambda,  \
        mottle_lambda, mottle_radius, print_mtf_radius, seed, reversal,              \
        origin_x, origin_y, halation_stride[0], halation_stride[1],                  \
        halation_stride[2], halation_strided_radius[0], halation_strided_radius[1],  \
        halation_strided_radius[2], diffusion_stride[0], diffusion_stride[1],        \
        diffusion_stride[2], diffusion_strided_radius[0],                            \
        diffusion_strided_radius[1], diffusion_strided_radius[2], &out_buf

    int status;
    if (feature_mask & FOTUFILM_FRAME_MONOCHROME) {
        status = monochrome_float(FOTUFILM_KERNEL_ARGUMENTS);
    } else {
        status = color_float(FOTUFILM_KERNEL_ARGUMENTS);
    }
#undef FOTUFILM_KERNEL_ARGUMENTS

    // A GPU pipeline leaves its result in device memory and marks the buffer device-dirty. The
    // native runner calls copy_to_host for exactly this reason; without it the host side reads
    // back the zeros it allocated.
    if (status == 0) status = halide_copy_to_host(nullptr, &out_buf);

    // The device allocations are per-call, since the frame buffers are reallocated whenever the
    // frame size changes. Releasing them here keeps a long editing session from growing a new
    // GPU buffer for every slider tick.
    halide_device_free(nullptr, &in_buf);
    halide_device_free(nullptr, &out_buf);
    halide_device_free(nullptr, &config_buf);
    halide_device_free(nullptr, &exposure_buf);
    return status;
}

/// The configuration is rebuilt in Swift, but the handful of slots that are a pure function of a
/// slider can be rewritten in place — no physics, just the value the engine already stores.
/// Anything that changes the halation kernel or the coupler matrix is not here on purpose: those
/// re-enter the film model and must come from a freshly exported pack.
/// The slot the frame's width lives in; its height is the next one. The browser writes the
/// frame it is actually developing there, because a pack is sealed for one size and the kernel
/// reads these for everything that spans the whole frame — the tone grid, the print's dither.
EMSCRIPTEN_KEEPALIVE
int32_t fotufilm_wasm_frame_size_slot(void) {
    return FOTUFILM_CONFIG_FRAME_WIDTH;
}

EMSCRIPTEN_KEEPALIVE
void fotufilm_wasm_set_exposure(float *configuration, float gain) {
    configuration[FOTUFILM_CONFIG_EXPOSURE_GAIN] = gain;
}

EMSCRIPTEN_KEEPALIVE
void fotufilm_wasm_set_scene(float *configuration, float highlights, float shadows,
                            float saturation, float vibrance) {
    configuration[FOTUFILM_CONFIG_HIGHLIGHTS] = highlights;
    configuration[FOTUFILM_CONFIG_SHADOWS] = shadows;
    configuration[FOTUFILM_CONFIG_SATURATION] = saturation;
    configuration[FOTUFILM_CONFIG_VIBRANCE] = vibrance;
}

EMSCRIPTEN_KEEPALIVE
void fotufilm_wasm_set_white_balance(float *configuration, float r, float g, float b) {
    configuration[FOTUFILM_CONFIG_WHITE_BALANCE] = r;
    configuration[FOTUFILM_CONFIG_WHITE_BALANCE + 1] = g;
    configuration[FOTUFILM_CONFIG_WHITE_BALANCE + 2] = b;
}

/// Grain strength is stored per layer, already folded together with the stock's own weight and
/// the aperture scale. Rescaling needs the amplitudes the pack was exported at, which the caller
/// keeps a pristine copy of.
EMSCRIPTEN_KEEPALIVE
void fotufilm_wasm_set_grain(float *configuration, const float *base, float scale) {
    for (int layer = 0; layer < 3; ++layer) {
        configuration[FOTUFILM_CONFIG_GRAIN + layer] = base[layer] * scale;
    }
}

EMSCRIPTEN_KEEPALIVE
int fotufilm_wasm_configuration_count(void) { return FOTUFILM_FRAME_CONFIGURATION_COUNT; }

EMSCRIPTEN_KEEPALIVE
int fotufilm_wasm_lut_count(void) { return 33 * 33 * 33 * 4; }

/// Floats in the buffer `fotufilm_wasm_render` wants for `configuration`: the frame's scalars, then
/// the film cube at `fotufilm_wasm_configuration_count()`, then the paper cube one cube further on.
EMSCRIPTEN_KEEPALIVE
int fotufilm_wasm_packed_count(void) {
    return FOTUFILM_FRAME_CONFIGURATION_COUNT + 2 * 33 * 33 * 33 * 4;
}

}  // extern "C"
