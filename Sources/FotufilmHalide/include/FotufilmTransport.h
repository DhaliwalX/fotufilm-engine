#ifndef FOTUFILM_TRANSPORT_H
#define FOTUFILM_TRANSPORT_H
#include <math.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/// Power-of-two strides a transport component's stencils may sit at: 1 through 4096.
#define FOTUFILM_TRANSPORT_LEVELS 13
/// The largest stencil radius at any stride; each level's weights fill a centred 25 x 25 slot.
#define FOTUFILM_TRANSPORT_STENCIL_RADIUS 12
/// One radius per level (0 leaves the level out), then each level's 625 weights.
#define FOTUFILM_TRANSPORT_TABLE_FLOATS (FOTUFILM_TRANSPORT_LEVELS + FOTUFILM_TRANSPORT_LEVELS * 625)

/// CPU (0) or Metal (1). Returns 0 when the backend is unavailable.
int32_t fotufilm_transport_available(int32_t backend);

/// Adds one Layered Transport component to the running sum. `exposure` and `accumulated` are
/// planar width * height * channels floats (channels 3, or 4 with a donor record), distinct.
/// Each level averages the exposure over stride x stride cells with edge pixels repeated,
/// convolves the cell grid with its stencil, and reconstructs at the pixel centres with the
/// cubic B-spline. Returns -1 for invalid input, -3 for an unavailable backend.
int32_t fotufilm_transport_component(
    const float *exposure, float *accumulated, int32_t width, int32_t height, int32_t channels,
    const float *stencils, int32_t backend);

/// A frame of components the transport exposes from the scene itself — each head's light is the
/// scene through its exposure LUT and the camera gate, which is every head whose lens adds no
/// flare or diffusion — so the scene and the running sum stay on the device between components.
typedef struct fotufilm_transport_frame fotufilm_transport_frame;

/// Starts a frame over `scene`, linear Rec.2020 RGBA floats, as the heads' shared `configuration`
/// (FOTUFILM_FRAME_CONFIGURATION_COUNT floats) exposes it, summing `channels` records (3, or 4
/// with a donor record, the LUT's fourth channel). Null when the backend cannot run frames.
fotufilm_transport_frame *fotufilm_transport_frame_begin(
    const float *scene, const float *configuration, int32_t width, int32_t height, int32_t channels,
    int32_t backend);

/// Adds one component: its head's configuration — the shared one, its preflash share and camera
/// gate aside — and exposure LUT (33^3 x 4 floats) expose it, and its stencil table spreads it.
int32_t fotufilm_transport_frame_add(fotufilm_transport_frame *frame, const float *configuration,
                                     const float *exposure_lut, const float *stencils);

/// Copies the sum, planar width * height * channels floats (zero before any component), into
/// `sum` unless it is null, and releases the frame.
int32_t fotufilm_transport_frame_finish(fotufilm_transport_frame *frame, float *sum);

/// The table's checks alone.
static inline int32_t fotufilm_transport_validate_table(const float *stencils) {
    if (!stencils) return -1;
    for (int level = 0; level < FOTUFILM_TRANSPORT_LEVELS; ++level) {
        const float radius = stencils[level];
        if (!(radius >= 0 && radius <= FOTUFILM_TRANSPORT_STENCIL_RADIUS) || radius != floorf(radius))
            return -1;
    }
    for (int i = FOTUFILM_TRANSPORT_LEVELS; i < FOTUFILM_TRANSPORT_TABLE_FLOATS; ++i) {
        if (!(stencils[i] >= 0 && stencils[i] < INFINITY)) return -1;
    }
    return 0;
}
/// The checks every implementation makes before running: 0, or -1.
static inline int32_t fotufilm_transport_validate(
    const float *exposure, const float *accumulated, int32_t width, int32_t height,
    int32_t channels, const float *stencils, int32_t backend) {
    if (!exposure || !accumulated || !stencils || exposure == accumulated || width < 1
        || height < 1 || (int64_t)width * height > 150000000 || channels < 3 || channels > 4
        || backend < 0 || backend > 1) return -1;
    return fotufilm_transport_validate_table(stencils);
}
#ifdef __cplusplus
}
#endif
#endif
