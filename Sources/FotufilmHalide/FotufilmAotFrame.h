// What every ahead-of-time shim shares, whatever device its kernels were generated for: the
// signature all frame variants have, choosing the variant with the fewest extra compiled stages,
// and the argument list a frame passes (FotufilmHalideIOS.cpp for Metal, FotufilmHalideLinux.cpp
// for CUDA and Vulkan).
#pragma once

#include <HalideRuntime.h>

#include "FotufilmAotVariants.h"
#include "FotufilmHalide.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <set>
#include <vector>

namespace fotufilm::aot {

/// The shape every generated variant shares: the u8 and float libraries differ only in the element
/// type inside the buffers, which does not reach the signature.
#define FOTUFILM_AOT_FRAME_SIGNATURE \
    halide_buffer_t *, halide_buffer_t *, halide_buffer_t *, halide_buffer_t *, \
    halide_buffer_t *, int32_t, int32_t, float, float, float, float, int32_t, \
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, float, int32_t, \
    float, int32_t, float, int32_t, float, int32_t, float, int32_t, float, float, int32_t, int32_t, \
    uint32_t, int32_t, int32_t, \
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, \
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, \
    halide_buffer_t *, int32_t, halide_buffer_t *
using FrameFunction = int (*)(FOTUFILM_AOT_FRAME_SIGNATURE);

struct AotVariant {
    int32_t mask;
    FrameFunction function;
    const char *name;
};

/// Select a compatible generated variant with the fewest extra compiled stages.
inline FrameFunction select_variant(const AotVariant *variants, size_t count,
                                    int32_t feature_mask) {
    const AotVariant *const end = variants + count;
    const int32_t wanted = feature_mask & FOTUFILM_AOT_VARIANT_BITS;
    const int32_t exact_bits = FOTUFILM_VARIANT_EXACT_BITS;
    // Diagnostic: choose another compatible variant to compare schedules. Extra compiled
    // stages are bypassed by the request's runtime gates, preserving its requested image.
    static const int wanted_rank = [] {
        const char *env = getenv("FOTUFILM_VARIANT_RANK");
        return env ? atoi(env) : -1;
    }();
    if (wanted_rank >= 0) {
        std::vector<const AotVariant *> acceptable;
        for (const AotVariant *variant = variants; variant != end; ++variant) {
            if ((variant->mask & exact_bits) != (wanted & exact_bits)) continue;
            if ((variant->mask & wanted) != wanted) continue;
            acceptable.push_back(variant);
        }
        std::stable_sort(acceptable.begin(), acceptable.end(),
                         [&](const AotVariant *a, const AotVariant *b) {
                             return __builtin_popcount((unsigned)(a->mask & ~wanted))
                                  < __builtin_popcount((unsigned)(b->mask & ~wanted));
                         });
        if (!acceptable.empty()) {
            const AotVariant *picked =
                acceptable[std::min<size_t>(wanted_rank, acceptable.size() - 1)];
            std::fprintf(stderr,
                         "Fotufilm variant rank %d of %zu: %s (+%d bits)\n",
                         wanted_rank, acceptable.size(), picked->name,
                         __builtin_popcount((unsigned)(picked->mask & ~wanted)));
            return picked->function;
        }
    }
    const AotVariant *best = nullptr;
    int best_extra = 0;
    for (const AotVariant *variant = variants; variant != end; ++variant) {
        if ((variant->mask & exact_bits) != (wanted & exact_bits)) continue;
        if ((variant->mask & wanted) != wanted) continue;
        const int extra = __builtin_popcount(
            (unsigned)(variant->mask & ~wanted));
        if (!best || extra < best_extra) {
            best = variant;
            best_extra = extra;
            if (extra == 0) break;
        }
    }
    // `FOTUFILM_TRACE_VARIANT=1` names what a render actually ran and how far the served variant
    // overshot what it asked for. The extra bits are stages compiled in and bypassed at run
    // time. It is printed once per distinct request, not once per frame.
    static std::set<int32_t> traced;
    static const bool tracing = [] {
        const char *env = getenv("FOTUFILM_TRACE_VARIANT");
        return env && atoi(env) != 0;
    }();
    if (tracing && best && traced.insert(wanted).second) {
        std::fprintf(stderr,
                     "Fotufilm variant: wanted 0x%x -> %s (0x%x), %d extra bit(s) 0x%x\n",
                     wanted, best->name, best->mask, best_extra,
                     (unsigned)(best->mask & ~wanted));
    }
    return best ? best->function : nullptr;
}

/// The arguments a frame variant takes, before its output: the frame's buffers, the resolved
/// geometry `frame` (FotufilmResolvedFrameParams.h), and the film grain tiles.
#define FOTUFILM_AOT_FRAME_ARGUMENTS(in, cfg, exposure, film, paper, width, height, frame, seed, \
                                     origin_x, origin_y, feature_mask, configuration, tiles,     \
                                     film_on)                                                    \
    in, cfg, exposure, film, paper, width, height, frame.mtf_sigma_0, frame.mtf_sigma_1, \
    frame.mtf_sigma_2, frame.mtf_luma_sigma, frame.mtf_radius_0, frame.mtf_radius_1, \
    frame.mtf_radius_2, frame.mtf_luma_radius, frame.halation_radius_0, frame.halation_radius_1, \
    frame.halation_radius_2, frame.coupler_sigma, frame.coupler_radius, frame.adjacency_sigma, \
    frame.adjacency_radius, frame.adjacency_secondary_sigma, frame.adjacency_secondary_radius, \
    frame.fringe_sigma, frame.fringe_radius, frame.grain_sigma, frame.grain_radius, \
    frame.grain_lambda, frame.mottle_lambda, frame.mottle_radius, frame.print_mtf_radius, seed, \
    frame.reversal, origin_x, origin_y, frame.halation_stride_0, frame.halation_stride_1, \
    frame.halation_stride_2, frame.halation_strided_radius_0, frame.halation_strided_radius_1, \
    frame.halation_strided_radius_2, frame.diffusion_stride_0, frame.diffusion_stride_1, \
    frame.diffusion_stride_2, frame.diffusion_strided_radius_0, frame.diffusion_strided_radius_1, \
    frame.diffusion_strided_radius_2, feature_mask, fotufilm_byte_basis(configuration), \
    tiles, film_on

}  // namespace fotufilm::aot
