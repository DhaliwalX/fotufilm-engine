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
#include "../../Sources/FotufilmHalide/FotufilmResolvedFrameParams.h"
#include "color_float.h"
#include "monochrome_float.h"
#include "plain_float.h"
#include "print_color_float.h"
#include "print_monochrome_float.h"

#include <emscripten/emscripten.h>

extern "C" {
EMSCRIPTEN_KEEPALIVE int fotufilm_wasm_plain_supported() { return 1; }



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
    const fotufilm::ResolvedFrameParams resolved(configuration, width, height, seed,
        (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0, origin_x, origin_y);

#define FOTUFILM_KERNEL_ARGUMENTS \
    &in_buf, &config_buf, &exposure_buf, width, height, resolved.mtf_sigma_0, resolved.mtf_sigma_1, \
    resolved.mtf_sigma_2, resolved.mtf_luma_sigma, resolved.mtf_radius_0, resolved.mtf_radius_1, \
    resolved.mtf_radius_2, resolved.mtf_luma_radius, resolved.halation_radius_0, \
    resolved.halation_radius_1, resolved.halation_radius_2, resolved.coupler_sigma, \
    resolved.coupler_radius, resolved.adjacency_sigma, resolved.adjacency_radius, \
    resolved.adjacency_secondary_sigma, resolved.adjacency_secondary_radius, resolved.fringe_sigma, \
    resolved.fringe_radius, resolved.grain_sigma, resolved.grain_radius, resolved.grain_lambda, \
    resolved.mottle_lambda, resolved.mottle_radius, resolved.print_mtf_radius, seed, \
    resolved.reversal, origin_x, origin_y, resolved.halation_stride_0, resolved.halation_stride_1, \
    resolved.halation_stride_2, resolved.halation_strided_radius_0, \
    resolved.halation_strided_radius_1, resolved.halation_strided_radius_2, \
    resolved.diffusion_stride_0, resolved.diffusion_stride_1, resolved.diffusion_stride_2, \
    resolved.diffusion_strided_radius_0, resolved.diffusion_strided_radius_1, \
    resolved.diffusion_strided_radius_2, feature_mask, fotufilm_byte_basis(c), &out_buf

    int status;
    if (feature_mask & FOTUFILM_FRAME_NO_FILM) {
        status = plain_float(FOTUFILM_KERNEL_ARGUMENTS);
    } else if (feature_mask & FOTUFILM_FRAME_DENSITY_IN) {
        status = feature_mask & FOTUFILM_FRAME_MONOCHROME
            ? print_monochrome_float(FOTUFILM_KERNEL_ARGUMENTS)
            : print_color_float(FOTUFILM_KERNEL_ARGUMENTS);
    } else if (feature_mask & FOTUFILM_FRAME_MONOCHROME) {
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

#include "generated/fotufilm_wasm_controls.inc"

EMSCRIPTEN_KEEPALIVE
int32_t fotufilm_wasm_control_count(void) { return kFotufilmWasmControlCount; }

EMSCRIPTEN_KEEPALIVE
int32_t fotufilm_wasm_control_slot(int32_t index) {
    return index >= 0 && index < kFotufilmWasmControlCount ? kFotufilmWasmControlSlots[index] : -1;
}

EMSCRIPTEN_KEEPALIVE
void fotufilm_wasm_set_slot(float *configuration, int32_t slot, float value) {
    if (slot >= 0 && slot < FOTUFILM_FRAME_CONFIGURATION_COUNT) configuration[slot] = value;
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
