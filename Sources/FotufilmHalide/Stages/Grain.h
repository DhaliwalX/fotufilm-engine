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

/// Grain mode 0 is the clump field, 1 the Boolean discs, 2 the crystal population.
/// Modes 0 and 1 are additive fluctuations around the curve; mode 2 forms the developed
/// density directly from the dye clouds (or silver grains).
inline Halide::Expr selected_grain(Halide::Expr mode, Halide::Expr clump,
                                   Halide::Expr disc = Halide::Expr(),
                                   Halide::Expr crystal = Halide::Expr()) {
    Halide::Expr chosen = clump;
    if (disc.defined()) chosen = Halide::select(mode == 1, disc, chosen);
    if (crystal.defined()) chosen = Halide::select(mode == 2, crystal, chosen);
    return chosen;
}

/// The developed density after grain: mode 0 (clump) and mode 1 (discs) add their fluctuation
/// to the curve density; mode 2 (crystals) forms the density directly from its dye clouds.
inline Halide::Expr selected_developed_density(Halide::Expr mode, Halide::Expr curve_density,
                                               Halide::Expr clump,
                                               Halide::Expr disc = Halide::Expr(),
                                               Halide::Expr crystal = Halide::Expr()) {
    Halide::Expr chosen = curve_density + clump;
    if (disc.defined()) chosen = Halide::select(mode == 1, curve_density + disc, chosen);
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
