#ifndef FOTUFILM_HALIDE_GEOMETRY_H
#define FOTUFILM_HALIDE_GEOMETRY_H

#include <algorithm>
#include <cstdint>

namespace fotufilm {

// Shared by Halide expressions and the AOT host's storage-footprint check.
template<typename Scalar, typename Select>
auto gaussian_grid_stride(Scalar sigma, Select choose) {
    return choose(sigma >= 8.0f, 8,
                  choose(sigma >= 4.0f, 4, choose(sigma >= 2.0f, 2, 1)));
}

template<typename Integer, typename Maximum>
auto gaussian_grid_radius(Integer radius, Integer stride, Maximum maximum) {
    return maximum((radius + stride - 1) / stride, 1);
}

constexpr int kTripleBoxPasses = 3;
constexpr int kWindowRows = 256;
// Frames shorter than two windows develop whole.
constexpr int kWindowMinimumHeight = 2 * kWindowRows;
// A row-window stage stores its window's rows and the apron its consumers read, recomputing the
// apron for every window, so a window costs more the further the frame's stages reach. Measured
// at 4K on an M4 Pro across every film, the windows develop a frame 6-24% faster than the
// whole-frame graph up to a reach of 179 pixels, and 2-8% slower from 187.
constexpr int kWindowMaximumReach = 180;

inline int64_t resampled_grid_reach(int64_t radius, int64_t stride) {
    // At stride 1 the zero-weight upper bilinear neighbour is still read.
    // Otherwise reserve two grid cells for box alignment and interpolation.
    return stride == 1 ? radius + 1 : stride * (radius + 2);
}

inline int64_t gaussian_grid_reach(float sigma, int32_t radius) {
    const int64_t stride = gaussian_grid_stride(sigma,
        [](bool condition, int yes, int no) { return condition ? yes : no; });
    const int64_t grid_radius = gaussian_grid_radius(int64_t(radius), stride,
        [](int64_t a, int64_t b) { return std::max(a, b); });
    return resampled_grid_reach(grid_radius, stride);
}

}  // namespace fotufilm
#endif
