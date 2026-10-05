#ifndef FOTUFILM_TRANSPORT_FRAME_AOT_H
#define FOTUFILM_TRANSPORT_FRAME_AOT_H

#include "FotufilmTransport.h"
#include "FotufilmConfigLayout.h"
#include <HalideBuffer.h>
#include <cstring>
#include <memory>

/// A transport frame over an ahead-of-time scene pipeline: the buffers persist between
/// components, so after the first the scene and the sum are already on the pipeline's device.
struct fotufilm_transport_frame {
    using Run = int (*)(halide_buffer_t *, halide_buffer_t *, halide_buffer_t *, halide_buffer_t *,
                        halide_buffer_t *, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
                        int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
                        bool, halide_buffer_t *);
    using Prepare = int (*)(halide_buffer_t *, halide_buffer_t *, halide_buffer_t *);
    Run run;
    Halide::Runtime::Buffer<float> domain, sum, configuration, lut, table;
    /// Whether a component has written the sum yet.
    bool written = false;
};

namespace fotufilm::transport_frame {

/// `device` is the pipelines' device interface, or null for the CPU: on a device the scene's
/// domain lives there alone.
inline fotufilm_transport_frame *begin(fotufilm_transport_frame::Prepare prepare,
                                       fotufilm_transport_frame::Run run,
                                       const halide_device_interface_t *device, const float *scene,
                                       const float *configuration, float *sum, int32_t width,
                                       int32_t height, int32_t channels) {
    if (!prepare || !run || !scene || !configuration || !sum || width < 1 || height < 1
        || (int64_t)width * height > 150000000 || channels < 3 || channels > 4) return nullptr;
    halide_dimension_t shape[3] = {{0, width, 4}, {0, height, 4 * width}, {0, 4, 1}};
    Halide::Runtime::Buffer<float> source(const_cast<float *>(scene), 3, shape);
    Halide::Runtime::Buffer<float> shared(const_cast<float *>(configuration),
                                          FOTUFILM_FRAME_CONFIGURATION_COUNT);
    source.set_host_dirty(); shared.set_host_dirty();
    auto *frame = new (std::nothrow) fotufilm_transport_frame{
        run, device ? Halide::Runtime::Buffer<float>(nullptr, 3, shape)
                    : Halide::Runtime::Buffer<float>::make_interleaved(width, height, 4),
        Halide::Runtime::Buffer<float>(sum, width, height, channels),
        Halide::Runtime::Buffer<float>(FOTUFILM_FRAME_CONFIGURATION_COUNT),
        Halide::Runtime::Buffer<float>(33 * 33 * 33 * 4),
        Halide::Runtime::Buffer<float>(FOTUFILM_TRANSPORT_TABLE_FLOATS)};
    if (!frame) return nullptr;
    if (device && frame->domain.device_malloc(device)) { delete frame; return nullptr; }
    // The scene is read here alone: the components read its domain, left on the device.
    if (prepare(source, shared, frame->domain)) { delete frame; return nullptr; }
    return frame;
}

inline int32_t add(fotufilm_transport_frame *frame, const float *configuration,
                   const float *exposure_lut, const float *stencils) {
    if (!frame || !configuration || !exposure_lut || fotufilm_transport_validate_table(stencils))
        return -1;
    std::memcpy(frame->configuration.data(), configuration,
                sizeof(float) * FOTUFILM_FRAME_CONFIGURATION_COUNT);
    std::memcpy(frame->lut.data(), exposure_lut, sizeof(float) * frame->lut.number_of_elements());
    std::memcpy(frame->table.data(), stencils, sizeof(float) * FOTUFILM_TRANSPORT_TABLE_FLOATS);
    frame->configuration.set_host_dirty(); frame->lut.set_host_dirty(); frame->table.set_host_dirty();
    int32_t r[FOTUFILM_TRANSPORT_LEVELS];
    for (int l = 0; l < FOTUFILM_TRANSPORT_LEVELS; ++l) r[l] = int32_t(stencils[l]);
    // The sum is read only at the point written, so the pipeline adds into it in place, and it
    // stays where the pipeline left it until the frame finishes.
    const int status = frame->run(frame->domain, frame->configuration, frame->lut, frame->sum,
                                  frame->table, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7],
                                  r[8], r[9], r[10], r[11], r[12], !frame->written, frame->sum);
    if (!status) frame->written = true;
    return status;
}

inline int32_t finish(fotufilm_transport_frame *frame, int32_t deliver) {
    if (!frame) return -1;
    std::unique_ptr<fotufilm_transport_frame> owned(frame);
    if (!deliver) return 0;
    if (!frame->written) {
        std::memset(frame->sum.data(), 0, sizeof(float) * frame->sum.number_of_elements());
        return 0;
    }
    return frame->sum.copy_to_host();
}

}

#endif
