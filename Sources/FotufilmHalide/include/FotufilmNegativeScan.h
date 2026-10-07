#ifndef FOTUFILM_NEGATIVE_SCAN_H
#define FOTUFILM_NEGATIVE_SCAN_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Contiguous planar RGB float32, linear sRGB in and out. Eight parameters.
// backend: 0 CPU, 1 Metal. Returns a recoverable error when unavailable.
int32_t fotufilm_negative_scan(const float *input, float *output, int32_t width,
    int32_t height, const float *parameters, int32_t backend);
// A scanned negative's scan made ready for the editor (ScanPreparePipeline): interleaved linear
// Rec. 2020 RGBA in and out, which may alias. `light` holds the light source's cells, interleaved
// RGB, or is null for none. Nine parameters: lit, plain, clear film[3], gains[3], reference.
int32_t fotufilm_scan_prepare(const float *input, float *output, int32_t width, int32_t height,
    const float *light, int32_t light_width, int32_t light_height, const float *parameters);
#ifdef __cplusplus
}
#endif
#endif
