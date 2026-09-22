#include "negative_scan.h"
#include <emscripten/emscripten.h>
#include <cmath>
#include <initializer_list>
extern "C" EMSCRIPTEN_KEEPALIVE int negative_convert(float *input, float *output,
    int width, int height, float *parameters) {
    if (!input || !output || !parameters || width < 1 || height < 1
        || width > 2048 || height > 2048) return -1;
    for (int c = 0; c < 3; ++c)
        if (!std::isfinite(parameters[c]) || !std::isfinite(parameters[c+3])
            || parameters[c] < 0 || parameters[c+3] < parameters[c]) return -1;
    if (!std::isfinite(parameters[6]) || parameters[6] < .1f || parameters[6] > 2
        || !std::isfinite(parameters[7])) return -1;
    halide_dimension_t dims[] = {{0,width,1,0}, {0,height,width,0}, {0,3,width*height,0}};
    halide_dimension_t pdim[] = {{0,8,1,0}};
    halide_buffer_t in{}, out{}, params{};
    for (auto b : {&in, &out, &params}) b->type = halide_type_t(halide_type_float, 32);
    in.host = reinterpret_cast<uint8_t *>(input); in.dim = dims; in.dimensions = 3;
    out.host = reinterpret_cast<uint8_t *>(output); out.dim = dims; out.dimensions = 3;
    params.host = reinterpret_cast<uint8_t *>(parameters); params.dim = pdim; params.dimensions = 1;
    in.flags = params.flags = halide_buffer_flag_host_dirty;
    int code = negative_scan(&in, &params, &out);
    if (code == 0) code = halide_copy_to_host(nullptr, &out);
    halide_device_free(nullptr, &in); halide_device_free(nullptr, &params); halide_device_free(nullptr, &out);
    return code;
}
