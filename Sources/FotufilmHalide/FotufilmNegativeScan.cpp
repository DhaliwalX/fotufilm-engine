#include "FotufilmNegativeScan.h"
#include "FotufilmHalide.h"
#if defined(FOTUFILM_HALIDE_ENABLED)
#include "Pipeline/NegativeScan.h"
#include <mutex>
#include <memory>
#include <cmath>
#include <cstdio>
extern "C" int32_t fotufilm_negative_scan(const float *in, float *out, int32_t w,
    int32_t h, const float *p, int32_t backend) {
    if (!in || !out || !p || w < 1 || h < 1 || w > 40000 || h > 40000
        || int64_t(w)*h > 150000000 || backend < 0 || backend > 1) return -1;
    for (int c = 0; c < 3; ++c)
        if (!std::isfinite(p[c]) || !std::isfinite(p[c+3]) || p[c] <= 0 || p[c+3] < p[c]) return -1;
    if (!std::isfinite(p[6]) || p[6] < 0.1f || p[6] > 2.0f || !std::isfinite(p[7])) return -1;
    static std::mutex mutex;
    static std::unique_ptr<fotufilm::pipelines::NegativeScanPipeline> pipelines[2];
    std::lock_guard<std::mutex> lock(mutex);
    try {
        auto target = Halide::get_host_target().with_feature(Halide::Target::StrictFloat);
        if (backend) target.set_feature(Halide::Target::Metal);
        auto &pipeline = pipelines[backend];
        if (!pipeline) {
            auto candidate = std::make_unique<fotufilm::pipelines::NegativeScanPipeline>(
                backend ? Halide::DeviceAPI::Metal : Halide::DeviceAPI::None);
            candidate->output.compile_jit(target);
            pipeline = std::move(candidate);
        }
        Halide::Buffer<float> input(const_cast<float *>(in), w, h, 3), output(out, w, h, 3);
        Halide::Buffer<float> params(const_cast<float *>(p), 8);
        input.set_host_dirty(); params.set_host_dirty();
        pipeline->input.set(input); pipeline->parameters.set(params);
        struct Unbind {
            fotufilm::pipelines::NegativeScanPipeline &pipeline;
            ~Unbind() { pipeline.input.reset(); pipeline.parameters.reset(); }
        } unbind{*pipeline};
        pipeline->output.realize(output, target);
        return output.copy_to_host();
    } catch (const Halide::Error &error) {
        std::fprintf(stderr, "Negative conversion: %s\n", error.what()); return -2;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Negative conversion: %s\n", error.what()); return -2;
    }
}
#elif !defined(FOTUFILM_HALIDE_IOS_AOT)
// SwiftPM can supply the unavailable stub beside the app's AOT implementation.
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_negative_scan(
    const float *, float *, int32_t, int32_t, const float *, int32_t) { return -3; }
#endif
