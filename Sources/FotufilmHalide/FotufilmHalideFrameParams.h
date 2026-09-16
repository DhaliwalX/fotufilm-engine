#ifndef FOTUFILM_HALIDE_FRAME_PARAMS_H
#define FOTUFILM_HALIDE_FRAME_PARAMS_H

#include "FotufilmHalide.h"
#include "FotufilmHalideGeometry.h"

#include <Halide.h>
#include <algorithm>
#include <string>

namespace fotufilm {

struct FrameParams {
    FrameParams(const std::string &prefix, const std::string &suffix)
        : width_(prefix + "width" + suffix), height_(prefix + "height" + suffix),
          mtf_sigma_0_(prefix + "mtf_sigma_0" + suffix),
          mtf_sigma_1_(prefix + "mtf_sigma_1" + suffix),
          mtf_sigma_2_(prefix + "mtf_sigma_2" + suffix),
          mtf_radius_0_(prefix + "mtf_radius_0" + suffix),
          mtf_radius_1_(prefix + "mtf_radius_1" + suffix),
          mtf_radius_2_(prefix + "mtf_radius_2" + suffix),
          mtf_luma_sigma_(prefix + "mtf_luma_sigma" + suffix),
          mtf_luma_radius_(prefix + "mtf_luma_radius" + suffix),
          halation_stride_0_(prefix + "halation_stride_0" + suffix),
          halation_stride_1_(prefix + "halation_stride_1" + suffix),
          halation_stride_2_(prefix + "halation_stride_2" + suffix),
          halation_strided_radius_0_(prefix + "halation_strided_radius_0" + suffix),
          halation_strided_radius_1_(prefix + "halation_strided_radius_1" + suffix),
          halation_strided_radius_2_(prefix + "halation_strided_radius_2" + suffix),
          diffusion_stride_0_(prefix + "diffusion_stride_0" + suffix),
          diffusion_stride_1_(prefix + "diffusion_stride_1" + suffix),
          diffusion_stride_2_(prefix + "diffusion_stride_2" + suffix),
          diffusion_strided_radius_0_(prefix + "diffusion_strided_radius_0" + suffix),
          diffusion_strided_radius_1_(prefix + "diffusion_strided_radius_1" + suffix),
          diffusion_strided_radius_2_(prefix + "diffusion_strided_radius_2" + suffix),
          coupler_sigma_(prefix + "coupler_sigma" + suffix),
          coupler_radius_(prefix + "coupler_radius" + suffix),
          adjacency_sigma_(prefix + "adjacency_sigma" + suffix),
          adjacency_radius_(prefix + "adjacency_radius" + suffix),
          adjacency_secondary_sigma_(prefix + "adjacency_secondary_sigma" + suffix),
          adjacency_secondary_radius_(prefix + "adjacency_secondary_radius" + suffix),
          fringe_sigma_(prefix + "fringe_sigma" + suffix),
          fringe_radius_(prefix + "fringe_radius" + suffix),
          grain_sigma_(prefix + "grain_sigma" + suffix),
          grain_radius_(prefix + "grain_radius" + suffix),
          grain_lambda_(prefix + "grain_lambda" + suffix),
          mottle_radius_(prefix + "mottle_radius" + suffix),
          mottle_lambda_(prefix + "mottle_lambda" + suffix),
          print_mtf_radius_(prefix + "print_mtf_radius" + suffix),
          seed_(prefix + "seed" + suffix),
          reversal_(prefix + "reversal" + suffix),
          origin_x_(prefix + "origin_x" + suffix),
          origin_y_(prefix + "origin_y" + suffix) {}

