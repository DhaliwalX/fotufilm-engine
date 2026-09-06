// Browser entry point for the reference CPU pipeline.
//
// Mirrors `fotufilm_halide_process_strip` in Sources/FotufilmHalide/FotufilmHalide.cpp: develop the
// negative into a density field, then print it. The two stages are separate AOT modules here
// because they are separate pipelines there, and the variant each frame needs is chosen from the
// feature mask exactly as `develop_pipeline_for` and `print_pipeline_for` choose it.
//
// Everything the kernels need beyond the image comes from the packed configuration, so the
// JavaScript side never has to know the layout.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "FotufilmHalide.h"

#include "fotufilm_wasm_variants.h"
#include "print_0.h"
#include "print_1.h"
#include "print_2.h"
#include "print_3.h"

#include <emscripten/emscripten.h>

extern "C" {

static const float kSigmaFloor = 0.151f;
static const int32_t kLutCount = 33 * 33 * 33 * 4;

static float max_f(float a, float b) { return a > b ? a : b; }
static int32_t max_i(int32_t a, int32_t b) { return a > b ? a : b; }

static void init_planar(halide_buffer_t *buffer, halide_dimension_t *dims,
                        float *host, int32_t width, int32_t height, int32_t channels) {
    memset(buffer, 0, sizeof(*buffer));
    dims[0].min = 0; dims[0].extent = width;  dims[0].stride = 1; dims[0].flags = 0;
    dims[1].min = 0; dims[1].extent = height; dims[1].stride = width; dims[1].flags = 0;
    if (channels > 0) {
        dims[2].min = 0; dims[2].extent = channels;
        dims[2].stride = width * height; dims[2].flags = 0;
    }
    buffer->host = (uint8_t *)host;
    buffer->dim = dims;
    buffer->dimensions = channels > 0 ? 3 : 2;
    // Constructed rather than assigned field by field: Halide 22 split the language Type from the
    // ABI halide_type_t and dropped `lanes` from the struct, but both versions take this ctor —
    // 21 defaults the lanes away, 22 never had them.
    buffer->type = halide_type_t(halide_type_float, 32);
}

static void init_flat(halide_buffer_t *buffer, halide_dimension_t *dim,
                      float *host, int32_t count) {
    memset(buffer, 0, sizeof(*buffer));
    dim[0].min = 0; dim[0].extent = count; dim[0].stride = 1; dim[0].flags = 0;
    buffer->host = (uint8_t *)host;
    buffer->dim = dim;
    buffer->dimensions = 1;
    // Constructed rather than assigned field by field: Halide 22 split the language Type from the
    // ABI halide_type_t and dropped `lanes` from the struct, but both versions take this ctor —
    // 21 defaults the lanes away, 22 never had them.
    buffer->type = halide_type_t(halide_type_float, 32);
}

/// Mirrors `develop_pipeline_for`.
static int develop_variant_for(int32_t feature_mask) {
    const int32_t spatial = feature_mask
        & (FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_MTF | FOTUFILM_FRAME_HALATION
           | FOTUFILM_FRAME_COUPLERS | FOTUFILM_FRAME_ADJACENCY | FOTUFILM_FRAME_GRAIN
           | FOTUFILM_FRAME_MTF_LUMA | FOTUFILM_FRAME_COUPLER_DIFFUSION
           | FOTUFILM_FRAME_DISC_GRAIN);
    const int32_t stages = spatial
        & (FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_MTF | FOTUFILM_FRAME_HALATION
           | FOTUFILM_FRAME_COUPLERS | FOTUFILM_FRAME_ADJACENCY | FOTUFILM_FRAME_GRAIN);
    return stages
        | ((spatial & FOTUFILM_FRAME_MTF_LUMA) ? 64 : 0)
        | ((spatial & FOTUFILM_FRAME_COUPLER_DIFFUSION) ? 128 : 0)
        | ((spatial & FOTUFILM_FRAME_DISC_GRAIN) ? 256 : 0);
}

/// Develops one frame, or one tile of a larger one. Input and output are planar float RGB —
/// three width*height planes — and scene-referred at both ends; the sRGB transfer belongs to the
/// caller. `origin_x` and `origin_y` say where the buffers sit in the frame, so a tile carrying
/// the pack's `spatialSupport` as apron develops exactly as it would inside the whole frame; see
/// fotufilm_wasm_render.
///
/// Returns 0 on success, or the Halide error code. -2 means no kernel was generated for this
/// stock's feature mask.
EMSCRIPTEN_KEEPALIVE
int fotufilm_wasm_cpu_render(float *input, float *output, int32_t width, int32_t height,
                            int32_t origin_x, int32_t origin_y,
                            float *configuration, float *exposure_lut, float *film_lut,
                            float *paper_lut, float *density, int32_t feature_mask,
                            uint32_t seed) {
    halide_buffer_t in_r, in_g, in_b, config_buf, exposure_buf, film_buf, paper_buf;
    halide_buffer_t density_buf, out_buf;
    halide_dimension_t dr[2], dg[2], db[2], dd[3], od[3];
    halide_dimension_t cd[1], ed[1], fd[1], pd[1];

    const int32_t plane = width * height;
    init_planar(&in_r, dr, input, width, height, 0);
    init_planar(&in_g, dg, input + plane, width, height, 0);
    init_planar(&in_b, db, input + 2 * plane, width, height, 0);
    init_planar(&density_buf, dd, density, width, height, 3);
    init_planar(&out_buf, od, output, width, height, 3);
    init_flat(&config_buf, cd, configuration, FOTUFILM_FRAME_CONFIGURATION_COUNT);
    init_flat(&exposure_buf, ed, exposure_lut, kLutCount);
    init_flat(&film_buf, fd, film_lut, kLutCount);
    init_flat(&paper_buf, pd, paper_lut, kLutCount);

    const float *c = configuration;
    const float mtf_sigma_0 = max_f(c[FOTUFILM_CONFIG_MTF_SIGMA], kSigmaFloor);
    const float mtf_sigma_1 = max_f(c[FOTUFILM_CONFIG_MTF_SIGMA + 1], kSigmaFloor);
    const float mtf_sigma_2 = max_f(c[FOTUFILM_CONFIG_MTF_SIGMA + 2], kSigmaFloor);
    const float mtf_luma_sigma = max_f(c[FOTUFILM_CONFIG_MTF_LUMA_SIGMA], kSigmaFloor);
    const int32_t mtf_radius_0 = max_i(0, (int32_t)c[FOTUFILM_CONFIG_MTF_RADIUS]);
    const int32_t mtf_radius_1 = max_i(0, (int32_t)c[FOTUFILM_CONFIG_MTF_RADIUS + 1]);
    const int32_t mtf_radius_2 = max_i(0, (int32_t)c[FOTUFILM_CONFIG_MTF_RADIUS + 2]);
    const int32_t mtf_luma_radius = max_i(0, (int32_t)c[FOTUFILM_CONFIG_MTF_LUMA_RADIUS]);

    int32_t stride[3], strided_radius[3];
    for (int scale = 0; scale < 3; ++scale) {
        const int32_t radius = max_i(0, (int32_t)c[FOTUFILM_CONFIG_HALATION_RADIUS + scale]);
        stride[scale] = fotufilm_halation_stride(radius);
        strided_radius[scale] = fotufilm_halation_strided_radius(radius, stride[scale]);
    }

    const float coupler_sigma = max_f(c[FOTUFILM_CONFIG_COUPLER_SIGMA], kSigmaFloor);
    const int32_t coupler_radius = max_i(0, (int32_t)c[FOTUFILM_CONFIG_COUPLER_RADIUS]);
    const float adjacency_sigma = max_f(c[FOTUFILM_CONFIG_ADJACENCY_SIGMA], kSigmaFloor);
    const int32_t adjacency_radius = max_i(0, (int32_t)c[FOTUFILM_CONFIG_ADJACENCY_RADIUS]);
    const float grain_sigma = max_f(c[FOTUFILM_CONFIG_GRAIN_SIGMA], kSigmaFloor);
    const int32_t grain_radius = max_i(0, (int32_t)c[FOTUFILM_CONFIG_GRAIN_RADIUS]);
    const float grain_lambda = c[FOTUFILM_CONFIG_GRAIN_LAMBDA];
    const int32_t print_mtf_radius = max_i(0, (int32_t)c[FOTUFILM_CONFIG_PRINT_MTF_RADIUS]);
    const int32_t reversal = (feature_mask & FOTUFILM_FRAME_REVERSAL) ? 1 : 0;
    const int32_t monochrome = (feature_mask & FOTUFILM_FRAME_MONOCHROME) ? 1 : 0;

#define FOTUFILM_DEVELOP_ARGUMENTS                                                     \
    &in_r, &in_g, &in_b, &config_buf, &exposure_buf, width, height, mtf_sigma_0,      \
        mtf_sigma_1, mtf_sigma_2, mtf_luma_sigma, mtf_radius_0, mtf_radius_1,         \
        mtf_radius_2, mtf_luma_radius, stride[0], stride[1], stride[2],               \
        strided_radius[0], strided_radius[1], strided_radius[2], coupler_sigma,       \
        coupler_radius, adjacency_sigma, adjacency_radius, grain_sigma, grain_radius, \
        grain_lambda, print_mtf_radius, seed, reversal, monochrome, origin_x, origin_y,  \
        &density_buf

    int status;
    switch (develop_variant_for(feature_mask)) {
#include "fotufilm_wasm_variants.inc"
    default: return -2;
    }
#undef FOTUFILM_DEVELOP_ARGUMENTS
    if (status != 0) return status;

    switch ((reversal ? 1 : 0) | (monochrome ? 2 : 0)) {
    case 0: return print_0(&density_buf, &config_buf, &film_buf, &paper_buf, &out_buf);
    case 1: return print_1(&density_buf, &config_buf, &film_buf, &paper_buf, &out_buf);
    case 2: return print_2(&density_buf, &config_buf, &film_buf, &paper_buf, &out_buf);
    default: return print_3(&density_buf, &config_buf, &film_buf, &paper_buf, &out_buf);
    }
}

// The configuration slots that are a pure function of a control. Anything that re-enters the film
// model — halation, coupler range — needs a pack exported at that setting instead.
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
/// the aperture scale, so rescaling needs the amplitudes the pack was exported at.
EMSCRIPTEN_KEEPALIVE
void fotufilm_wasm_set_grain(float *configuration, const float *base, float scale) {
    for (int layer = 0; layer < 3; ++layer) {
        configuration[FOTUFILM_CONFIG_GRAIN + layer] = base[layer] * scale;
    }
}

EMSCRIPTEN_KEEPALIVE
int fotufilm_wasm_configuration_count(void) { return FOTUFILM_FRAME_CONFIGURATION_COUNT; }

EMSCRIPTEN_KEEPALIVE
int fotufilm_wasm_lut_count(void) { return kLutCount; }

}  // extern "C"
