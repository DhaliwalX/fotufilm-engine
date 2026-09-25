#ifndef FOTUFILM_FILM_TILE_BUILD_H
#define FOTUFILM_FILM_TILE_BUILD_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// One dye-cloud record's periodic Film grain tile, rendered crystal by crystal, as the light
// each texel passes at `levels` developed densities: `light` holds texels² floats per level,
// level-major. `sublayers` holds 4 × 51 floats (cells per tile side, peak demand over capacity,
// capacity, then 48 Poisson count thresholds; an absent sublayer has thresholds of 1);
// `fractions` holds `levels` developed fractions per sublayer; `terms` holds each cloud term's
// sigma in samples, then its weight. Runs on the CPU. Returns 0, or a negative error when the
// host has no Halide compiler or the arguments are out of range.
int32_t fotufilm_film_tile_build(int32_t texels, int32_t supersample, int32_t markShape,
    const float *terms, int32_t termCount, const float *sublayers, const float *fractions,
    int32_t levels, uint32_t seed, int32_t record, float *light);
#ifdef __cplusplus
}
#endif
#endif
