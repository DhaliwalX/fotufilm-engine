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
/// mode 2 (crystals) forms the density directly from its dye clouds. Mode 1, the film grain
/// model, is laid after this by its own stage (`FilmTiles.h`).
inline Halide::Expr selected_developed_density(Halide::Expr mode, Halide::Expr curve_density,
                                               Halide::Expr clump,
                                               Halide::Expr crystal = Halide::Expr()) {
    Halide::Expr chosen = curve_density + clump;
    if (crystal.defined()) chosen = Halide::select(mode == 2, crystal, chosen);
    return chosen;
}

// The crystal grain model, in the three stages a real emulsion's grain passes through. The
// host derives the population (`CrystalGrainModel`); the kernel exposes it, develops it and
// prints it.

/// Hash streams of the crystal grain model: four per size bin — one per record and a shared
/// one — from here, above the mottle's; the print material's own records follow them.
constexpr int kCrystalStreamBase = 8;
constexpr int kCrystalPaperStreamBase = kCrystalStreamBase + 4 * FOTUFILM_CRYSTAL_GRAIN_BINS;

/// How far a developed crystal's mass strays from its sublayer's mean: each crystal forms
/// `1 ± kCrystalMarkDispersion` of it, the two-point stand-in for the developed-grain mass
/// distribution whose second moment, `1 + d²`, Dainty and Shaw put at 1.2–1.5 for coated
/// emulsions. The host anchors the dye per crystal with the same factor, so the published
/// granularity is unchanged by it; what it changes is that no two clouds are alike.
constexpr float kCrystalMarkDispersion = 0.5f;

// MARK: Stage 1 — exposure

/// The mean latent-crystal count per pixel for `bin` of `layer` where the record has formed
/// `amount` of its density range, read off the host's table: FOTUFILM_CRYSTAL_GRAIN_SAMPLES
/// values from 0 to 1, interpolated. Keyed on developed density rather than exposure because
/// the split renderer's tail is handed densities and has no exposure left to key on; the curve
/// is monotone, so the two say the same thing.
inline Halide::Expr crystal_lambda(Halide::ImageParam &configuration, Halide::Expr layer,
                                   int bin, Halide::Expr amount) {
    using Halide::Expr;
    const int samples = FOTUFILM_CRYSTAL_GRAIN_SAMPLES;
    Expr position = Halide::clamp(amount * float(samples - 1),
                                  0.0f, float(samples - 1) - 1.0e-4f);
    Expr index = Halide::cast<int32_t>(Halide::floor(position));
    Expr fraction = position - Halide::cast<float>(index);
    Expr base = FOTUFILM_CONFIG_CRYSTAL_GRAIN_LAMBDA
        + (layer * FOTUFILM_CRYSTAL_GRAIN_BINS + bin) * samples;
    Expr first = configuration(base + index);
    Expr second = configuration(base + Halide::min(index + 1, samples - 1));
    return Halide::max(first + (second - first) * fraction, 0.0f);
}

/// One of the four per-bin fields: 0 the lattice blur sigma of the bin's dye cloud, 1 the
/// density one cloud adds to the pixel it lands in, 2 the sublayer's coupler pool in density
/// (0 for silver, which has none), 3 the mean-dye factor `crystal_mean_dye` reads.
inline Halide::Expr crystal_bin_field(Halide::ImageParam &configuration, Halide::Expr layer,
                                      int bin, int field) {
    return configuration(FOTUFILM_CONFIG_CRYSTAL_GRAIN_BIN
                         + (layer * FOTUFILM_CRYSTAL_GRAIN_BINS + bin) * 4 + field);
}

/// The exposure stage: which crystals of one size bin carry a developable latent image in
/// one pixel. Photons arrive at each crystal as a Poisson count and a crystal is developable
/// once enough have, so the developable crystals of a pixel are a Poisson count at the mean
/// the light that fell there gives the bin, drawn as two Poisson parts so the records can share
/// crystals in the proportion FOTUFILM_CONFIG_GRAIN_CORRELATION asks for — the shared part
/// reads the same hash stream in every record, and a Poisson count is monotone in that stream,
/// so records whose means differ still rise and fall together. A monochrome stock sets the
/// correlation to one and every record reads the same count. Each crystal is drawn with the
/// mark development will give it, so the field this returns is already weighted by what each
/// developed crystal forms, in units of the bin's mean.
inline Halide::Expr crystal_latent_count(Halide::ImageParam &configuration, Halide::Expr x,
                                         Halide::Expr y, Halide::Param<uint32_t> &seed,
                                         Halide::Expr layer, int bin, Halide::Expr lambda,
                                         bool approximate = false) {
    using Halide::Expr;
    Expr rho = Halide::clamp(configuration(FOTUFILM_CONFIG_GRAIN_CORRELATION), 0.0f, 1.0f);
    Expr own = poisson_marked_count(
        pixel_hash(x, y, seed, kCrystalStreamBase + bin * 4 + layer),
        lambda * (1.0f - rho), kCrystalMarkDispersion, approximate);
    Expr shared = poisson_marked_count(
        pixel_hash(x, y, seed, kCrystalStreamBase + bin * 4 + 3),
        lambda * rho, kCrystalMarkDispersion, approximate);
    return own + shared;
}

// MARK: Stage 2 — development

