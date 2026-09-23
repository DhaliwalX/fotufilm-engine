#if defined(FOTUFILM_HALIDE_ANDROID_AOT)

#include "fotufilm_halide_android_develop.h"
#include "fotufilm_halide_android_print.h"
#include "fotufilm_halide_android_print_reversal.h"
#include "fotufilm_halide_android_print_monochrome.h"
#include "fotufilm_halide_android_print_reversal_monochrome.h"
#include <HalideBuffer.h>

#include "FotufilmHalide.h"
#include "FotufilmResolvedFrameParams.h"
#include "Pipeline/FilmTileStore.h"

#include <algorithm>
#include <cstring>

using Halide::Runtime::Buffer;

namespace {

/// The film grain model's tiles, shared with the Vulkan shim, which keeps its own device copy.
using FilmTileStore = fotufilm::BasicFilmTileStore<Buffer<float>>;

constexpr int kLutDimension = 33;
constexpr int kLutValueCount = kLutDimension * kLutDimension * kLutDimension * 4;

/// Runs the develop kernel over one strip, unpacking the configuration the way the JIT host does.
int run_develop(const float *input_r, const float *input_g, const float *input_b,
                Buffer<float> &density, int32_t width, int32_t height,
                const float *configuration, const float *exposure_lut,
                int32_t feature_mask, uint32_t seed,
                int32_t origin_x, int32_t origin_y) {
    Buffer<float> red(const_cast<float *>(input_r), width, height);
    Buffer<float> green(const_cast<float *>(input_g), width, height);
    Buffer<float> blue(const_cast<float *>(input_b), width, height);
    Buffer<float> config(const_cast<float *>(configuration),
                         FOTUFILM_FRAME_CONFIGURATION_COUNT);
    Buffer<float> exposure(const_cast<float *>(exposure_lut), kLutValueCount);

    fotufilm::ResolvedFrameParams resolved(configuration, width, height, seed,
        (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0, origin_x, origin_y);
    // Standalone development returns a negative before the enlarger.
    resolved.print_mtf_radius = 0;
    const int32_t monochrome = (feature_mask & FOTUFILM_FRAME_MONOCHROME) != 0;
    bool film_on = false;
    Buffer<float> film_tiles = FilmTileStore::shared().tiles_for(configuration, film_on);

    return fotufilm_halide_android_develop(
        red, green, blue, config, exposure, width, height,
        resolved.mtf_sigma_0, resolved.mtf_sigma_1, resolved.mtf_sigma_2, resolved.mtf_luma_sigma,
        resolved.mtf_radius_0, resolved.mtf_radius_1, resolved.mtf_radius_2, resolved.mtf_luma_radius,
        resolved.halation_stride_0, resolved.halation_stride_1, resolved.halation_stride_2,
        resolved.halation_strided_radius_0, resolved.halation_strided_radius_1, resolved.halation_strided_radius_2,
        resolved.coupler_sigma, resolved.coupler_radius, resolved.adjacency_sigma, resolved.adjacency_radius,
        resolved.adjacency_secondary_sigma, resolved.adjacency_secondary_radius,
        resolved.fringe_sigma, resolved.fringe_radius,
        resolved.grain_sigma, resolved.grain_radius, resolved.grain_lambda, resolved.print_mtf_radius,
        seed, resolved.reversal, monochrome, origin_x, origin_y, feature_mask,
        film_tiles, film_on ? 1 : 0, density);
}

int run_print(Buffer<float> &density, Buffer<float> &result,
              const float *configuration, const float *film_lut,
              const float *paper_lut, int32_t feature_mask) {
    Buffer<float> config(const_cast<float *>(configuration),
                         FOTUFILM_FRAME_CONFIGURATION_COUNT);
    Buffer<float> film(const_cast<float *>(film_lut), kLutValueCount);
    Buffer<float> paper(const_cast<float *>(paper_lut), kLutValueCount);
    const bool reversal = (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0;
    const bool monochrome = (feature_mask & FOTUFILM_FRAME_MONOCHROME) != 0;
    if (reversal && monochrome) {
        return fotufilm_halide_android_print_reversal_monochrome(
            density, config, film, paper, result);
    }
    if (reversal) {
        return fotufilm_halide_android_print_reversal(
            density, config, film, paper, result);
    }
    if (monochrome) {
        return fotufilm_halide_android_print_monochrome(
            density, config, film, paper, result);
    }
    return fotufilm_halide_android_print(density, config, film, paper, result);
}

}

extern "C" int32_t fotufilm_halide_available(void) { return 1; }

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
    Buffer<float> density(width, height, 3);
    // The negative on its own: no enlarger images it. See the note on the reference entry point.
    const int32_t film_only = feature_mask & ~FOTUFILM_FRAME_PRINT_MTF;
    const int error = run_develop(input_r, input_g, input_b, density, width, height,
                                  configuration, exposure_lut, film_only, seed, 0, 0);
    if (error) return error;
    const int64_t count = static_cast<int64_t>(width) * height;
    std::memcpy(output_r, density.data(), count * sizeof(float));
    std::memcpy(output_g, density.data() + count, count * sizeof(float));
    std::memcpy(output_b, density.data() + count * 2, count * sizeof(float));
    return 0;
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
    Buffer<float> density(width, height, 3);
    const int64_t count = static_cast<int64_t>(width) * height;
    std::memcpy(density.data(), input_r, count * sizeof(float));
    std::memcpy(density.data() + count, input_g, count * sizeof(float));
    std::memcpy(density.data() + count * 2, input_b, count * sizeof(float));
    Buffer<float> result(width, height, 3);
    const int error = run_print(density, result, configuration, film_output_lut,
                                paper_output_lut, feature_mask);
    if (error) return error;
    std::memcpy(output_r, result.data(), count * sizeof(float));
    std::memcpy(output_g, result.data() + count, count * sizeof(float));
    std::memcpy(output_b, result.data() + count * 2, count * sizeof(float));
    return 0;
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
    Buffer<float> density(width, height, 3);
    int error = run_develop(input_r, input_g, input_b, density, width, height,
                            configuration, exposure_lut, feature_mask, seed,
                            origin_x, origin_y);
    if (error) return error;
    Buffer<float> result(interior_width, interior_height, 3);
    result.translate(0, interior_left);
    result.translate(1, interior_top);
    error = run_print(density, result, configuration, film_output_lut,
                      paper_output_lut, feature_mask);
    if (error) return error;
    float *destination[3] = {output_r, output_g, output_b};
    for (int channel = 0; channel < 3; ++channel) {
        for (int row = 0; row < interior_height; ++row) {
            const float *source = &result(interior_left, interior_top + row, channel);
            const int64_t target =
                static_cast<int64_t>(origin_y + interior_top + row) * output_width
                + origin_x + interior_left;
            std::memcpy(destination[channel] + target, source,
                        interior_width * sizeof(float));
        }
    }
    return 0;
}

#endif
