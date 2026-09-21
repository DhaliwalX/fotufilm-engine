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
#ifdef __cplusplus
}
#endif
#endif