/// Dye a sublayer forms from `demand`, the dye its developed crystals ask for: drawn from a
/// finite coupler pool, `pool (1 - exp(-demand / pool))`, so a crystal landing where the pool is
/// already drawn down forms less. Silver has no pool and forms what it asks for.
inline Halide::Expr crystal_dye(Halide::Expr demand, Halide::Expr pool) {
    return Halide::select(pool > 0.0f,
                          pool * (1.0f - Halide::exp(-demand / Halide::max(pool, 1.0e-6f))),
                          demand);
}

/// The dye a sublayer forms on average where its crystals land at `lambda` per pixel.
///
/// The clouds are a Poisson field through the pool's concave law, and the mean of a concave
/// function of a Poisson sum is not the function of its mean: by Campbell's theorem
/// `E[exp(-demand / C)] = exp(-lambda Σ_taps E_mark[1 - exp(-mark q K / C)])`, the sum running
/// over the cloud's lattice taps `K` with `q` the density one cloud adds and the expectation
/// over the two marks. The host packs that sum as the bin's `factor`, so what is taken away
/// below is the field's exact expectation under locally uniform exposure rather than the
/// mean's dye. This centers flat fields on the population fit; it does not remove spatial
/// development effects at exposure edges. Silver's factor is `q` itself and its mean is linear.
inline Halide::Expr crystal_mean_dye(Halide::Expr lambda, Halide::Expr factor,
                                     Halide::Expr pool) {
    return Halide::select(pool > 0.0f,
                          pool * (1.0f - Halide::exp(-lambda * factor)),
                          lambda * factor);
}

/// The development stage for one pixel of `layer`: each size bin's blurred latent count, in
/// `fields`, is what its crystals' clouds deposit here — the developer's diffusion having
/// spread each crystal's dye to the bin's cloud; that demand is drawn from the sublayer's pool.
/// The population fit specifies dye at mean demand, whereas a finite Poisson population through
/// a concave pool yields less dye on average. Calibrate that difference with the exact marked
/// Poisson expectation for the rendered taps. Otherwise the lattice changes the mean density
/// as well as its texture. Silver is linear, so its correction is identically zero.
inline Halide::Expr crystal_grain(Halide::ImageParam &configuration, Halide::Expr layer,
                                  const std::vector<Halide::Func> &fields,
                                  Halide::Expr x, Halide::Expr y, Halide::Expr amount) {
    using Halide::Expr;
    Expr total = 0.0f;
    for (int bin = 0; bin < FOTUFILM_CRYSTAL_GRAIN_BINS; ++bin) {
        Expr per_cloud = crystal_bin_field(configuration, layer, bin, 1);
        Expr pool = crystal_bin_field(configuration, layer, bin, 2);
        Expr demand = per_cloud * fields[bin](x, y, layer);
        Expr lambda = crystal_lambda(configuration, layer, bin, amount);
        Expr factor = crystal_bin_field(configuration, layer, bin, 3);
        Expr target_mean = crystal_dye(per_cloud * lambda, pool);
        Expr rendered_mean = crystal_mean_dye(lambda, factor, pool);
        total = total + crystal_dye(demand, pool) + target_mean - rendered_mean;
    }
    Expr base = FOTUFILM_CONFIG_CURVES + layer * 6;
    Expr d_min = configuration(base);
    return d_min + total;
}

// MARK: Stage 3 — print

/// The print stage's own crystals. The paper — or the release print's film — is an emulsion
/// exposed by the light the negative transmits, and its developed crystals are a Poisson
/// count of their own: at `activation`, the paper's developed fraction of its range, the mean
/// count in one output pixel is that fraction of the crystals the pixel holds at full
/// development, which the host packs per record in FOTUFILM_CONFIG_CRYSTAL_PRINT_GRAIN (0
/// when nothing exposes a paper). What comes back is the count's departure from its mean as a
/// fraction of the range, to add to the activation. The negative's own grain reaches the
/// paper by the road it always took — the enlarger's spread in transmittance and the paper's
/// curve — so this is only what the paper adds of itself.
inline Halide::Expr paper_grain_expr(Halide::ImageParam &configuration,
                                     Halide::Expr channel, Halide::Expr hash,
                                     Halide::Expr activation, bool approximate = false) {
    using Halide::Expr;
    Expr full = configuration(FOTUFILM_CONFIG_CRYSTAL_PRINT_GRAIN + channel);
    Expr lambda = Halide::clamp(activation, 0.0f, 1.0f) * Halide::max(full, 0.0f);
    Expr count = poisson_marked_count(hash, lambda, kCrystalMarkDispersion, approximate);
    return Halide::select(full > 0.0f, (count - lambda) / Halide::max(full, 1.0e-6f), 0.0f);
}

/// The print's hash seed, carried in the configuration for the pipeline that has no seed
/// parameter, and the paper record's stream: a black-and-white paper is one emulsion, so a
/// monochrome print reads one stream for its three channels.
inline Halide::Expr paper_grain_hash(Halide::ImageParam &configuration, Halide::Expr x,
                                     Halide::Expr y, Halide::Expr channel, bool monochrome) {
    Halide::Expr seed = Halide::cast<uint32_t>(Halide::max(
        configuration(FOTUFILM_CONFIG_CRYSTAL_PRINT_GRAIN + 3), 0.0f));
    return pixel_hash(x, y, seed,
                      kCrystalPaperStreamBase + (monochrome ? Halide::Expr(0) : channel));
}

inline Halide::Expr grain_correlate(Halide::ImageParam &configuration,
                                    Halide::Func base_noise, Halide::Expr x,
                                    Halide::Expr y, Halide::Expr channel) {
    return grain_mix(configuration, base_noise(x, y, channel),
                     base_noise(x, y, kGrainSharedLayer));
}

}

#endif
