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
        | FOTUFILM_FRAME_GRAIN_MOTTLE
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

#ifdef __cplusplus
extern "C" {
#endif

/// Host-queue async scope: bind a caller-owned MTLCommandQueue so that subsequent
/// Halide Metal calls on this thread encode into ONE command buffer and serial
/// compute encoder on that queue without CPU stalls.
void    fotufilm_halide_metal_host_queue_begin(void *mtl_command_queue);
int32_t fotufilm_halide_metal_host_queue_active(void);
void   *fotufilm_halide_metal_host_compute_encoder(void);
void   *fotufilm_halide_metal_host_queue_end(void);

/// 1 when something inside the scope opened last on this thread asked for results back on the
/// CPU and the host's queue did not deliver them in time (FOTUFILM_HOST_QUEUE_PATIENCE_MS, 250
/// by default): the host is holding its queue across its render call. The wait was given up, so
/// the frame the scope encoded is not finished and has to be developed outside the call.
int32_t fotufilm_halide_metal_host_queue_refused(void);

/// Calls `function(context, failed)` once the open scope's command buffer has run on the GPU,
/// with `failed` non-zero when the GPU reported an error. Returns 0, and never calls
/// `function`, when no scope is open on this thread.
int32_t fotufilm_halide_metal_host_queue_on_completed(
    void (*function)(void *context, int32_t failed), void *context);

/// The next decode on this thread inside a host-queue scope reports through `sink` once its
/// command buffer has run, rather than not at all. `sink` is always called exactly once.
void fotufilm_halide_metal_decode_report_later(
    void (*sink)(void *context, float peak, int32_t repaired), void *context);

/// Configures per-thread vertical row-flip for zero-copy bottom-up host MTLBuffers
/// (e.g. DaVinci Resolve OFX gpuFrames) on decode input and/or frame develop output.
void  fotufilm_halide_metal_set_io_flip(int32_t flip_decode_input_y,
                                        int32_t flip_frame_output_y,
                                        int32_t full_frame_height);

#ifdef __cplusplus
}
#endif

#endif
