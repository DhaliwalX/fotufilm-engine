#include "FotufilmFilmTileBuild.h"
#include "FotufilmHalide.h"
#if defined(FOTUFILM_HALIDE_ENABLED)
#include "Pipeline/FilmTileBuild.h"
#include <cmath>
#include <cstdio>
#include <map>
#include <memory>
#include <mutex>
#include <tuple>
#include <vector>

namespace {
using fotufilm::pipelines::FilmCloudTerm;
using fotufilm::pipelines::FilmTileBuildPipeline;
using Key = std::tuple<int32_t, int32_t, int32_t, std::vector<float>>;
}

extern "C" int32_t fotufilm_film_tile_build(int32_t texels, int32_t supersample, int32_t markShape,
    const float *terms, int32_t termCount, const float *sublayers, const float *fractions,
    int32_t levels, uint32_t seed, int32_t record, float *light) {
    using namespace fotufilm::pipelines;
    if (!terms || !sublayers || !fractions || !light || texels < 16 || texels > 1024
        || supersample < 1 || supersample > 8 || markShape < 1 || markShape > 16
        || termCount < 1 || termCount > 8 || levels < 1 || levels > 64
        || record < 0 || record > 2) return -1;
    std::vector<float> termValues(terms, terms + 2 * termCount);
    for (int i = 0; i < termCount; ++i)
        if (!std::isfinite(terms[2 * i]) || terms[2 * i] <= 0 || !std::isfinite(terms[2 * i + 1])) return -1;
    for (int i = 0; i < kFilmBuildFields * kFilmBuildSublayers; ++i)
        if (!std::isfinite(sublayers[i])) return -1;
    for (int b = 0; b < kFilmBuildSublayers; ++b) {
        float cells = sublayers[b * kFilmBuildFields];
        if (cells < 1 || cells > kFilmBuildMaxCells || cells != std::floor(cells)
            || float(texels * supersample) / cells < 0.75f) return -1;
    }
    static std::mutex mutex;
    static std::map<Key, std::unique_ptr<FilmTileBuildPipeline>> pipelines;
    std::lock_guard<std::mutex> lock(mutex);
    try {
        auto target = Halide::get_host_target();
        Key key{texels, supersample, markShape, termValues};
        auto &pipeline = pipelines[key];
        if (!pipeline) {
            std::vector<FilmCloudTerm> cloud;
            for (int i = 0; i < termCount; ++i) cloud.push_back({terms[2 * i], terms[2 * i + 1]});
            auto candidate = std::make_unique<FilmTileBuildPipeline>(
                texels, supersample, markShape, cloud);
            candidate->output.compile_jit(target);
            pipeline = std::move(candidate);
        }
        Halide::Buffer<float> sub(const_cast<float *>(sublayers), kFilmBuildFields, kFilmBuildSublayers);
        Halide::Buffer<float> frac(const_cast<float *>(fractions), levels, kFilmBuildSublayers);
        Halide::Buffer<float> out(light, texels, texels, levels);
        pipeline->sublayers.set(sub); pipeline->fractions.set(frac);
        pipeline->seed.set(seed); pipeline->record.set(record);
        for (int b = 0; b < kFilmBuildSublayers; ++b) {
            // A count only reaches the thresholds a uniform draw can pass.
            const float *thresholds = sublayers + b * kFilmBuildFields + 3;
            int limit = 0;
            for (int k = 0; k < kFilmBuildMaxCount; ++k) if (thresholds[k] < 1.0f) limit = k + 1;
            pipeline->limits[b].set(std::max(limit, 1));
            pipeline->cellCounts[b].set(int32_t(sublayers[b * kFilmBuildFields]));
        }
        struct Unbind {
            FilmTileBuildPipeline &pipeline;
            ~Unbind() { pipeline.sublayers.reset(); pipeline.fractions.reset(); }
        } unbind{*pipeline};
        pipeline->output.realize(out, target);
        return 0;
    } catch (const Halide::Error &error) {
        std::fprintf(stderr, "Film tile build: %s\n", error.what()); return -2;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Film tile build: %s\n", error.what()); return -2;
    }
}
#else
// Hosts without the Halide compiler build Film tiles in Swift.
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_film_tile_build(int32_t, int32_t, int32_t,
    const float *, int32_t, const float *, const float *, int32_t, uint32_t, int32_t, float *) {
    return -3;
}
#endif
