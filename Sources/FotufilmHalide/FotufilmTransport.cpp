#include "FotufilmTransport.h"
#include "FotufilmHalide.h"
#if defined(FOTUFILM_HALIDE_ENABLED)
#include "Pipeline/Transport.h"
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>

static_assert(FOTUFILM_TRANSPORT_TABLE_FLOATS == fotufilm::pipelines::kTransportTableFloats,
              "the C table size names the pipeline's");

namespace {
using fotufilm::pipelines::TransportDomainPipeline;
using fotufilm::pipelines::TransportPipeline;

std::mutex &pipeline_mutex() {
    // Never destroyed, like every pipeline cache here: a warm-up thread still compiling when the
    // process exits must not find its cache torn down by the exit-time destructors.
    static std::mutex &mutex = *new std::mutex;
    return mutex;
}

Halide::Target transport_target(int32_t backend) {
    auto target = Halide::get_host_target().with_feature(Halide::Target::StrictFloat);
    if (backend) target.set_feature(Halide::Target::Metal);
    return target;
}

/// The pipeline for a backend and input, compiled on first use. Call with the mutex held.
TransportPipeline &pipeline(int32_t backend, bool from_scene) {
    static auto *const pipelines = new std::unique_ptr<TransportPipeline>[4]();
    auto &pipeline = pipelines[backend + 2 * from_scene];
    if (!pipeline) {
        auto candidate = std::make_unique<TransportPipeline>(
            backend ? Halide::DeviceAPI::Metal : Halide::DeviceAPI::None, from_scene);
        candidate->output.compile_jit(transport_target(backend));
        pipeline = std::move(candidate);
    }
    return *pipeline;
}

bool metal_available() {
#if defined(__APPLE__)
    return Halide::host_supports_target_device(
        Halide::get_host_target().with_feature(Halide::Target::Metal));
#else
    return false;
#endif
}
}

extern "C" int32_t fotufilm_transport_available(int32_t backend) {
    if (backend == 0) return 1;
    return backend == 1 && metal_available() ? 1 : 0;
}

extern "C" int32_t fotufilm_transport_component(
    const float *exposure, float *accumulated, int32_t width, int32_t height, int32_t channels,
    const float *stencils, int32_t backend) {
    const int32_t status = fotufilm_transport_validate(exposure, accumulated, width, height,
                                                       channels, stencils, backend);
    if (status) return status;
    if (!fotufilm_transport_available(backend)) return -3;
    std::lock_guard<std::mutex> lock(pipeline_mutex());
    try {
        const auto target = transport_target(backend);
        TransportPipeline &pipeline = ::pipeline(backend, false);
        Halide::Buffer<float> input(const_cast<float *>(exposure), width, height, channels);
        Halide::Buffer<float> sum(accumulated, width, height, channels);
        Halide::Buffer<float> table(const_cast<float *>(stencils), FOTUFILM_TRANSPORT_TABLE_FLOATS);
        input.set_host_dirty(); sum.set_host_dirty(); table.set_host_dirty();
        pipeline.exposure.set(input);
        pipeline.accumulated.set(sum);
        pipeline.stencils.set(table);
        for (int l = 0; l < FOTUFILM_TRANSPORT_LEVELS; ++l) pipeline.radii[l].set(int32_t(stencils[l]));
        struct Unbind {
            TransportPipeline &pipeline;
            ~Unbind() {
                pipeline.exposure.reset(); pipeline.accumulated.reset(); pipeline.stencils.reset();
            }
        } unbind{pipeline};
        // The sum is read only at the point written, so the pipeline adds into it in place.
        pipeline.output.realize(sum, target);
        return sum.copy_to_host();
    } catch (const Halide::Error &error) {
        std::fprintf(stderr, "Layered transport: %s\n", error.what());
        return -2;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Layered transport: %s\n", error.what());
        return -2;
    }
}

struct fotufilm_transport_frame {
    int32_t backend;
    Halide::Buffer<float> domain, sum, configuration, lut, table;
    /// Whether a component has written the sum yet.
    bool written = false;
};

