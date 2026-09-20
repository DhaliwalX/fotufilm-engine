#ifndef FOTUFILM_RESOLVED_FRAME_PARAMS_H
#define FOTUFILM_RESOLVED_FRAME_PARAMS_H

#include "FotufilmHalide.h"
#include <algorithm>

namespace fotufilm {

/// Host values shared by JIT parameter binding and AOT calls. No Halide compiler dependency.
struct ResolvedFrameParams {
    int32_t width, height;
    float mtf_sigma_0, mtf_sigma_1, mtf_sigma_2;
    int32_t mtf_radius_0, mtf_radius_1, mtf_radius_2;
    float mtf_luma_sigma;
    int32_t mtf_luma_radius;
    int32_t halation_stride_0, halation_stride_1, halation_stride_2;
    int32_t halation_strided_radius_0, halation_strided_radius_1,
                           halation_strided_radius_2;
    int32_t diffusion_stride_0, diffusion_stride_1, diffusion_stride_2;
    int32_t diffusion_strided_radius_0, diffusion_strided_radius_1,
                           diffusion_strided_radius_2;
    float coupler_sigma;
    int32_t coupler_radius;
    float adjacency_sigma;
    int32_t adjacency_radius;
    float adjacency_secondary_sigma;
    int32_t adjacency_secondary_radius;
    float fringe_sigma;
    int32_t fringe_radius;
    float grain_sigma;
    int32_t grain_radius;
    float grain_lambda;
    int32_t mottle_radius;
    float mottle_lambda;
    int32_t print_mtf_radius;
    uint32_t seed;
    int32_t reversal;
    int32_t origin_x, origin_y;
    int32_t halation_radius_0, halation_radius_1, halation_radius_2;

    ResolvedFrameParams(const float *configuration, int32_t width, int32_t height,
                        uint32_t seed, int32_t reversal, int32_t origin_x, int32_t origin_y) {
        auto sigma = [&](int offset) { return std::max(configuration[offset], 0.151f); };
        auto radius = [&](int offset) { return std::max(0, int(configuration[offset])); };
        this->width = width;
        this->height = height;
        mtf_sigma_0 = sigma(FOTUFILM_CONFIG_MTF_SIGMA);
        mtf_sigma_1 = sigma(FOTUFILM_CONFIG_MTF_SIGMA + 1);
        mtf_sigma_2 = sigma(FOTUFILM_CONFIG_MTF_SIGMA + 2);
        mtf_radius_0 = radius(FOTUFILM_CONFIG_MTF_RADIUS);
        mtf_radius_1 = radius(FOTUFILM_CONFIG_MTF_RADIUS + 1);
        mtf_radius_2 = radius(FOTUFILM_CONFIG_MTF_RADIUS + 2);
        mtf_luma_sigma = sigma(FOTUFILM_CONFIG_MTF_LUMA_SIGMA);
        mtf_luma_radius = std::max({
            0,
            int(configuration[FOTUFILM_CONFIG_MTF_LUMA_RADIUS]),
            int(configuration[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS]),
            int(configuration[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS + 1]),
            int(configuration[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS + 2]),
        });
        int32_t *halation_strides[3] = {
            &halation_stride_0, &halation_stride_1, &halation_stride_2};
        int32_t *halation_strided_radii[3] = {
            &halation_strided_radius_0, &halation_strided_radius_1,
            &halation_strided_radius_2};
        for (int scale = 0; scale < 3; ++scale) {
            const int32_t pixels = radius(FOTUFILM_CONFIG_HALATION_RADIUS + scale);
            const int32_t stride = fotufilm_halation_stride(pixels);
            *halation_strides[scale] = stride;
            *halation_strided_radii[scale] = fotufilm_halation_strided_radius(pixels, stride);
        }
        int32_t *diffusion_strides[3] = {
            &diffusion_stride_0, &diffusion_stride_1, &diffusion_stride_2};
        int32_t *diffusion_strided_radii[3] = {
            &diffusion_strided_radius_0, &diffusion_strided_radius_1,
            &diffusion_strided_radius_2};
        for (int scale = 0; scale < 3; ++scale) {
            const int32_t pixels = radius(FOTUFILM_CONFIG_DIFFUSION_RADIUS + scale);
            const int32_t stride = fotufilm_diffusion_stride(pixels);
            *diffusion_strides[scale] = stride;
            *diffusion_strided_radii[scale] = fotufilm_halation_strided_radius(pixels, stride);
        }
        coupler_sigma = sigma(FOTUFILM_CONFIG_COUPLER_SIGMA);
        coupler_radius = radius(FOTUFILM_CONFIG_COUPLER_RADIUS);
        adjacency_sigma = sigma(FOTUFILM_CONFIG_ADJACENCY_SIGMA);
        adjacency_radius = radius(FOTUFILM_CONFIG_ADJACENCY_RADIUS);
        adjacency_secondary_sigma = sigma(FOTUFILM_CONFIG_ADJACENCY_SECONDARY_SIGMA);
        adjacency_secondary_radius = radius(FOTUFILM_CONFIG_ADJACENCY_SECONDARY_RADIUS);
        fringe_sigma = sigma(FOTUFILM_CONFIG_CHROMATIC_FRINGE_SIGMA);
        fringe_radius = radius(FOTUFILM_CONFIG_CHROMATIC_FRINGE_RADIUS);
        grain_sigma = sigma(FOTUFILM_CONFIG_GRAIN_SIGMA);
        grain_radius = radius(FOTUFILM_CONFIG_GRAIN_RADIUS);
        grain_lambda = configuration[FOTUFILM_CONFIG_GRAIN_LAMBDA];
        mottle_radius = radius(FOTUFILM_CONFIG_MOTTLE_RADIUS);
        mottle_lambda = configuration[FOTUFILM_CONFIG_MOTTLE_LAMBDA];
        print_mtf_radius = radius(FOTUFILM_CONFIG_PRINT_MTF_RADIUS);
        this->seed = seed;
        this->reversal = reversal;
        this->origin_x = origin_x;
        this->origin_y = origin_y;
        halation_radius_0 = radius(FOTUFILM_CONFIG_HALATION_RADIUS);
        halation_radius_1 = radius(FOTUFILM_CONFIG_HALATION_RADIUS + 1);
        halation_radius_2 = radius(FOTUFILM_CONFIG_HALATION_RADIUS + 2);
    }
};

} // namespace fotufilm
#endif
