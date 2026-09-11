#ifndef FOTUFILM_HALIDE_DEVELOP_H
#define FOTUFILM_HALIDE_DEVELOP_H

#include "FotufilmHalide.h"

/// Features that change the CPU develop kernel. Keep the native cache, browser
/// AOT generator, and browser dispatch on this one definition.
static inline int32_t fotufilm_develop_features(int32_t feature_mask) {
    const int32_t bits = FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_MTF
        | FOTUFILM_FRAME_HALATION | FOTUFILM_FRAME_COUPLERS
        | FOTUFILM_FRAME_ADJACENCY | FOTUFILM_FRAME_GRAIN
        | FOTUFILM_FRAME_MTF_LUMA | FOTUFILM_FRAME_COUPLER_DIFFUSION
        | FOTUFILM_FRAME_DISC_GRAIN | FOTUFILM_FRAME_GRAIN_MOTTLE
        | FOTUFILM_FRAME_PRINT_MTF | FOTUFILM_FRAME_DENSITY_IN
        | FOTUFILM_FRAME_TEXTURE | FOTUFILM_FRAME_DIFFUSION
        | FOTUFILM_FRAME_DONOR_LAYER | FOTUFILM_FRAME_HALATION_ANNULAR
        | FOTUFILM_FRAME_RECORD_EXPOSURE_IN | FOTUFILM_FRAME_LIGHT_OUT;
    return feature_mask & bits;
}

static inline int32_t fotufilm_develop_variant(int32_t feature_mask) {
    const int32_t features = fotufilm_develop_features(feature_mask);
    const int32_t stage_bits = FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_MTF
        | FOTUFILM_FRAME_HALATION | FOTUFILM_FRAME_COUPLERS
        | FOTUFILM_FRAME_ADJACENCY | FOTUFILM_FRAME_GRAIN;
    return (features & stage_bits)
        | ((features & FOTUFILM_FRAME_MTF_LUMA) ? 64 : 0)
        | ((features & FOTUFILM_FRAME_COUPLER_DIFFUSION) ? 128 : 0)
        | ((features & FOTUFILM_FRAME_DISC_GRAIN) ? 256 : 0)
        | ((features & FOTUFILM_FRAME_GRAIN_MOTTLE) ? 512 : 0)
        | ((features & FOTUFILM_FRAME_PRINT_MTF) ? 1024 : 0)
        | ((features & FOTUFILM_FRAME_DENSITY_IN) ? 2048 : 0)
        | ((features & FOTUFILM_FRAME_TEXTURE) ? 4096 : 0)
        | ((features & FOTUFILM_FRAME_DIFFUSION) ? 8192 : 0)
        | ((features & FOTUFILM_FRAME_DONOR_LAYER) ? 16384 : 0)
        | ((features & FOTUFILM_FRAME_HALATION_ANNULAR) ? 32768 : 0)
        | ((features & FOTUFILM_FRAME_RECORD_EXPOSURE_IN) ? 65536 : 0)
        | ((features & FOTUFILM_FRAME_LIGHT_OUT) ? 131072 : 0);
}
#endif