extern "C" fotufilm_transport_frame *fotufilm_transport_frame_begin(
    const float *scene, const float *configuration, float *sum, int32_t width, int32_t height,
    int32_t channels, int32_t backend) {
    if (!scene || !configuration || !sum || width < 1 || height < 1 || (int64_t)width * height > 150000000
        || channels < 3 || channels > 4 || !fotufilm_transport_available(backend)) return nullptr;
    std::lock_guard<std::mutex> lock(pipeline_mutex());
    try {
        static auto *const domains = new std::unique_ptr<TransportDomainPipeline>[2]();
        auto &domain = domains[backend];
        if (!domain) {
            auto candidate = std::make_unique<TransportDomainPipeline>(
                backend ? Halide::DeviceAPI::Metal : Halide::DeviceAPI::None);
            candidate->output.compile_jit(transport_target(backend));
            domain = std::move(candidate);
        }
        halide_dimension_t shape[3] = {{0, width, 4}, {0, height, 4 * width}, {0, 4, 1}};
        Halide::Buffer<float> source(const_cast<float *>(scene), 3, shape);
        Halide::Buffer<float> shared(const_cast<float *>(configuration),
                                     FOTUFILM_FRAME_CONFIGURATION_COUNT);
        source.set_host_dirty(); shared.set_host_dirty();
        // On a device the scene's domain lives there alone.
        auto frame = std::make_unique<fotufilm_transport_frame>(fotufilm_transport_frame{
            backend, backend ? Halide::Buffer<float>(nullptr, 3, shape)
                             : Halide::Buffer<float>::make_interleaved(width, height, 4),
            Halide::Buffer<float>(sum, width, height, channels),
            Halide::Buffer<float>(FOTUFILM_FRAME_CONFIGURATION_COUNT),
            Halide::Buffer<float>(33 * 33 * 33 * 4),
            Halide::Buffer<float>(FOTUFILM_TRANSPORT_TABLE_FLOATS)});
        if (backend && frame->domain.device_malloc(
                Halide::get_device_interface_for_device_api(Halide::DeviceAPI::Metal,
                                                            transport_target(backend)))) {
            return nullptr;
        }
        domain->scene.set(source);
        domain->configuration.set(shared);
        struct Unbind {
            TransportDomainPipeline &pipeline;
            ~Unbind() { pipeline.scene.reset(); pipeline.configuration.reset(); }
        } unbind{*domain};
        // The scene is read here alone: the components read its domain, left on the device.
        domain->output.realize(frame->domain, transport_target(backend));
        return frame.release();
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Layered transport: %s\n", error.what());
        return nullptr;
    }
}

extern "C" int32_t fotufilm_transport_frame_add(fotufilm_transport_frame *frame,
                                                const float *configuration,
                                                const float *exposure_lut, const float *stencils) {
    if (!frame || !configuration || !exposure_lut || fotufilm_transport_validate_table(stencils))
        return -1;
    std::lock_guard<std::mutex> lock(pipeline_mutex());
    try {
        auto &pipeline = ::pipeline(frame->backend, true);
        std::memcpy(frame->configuration.data(), configuration,
                    sizeof(float) * FOTUFILM_FRAME_CONFIGURATION_COUNT);
        std::memcpy(frame->lut.data(), exposure_lut, sizeof(float) * frame->lut.number_of_elements());
        std::memcpy(frame->table.data(), stencils, sizeof(float) * FOTUFILM_TRANSPORT_TABLE_FLOATS);
        frame->configuration.set_host_dirty(); frame->lut.set_host_dirty();
        frame->table.set_host_dirty();
        pipeline.exposure.set(frame->domain);
        pipeline.configuration.set(frame->configuration);
        pipeline.exposure_lut.set(frame->lut);
        pipeline.accumulated.set(frame->sum);
        pipeline.stencils.set(frame->table);
        for (int l = 0; l < FOTUFILM_TRANSPORT_LEVELS; ++l) pipeline.radii[l].set(int32_t(stencils[l]));
        pipeline.first.set(!frame->written);
        struct Unbind {
            TransportPipeline &pipeline;
            ~Unbind() {
                pipeline.exposure.reset(); pipeline.configuration.reset();
                pipeline.exposure_lut.reset(); pipeline.accumulated.reset(); pipeline.stencils.reset();
            }
        } unbind{pipeline};
        // The sum stays where the pipeline left it until the frame finishes.
        pipeline.output.realize(frame->sum, transport_target(frame->backend));
        frame->written = true;
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Layered transport: %s\n", error.what());
        return -2;
    }
}

extern "C" int32_t fotufilm_transport_frame_finish(fotufilm_transport_frame *frame, int32_t deliver) {
    if (!frame) return -1;
    std::unique_ptr<fotufilm_transport_frame> owned(frame);
    if (!deliver) return 0;
    if (!frame->written) {
        std::memset(frame->sum.data(), 0, sizeof(float) * frame->sum.number_of_elements());
        return 0;
    }
    return frame->sum.copy_to_host();
}
#elif !defined(FOTUFILM_HALIDE_IOS_AOT)
// SwiftPM can supply the unavailable stubs beside the app's AOT implementation.
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_transport_available(int32_t) { return 0; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_transport_component(
    const float *, float *, int32_t, int32_t, int32_t, const float *, int32_t) { return -3; }
extern "C" FOTUFILM_FALLBACK fotufilm_transport_frame *fotufilm_transport_frame_begin(
    const float *, const float *, float *, int32_t, int32_t, int32_t, int32_t) { return nullptr; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_transport_frame_add(
    fotufilm_transport_frame *, const float *, const float *, const float *) { return -3; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_transport_frame_finish(
    fotufilm_transport_frame *, int32_t) { return -3; }
#endif
