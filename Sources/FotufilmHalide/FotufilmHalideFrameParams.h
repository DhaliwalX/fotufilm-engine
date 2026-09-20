#ifndef FOTUFILM_HALIDE_FRAME_PARAMS_H
#define FOTUFILM_HALIDE_FRAME_PARAMS_H

#include "FotufilmHalide.h"
#include "FotufilmResolvedFrameParams.h"

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
        set_frame(ResolvedFrameParams(configuration, width, height, seed, reversal,
                                      origin_x, origin_y));
    }

    void set_frame(const ResolvedFrameParams &frame) {
        width_.set(frame.width);
        height_.set(frame.height);
        mtf_sigma_0_.set(frame.mtf_sigma_0);
        mtf_sigma_1_.set(frame.mtf_sigma_1);
        mtf_sigma_2_.set(frame.mtf_sigma_2);
        mtf_radius_0_.set(frame.mtf_radius_0);
        mtf_radius_1_.set(frame.mtf_radius_1);
        mtf_radius_2_.set(frame.mtf_radius_2);
        mtf_luma_sigma_.set(frame.mtf_luma_sigma);
        mtf_luma_radius_.set(frame.mtf_luma_radius);
        halation_stride_0_.set(frame.halation_stride_0);
        halation_stride_1_.set(frame.halation_stride_1);
        halation_stride_2_.set(frame.halation_stride_2);
        halation_strided_radius_0_.set(frame.halation_strided_radius_0);
        halation_strided_radius_1_.set(frame.halation_strided_radius_1);
        halation_strided_radius_2_.set(frame.halation_strided_radius_2);
        diffusion_stride_0_.set(frame.diffusion_stride_0);
        diffusion_stride_1_.set(frame.diffusion_stride_1);
        diffusion_stride_2_.set(frame.diffusion_stride_2);
        diffusion_strided_radius_0_.set(frame.diffusion_strided_radius_0);
        diffusion_strided_radius_1_.set(frame.diffusion_strided_radius_1);
        diffusion_strided_radius_2_.set(frame.diffusion_strided_radius_2);
        coupler_sigma_.set(frame.coupler_sigma);
        coupler_radius_.set(frame.coupler_radius);
        adjacency_sigma_.set(frame.adjacency_sigma);
        adjacency_radius_.set(frame.adjacency_radius);
        adjacency_secondary_sigma_.set(frame.adjacency_secondary_sigma);
        adjacency_secondary_radius_.set(frame.adjacency_secondary_radius);
        fringe_sigma_.set(frame.fringe_sigma);
        fringe_radius_.set(frame.fringe_radius);
        grain_sigma_.set(frame.grain_sigma);
        grain_radius_.set(frame.grain_radius);
        grain_lambda_.set(frame.grain_lambda);
        mottle_radius_.set(frame.mottle_radius);
        mottle_lambda_.set(frame.mottle_lambda);
        print_mtf_radius_.set(frame.print_mtf_radius);
        seed_.set(frame.seed);
        reversal_.set(frame.reversal);
        origin_x_.set(frame.origin_x);
        origin_y_.set(frame.origin_y);
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
