#pragma once
#include "display_rgba8.h"
#include "display_rgba16.h"

struct DisplayOutput {
    uint32_t *pixels;
    int32_t depth, p3, frame_width;
    // The material's SDR knee from the pack's output shoulder slot; negative is none.
    float shoulder_knee;
};

// The source remains device-dirty, so Halide binds the film's existing buffer.
// Packed words are little-endian RGBA on WebAssembly, including RGBA16 TIFF data.
static int encode_display(halide_buffer_t *source, const DisplayOutput &display,
                          int32_t width, int32_t height, int32_t origin_x,
                          int32_t origin_y, uint32_t seed) {
    const int words = display.depth == 16 ? 2 : 1;
    halide_dimension_t dimensions[2] = {{0, width * words, 1, 0},
                                       {0, height, width * words, 0}};
    halide_buffer_t output = {};
    output.host = reinterpret_cast<uint8_t *>(display.pixels);
    output.type = halide_type_t(halide_type_uint, 32);
    output.dimensions = 2;
    output.dim = dimensions;
    const float knee = display.shoulder_knee < 0.0f ? 1.0f : display.shoulder_knee;
    int status = display.depth == 16
        ? display_rgba16(source, origin_x, origin_y, display.frame_width, display.p3, seed, knee,
                         &output)
        : display_rgba8(source, origin_x, origin_y, display.frame_width, display.p3, seed, knee,
                        &output);
    if (!status) status = halide_copy_to_host(nullptr, &output);
    halide_device_free(nullptr, &output);
    return status;
}
