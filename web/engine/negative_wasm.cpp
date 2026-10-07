#include "scan_prepare.h"
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

