#ifndef FOTUFILM_HALIDE_STAGES_GRAIN_H
#define FOTUFILM_HALIDE_STAGES_GRAIN_H

#include "FotufilmHalide.h"
#include "Random.h"
#include "Curves.h"

#include <Halide.h>
#include <cmath>
#include <vector>

namespace fotufilm {

/// Granularity variance of a chromogenic negative's record at diffuse density `density`, in
/// arbitrary units — the shape fitted per record to Kodak's published diffuse RMS granularity
/// against density for Vision3 50D (5203), 250D (5207), 200T (5213) and 500T (5219), 48 µm
/// aperture, each sheet read off its own plot:
///
///     s²(D) = (1 - e^(-D/toe)) * (1 + amplitude * e^(-D/decay)
///                                 + hump * e^(-((D - hump_density) / hump_width)² / 2))
///
/// The first factor is how much of the emulsion has developed at all, so granularity vanishes
/// where no image formed; the bracket is the variance each unit of density carries, high while
/// the fast coarse sub-layer is developing and decaying over `decay` onto the fine slow one's
/// floor of 1. Every sheet peaks 0.15–0.2 above D-min at about 1.5× the read density's figure
/// and falls — Selwyn's √D rises there instead, 3× too quiet at the peak and 2× too loud at
/// net 2 — then rises again near net 1.1–1.5, most in the blue record, where the slow
/// sub-layer's own coarse population comes in; that second rise is the Gaussian term, which
/// the earlier two-term form could not make and so ran 20–30 % quiet through the upper
/// mid-scale. Past it the bracket's floor keeps the extrapolation beyond the sheets' last
/// reading (net 2.1, where the data stops) flat rather than turning back up.
inline Halide::Expr dye_cloud_granularity_variance(Halide::Expr density,
                                                   Halide::Expr amplitude,
                                                   Halide::Expr toe,
                                                   Halide::Expr decay,
                                                   Halide::Expr hump,
                                                   Halide::Expr hump_density,
                                                   Halide::Expr hump_width) {
    Halide::Expr offset = (density - hump_density) / Halide::max(hump_width, 1.0e-4f);
    return (1.0f - Halide::exp(-density / Halide::max(toe, 1.0e-4f)))
        * (1.0f + amplitude * Halide::exp(-density / Halide::max(decay, 1.0e-4f))
           + hump * Halide::exp(-0.5f * offset * offset));
}

/// Granularity variance of a silver emulsion at diffuse density `density`, in arbitrary units.
///
/// For opaque grains much smaller than the reading aperture the Boolean (Siedentopf) variance
/// is `F(D) = 2π ∫₀² (10^(D k(u)) - 1) u du` with `k` the normalised self-overlap of two unit
/// discs. That integral reduces to the form below within 0.6% in σ over D 0…3.5, where the
/// `√(10^D - 1)` it replaced was 50% off at D = 2.
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
    Expr record = FOTUFILM_CONFIG_GRAIN_DENSITY_RECORDS + layer * 6;
    Expr amplitude = configuration(record);
    Expr toe = configuration(record + 1);
    Expr decay = configuration(record + 2);
    Expr hump = configuration(record + 3);
    Expr hump_density = configuration(record + 4);
    Expr hump_width = configuration(record + 5);
    Expr dye_cloud =
        dye_cloud_granularity_variance(here, amplitude, toe, decay,
                                       hump, hump_density, hump_width)
        / Halide::max(
            dye_cloud_granularity_variance(anchor, amplitude, toe, decay,
                                           hump, hump_density, hump_width),
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

/// The developed density after grain. Mode 0 (clump) adds its fluctuation to the curve density;
/// mode 1, the film grain model, is laid after this by its own stage (`FilmTiles.h`).
inline Halide::Expr selected_developed_density(Halide::Expr curve_density, Halide::Expr clump) {
    return curve_density + clump;
}

inline Halide::Expr grain_correlate(Halide::ImageParam &configuration,
                                    Halide::Func base_noise, Halide::Expr x,
                                    Halide::Expr y, Halide::Expr channel) {
    return grain_mix(configuration, base_noise(x, y, channel),
                     base_noise(x, y, kGrainSharedLayer));
}

}

#endif
