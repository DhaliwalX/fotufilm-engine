#include "library_thumbnail.h"
#include <emscripten/emscripten.h>
#include <cstdint>

// Interleaved RGBA8 in and out. The output is already oriented: for EXIF 5-8 pass the
// rotated width and height.
extern "C" EMSCRIPTEN_KEEPALIVE int library_thumbnail_rgba(const uint8_t *input, int width,
    int height, uint8_t *output, int outputWidth, int outputHeight, int orientation) {
    if (!input || !output || width < 1 || height < 1 || outputWidth < 1 || outputHeight < 1
        || width > 8192 || height > 8192 || outputWidth > 2048 || outputHeight > 2048
        || orientation < 1 || orientation > 8) return -1;
    halide_dimension_t in[] = {{0, 4, 1, 0}, {0, width, 4, 0}, {0, height, width * 4, 0}};
    halide_dimension_t out[] = {{0, 4, 1, 0}, {0, outputWidth, 4, 0},
                                {0, outputHeight, outputWidth * 4, 0}};
    halide_buffer_t source{}, result{};
    source.type = result.type = halide_type_t(halide_type_uint, 8);
    source.host = const_cast<uint8_t *>(input);
    source.dim = in;
    source.dimensions = 3;
    result.host = output;
    result.dim = out;
    result.dimensions = 3;
    bool quarter = orientation >= 5;
    return library_thumbnail(&source, quarter ? outputHeight : outputWidth,
                             quarter ? outputWidth : outputHeight, orientation, &result);
}
