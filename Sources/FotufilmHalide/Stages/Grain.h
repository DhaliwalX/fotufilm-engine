#ifndef FOTUFILM_HALIDE_STAGES_GRAIN_H
#define FOTUFILM_HALIDE_STAGES_GRAIN_H

#include "FotufilmHalide.h"
#include "Random.h"
#include "Curves.h"

#include <Halide.h>
#include <cmath>

namespace fotufilm {

/// Granularity variance of a chromogenic negative at diffuse density `density`, in arbitrary
/// units — the shape fitted to Kodak's published diffuse RMS granularity against density for
/// Vision3 250D (5207) and 500T (5219), 48 µm aperture, both sheets read off their own plots:
///
///     s²(D) = (1 - e^(-D/toe)) * (1 + amplitude * e^(-D/decay))
///
/// The first factor is how much of the emulsion has developed at all, so granularity vanishes
/// where no image formed; the bracket is the variance each unit of density carries, high while
/// the fast coarse sub-layer is developing and decaying over `decay` onto the fine slow one's
/// floor of 1. Both sheets peak 0.15–0.2 above D-min at about 1.5× the read density's figure
/// and fall thereafter — Selwyn's √D rises there instead, 3× too quiet at the peak and 2× too
/// loud at net 2. The bracket's floor is what keeps the extrapolation past the sheets' last
/// reading (net 2.1, where the data stops) flat rather than turning back up.
inline Halide::Expr dye_cloud_granularity_variance(Halide::Expr density,
                                                   Halide::Expr amplitude,
                                                   Halide::Expr toe,
                                                   Halide::Expr decay) {
    return (1.0f - Halide::exp(-density / Halide::max(toe, 1.0e-4f)))
        * (1.0f + amplitude * Halide::exp(-density / Halide::max(decay, 1.0e-4f)));
}

/// Granularity variance of a silver emulsion at diffuse density `density`, in arbitrary units.
///
/// For opaque grains much smaller than the reading aperture the Boolean (Siedentopf) variance
/// is `F(D) = 2π ∫₀² (10^(D k(u)) - 1) u du` with `k` the normalised self-overlap of two unit
/// discs — the same model `BooleanGrain.granularity` and the disc path integrate. That integral
/// reduces to the form below within 0.6% in σ over D 0…3.5, so the clump path no longer has to
/// disagree with the disc path by 50% at D = 2 the way `√(10^D - 1)` did.
inline Halide::Expr silver_granularity_variance(Halide::Expr density) {
    return density * Halide::pow(
        10.0f, 0.21004f * density + 0.06114f * density * density);
}

/// Saturating reversal variance, divided by the constant Ds^(2p) that cancels at the anchor.
inline Halide::Expr reversal_granularity_variance(Halide::Expr density,
                                                 Halide::Expr exponent,
                                                 Halide::Expr shoulder) {
    Halide::Expr power = Halide::pow(density / Halide::max(shoulder, 1.0e-4f),
                                     2.0f * exponent);
    return power / (1.0f + power);
}

/// Granularity relative to the stock's reference density. Fog is included at both densities.
inline Halide::Expr grain_density_modulation(Halide::ImageParam &configuration,
                                             Halide::Expr layer,
                                             Halide::Expr net_density) {
    using Halide::Expr;
    Expr fog = configuration(FOTUFILM_CONFIG_GRAIN_FOG + layer);
    Expr anchor = Halide::max(
        configuration(FOTUFILM_CONFIG_GRAIN_ANCHOR + layer) + fog, 1.0e-4f);
    Expr here = Halide::max(net_density, 0.0f) + fog;
    Expr amplitude = configuration(FOTUFILM_CONFIG_GRAIN_DENSITY_PROFILE);
    Expr toe = configuration(FOTUFILM_CONFIG_GRAIN_DENSITY_PROFILE + 1);
    Expr decay = configuration(FOTUFILM_CONFIG_GRAIN_DENSITY_PROFILE + 2);
    Expr dye_cloud =
        dye_cloud_granularity_variance(here, amplitude, toe, decay)
        / Halide::max(
            dye_cloud_granularity_variance(anchor, amplitude, toe, decay),
            1.0e-6f);
    Expr silver = silver_granularity_variance(here)
        / Halide::max(silver_granularity_variance(anchor), 1.0e-6f);
    Expr exponent = configuration(FOTUFILM_CONFIG_GRAIN_REVERSAL_PROFILE);
    Expr shoulder = configuration(FOTUFILM_CONFIG_GRAIN_REVERSAL_PROFILE + 1);
    Expr reversal = reversal_granularity_variance(here, exponent, shoulder)
        / Halide::max(reversal_granularity_variance(anchor, exponent, shoulder), 1.0e-20f);
    // Selwyn remains an explicitly selectable legacy law (2).
    Expr selwyn = here / anchor;
    Expr law = configuration(FOTUFILM_CONFIG_GRAIN_LAW);
    Expr ratio = Halide::select(law > 2.5f, reversal, law > 1.5f, selwyn,
                                Halide::select(law > 0.5f, silver, dye_cloud));
    return Halide::sqrt(Halide::max(ratio, 0.0f));
}

/// Covered fraction of a silver emulsion at net density `net_density`, by Nutting's relation.
///
/// The Boolean model's own premise is that opaque grains hide one another, so what the model
/// fluctuates is covered area and density follows as `-log10(1 - a)`. Feeding it a normalised
/// density instead treats the two as proportional, which is the one thing the model says they
/// are not.
inline Halide::Expr nutting_coverage(Halide::Expr net_density) {
    return Halide::clamp(
        1.0f - Halide::pow(10.0f, -Halide::max(net_density, 0.0f)),
        1.0e-4f, 0.99f);
}

/// Density per unit of covered fraction at coverage `a` — the derivative of Nutting's relation,
/// `1 / ((1 - a) ln 10)`. This is the amplification the disc path was missing: the same
/// fluctuation in covered area is worth more density the more of the film is already covered.
inline Halide::Expr nutting_density_gain(Halide::Expr coverage) {
    return 1.0f / (Halide::max(1.0f - coverage, 1.0e-2f) * float(M_LN10));
}

/// Grain centres considered per cell, and sample points per pixel, in the Boolean grain model.
///
/// A cell is one grain radius across, so the mean count in a cell is `-ln(1 - coverage) / pi`
/// whatever the grain size — 0.22 at mid density and 1.47 at the 0.99 the coverage is clamped to.
/// Six is that distribution's tail at six in ten thousand, which is below the sampling noise of
/// nine points.
constexpr int kBooleanGrainsPerCell = 6;
constexpr int kBooleanSamplesPerAxis = 3;

/// Stratified estimate of covered-fraction deviation for equal Boolean discs from a Poisson process.
/// Coverage fixes intensity at `-ln(1 - coverage) / (πr²)`. Cell counts invert the Poisson CDF at
/// local density; adjacent pixels may estimate shared cells differently across steep gradients.
inline Halide::Expr boolean_coverage(Halide::Expr x, Halide::Expr y,
                                     Halide::Expr coverage,
                                     Halide::Expr radius_px,
                                     Halide::Param<uint32_t> &seed,
                                     Halide::Expr layer) {
    using Halide::Expr;
    using Halide::cast;
    Expr covered = Halide::clamp(coverage, 1.0e-4f, 0.99f);
    Expr cell = Halide::max(radius_px, 1.0f);
    Expr lambda_cell = -Halide::log(1.0f - covered) * (1.0f / float(M_PI));

    // Sample points, stratified over the pixel so the estimate does not carry the variance of
    // nine independent uniforms.
    Expr sample_x[kBooleanSamplesPerAxis * kBooleanSamplesPerAxis];
    Expr sample_y[kBooleanSamplesPerAxis * kBooleanSamplesPerAxis];
    Expr hit[kBooleanSamplesPerAxis * kBooleanSamplesPerAxis];
    const float stratum = 1.0f / float(kBooleanSamplesPerAxis);
    for (int sy = 0; sy < kBooleanSamplesPerAxis; ++sy) {
        for (int sx = 0; sx < kBooleanSamplesPerAxis; ++sx) {
            int k = sy * kBooleanSamplesPerAxis + sx;
            Expr jitter = pixel_hash(x, y, seed,
                                     layer * 64 + Expr(1024 + k));
            Expr jx = cast<float>(jitter >> 8) * (1.0f / 16777216.0f);
            Expr jy = cast<float>(pcg(jitter) >> 8) * (1.0f / 16777216.0f);
            sample_x[k] = cast<float>(x) + (float(sx) + jx) * stratum;
            sample_y[k] = cast<float>(y) + (float(sy) + jy) * stratum;
            hit[k] = Halide::cast<bool>(Expr(0));
        }
    }

    // A cell is one grain radius across and the caller only takes this path once that is at least a
    // pixel, so the pixel touches two cells per axis and a grain can reach one cell further: four
    // cells per axis cover every sample, and the neighbourhood is a constant rather than something
    // that grows as the grain goes sub-pixel.
    Expr base_cell_x = cast<int32_t>(Halide::floor(cast<float>(x) / cell));
    Expr base_cell_y = cast<int32_t>(Halide::floor(cast<float>(y) / cell));
    // Keep the cell walk in the generated program instead of expanding sixteen copies of
    // every grain/sample expression in the compiler. The reductions preserve the Boolean
    // union exactly, including the sample positions, hash streams and coverage.
    Halide::RDom cells(-1, 4, -1, 4);
    Expr cell_x = base_cell_x + cells.x;
    Expr cell_y = base_cell_y + cells.y;
    Expr cell_hash = pixel_hash(cell_x, cell_y, seed, layer);
    // Poisson count for this cell, by comparing one uniform against the running CDF.
    Expr uniform = cast<float>(cell_hash >> 8) * (1.0f / 16777216.0f);
    Expr term = Halide::exp(-lambda_cell);
    Expr cdf = term;
    Expr count = 0;
    for (int n = 1; n <= kBooleanGrainsPerCell; ++n) {
        count += Halide::select(uniform > cdf, 1, 0);
        term = term * lambda_cell * (1.0f / float(n));
        cdf = cdf + term;
    }
    Expr grain_hash = pcg(cell_hash);
    for (int g = 0; g < kBooleanGrainsPerCell; ++g) {
        grain_hash = pcg(grain_hash);
        Expr gx = cast<float>(grain_hash >> 8) * (1.0f / 16777216.0f);
        Expr next = pcg(grain_hash);
        Expr gy = cast<float>(next >> 8) * (1.0f / 16777216.0f);
        grain_hash = next;
        Expr present = Expr(g) < count;
        Expr centre_x = (cast<float>(cell_x) + gx) * cell;
        Expr centre_y = (cast<float>(cell_y) + gy) * cell;
        for (int k = 0;
             k < kBooleanSamplesPerAxis * kBooleanSamplesPerAxis; ++k) {
            Expr ox = sample_x[k] - centre_x;
            Expr oy = sample_y[k] - centre_y;
            hit[k] = hit[k]
                || (present && (ox * ox + oy * oy < radius_px * radius_px));
        }
    }

    // Each of the sixteen cells contributes zero or one for a sample. Five bits per
    // sample hold the entire count without carries into its neighbour. Two reductions
    // share each cell's hash and Poisson count across six/three samples respectively.
    Expr total = 0.0f;
    constexpr int samples = kBooleanSamplesPerAxis * kBooleanSamplesPerAxis;
    for (int first = 0; first < samples; first += 6) {
        Expr packed = cast<uint32_t>(0);
        const int end = std::min(first + 6, samples);
        for (int k = first; k < end; ++k) {
            packed = packed | (cast<uint32_t>(hit[k]) << (5 * (k - first)));
        }
        Expr counts = Halide::sum(cells, packed);
        for (int k = first; k < end; ++k) {
            Expr count = (counts >> (5 * (k - first))) & 31;
            total += Halide::select(count != 0, 1.0f, 0.0f);
        }
    }
    // Centered on the fraction the model actually covers, which is the clamped value rather than
    // the requested one, so the clamp costs variance at the extremes and never a density shift.
    return total * (1.0f / float(kBooleanSamplesPerAxis * kBooleanSamplesPerAxis))
        - covered;
}

/// Hash stream carrying the grain fluctuation common to all three layers.
constexpr int kGrainSharedLayer = 3;

/// Hash streams of the grain-size mixture's coarse component: per-layer streams
/// at 4 + layer, and the shared one here — all disjoint from the fine field's.
constexpr int kGrainMottleLayerBase = 4;
constexpr int kGrainMottleSharedLayer = 7;

/// One layer's clump field, as a correlated mixture of that layer's own noise and the field shared
/// by all three.
inline Halide::Expr grain_mix(Halide::ImageParam &configuration,
                              Halide::Expr own, Halide::Expr shared) {
    Halide::Expr rho = Halide::clamp(
        configuration(FOTUFILM_CONFIG_GRAIN_CORRELATION), 0.0f, 1.0f);
    return Halide::sqrt(1.0f - rho) * own + Halide::sqrt(rho) * shared;
}

/// Resolved silver-grain coverage, shared by the CPU and Metal schedules. Density includes
/// base fog for the Nutting coverage law; the green record supplies one shared field so the
/// configured inter-layer correlation is preserved.
inline Halide::Expr disc_grain(Halide::ImageParam &configuration,
                               Halide::Func density, Halide::Expr net_density,
                               Halide::Expr x, Halide::Expr y, Halide::Expr channel,
                               Halide::Expr origin_x, Halide::Expr origin_y,
                               Halide::Param<uint32_t> &seed) {
    using Halide::Expr;
    Expr radius = configuration(FOTUFILM_CONFIG_GRAIN_DISC_RADIUS);
    Expr coverage = nutting_coverage(
        net_density + configuration(FOTUFILM_CONFIG_GRAIN_FOG + channel));
    Expr green_net = Halide::clamp(
        density(x, y, 1) - configuration(Expr(FOTUFILM_CONFIG_CURVES + 6)),
        0.0f, film_curve_range(configuration, 1));
    Expr green_coverage = nutting_coverage(
        green_net + configuration(FOTUFILM_CONFIG_GRAIN_FOG + 1));
    return configuration(FOTUFILM_CONFIG_GRAIN_DISC + channel)
        * nutting_density_gain(coverage)
        * grain_mix(configuration,
                    boolean_coverage(x + origin_x, y + origin_y, coverage,
                                     radius, seed, channel),
                    boolean_coverage(x + origin_x, y + origin_y, green_coverage,
                                     radius, seed, Expr(kGrainSharedLayer)));
}

inline Halide::Expr clump_grain(Halide::ImageParam &configuration, Halide::Expr channel,
                                Halide::Expr modulation, Halide::Expr grain_field,
                                Halide::Expr mottle_field = Halide::Expr()) {
    Halide::Expr clump = configuration(FOTUFILM_CONFIG_GRAIN + channel)
        * modulation * grain_field;
    if (mottle_field.defined()) {
        clump = clump + configuration(FOTUFILM_CONFIG_MOTTLE + channel)
            * modulation * mottle_field;
    }
    return clump;
}

inline Halide::Expr selected_grain(Halide::Expr disc_mode, Halide::Expr clump,
                                   Halide::Expr disc = Halide::Expr()) {
    return disc.defined() ? Halide::select(disc_mode, disc, clump) : clump;
}

inline Halide::Expr grain_correlate(Halide::ImageParam &configuration,
                                    Halide::Func base_noise, Halide::Expr x,
                                    Halide::Expr y, Halide::Expr channel) {
    return grain_mix(configuration, base_noise(x, y, channel),
                     base_noise(x, y, kGrainSharedLayer));
}

}

#endif
