
#include "FotufilmHalide.h"
#include "FotufilmHalideDevelop.h"

#if defined(FOTUFILM_HALIDE_ENABLED)

#include "Pipeline/Cpu.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <exception>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <unordered_map>

using Halide::BoundaryConditions::constant_exterior;
using Halide::Buffer;
using Halide::Expr;
using Halide::Float;
using Halide::Func;
using Halide::ImageParam;
using Halide::Param;
using Halide::Pipeline;
using Halide::RDom;
using Halide::Var;

using namespace fotufilm;
using namespace fotufilm::cpu;
using namespace fotufilm::pipelines;

namespace {

template<typename Function>
int32_t translate_exceptions(Function &&function) {
    try {
        function();
        return 0;
    } catch (const Halide::Error &error) {
        std::fprintf(stderr, "Fotufilm Halide error: %s\n", error.what());
        return -1;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Fotufilm Halide error: %s\n", error.what());
        return -1;
    } catch (...) {
        std::fprintf(stderr, "Fotufilm Halide error: unknown exception\n");
        return -2;
    }
}

}

extern "C" int32_t fotufilm_halide_available(void) { return 1; }

namespace {

DevelopPipeline *develop_pipeline_for(int32_t feature_mask, bool additional_exposure = false) {
    const int32_t features = fotufilm_develop_features(feature_mask);
    const int64_t variant = int64_t(fotufilm_develop_variant(features)) * 2 + (additional_exposure ? 1 : 0);
    // Never destroyed, like every pipeline cache here: a warm-up thread still compiling when the
    // process exits must not find its cache torn down by the exit-time destructors.
    static auto &pipelines = *new std::unordered_map<int64_t, std::unique_ptr<DevelopPipeline>>;
    static std::mutex &pipelines_mutex = *new std::mutex;
    std::lock_guard<std::mutex> lock(pipelines_mutex);
    auto &pipeline = pipelines[variant];
    if (!pipeline) {
        pipeline = std::make_unique<DevelopPipeline>(
            features, "_variant_" + std::to_string(variant), additional_exposure);
    }
    return pipeline.get();
}

/// The shape the host's space takes, or -1 to read it from the configuration per pixel.
int output_transfer_shape_for(int32_t feature_mask) {
    if ((feature_mask & FOTUFILM_FRAME_ENCODE_OUT) == 0) return -1;
    if (feature_mask & FOTUFILM_FRAME_OUTPUT_LINEAR) return 0;
    if (feature_mask & FOTUFILM_FRAME_OUTPUT_POWER) return 1;
    if (feature_mask & FOTUFILM_FRAME_OUTPUT_LOG) return 2;
    return -1;
}

PlainPipeline *plain_pipeline_for(int32_t feature_mask) {
    const bool monochrome = (feature_mask & FOTUFILM_FRAME_MONOCHROME) != 0;
    const bool encode = (feature_mask & FOTUFILM_FRAME_ENCODE_OUT) != 0;
    const int shape = output_transfer_shape_for(feature_mask);
    static auto *const pipelines = new std::unique_ptr<PlainPipeline>[16]();
    static std::mutex &pipelines_mutex = *new std::mutex;
    std::lock_guard<std::mutex> lock(pipelines_mutex);
    const int variant = (monochrome ? 1 : 0) | (encode ? 2 : 0)
        | ((shape + 1) << 2);
    if (!pipelines[variant]) {
        pipelines[variant] = std::make_unique<PlainPipeline>(
            monochrome, "_plain_variant_" + std::to_string(variant), encode,
            shape);
    }
    return pipelines[variant].get();
}

PrintPipeline *print_pipeline_for(int32_t feature_mask) {
    const bool reversal = (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0;
    const bool monochrome = (feature_mask & FOTUFILM_FRAME_MONOCHROME) != 0;
    // The host's own last step, when it asked for it. This road JITs its pipelines and keeps
    // them, so a shape costs a cache slot rather than a shipped variant; the ahead-of-time
    // generators construct `PrintPipeline` directly and keep their four non-encoding variants.
    const bool encode = (feature_mask & FOTUFILM_FRAME_ENCODE_OUT) != 0;
    // A shape bit is a promise that every frame this pipeline serves takes that shape, so it may
    // be compiled in; without one the shape is read per pixel, exactly as the fused GPU pipeline
    // reads it when the caller asked for no shaped variant.
    const int shape = output_transfer_shape_for(feature_mask);
    static auto *const pipelines = new std::unique_ptr<PrintPipeline>[32]();
    static std::mutex &pipelines_mutex = *new std::mutex;
    std::lock_guard<std::mutex> lock(pipelines_mutex);
    const int variant = (reversal ? 1 : 0) | (monochrome ? 2 : 0)
        | (encode ? 4 : 0) | ((shape + 1) << 3);
    if (!pipelines[variant]) {
        pipelines[variant] = std::make_unique<PrintPipeline>(
            reversal, monochrome, "_print_variant_" + std::to_string(variant),
            encode, shape);
    }
    return pipelines[variant].get();
}

}

extern "C" int32_t fotufilm_halide_set_film_tiles(int32_t id, const float *tiles,
                                                  int64_t count) {
    return FilmTileStore::shared().set(id, tiles, count) ? 0 : -1;
}

extern "C" int32_t fotufilm_halide_develop(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height, const float *configuration,
    const float *exposure_lut, int32_t lut_dimension,
    int32_t feature_mask, uint32_t seed) {
    if (!input_r || !input_g || !input_b || !output_r || !output_g || !output_b ||
        !configuration || !exposure_lut || width <= 0 || height <= 0 ||
        lut_dimension != kLutDimension) return -1;
    // The negative on its own, which is what this stage is for: no enlarger images it, so the
    // print's optics are cleared however the frame would have been finished. A microdensitometer
    // reading the granularity of this film is not looking through a lens either. The full frame
    // path keeps the bit, because there the print really does follow.
    const int32_t film_only = feature_mask & ~FOTUFILM_FRAME_PRINT_MTF;
    return translate_exceptions([&] {
        Buffer<float> density(width, height, 3);
        develop_pipeline_for(film_only)->run(
            input_r, input_g, input_b, density, width, height, configuration,
            exposure_lut, film_only, seed);
        copy_planar(density, output_r, output_g, output_b, width, height);
    });
}

extern "C" int32_t fotufilm_halide_print(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height, const float *configuration,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, int32_t feature_mask) {
    if (!input_r || !input_g || !input_b || !output_r || !output_g || !output_b ||
        !configuration || !film_output_lut || !paper_output_lut ||
        width <= 0 || height <= 0 || lut_dimension != kLutDimension) return -1;
    return translate_exceptions([&] {
        Buffer<float> density = planar_buffer(input_r, input_g, input_b,
                                              width, height);
        Buffer<float> result(width, height, 3);
        print_pipeline_for(feature_mask)->run(
            density, result, width, height, configuration, film_output_lut,
            paper_output_lut, feature_mask);
        copy_planar(result, output_r, output_g, output_b, width, height);
    });
}

extern "C" int32_t fotufilm_halide_process(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height, const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    int32_t feature_mask, uint32_t seed) {
    return fotufilm_halide_process_strip(
        input_r, input_g, input_b, output_r, output_g, output_b, width, height,
        width, height, 0, 0, 0, height, configuration, exposure_lut,
        film_output_lut, paper_output_lut, lut_dimension, feature_mask, seed);
}

extern "C" int32_t fotufilm_halide_process_strip(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height, int32_t output_width, int32_t output_height,
    int32_t origin_x, int32_t origin_y, int32_t interior_top,
    int32_t interior_height,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, int32_t feature_mask, uint32_t seed) {
    return fotufilm_halide_process_tile(
        input_r, input_g, input_b, output_r, output_g, output_b,
        width, height, output_width, output_height, origin_x, origin_y,
        0, interior_top, width, interior_height, configuration, exposure_lut,
        film_output_lut, paper_output_lut, lut_dimension, feature_mask, seed);
}

extern "C" int32_t fotufilm_halide_process_tile(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height, int32_t output_width, int32_t output_height,
    int32_t origin_x, int32_t origin_y, int32_t interior_left, int32_t interior_top,
    int32_t interior_width, int32_t interior_height,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, int32_t feature_mask, uint32_t seed) {
    return fotufilm_halide_process_tile_with_exposure(
        input_r, input_g, input_b, output_r, output_g, output_b,
        width, height, output_width, output_height, origin_x, origin_y,
        interior_left, interior_top, interior_width, interior_height,
        configuration, exposure_lut, film_output_lut, paper_output_lut,
        lut_dimension, feature_mask, seed, nullptr);
}

static int32_t process_tile_output(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height, int32_t output_width, int32_t output_height,
    int32_t origin_x, int32_t origin_y, int32_t interior_left, int32_t interior_top,
    int32_t interior_width, int32_t interior_height,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, int32_t feature_mask, uint32_t seed, const float *additional_record_exposure, bool compact_output) {
    if (!input_r || !input_g || !input_b || !output_r || !output_g || !output_b ||
        !configuration || !exposure_lut || !film_output_lut ||
        !paper_output_lut || width <= 0 || height <= 0 ||
        output_width < width || output_height < height || origin_x < 0 || origin_y < 0 ||
        origin_x > output_width - width || origin_y > output_height - height ||
        interior_left < 0 || interior_width <= 0 || interior_width > width ||
        interior_left > width - interior_width ||
        interior_top < 0 || interior_height <= 0 || interior_height > height ||
        interior_top > height - interior_height ||
        lut_dimension != kLutDimension) return -1;
    if (additional_record_exposure) {
        const int32_t unsupported = FOTUFILM_FRAME_NO_FILM | FOTUFILM_FRAME_DENSITY_IN
            | FOTUFILM_FRAME_RECORD_EXPOSURE_IN | FOTUFILM_FRAME_LIGHT_OUT | FOTUFILM_FRAME_TEXTURE;
        if (feature_mask & unsupported) return -1;
        for (int64_t i = 0; i < int64_t(width) * height * 4; ++i)
            if (!std::isfinite(additional_record_exposure[i]) || additional_record_exposure[i] < 0) return -1;
    }

    return translate_exceptions([&] {
        // The tile's interior, wherever it came from, laid into the caller's frame planes.
        auto copy_out = [&](Buffer<float> &result) {
            float *destination[3] = {output_r, output_g, output_b};
            for (int channel = 0; channel < 3; ++channel) {
                for (int row = 0; row < interior_height; ++row) {
                    const float *source = &result(interior_left, interior_top + row, channel);
                    const int64_t target = compact_output
                        ? static_cast<int64_t>(row) * interior_width
                        : static_cast<int64_t>(origin_y + interior_top + row) * output_width
                            + origin_x + interior_left;
                    std::copy_n(source, interior_width, destination[channel] + target);
                }
            }
        };
        if (feature_mask & FOTUFILM_FRAME_NO_FILM) {
            // No emulsion to develop and no paper to print: the strip goes straight through the
            // creative controls into the delivery basis. Its rows are still the strip's own, so
            // the tone masks land where the whole frame measured them.
            Buffer<float> plain(interior_width, interior_height, 3);
            plain.translate(0, interior_left);
            plain.translate(1, interior_top);
            plain_pipeline_for(feature_mask)->run(
                input_r, input_g, input_b, plain, width, height,
                configuration, origin_x, origin_y);
            copy_out(plain);
            return;
        }
        Buffer<float> density(width, height, 3);
        develop_pipeline_for(feature_mask, additional_record_exposure != nullptr)->run(
            input_r, input_g, input_b, density, width, height, configuration,
            exposure_lut, feature_mask, seed, origin_x, origin_y, additional_record_exposure);
        // `PipelineStage.negative` and `PipelineStage.texture` end here: the first returns the
        // developed negative itself and the second the source the develop's two passes differed
        // on, and neither is a thing the paper prints. The strip's interior is copied out of the
        // develop buffer exactly where the print's result would have been read from.
        const bool develop_is_the_result =
            feature_mask & (FOTUFILM_FRAME_DENSITY_OUT | FOTUFILM_FRAME_TEXTURE);
        Buffer<float> result(interior_width, interior_height, 3);
        result.translate(0, interior_left);
        result.translate(1, interior_top);
        if (develop_is_the_result) {
            for (int channel = 0; channel < 3; ++channel) {
                for (int row = 0; row < interior_height; ++row) {
                    const int y = interior_top + row;
                    std::copy_n(&density(interior_left, y, channel), interior_width,
                                &result(interior_left, y, channel));
                }
            }
        } else {
            // The print screen is fixed to the full frame, including compact tile output.
            density.translate(0, origin_x); density.translate(1, origin_y);
            result.translate(0, origin_x); result.translate(1, origin_y);
            print_pipeline_for(feature_mask)->run(
                density, result, width, interior_height, configuration,
                film_output_lut, paper_output_lut, feature_mask);
            result.translate(0, -origin_x); result.translate(1, -origin_y);
        }
        copy_out(result);
    });
}

extern "C" int32_t fotufilm_halide_process_tile_with_exposure(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height, int32_t output_width, int32_t output_height,
    int32_t origin_x, int32_t origin_y, int32_t interior_left, int32_t interior_top,
    int32_t interior_width, int32_t interior_height,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, int32_t feature_mask, uint32_t seed, const float *additional_record_exposure) {
    return process_tile_output(
        input_r, input_g, input_b, output_r, output_g, output_b,
        width, height, output_width, output_height, origin_x, origin_y,
        interior_left, interior_top, interior_width, interior_height,
        configuration, exposure_lut, film_output_lut, paper_output_lut,
        lut_dimension, feature_mask, seed, additional_record_exposure, false);
}

extern "C" int32_t fotufilm_halide_process_region(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height, int32_t output_width, int32_t output_height,
    int32_t origin_x, int32_t origin_y, int32_t interior_left, int32_t interior_top,
    int32_t interior_width, int32_t interior_height,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, int32_t feature_mask, uint32_t seed, const float *additional_record_exposure) {
    // The compact CPU contract is combined film development with linear output.
    // Other stage/encoding variants must not silently run the Android full-film kernel.
    const int32_t unsupported = FOTUFILM_FRAME_NO_FILM | FOTUFILM_FRAME_DENSITY_IN
        | FOTUFILM_FRAME_DENSITY_OUT | FOTUFILM_FRAME_RECORD_EXPOSURE_IN
        | FOTUFILM_FRAME_LIGHT_OUT | FOTUFILM_FRAME_TEXTURE | FOTUFILM_FRAME_ENCODE_OUT
        | FOTUFILM_FRAME_OUTPUT_LINEAR | FOTUFILM_FRAME_OUTPUT_POWER | FOTUFILM_FRAME_OUTPUT_LOG;
    if (feature_mask & unsupported) return -1;
    return process_tile_output(
        input_r, input_g, input_b, output_r, output_g, output_b,
        width, height, output_width, output_height, origin_x, origin_y,
        interior_left, interior_top, interior_width, interior_height,
        configuration, exposure_lut, film_output_lut, paper_output_lut,
        lut_dimension, feature_mask, seed, additional_record_exposure, true);
}

extern "C" int32_t fotufilm_halide_gaussian(
    const float *input, float *output, int32_t width, int32_t height,
    float sigma, int32_t radius) {
    return translate_exceptions([&] {
        static GaussianPipeline pipeline;
        pipeline.run(input, output, width, height, sigma, radius);
    });
}

extern "C" int32_t fotufilm_halide_approximate_gaussian(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t radius) {
    return translate_exceptions([&] {
        static ApproximateGaussianPipeline pipeline;
        pipeline.run(input, output, width, height, radius);
    });
}

#else

extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_available(void) { return 0; }

extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_set_film_tiles(
    int32_t, const float *, int64_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_develop(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, const float *, const float *, int32_t, int32_t,
    uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_print(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, const float *, const float *, const float *, int32_t,
    int32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_process(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, const float *, const float *, const float *,
    const float *, int32_t, int32_t, uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_process_strip(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    const float *, const float *, const float *, const float *, int32_t,
    int32_t, uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_process_tile(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, int32_t, const float *, const float *, const float *, const float *,
    int32_t, int32_t, uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_process_tile_with_exposure(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, int32_t, const float *, const float *, const float *, const float *,
    int32_t, int32_t, uint32_t, const float *) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_process_region(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, int32_t, const float *, const float *, const float *, const float *,
    int32_t, int32_t, uint32_t, const float *) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_gaussian(
    const float *, float *, int32_t, int32_t, float, int32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_approximate_gaussian(
    const float *, float *, int32_t, int32_t, int32_t) { return -1; }

#endif
