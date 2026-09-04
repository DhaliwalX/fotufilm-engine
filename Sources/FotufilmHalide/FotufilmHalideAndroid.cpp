#if defined(FOTUFILM_HALIDE_ANDROID_AOT)

#include "fotufilm_halide_android_develop.h"
#include "fotufilm_halide_android_print.h"
#include "fotufilm_halide_android_print_reversal.h"
#include "fotufilm_halide_android_print_monochrome.h"
#include "fotufilm_halide_android_print_reversal_monochrome.h"
#include <HalideBuffer.h>

#include "FotufilmHalide.h"

#include <algorithm>
#include <cstring>

using Halide::Runtime::Buffer;

namespace {

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

    const float sigma0 = std::max(configuration[FOTUFILM_CONFIG_MTF_SIGMA], 0.151f);
    const float sigma1 = std::max(configuration[FOTUFILM_CONFIG_MTF_SIGMA + 1], 0.151f);
    const float sigma2 = std::max(configuration[FOTUFILM_CONFIG_MTF_SIGMA + 2], 0.151f);
    const int32_t radius0 = std::max(0, int32_t(configuration[FOTUFILM_CONFIG_MTF_RADIUS]));
    const int32_t radius1 = std::max(0, int32_t(configuration[FOTUFILM_CONFIG_MTF_RADIUS + 1]));
    const int32_t radius2 = std::max(0, int32_t(configuration[FOTUFILM_CONFIG_MTF_RADIUS + 2]));
    const float luma_sigma = std::max(configuration[FOTUFILM_CONFIG_MTF_LUMA_SIGMA], 0.151f);
    const int32_t luma_radius = std::max({
        int32_t(0),
        int32_t(configuration[FOTUFILM_CONFIG_MTF_LUMA_RADIUS]),
        int32_t(configuration[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS]),
        int32_t(configuration[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS + 1]),
        int32_t(configuration[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS + 2]),
    });
    const float coupler_sigma = std::max(configuration[FOTUFILM_CONFIG_COUPLER_SIGMA], 0.151f);
    const int32_t coupler_radius =
        std::max(0, int32_t(configuration[FOTUFILM_CONFIG_COUPLER_RADIUS]));
    const float adjacency_sigma =
        std::max(configuration[FOTUFILM_CONFIG_ADJACENCY_SIGMA], 0.151f);
    const int32_t adjacency_radius =
        std::max(0, int32_t(configuration[FOTUFILM_CONFIG_ADJACENCY_RADIUS]));
    const float grain_sigma = std::max(configuration[FOTUFILM_CONFIG_GRAIN_SIGMA], 0.151f);
    const int32_t grain_radius =
        std::max(0, int32_t(configuration[FOTUFILM_CONFIG_GRAIN_RADIUS]));
    const float grain_lambda = configuration[FOTUFILM_CONFIG_GRAIN_LAMBDA];
    // The standalone develop stage returns the negative itself, which no enlarger has imaged
    // yet, so the radius is zero here whatever the paper asks for. `fotufilm_halide_develop` clears
    // the feature bit for the same reason.
    const int32_t print_mtf_radius = 0;
    const int32_t reversal = (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0;
    const int32_t monochrome = (feature_mask & FOTUFILM_FRAME_MONOCHROME) != 0 ? 1 : 0;

    int32_t stride[3], strided_radius[3];
    for (int scale = 0; scale < 3; ++scale) {
        const int32_t radius =
            std::max(0, int32_t(configuration[FOTUFILM_CONFIG_HALATION_RADIUS + scale]));
        stride[scale] = fotufilm_halation_stride(radius);
        strided_radius[scale] = fotufilm_halation_strided_radius(radius, stride[scale]);
    }

    return fotufilm_halide_android_develop(
        red, green, blue, config, exposure, width, height,
        sigma0, sigma1, sigma2, luma_sigma,
        radius0, radius1, radius2, luma_radius,
        stride[0], stride[1], stride[2],
        strided_radius[0], strided_radius[1], strided_radius[2],
        coupler_sigma, coupler_radius, adjacency_sigma, adjacency_radius,
        grain_sigma, grain_radius, grain_lambda, print_mtf_radius,
        seed, reversal, monochrome, origin_x, origin_y, density);
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
    if (!input_r || !input_g || !input_b || !output_r || !output_g || !output_b ||
        !configuration || !exposure_lut || !film_output_lut ||
        !paper_output_lut || width <= 0 || height <= 0 ||
        output_width < width || interior_top < 0 || interior_height < 0 ||
        interior_top + interior_height > height ||
        lut_dimension != kLutDimension) return -1;
    Buffer<float> density(width, height, 3);
    int error = run_develop(input_r, input_g, input_b, density, width, height,
                            configuration, exposure_lut, feature_mask, seed,
                            origin_x, origin_y);
    if (error) return error;
    Buffer<float> result(width, interior_height, 3);
    result.translate(1, interior_top);
    error = run_print(density, result, configuration, film_output_lut,
                      paper_output_lut, feature_mask);
    if (error) return error;
    const int64_t strip_plane = static_cast<int64_t>(width) * interior_height;
    const int64_t frame_plane = static_cast<int64_t>(output_width) * output_height;
    float *destination[3] = {output_r, output_g, output_b};
    for (int channel = 0; channel < 3; ++channel) {
        for (int row = 0; row < interior_height; ++row) {
            const float *source = result.data() + channel * strip_plane
                + static_cast<int64_t>(row) * width;
            const int64_t target =
                static_cast<int64_t>(origin_y + interior_top + row) * output_width
                + origin_x;
            if (target + width > frame_plane) break;
            std::memcpy(destination[channel] + target, source,
                        width * sizeof(float));
        }
    }
    return 0;
}

#endif
