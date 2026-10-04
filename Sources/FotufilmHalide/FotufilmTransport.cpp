#include "FotufilmTransport.h"
#include "FotufilmHalide.h"
#if defined(FOTUFILM_HALIDE_ENABLED)
#include "Pipeline/Transport.h"
#include <cstdio>
#include <memory>
#include <mutex>

static_assert(FOTUFILM_TRANSPORT_TABLE_FLOATS == fotufilm::pipelines::kTransportTableFloats,
              "the C table size names the pipeline's");

namespace {
using fotufilm::pipelines::TransportPipeline;

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
    // Never destroyed, like every pipeline cache here: a warm-up thread still compiling when the
    // process exits must not find its cache torn down by the exit-time destructors.
    static std::mutex &mutex = *new std::mutex;
    static auto *const pipelines = new std::unique_ptr<TransportPipeline>[2]();
    std::lock_guard<std::mutex> lock(mutex);
    try {
        auto target = Halide::get_host_target().with_feature(Halide::Target::StrictFloat);
        if (backend) target.set_feature(Halide::Target::Metal);
        auto &pipeline = pipelines[backend];
        if (!pipeline) {
            auto candidate = std::make_unique<TransportPipeline>(
                backend ? Halide::DeviceAPI::Metal : Halide::DeviceAPI::None);
            candidate->output.compile_jit(target);
            pipeline = std::move(candidate);
        }
        Halide::Buffer<float> input(const_cast<float *>(exposure), width, height, channels);
        Halide::Buffer<float> sum(accumulated, width, height, channels);
        Halide::Buffer<float> table(const_cast<float *>(stencils), FOTUFILM_TRANSPORT_TABLE_FLOATS);
        Halide::Buffer<float> output(width, height, channels);
        input.set_host_dirty(); sum.set_host_dirty(); table.set_host_dirty();
        pipeline->exposure.set(input);
        pipeline->accumulated.set(sum);
        pipeline->stencils.set(table);
        for (int l = 0; l < FOTUFILM_TRANSPORT_LEVELS; ++l) pipeline->radii[l].set(int32_t(stencils[l]));
        struct Unbind {
            TransportPipeline &pipeline;
            ~Unbind() {
                pipeline.exposure.reset(); pipeline.accumulated.reset(); pipeline.stencils.reset();
            }
        } unbind{*pipeline};
        pipeline->output.realize(output, target);
        if (int copied = output.copy_to_host()) return copied;
        std::copy_n(output.data(), int64_t(width) * height * channels, accumulated);
        return 0;
    } catch (const Halide::Error &error) {
        std::fprintf(stderr, "Layered transport: %s\n", error.what());
        return -2;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Layered transport: %s\n", error.what());
        return -2;
    }
}
#elif !defined(FOTUFILM_HALIDE_IOS_AOT)
// SwiftPM can supply the unavailable stubs beside the app's AOT implementation.
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_transport_available(int32_t) { return 0; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_transport_component(
    const float *, float *, int32_t, int32_t, int32_t, const float *, int32_t) { return -3; }
#endif
