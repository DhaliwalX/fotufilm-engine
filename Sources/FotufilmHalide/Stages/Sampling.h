#ifndef FOTUFILM_HALIDE_STAGES_SAMPLING_H
#define FOTUFILM_HALIDE_STAGES_SAMPLING_H

#include "FotufilmHalide.h"

#include <Halide.h>
#include <cmath>

namespace fotufilm {

constexpr int kLutDimension = 33;
constexpr int kLutValueCount = kLutDimension * kLutDimension * kLutDimension * 4;

/// Bilinear sampling shared by the CPU and GPU halation schedules.
template<typename Sample>
inline Halide::Expr bilinear_sample(Sample sample, Halide::Expr px, Halide::Expr py,
                                    bool separate_weights = false) {
    using Halide::Expr;
    Expr x0 = Halide::cast<int32_t>(Halide::floor(px));
    Expr y0 = Halide::cast<int32_t>(Halide::floor(py));
    Expr fx = px - Halide::floor(px);
    Expr fy = py - Halide::floor(py);
    if (separate_weights) {
        // The reference CPU's decimated grids round each of the four weighted terms.
        Expr w00 = (1.0f - fx) * (1.0f - fy), w01 = (1.0f - fx) * fy;
        Expr w10 = fx * (1.0f - fy), w11 = fx * fy;
        return w00 * sample(x0, y0) + w01 * sample(x0, y0 + 1)
            + w10 * sample(x0 + 1, y0) + w11 * sample(x0 + 1, y0 + 1);
    }
    return (1.0f - fx) * ((1.0f - fy) * sample(x0, y0)
                          + fy * sample(x0, y0 + 1))
        + fx * ((1.0f - fy) * sample(x0 + 1, y0)
                + fy * sample(x0 + 1, y0 + 1));
}

/// Smooth bicubic sampling using C2-continuous cubic B-spline weights.
/// Evaluates a separable 4x4 grid of samples around (floor(px), floor(py)).
/// Guarantees strictly non-negative weights (no ringing or negative exposure overshoot),
/// partition of unity (sum = 1), and C2 continuity.
template<typename Sample>
inline Halide::Expr bicubic_sample(Sample sample, Halide::Expr px, Halide::Expr py) {
    using Halide::Expr;
    Expr x0 = Halide::cast<int32_t>(Halide::floor(px));
    Expr y0 = Halide::cast<int32_t>(Halide::floor(py));
    Expr fx = px - Halide::floor(px);
    Expr fy = py - Halide::floor(py);

    Expr one_minus_fx = 1.0f - fx;
    Expr fx2 = fx * fx;
    Expr fx3 = fx2 * fx;
    Expr wx0 = (1.0f / 6.0f) * (one_minus_fx * one_minus_fx * one_minus_fx);
    Expr wx1 = (1.0f / 6.0f) * (3.0f * fx3 - 6.0f * fx2 + 4.0f);
    Expr wx2 = (1.0f / 6.0f) * (-3.0f * fx3 + 3.0f * fx2 + 3.0f * fx + 1.0f);
    Expr wx3 = (1.0f / 6.0f) * fx3;

    Expr one_minus_fy = 1.0f - fy;
    Expr fy2 = fy * fy;
    Expr fy3 = fy2 * fy;
    Expr wy0 = (1.0f / 6.0f) * (one_minus_fy * one_minus_fy * one_minus_fy);
    Expr wy1 = (1.0f / 6.0f) * (3.0f * fy3 - 6.0f * fy2 + 4.0f);
    Expr wy2 = (1.0f / 6.0f) * (-3.0f * fy3 + 3.0f * fy2 + 3.0f * fy + 1.0f);
    Expr wy3 = (1.0f / 6.0f) * fy3;

    Expr row0 = wx0 * sample(x0 - 1, y0 - 1) + wx1 * sample(x0, y0 - 1) + wx2 * sample(x0 + 1, y0 - 1) + wx3 * sample(x0 + 2, y0 - 1);
    Expr row1 = wx0 * sample(x0 - 1, y0)     + wx1 * sample(x0, y0)     + wx2 * sample(x0 + 1, y0)     + wx3 * sample(x0 + 2, y0);
    Expr row2 = wx0 * sample(x0 - 1, y0 + 1) + wx1 * sample(x0, y0 + 1) + wx2 * sample(x0 + 1, y0 + 1) + wx3 * sample(x0 + 2, y0 + 1);
    Expr row3 = wx0 * sample(x0 - 1, y0 + 2) + wx1 * sample(x0, y0 + 2) + wx2 * sample(x0 + 1, y0 + 2) + wx3 * sample(x0 + 2, y0 + 2);

    return wy0 * row0 + wy1 * row1 + wy2 * row2 + wy3 * row3;
}

/// A positive normalized annulus. Sixteen directions keep the critical-angle ring round at the
/// smallest radius where it is visible; the Gaussian field underneath supplies its measured
/// thickness. Radius zero selects the center sample exactly for AOT variants serving legacy packs.
template<typename Sample>
inline Halide::Expr annular_sample(Sample sample, Halide::Expr px, Halide::Expr py,
                                   Halide::Expr radius) {
    using Halide::Expr;
    Halide::RDom direction(0, 16);
    Expr dx = Halide::mux(direction.x, {
         1.000000000f,  0.923879533f,  0.707106781f,  0.382683432f,
         0.000000000f, -0.382683432f, -0.707106781f, -0.923879533f,
        -1.000000000f, -0.923879533f, -0.707106781f, -0.382683432f,
         0.000000000f,  0.382683432f,  0.707106781f,  0.923879533f,
    });
    Expr dy = Halide::mux(direction.x, {
         0.000000000f,  0.382683432f,  0.707106781f,  0.923879533f,
         1.000000000f,  0.923879533f,  0.707106781f,  0.382683432f,
         0.000000000f, -0.382683432f, -0.707106781f, -0.923879533f,
        -1.000000000f, -0.923879533f, -0.707106781f, -0.382683432f,
    });
    // Keep the direction walk as an inline reduction. Expanding all sixteen samples in C++
    // multiplies Halide's generated IR and first-use JIT cost. The unroll factor is also a
    // *shipping* constraint, not only a scheduling one: the AOT kernels embed their Metal as
    // source text in the app executable, the ring body is repeated once per unrolled lane in
    // every one of the ~319 variants, and at 8 lanes that put the executable at 536 MB —
    // past the 500 MB ceiling App Store Connect enforces on a single executable (ITMS-90122).
    // Two lanes keep a pair of independent samples in flight and the binary near 410 MB.
    Halide::Func ring_sum;
    Expr ring = Halide::sum(
        direction,
        bilinear_sample(sample, px + radius * dx, py + radius * dy),
        ring_sum);
    ring_sum.update().unroll(direction.x, 2);
    Expr center = bilinear_sample(sample, px, py);
    return Halide::select(radius > 1.0e-4f, ring * (1.0f / 16.0f), center);
}
inline Halide::Expr lut_load(Halide::ImageParam &lut, Halide::Expr x,
                             Halide::Expr y, Halide::Expr z, Halide::Expr channel) {
    return Halide::cast<float>(
        lut((((z * kLutDimension + y) * kLutDimension + x) * 4) + channel));
}

/// Tetrahedral interpolation matching SpectralLUT.sample, over any loader —
/// the packed ImageParam LUTs or a per-frame Func-built table.
template <typename Load>
inline Halide::Expr lut_sample_with(Load load, Halide::Expr px,
                                    Halide::Expr py, Halide::Expr pz,
                                    Halide::Expr channel,
                                    bool half_math = false) {
    using Halide::Expr;
    using Halide::max;
    using Halide::min;
    using Halide::select;
    Expr qx = Halide::clamp(px, 0.0f, 1.0f) * float(kLutDimension - 1);
    Expr qy = Halide::clamp(py, 0.0f, 1.0f) * float(kLutDimension - 1);
    Expr qz = Halide::clamp(pz, 0.0f, 1.0f) * float(kLutDimension - 1);
    Expr x0 = min(Halide::cast<int32_t>(qx), kLutDimension - 2);
    Expr y0 = min(Halide::cast<int32_t>(qy), kLutDimension - 2);
    Expr z0 = min(Halide::cast<int32_t>(qz), kLutDimension - 2);
    Expr fx = qx - Halide::cast<float>(x0);
    Expr fy = qy - Halide::cast<float>(y0);
    Expr fz = qz - Halide::cast<float>(z0);

    Expr largest = max(fx, max(fy, fz));
    Expr smallest = min(fx, min(fy, fz));
    Expr middle = max(min(fx, fy), min(max(fx, fy), fz));

    Expr x_largest = fx >= fy && fx >= fz;
    Expr y_largest = !x_largest && fy >= fz;
    Expr x_smallest = fx <= fy && fx <= fz;
    Expr y_smallest = !x_smallest && fy <= fz;
    Expr ax = select(x_largest, 1, 0);
    Expr ay = select(y_largest, 1, 0);
    Expr az = select(!x_largest && !y_largest, 1, 0);
    Expr bx = select(x_smallest, 0, 1);
    Expr by = select(y_smallest, 0, 1);
    Expr bz = select(!x_smallest && !y_smallest, 0, 1);

    Expr c000 = load(x0, y0, z0, channel);
    Expr near_step = load(x0 + ax, y0 + ay, z0 + az, channel);
    Expr far_step = load(x0 + bx, y0 + by, z0 + bz, channel);
    Expr c111 = load(x0 + 1, y0 + 1, z0 + 1, channel);
    if (half_math) {
        auto h = [](Expr v) { return Halide::cast(Halide::Float(16), v); };
        Expr c000h = h(c000), nearh = h(near_step), farh = h(far_step);
        return Halide::cast<float>(
            c000h + h(largest) * (nearh - c000h)
            + h(middle) * (farh - nearh)
            + h(smallest) * (h(c111) - farh));
    }
    return c000 + largest * (near_step - c000)
        + middle * (far_step - near_step)
        + smallest * (c111 - far_step);
}

inline Halide::Expr lut_sample(Halide::ImageParam &lut, Halide::Expr px,
                               Halide::Expr py, Halide::Expr pz,
                               Halide::Expr channel, bool half_math = false) {
    return lut_sample_with(
        [&](Halide::Expr x, Halide::Expr y, Halide::Expr z, Halide::Expr c) {
            return lut_load(lut, x, y, z, c);
        },
        px, py, pz, channel, half_math);
}

/// The same sampler over a cube that shares a buffer with other data, `base` floats in. WebGPU
/// counts every bound storage buffer against a small per-stage budget, so a backend that runs out
/// of bindings can carry a cube inside another parameter rather than give it one of its own.
inline Halide::Expr lut_sample_at(Halide::ImageParam &packed, int base,
                                  Halide::Expr px, Halide::Expr py, Halide::Expr pz,
                                  Halide::Expr channel, bool half_math = false) {
    return lut_sample_with(
        [&](Halide::Expr x, Halide::Expr y, Halide::Expr z, Halide::Expr c) {
            return Halide::cast<float>(packed(
                base + (((z * kLutDimension + y) * kLutDimension + x) * 4) + c));
        },
        px, py, pz, channel, half_math);
}

/// The same sampler over a per-frame table materialized as a Func indexed (x, y, z, channel).
inline Halide::Expr lut_sample_table(Halide::Func table, Halide::Expr px,
                                     Halide::Expr py, Halide::Expr pz,
                                     Halide::Expr channel,
                                     bool half_math = false) {
    return lut_sample_with(
        [&](Halide::Expr x, Halide::Expr y, Halide::Expr z, Halide::Expr c) {
            return Halide::cast<float>(table(x, y, z, c));
        },
        px, py, pz, channel, half_math);
}

}

#endif
