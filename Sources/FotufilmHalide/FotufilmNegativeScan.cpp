#include "FotufilmNegativeScan.h"
#include "FotufilmTrichromatic.h"
#include "FotufilmHalide.h"
#if defined(FOTUFILM_HALIDE_ENABLED)
#include "Pipeline/NegativeScan.h"
#include "Pipeline/Trichromatic.h"
#include "FotufilmTrichromaticMeasure.h"
#include <mutex>
#include <memory>
#include <cmath>
#include <cstdio>
extern "C" int32_t fotufilm_negative_scan(const float *in, float *out, int32_t w,
    int32_t h, const float *p, int32_t backend) {
    if (!in || !out || !p || w < 1 || h < 1 || w > 40000 || h > 40000
        || int64_t(w)*h > 150000000 || backend < 0 || backend > 1) return -1;
    for (int c = 0; c < 3; ++c)
        if (!std::isfinite(p[c]) || !std::isfinite(p[c+3]) || p[c] < 0 || p[c+3] < p[c]) return -1;
    if (!std::isfinite(p[6]) || p[6] < 0.1f || p[6] > 2.0f || !std::isfinite(p[7])) return -1;
    // Never destroyed, like every pipeline cache here: a warm-up thread still compiling when the
    // process exits must not find its cache torn down by the exit-time destructors.
    static std::mutex &mutex = *new std::mutex;
    static auto *const pipelines =
        new std::unique_ptr<fotufilm::pipelines::NegativeScanPipeline>[2]();
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

extern "C" int32_t fotufilm_scan_prepare(const float *in, float *out, int32_t w, int32_t h,
    const float *light, int32_t lw, int32_t lh, const float *p) {
    if (!in || !out || !p || w < 1 || h < 1 || w > 40000 || h > 40000
        || int64_t(w)*h > 150000000) return -1;
    for (int i = 0; i < 9; ++i) if (!std::isfinite(p[i])) return -1;
    bool lit = p[0] > 0.5f;
    if (lit && (!light || lw < 1 || lh < 1 || lw > 4096 || lh > 4096)) return -1;
    static std::mutex &mutex = *new std::mutex;
    static auto *pipeline = (fotufilm::pipelines::ScanPreparePipeline *)nullptr;
    std::lock_guard<std::mutex> lock(mutex);
    try {
        auto target = Halide::get_host_target().with_feature(Halide::Target::StrictFloat);
        if (!pipeline) {
            auto candidate = std::make_unique<fotufilm::pipelines::ScanPreparePipeline>();
            candidate->output.compile_jit(target);
            pipeline = candidate.release();
        }
        static const float none[3] = {1, 1, 1};
        auto input = Halide::Buffer<float>::make_interleaved(const_cast<float *>(in), w, h, 4);
        auto output = Halide::Buffer<float>::make_interleaved(out, w, h, 4);
        auto cells = lit ? Halide::Buffer<float>::make_interleaved(const_cast<float *>(light), lw, lh, 3)
                         : Halide::Buffer<float>::make_interleaved(const_cast<float *>(none), 1, 1, 3);
        Halide::Buffer<float> params(const_cast<float *>(p), 9);
        pipeline->input.set(input); pipeline->light.set(cells); pipeline->parameters.set(params);
        struct Unbind {
            fotufilm::pipelines::ScanPreparePipeline &pipeline;
            ~Unbind() { pipeline.input.reset(); pipeline.light.reset(); pipeline.parameters.reset(); }
        } unbind{*pipeline};
        pipeline->output.realize(output, target);
        return 0;
    } catch (const Halide::Error &error) {
        std::fprintf(stderr, "Scan preparation: %s\n", error.what()); return -2;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Scan preparation: %s\n", error.what()); return -2;
    }
}
extern "C" int32_t fotufilm_trichromatic_layer(const float *rgba, int32_t w, int32_t h,
    const float colour[3], float *layer) {
    float weights[3];
    if (!rgba || !layer || !fotufilm::trichromatic::valid_size(w, h)
        || !fotufilm::trichromatic::layer_weights(colour, weights)) return -1;
    static std::mutex &mutex = *new std::mutex;
    static auto *pipeline = (fotufilm::pipelines::TrichromaticLayerPipeline *)nullptr;
    std::lock_guard<std::mutex> lock(mutex);
    try {
        auto target = Halide::get_host_target().with_feature(Halide::Target::StrictFloat);
        if (!pipeline) {
            auto candidate = std::make_unique<fotufilm::pipelines::TrichromaticLayerPipeline>();
            candidate->output.compile_jit(target);
            pipeline = candidate.release();
        }
        auto input = Halide::Buffer<float>::make_interleaved(const_cast<float *>(rgba), w, h, 4);
        Halide::Buffer<float> output(layer, w, h), params(weights, 3);
        pipeline->input.set(input); pipeline->parameters.set(params);
        struct Unbind {
            fotufilm::pipelines::TrichromaticLayerPipeline &pipeline;
            ~Unbind() { pipeline.input.reset(); pipeline.parameters.reset(); }
        } unbind{*pipeline};
        pipeline->output.realize(output, target);
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Trichromatic layer: %s\n", error.what()); return -2;
    }
}

extern "C" int32_t fotufilm_trichromatic_merge(const float *red, const float *green,
    const float *blue, int32_t w, int32_t h, const float green_affine[6],
    const float blue_affine[6], uint8_t *file, int64_t size) {
    float p[15];
    if (!fotufilm::trichromatic::merge_header(red, green, blue, w, h, green_affine, blue_affine,
                                               file, size, p)) return -1;
    static std::mutex &mutex = *new std::mutex;
    static auto *pipeline = (fotufilm::pipelines::TrichromaticMergePipeline *)nullptr;
    std::lock_guard<std::mutex> lock(mutex);
    try {
        auto target = Halide::get_host_target().with_feature(Halide::Target::StrictFloat);
        if (!pipeline) {
            auto candidate = std::make_unique<fotufilm::pipelines::TrichromaticMergePipeline>();
            candidate->output.compile_jit(target);
            pipeline = candidate.release();
        }
        Halide::Buffer<float> r(const_cast<float *>(red), w, h), g(const_cast<float *>(green), w, h),
            b(const_cast<float *>(blue), w, h), params(p, 15);
        auto output = Halide::Buffer<uint16_t>::make_interleaved(
            reinterpret_cast<uint16_t *>(file + fotufilm::trichromatic::pixel_offset(h)), w, h, 3);
        pipeline->red.set(r); pipeline->green.set(g); pipeline->blue.set(b);
        pipeline->parameters.set(params);
        struct Unbind {
            fotufilm::pipelines::TrichromaticMergePipeline &pipeline;
            ~Unbind() {
                pipeline.red.reset(); pipeline.green.reset(); pipeline.blue.reset();
                pipeline.parameters.reset();
            }
        } unbind{*pipeline};
        pipeline->output.realize(output, target);
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Trichromatic merge: %s\n", error.what()); return -2;
    }
}
#elif !defined(FOTUFILM_HALIDE_IOS_AOT)
// SwiftPM can supply the unavailable stub beside the app's AOT implementation.
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_negative_scan(
    const float *, float *, int32_t, int32_t, const float *, int32_t) { return -3; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_scan_prepare(
    const float *, float *, int32_t, int32_t, const float *, int32_t, int32_t, const float *) {
    return -3;
}
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_trichromatic_measure(
    const float *, int32_t, int32_t, float *, int32_t *) { return -3; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_trichromatic_group(
    const int32_t *, int32_t, int32_t *) { return -3; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_trichromatic_layer(
    const float *, int32_t, int32_t, const float *, float *) { return -3; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_trichromatic_register(
    const float *, const float *, int32_t, int32_t, float *, float *) { return -3; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_trichromatic_repeats(
    const float *, const float *, int32_t, int32_t) { return -3; }
extern "C" FOTUFILM_FALLBACK int64_t fotufilm_trichromatic_file_size(int32_t, int32_t) { return -3; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_trichromatic_merge(const float *, const float *,
    const float *, int32_t, int32_t, const float *, const float *, uint8_t *, int64_t) {
    return -3;
}
#endif
