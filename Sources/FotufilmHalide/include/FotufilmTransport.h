#ifndef FOTUFILM_TRANSPORT_H
#define FOTUFILM_TRANSPORT_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/// CPU (0) or Halide Metal JIT (1). Returns -3 when the backend is unavailable.
int32_t fotufilm_transport_available(int32_t backend);
/// Positive normalized convolution of record exposure. Kernel is row-major (2r+1)^2.
/// Input/output planes must be distinct. The stride grid is anchored at the true frame origin.
int32_t fotufilm_transport_convolve(
    const float *r, const float *g, const float *b,
    float *out_r, float *out_g, float *out_b,
    int32_t width, int32_t height, const float *kernel,
    int32_t radius, int32_t stride, int32_t backend);

typedef struct {
    const float *kernel;
    int32_t radius;
    int32_t stride;
    float weight;
} FotufilmTransportBand;

/// Multi-band positive normalized accumulation.
/// Input (r, g, b) is uploaded to the device ONCE.
/// All bands are evaluated and accumulated on the device.
/// Accumulated result is downloaded to host ONCE and accumulated into (accum_r, accum_g, accum_b).
int32_t fotufilm_transport_accumulate(
    const float *r, const float *g, const float *b,
    float *accum_r, float *accum_g, float *accum_b,
    int32_t width, int32_t height,
    const FotufilmTransportBand *bands, int32_t band_count,
    int32_t backend);
#ifdef __cplusplus
}
#endif
#endif