    void set_frame(const float *configuration, int32_t width, int32_t height,
                   uint32_t seed, int32_t reversal, int32_t origin_x, int32_t origin_y) {
        auto sigma = [&](int offset) { return std::max(configuration[offset], 0.151f); };
        auto radius = [&](int offset) { return std::max(0, int(configuration[offset])); };
        width_.set(width);
        height_.set(height);
        mtf_sigma_0_.set(sigma(FOTUFILM_CONFIG_MTF_SIGMA));
        mtf_sigma_1_.set(sigma(FOTUFILM_CONFIG_MTF_SIGMA + 1));
        mtf_sigma_2_.set(sigma(FOTUFILM_CONFIG_MTF_SIGMA + 2));
        mtf_radius_0_.set(radius(FOTUFILM_CONFIG_MTF_RADIUS));
        mtf_radius_1_.set(radius(FOTUFILM_CONFIG_MTF_RADIUS + 1));
        mtf_radius_2_.set(radius(FOTUFILM_CONFIG_MTF_RADIUS + 2));
        mtf_luma_sigma_.set(sigma(FOTUFILM_CONFIG_MTF_LUMA_SIGMA));
        mtf_luma_radius_.set(std::max({
            0,
            int(configuration[FOTUFILM_CONFIG_MTF_LUMA_RADIUS]),
            int(configuration[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS]),
            int(configuration[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS + 1]),
            int(configuration[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS + 2]),
        }));
        Halide::Param<int32_t> *halation_strides[3] = {
            &halation_stride_0_, &halation_stride_1_, &halation_stride_2_};
        Halide::Param<int32_t> *halation_strided_radii[3] = {
            &halation_strided_radius_0_, &halation_strided_radius_1_,
            &halation_strided_radius_2_};
        for (int scale = 0; scale < 3; ++scale) {
            const int32_t pixels = radius(FOTUFILM_CONFIG_HALATION_RADIUS + scale);
            const int32_t stride = fotufilm_halation_stride(pixels);
            halation_strides[scale]->set(stride);
            halation_strided_radii[scale]->set(
                fotufilm_halation_strided_radius(pixels, stride));
        }
        Halide::Param<int32_t> *diffusion_strides[3] = {
            &diffusion_stride_0_, &diffusion_stride_1_, &diffusion_stride_2_};
        Halide::Param<int32_t> *diffusion_strided_radii[3] = {
            &diffusion_strided_radius_0_, &diffusion_strided_radius_1_,
            &diffusion_strided_radius_2_};
        for (int scale = 0; scale < 3; ++scale) {
            const int32_t pixels = radius(FOTUFILM_CONFIG_DIFFUSION_RADIUS + scale);
            const int32_t stride = fotufilm_diffusion_stride(pixels);
            diffusion_strides[scale]->set(stride);
            diffusion_strided_radii[scale]->set(
                fotufilm_halation_strided_radius(pixels, stride));
        }
        coupler_sigma_.set(sigma(FOTUFILM_CONFIG_COUPLER_SIGMA));
        coupler_radius_.set(radius(FOTUFILM_CONFIG_COUPLER_RADIUS));
        adjacency_sigma_.set(sigma(FOTUFILM_CONFIG_ADJACENCY_SIGMA));
        adjacency_radius_.set(radius(FOTUFILM_CONFIG_ADJACENCY_RADIUS));
        adjacency_secondary_sigma_.set(sigma(FOTUFILM_CONFIG_ADJACENCY_SECONDARY_SIGMA));
        adjacency_secondary_radius_.set(radius(FOTUFILM_CONFIG_ADJACENCY_SECONDARY_RADIUS));
        fringe_sigma_.set(sigma(FOTUFILM_CONFIG_CHROMATIC_FRINGE_SIGMA));
        fringe_radius_.set(radius(FOTUFILM_CONFIG_CHROMATIC_FRINGE_RADIUS));
        grain_sigma_.set(sigma(FOTUFILM_CONFIG_GRAIN_SIGMA));
        grain_radius_.set(radius(FOTUFILM_CONFIG_GRAIN_RADIUS));
        grain_lambda_.set(configuration[FOTUFILM_CONFIG_GRAIN_LAMBDA]);
        mottle_radius_.set(radius(FOTUFILM_CONFIG_MOTTLE_RADIUS));
        mottle_lambda_.set(configuration[FOTUFILM_CONFIG_MOTTLE_LAMBDA]);
        print_mtf_radius_.set(radius(FOTUFILM_CONFIG_PRINT_MTF_RADIUS));
        seed_.set(seed);
        reversal_.set(reversal);
        origin_x_.set(origin_x);
        origin_y_.set(origin_y);
    }

    Halide::Param<int32_t> width_, height_;
    Halide::Param<float> mtf_sigma_0_, mtf_sigma_1_, mtf_sigma_2_;
    Halide::Param<int32_t> mtf_radius_0_, mtf_radius_1_, mtf_radius_2_;
    Halide::Param<float> mtf_luma_sigma_;
    Halide::Param<int32_t> mtf_luma_radius_;
    Halide::Param<int32_t> halation_stride_0_, halation_stride_1_, halation_stride_2_;
    Halide::Param<int32_t> halation_strided_radius_0_, halation_strided_radius_1_,
                           halation_strided_radius_2_;
    /// Referenced only when FOTUFILM_FRAME_DIFFUSION is set, which is what keeps them out of the
    /// CPU AOT argument list and the pre-generated libraries' signatures unchanged.
    Halide::Param<int32_t> diffusion_stride_0_, diffusion_stride_1_, diffusion_stride_2_;
    Halide::Param<int32_t> diffusion_strided_radius_0_, diffusion_strided_radius_1_,
                           diffusion_strided_radius_2_;
    Halide::Param<float> coupler_sigma_;
    Halide::Param<int32_t> coupler_radius_;
    Halide::Param<float> adjacency_sigma_;
    Halide::Param<int32_t> adjacency_radius_;
    Halide::Param<float> adjacency_secondary_sigma_;
    Halide::Param<int32_t> adjacency_secondary_radius_;
    Halide::Param<float> fringe_sigma_;
    Halide::Param<int32_t> fringe_radius_;
    Halide::Param<float> grain_sigma_;
    Halide::Param<int32_t> grain_radius_;
    Halide::Param<float> grain_lambda_;
    Halide::Param<int32_t> mottle_radius_;
    Halide::Param<float> mottle_lambda_;
    Halide::Param<int32_t> print_mtf_radius_;
    Halide::Param<uint32_t> seed_;
    Halide::Param<int32_t> reversal_;
    /// Where this call's pixels sit in the whole frame.
    Halide::Param<int32_t> origin_x_, origin_y_;
};

}

#endif
