#include "scan_prepare.h"
#include "trichromatic_layer_rgb16_kernel.h"
#include "trichromatic_layer_rgba_kernel.h"
#include "trichromatic_merge_kernel.h"
#include "FotufilmTrichromaticMeasure.h"
#include <emscripten/emscripten.h>
#include <cmath>

// A scanned negative's scan read without a film (ScanPreparePipeline's plain reading):
// interleaved linear Rec. 2020 RGBA in and out, which may alias. Seven parameters: clear film[3],
// gains[3], reference. The browser keeps no light frames.
extern "C" EMSCRIPTEN_KEEPALIVE int scan_prepare_plain(float *input, float *output, int width,
    int height, const float *reading) {
    if (!input || !output || !reading || width < 1 || height < 1
        || width > 16384 || height > 16384) return -1;
    float parameters[9] = {0, 1};
    for (int i = 0; i < 7; ++i) {
        if (!std::isfinite(reading[i])) return -1;
        parameters[2 + i] = reading[i];
    }
    float none[3] = {1, 1, 1};
    halide_dimension_t pixels[] = {{0, width, 4, 0}, {0, height, width * 4, 0}, {0, 4, 1, 0}};
    halide_dimension_t cells[] = {{0, 1, 3, 0}, {0, 1, 3, 0}, {0, 3, 1, 0}};
    halide_dimension_t slots[] = {{0, 9, 1, 0}};
    halide_buffer_t in{}, light{}, params{}, out{};
    for (auto *b : {&in, &light, &params, &out}) b->type = halide_type_t(halide_type_float, 32);
    in.host = reinterpret_cast<uint8_t *>(input); in.dim = pixels; in.dimensions = 3;
    out.host = reinterpret_cast<uint8_t *>(output); out.dim = pixels; out.dimensions = 3;
    light.host = reinterpret_cast<uint8_t *>(none); light.dim = cells; light.dimensions = 3;
    params.host = reinterpret_cast<uint8_t *>(parameters); params.dim = slots; params.dimensions = 1;
    return scan_prepare(&in, &light, &params, &out);
}


// A trichromatic scan (FotufilmTrichromatic.h): the measuring is the engine's C++, the layers and
// the merge its kernels.
namespace {
halide_buffer_t interleaved(void *host, halide_type_t type, halide_dimension_t *dims, int width,
                            int height, int channels) {
    dims[0] = {0, width, channels, 0};
    dims[1] = {0, height, width * channels, 0};
    dims[2] = {0, channels, 1, 0};
    halide_buffer_t buffer{};
    buffer.host = static_cast<uint8_t *>(host);
    buffer.type = type;
    buffer.dim = dims;
    buffer.dimensions = 3;
    return buffer;
}
halide_buffer_t plane(const float *host, halide_dimension_t *dims, int width, int height) {
    dims[0] = {0, width, 1, 0};
    dims[1] = {0, height, width, 0};
    halide_buffer_t buffer{};
    buffer.host = reinterpret_cast<uint8_t *>(const_cast<float *>(host));
    buffer.type = halide_type_t(halide_type_float, 32);
    buffer.dim = dims;
    buffer.dimensions = 2;
    return buffer;
}
halide_buffer_t values(float *host, halide_dimension_t *dims, int count) {
    dims[0] = {0, count, 1, 0};
    halide_buffer_t buffer{};
    buffer.host = reinterpret_cast<uint8_t *>(host);
    buffer.type = halide_type_t(halide_type_float, 32);
    buffer.dim = dims;
    buffer.dimensions = 1;
    return buffer;
}
}  // namespace

// The browser's RAW decoder gives interleaved 16-bit RGB.
extern "C" EMSCRIPTEN_KEEPALIVE int trichromatic_measure_rgb16(const uint16_t *rgb, int width,
    int height, float measured[4], int32_t *light) {
    if (!rgb || !measured || !light || !fotufilm::trichromatic::valid_size(width, height)) return -1;
    return fotufilm::trichromatic::measure(rgb, 3, width, height, measured, *light);
}

extern "C" int32_t fotufilm_trichromatic_layer(const float *rgba, int32_t width, int32_t height,
                                               const float colour[3], float *layer) {
    float weights[3];
    if (!rgba || !layer || !fotufilm::trichromatic::valid_size(width, height)
        || !fotufilm::trichromatic::layer_weights(colour, weights)) return -1;
    halide_dimension_t in_dims[3], out_dims[2], weight_dims[1];
    halide_buffer_t in = interleaved(const_cast<float *>(rgba), halide_type_t(halide_type_float, 32),
                                     in_dims, width, height, 4);
    halide_buffer_t out = plane(layer, out_dims, width, height);
    halide_buffer_t params = values(weights, weight_dims, 3);
    return trichromatic_layer_rgba_kernel(&in, &params, &out);
}

extern "C" EMSCRIPTEN_KEEPALIVE int trichromatic_layer_rgb16(const uint16_t *rgb, int width,
    int height, const float colour[3], float *layer) {
    float weights[3];
    if (!rgb || !layer || !fotufilm::trichromatic::valid_size(width, height)
        || !fotufilm::trichromatic::layer_weights(colour, weights)) return -1;
    halide_dimension_t in_dims[3], out_dims[2], weight_dims[1];
    halide_buffer_t in = interleaved(const_cast<uint16_t *>(rgb),
                                     halide_type_t(halide_type_uint, 16), in_dims, width, height, 3);
    halide_buffer_t out = plane(layer, out_dims, width, height);
    halide_buffer_t params = values(weights, weight_dims, 3);
    return trichromatic_layer_rgb16_kernel(&in, &params, &out);
}

extern "C" int32_t fotufilm_trichromatic_merge(const float *red, const float *green,
    const float *blue, int32_t width, int32_t height, const float green_affine[6],
    const float blue_affine[6], uint8_t *file, int64_t size) {
    float p[15];
    if (!fotufilm::trichromatic::merge_header(red, green, blue, width, height, green_affine,
                                               blue_affine, file, size, p)) return -1;
    halide_dimension_t r_dims[2], g_dims[2], b_dims[2], p_dims[1], out_dims[3];
    halide_buffer_t r = plane(red, r_dims, width, height), g = plane(green, g_dims, width, height),
                    b = plane(blue, b_dims, width, height), params = values(p, p_dims, 15);
    halide_buffer_t out = interleaved(file + fotufilm::trichromatic::pixel_offset(height),
                                      halide_type_t(halide_type_uint, 16), out_dims, width, height, 3);
    return trichromatic_merge_kernel(&r, &g, &b, &params, &out);
}
