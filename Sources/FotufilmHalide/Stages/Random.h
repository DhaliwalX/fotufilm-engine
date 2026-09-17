#ifndef FOTUFILM_HALIDE_STAGES_RANDOM_H
#define FOTUFILM_HALIDE_STAGES_RANDOM_H

#include "FotufilmHalide.h"
#include "Math.h"

#include <Halide.h>
#include <cmath>

namespace fotufilm {

inline Halide::Expr pcg(Halide::Expr value) {
    Halide::Expr state = Halide::cast<uint32_t>(value) * Halide::Expr(uint32_t{747796405})
        + Halide::Expr(uint32_t{2891336453});
    Halide::Expr word =
        ((state >> ((state >> 28) + 4)) ^ state) * Halide::Expr(uint32_t{277803737});
    return (word >> 22) ^ word;
}

inline Halide::Expr pixel_hash(Halide::Expr x, Halide::Expr y,
                               Halide::Param<uint32_t> &seed, Halide::Expr layer) {
    return pcg(Halide::cast<uint32_t>(x) ^
               pcg(Halide::cast<uint32_t>(y) ^
                   pcg(seed ^ (Halide::cast<uint32_t>(layer)
                               * Halide::Expr(uint32_t{0x9E3779B9u})))));
}

inline Halide::Expr gaussian_from_hash(Halide::Expr hash,
                                       bool approximate = false) {
    Halide::Expr hash2 = pcg(hash);
    Halide::Expr uniform1 =
        Halide::cast<float>(hash >> 8) * (1.0f / 16777216.0f) + 1.0e-7f;
    Halide::Expr uniform2 = Halide::cast<float>(hash2 >> 8) * (1.0f / 16777216.0f);
    return Halide::sqrt(-2.0f * fs_log(uniform1, approximate))
        * fs_cos(2.0f * float(M_PI) * uniform2, approximate);
}

/// Unit-variance normal field used for silver clumps. A silver clump is a correlation length,
/// not one countable dye cloud; using the sparse Poisson count at high sampling densities makes
/// the blurred impulses resolve as repeated dots.
inline Halide::Expr normal_sample(Halide::Expr x, Halide::Expr y,
                                  Halide::Param<uint32_t> &seed,
                                  Halide::Expr layer,
                                  bool approximate = false) {
    return gaussian_from_hash(pixel_hash(x, y, seed, layer), approximate);
}

/// Centered unit-variance Poisson clump field.
inline Halide::Expr poisson_sample(Halide::Expr x, Halide::Expr y,
                                   Halide::Param<uint32_t> &seed,
                                   Halide::Param<float> &lambda,
                                   Halide::Expr layer,
                                   bool approximate = false) {
    using Halide::Expr;
    Expr hash = pixel_hash(x, y, seed, layer);
    Expr initial_hash = hash;
    Expr product = 1.0f;
    Expr trials = 0;
    Expr limit = Halide::exp(-lambda);
    for (int i = 0; i < 32; ++i) {
        Expr active = product > limit;
        hash = pcg(hash);
        Expr uniform = Halide::cast<float>(hash >> 8) * (1.0f / 16777216.0f);
        product = Halide::select(active, product * uniform, product);
        trials += Halide::select(active, 1, 0);
    }
    Expr count = Halide::max(trials - 1, 0);
    Expr poisson = (Halide::cast<float>(count) - lambda)
        / Halide::sqrt(Halide::max(lambda, 1.0e-4f));
    return Halide::select(lambda >= 16.0f,
                          gaussian_from_hash(initial_hash, approximate), poisson);
}

/// Centers a 1024-entry quantile table on zero and scales it to unit variance.
///
/// A quantile table is a discretisation, not the distribution it came from: rounding a CDF onto
/// 1024 steps moves the variance by a per cent or two at the small lambda a clump count actually
/// takes, and the grain amplitude is calibrated against a published standard deviation, so that
/// lands directly on the granularity. Lambda falls with output resolution, which would make the
/// error resolution-dependent as well. Normalising by the moments the table actually carries
/// removes both, and leaves the sampler with nothing to do but a load.
inline Halide::Func normalized_quantile_table(Halide::Func raw,
                                              const std::string &name,
                                              Halide::DeviceAPI gpu) {
    Halide::Var i(name + "_i");
    Halide::RDom quantiles(0, 1024, name + "_moment_quantiles");
    Halide::Func mean(name + "_mean");
    mean(i) = Halide::sum(Halide::cast<float>(raw(quantiles.x)),
                          name + "_mean_sum") / 1024.0f;
    Halide::Func deviation(name + "_deviation");
    Halide::Expr centered = Halide::cast<float>(raw(quantiles.x)) - mean(0);
    deviation(i) = Halide::sqrt(Halide::max(
        Halide::sum(centered * centered, name + "_deviation_sum") / 1024.0f,
        1.0e-12f));
    Halide::Func table(name);
    table(i) = (Halide::cast<float>(raw(i)) - mean(0)) / deviation(0);
    raw.compute_root();
    mean.compute_root();
    deviation.compute_root();
    table.compute_root();
    if (gpu != Halide::DeviceAPI::None) {
        // The two moments are one lane each; the two 1024-entry tables are not, and putting them
        // on a single thread would cost more per realization than the normalization saves.
        mean.gpu_single_thread(gpu);
        deviation.gpu_single_thread(gpu);
        Halide::Var block_raw(name + "_block_raw"), thread_raw(name + "_thread_raw");
        raw.gpu_tile(raw.args()[0], block_raw, thread_raw, 64,
                     Halide::TailStrategy::GuardWithIf, gpu);
        Halide::Var block_i(name + "_block_i"), thread_i(name + "_thread_i");
        table.gpu_tile(i, block_i, thread_i, 64,
                       Halide::TailStrategy::GuardWithIf,
                       gpu);
    }
    return table;
}

/// Per-frame inverse CDF of Poisson(lambda), 1024 quantiles, centered and unit-variance.
inline Halide::Func poisson_inverse_cdf(Halide::Param<float> &lambda,
                                        const std::string &name,
                                        Halide::DeviceAPI gpu
                                            = Halide::DeviceAPI::None) {
    Halide::Var n(name + "_n"), i(name + "_i");
    Halide::Func pmf(name + "_pmf");
    pmf(n) = Halide::select(n == 0, Halide::exp(-lambda), 0.0f);
    Halide::RDom scan(1, 63, name + "_scan");
    pmf(scan) = pmf(scan - 1) * (lambda / scan);
    Halide::Func cdf(name + "_cdf");
    cdf(n) = pmf(n);
    Halide::RDom accumulate(1, 63, name + "_accumulate");
    cdf(accumulate) = cdf(accumulate - 1) + pmf(accumulate);
    Halide::Func raw(name + "_counts");
    Halide::RDom counts(0, 64, name + "_count_domain");
    raw(i) = Halide::sum(
        Halide::select(cdf(counts.x)
                           < (Halide::cast<float>(i) + 0.5f) / 1024.0f, 1, 0),
        name + "_quantile_sum");
    pmf.compute_root();
    cdf.compute_root();
    if (gpu != Halide::DeviceAPI::None) {
        pmf.gpu_single_thread(gpu);
        pmf.update(0).gpu_single_thread(gpu);
        cdf.gpu_single_thread(gpu);
        cdf.update(0).gpu_single_thread(gpu);
    }
    return normalized_quantile_table(raw, name, gpu);
}

/// 1024-quantile inverse normal CDF, tabulated once per realization so the Gaussian limit of the
/// clump field is a single load per draw instead of a log, a square root and a cosine.
inline Halide::Func normal_inverse_cdf(const std::string &name,
                                       Halide::DeviceAPI gpu
                                           = Halide::DeviceAPI::None) {
    using Halide::Expr;
    Halide::Var i(name + "_i");
    Halide::Func table(name + "_quantiles");
    Expr p = (Halide::cast<float>(i) + 0.5f) * (1.0f / 1024.0f);
    const float p_low = 0.02425f;
    Expr q = p - 0.5f;
    Expr r = q * q;
    Expr central =
        (((((-39.69683028665376f * r + 220.9460984245205f) * r
            - 275.9285104469687f) * r + 138.3577518672690f) * r
          - 30.66479806614716f) * r + 2.506628277459239f) * q
        / (((((-54.47609879822406f * r + 161.5858368580409f) * r
              - 155.6989798598866f) * r + 66.80131188771972f) * r
            - 13.28068155288572f) * r + 1.0f);
    Expr tail_p = Halide::min(p, 1.0f - p);
    Expr t = Halide::sqrt(-2.0f * Halide::log(Halide::max(tail_p, 1.0e-8f)));
    Expr tail =
        (((((-7.784894002430293e-3f * t - 0.3223964580411365f) * t
            - 2.400758277161838f) * t - 2.549732539343734f) * t
          + 4.374664141464968f) * t + 2.938163982698783f)
        / ((((7.784695709041462e-3f * t + 0.3224671290700398f) * t
             + 2.445134137142996f) * t + 3.754408661907416f) * t + 1.0f);
    table(i) = Halide::select(p < p_low, tail,
                              p > 1.0f - p_low, -tail, central);
    return normalized_quantile_table(table, name, gpu);
}

/// Centered unit-variance Poisson clump field sampled through the table
/// `poisson_inverse_cdf` built for the same lambda. Both tables arrive centered and unit-variance,
/// so a draw is one load.
inline Halide::Expr poisson_sample_lut(Halide::Func table,
                                       Halide::Func normal_table,
                                       Halide::Expr x, Halide::Expr y,
                                       Halide::Param<uint32_t> &seed,
                                       Halide::Param<float> &lambda,
                                       Halide::Expr layer) {
    Halide::Expr hash = pixel_hash(x, y, seed, layer);
    Halide::Expr quantile = Halide::cast<int32_t>(
        hash % Halide::Expr(uint32_t{1024}));
    return Halide::select(lambda >= 16.0f, normal_table(quantile),
                          table(quantile));
}

/// Table-driven counterpart of `normal_sample`. The table is centered and unit variance, so it
/// preserves the grain calibration while avoiding the high-resolution impulse pattern.
inline Halide::Expr normal_sample_lut(Halide::Func normal_table,
                                      Halide::Expr x, Halide::Expr y,
                                      Halide::Param<uint32_t> &seed,
                                      Halide::Expr layer) {
    Halide::Expr hash = pixel_hash(x, y, seed, layer);
    Halide::Expr quantile = Halide::cast<int32_t>(
        hash % Halide::Expr(uint32_t{1024}));
    return normal_table(quantile);
}
/// One triangular-PDF dither sample, spanning +/-1 quantizer step, matching `triangularDither` in
/// Math.swift hash for hash.
inline Halide::Expr triangular_dither(Halide::Expr x, Halide::Expr y,
                                      Halide::Expr channel,
                                      Halide::Expr width,
                                      Halide::Param<uint32_t> &seed) {
    using Halide::Expr;
    Expr index = Halide::cast<uint32_t>(y * width + x);
    Expr hash1 = pcg(index ^ pcg(Halide::cast<uint32_t>(channel)
                    + seed * Expr(uint32_t{0x9E3779B9u})));
    Expr hash2 = pcg(hash1);
    Expr u1 = Halide::cast<float>(hash1 >> 8) * (1.0f / 16777216.0f);
    Expr u2 = Halide::cast<float>(hash2 >> 8) * (1.0f / 16777216.0f);
    return u1 + u2 - 1.0f;
}

}

#endif
