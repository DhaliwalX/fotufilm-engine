#pragma once
#include "fixture.h"
#include "../../Sources/FotufilmHalide/FotufilmResolvedFrameParams.h"
#include "vk_color.h"
#include "vk_plain.h"
#include "vk_mono.h"
#include "vk_annular.h"
#include "vk_print.h"
inline int render_gpu(Fixture &f, Buffer<float> &in, Buffer<float> &out,
                      int feature_mask, int origin_x, int origin_y) {
    int width=in.width(), height=in.height();
    auto configuration=f.config.data(); uint32_t seed=f.seed;
    Buffer<float> config(configuration, int(f.config.size()));
    Buffer<float> exposure(f.exposure.data(), int(f.exposure.size()));
    Buffer<float> film(f.film.data(), int(f.film.size()));
    Buffer<float> paper(f.paper.data(), int(f.paper.size()));
    in.set_host_dirty(); config.set_host_dirty();
    exposure.set_host_dirty(); film.set_host_dirty(); paper.set_host_dirty();
    // The parity fixtures carry no film grain tiles: the one-float stand-in with the model off.
    Buffer<float> film_tiles(1, 1, 1);
    film_tiles(0, 0, 0) = 0.0f;
    film_tiles.set_host_dirty();
    const fotufilm::ResolvedFrameParams resolved(configuration, width, height, seed,
        (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0, origin_x, origin_y);
#define FOTUFILM_GPU_ARGUMENTS \
    in, config, exposure, film, paper, width, \
    height, resolved.mtf_sigma_0, resolved.mtf_sigma_1, resolved.mtf_sigma_2, \
    resolved.mtf_luma_sigma, resolved.mtf_radius_0, resolved.mtf_radius_1, resolved.mtf_radius_2, \
    resolved.mtf_luma_radius, resolved.halation_radius_0, resolved.halation_radius_1, \
    resolved.halation_radius_2, resolved.coupler_sigma, resolved.coupler_radius, \
    resolved.adjacency_sigma, resolved.adjacency_radius, resolved.adjacency_secondary_sigma, \
    resolved.adjacency_secondary_radius, resolved.fringe_sigma, resolved.fringe_radius, \
    resolved.grain_sigma, resolved.grain_radius, resolved.grain_lambda, resolved.mottle_lambda, \
    resolved.mottle_radius, resolved.print_mtf_radius, seed, resolved.reversal, origin_x, origin_y, \
    resolved.halation_stride_0, resolved.halation_stride_1, resolved.halation_stride_2, \
    resolved.halation_strided_radius_0, resolved.halation_strided_radius_1, \
    resolved.halation_strided_radius_2, resolved.diffusion_stride_0, resolved.diffusion_stride_1, \
    resolved.diffusion_stride_2, resolved.diffusion_strided_radius_0, \
    resolved.diffusion_strided_radius_1, resolved.diffusion_strided_radius_2, feature_mask, \
    fotufilm_byte_basis(configuration), film_tiles, 0, out

    auto fn = feature_mask & FOTUFILM_FRAME_NO_FILM ? vk_plain
        : feature_mask & FOTUFILM_FRAME_DENSITY_IN ? vk_print
        : feature_mask & FOTUFILM_FRAME_MONOCHROME ? vk_mono
        : feature_mask & FOTUFILM_FRAME_HALATION_ANNULAR ? vk_annular : vk_color;
    int status = fn(FOTUFILM_GPU_ARGUMENTS);
    if (!status) status = out.copy_to_host();
    return status;
#undef FOTUFILM_GPU_ARGUMENTS
}
