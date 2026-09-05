#ifndef FOTUFILM_HALIDE_H
#define FOTUFILM_HALIDE_H

#include <math.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Samples per channel in the DIR coupler neutral-anchor warp table, and the
/// log-exposure domain it spans.
enum {
    FOTUFILM_COUPLER_WARP_SAMPLES = 128,
    FOTUFILM_COUPLER_WARP_MIN = -4,
    FOTUFILM_COUPLER_WARP_MAX = 4,
};

/// Cells along the tone-base grid's long edge, and the storage reserved for
/// each of its two coefficient planes.
enum {
    FOTUFILM_TONE_GRID_EDGE = 64,
    FOTUFILM_TONE_GRID_CELLS = FOTUFILM_TONE_GRID_EDGE * FOTUFILM_TONE_GRID_EDGE,
};

/// Number of floats in the packed configuration. Offsets are defined by the enum below; append new
/// fields without renumbering existing entries.
enum {
    FOTUFILM_FRAME_CONFIGURATION_COUNT = 232 + 3 * FOTUFILM_COUPLER_WARP_SAMPLES
        + 2 * FOTUFILM_TONE_GRID_CELLS,
};

/// Offsets into the packed configuration.
enum {
    FOTUFILM_CONFIG_CURVES = 0,
    FOTUFILM_CONFIG_HALATION = 18,
    FOTUFILM_CONFIG_COUPLER = 21,
    FOTUFILM_CONFIG_GRAIN = 30,
    FOTUFILM_CONFIG_PAPER = 33,
    FOTUFILM_CONFIG_MASKING = 39,
    FOTUFILM_CONFIG_MTF_SIGMA = 42,
    FOTUFILM_CONFIG_MTF_RADIUS = 45,
    FOTUFILM_CONFIG_HALATION_RADIUS = 48,
    FOTUFILM_CONFIG_COUPLER_SIGMA = 51,
    FOTUFILM_CONFIG_COUPLER_RADIUS = 52,
    FOTUFILM_CONFIG_ADJACENCY_SIGMA = 53,
    FOTUFILM_CONFIG_ADJACENCY_RADIUS = 54,
    FOTUFILM_CONFIG_GRAIN_SIGMA = 55,
    FOTUFILM_CONFIG_GRAIN_RADIUS = 56,
    FOTUFILM_CONFIG_FLARE = 57,
    FOTUFILM_CONFIG_COUPLER_SCALE = 58,
    FOTUFILM_CONFIG_ADJACENCY_STRENGTH = 59,
    FOTUFILM_CONFIG_GRAIN_LAMBDA = 60,
    FOTUFILM_CONFIG_EXPOSURE_GAIN = 61,
    FOTUFILM_CONFIG_PAPER_MIDPOINT = 62,
    FOTUFILM_CONFIG_FLARE_MEAN = 63,
    FOTUFILM_CONFIG_COUPLER_WARP = 66,
    FOTUFILM_CONFIG_WHITE_BALANCE = 66 + 3 * FOTUFILM_COUPLER_WARP_SAMPLES,
    FOTUFILM_CONFIG_HIGHLIGHTS = FOTUFILM_CONFIG_WHITE_BALANCE + 3,
    FOTUFILM_CONFIG_SHADOWS,
    FOTUFILM_CONFIG_SATURATION,
    FOTUFILM_CONFIG_VIBRANCE,
    FOTUFILM_CONFIG_HALATION_KERNEL = FOTUFILM_CONFIG_VIBRANCE + 1,
    FOTUFILM_CONFIG_GRAIN_CORRELATION = FOTUFILM_CONFIG_HALATION_KERNEL + 9,
    FOTUFILM_CONFIG_MTF_LUMA_SHARE,
    FOTUFILM_CONFIG_MTF_LUMA_SIGMA,
    FOTUFILM_CONFIG_MTF_LUMA_RADIUS,
    FOTUFILM_CONFIG_GRADE_LIFT,
    FOTUFILM_CONFIG_GRADE_GAIN = FOTUFILM_CONFIG_GRADE_LIFT + 3,
    FOTUFILM_CONFIG_GRADE_INV_GAMMA = FOTUFILM_CONFIG_GRADE_GAIN + 3,
    FOTUFILM_CONFIG_FRAME_WIDTH = FOTUFILM_CONFIG_GRADE_INV_GAMMA + 3,
    FOTUFILM_CONFIG_FRAME_HEIGHT,
    FOTUFILM_CONFIG_TONE_GRID_WIDTH,
    FOTUFILM_CONFIG_TONE_GRID_HEIGHT,
    FOTUFILM_CONFIG_TONE_GRID_A,
    FOTUFILM_CONFIG_TONE_GRID_B = FOTUFILM_CONFIG_TONE_GRID_A
        + FOTUFILM_TONE_GRID_CELLS,
    /// Non-zero to develop grain as a Boolean model of discs rather than as a blurred clump field.
    FOTUFILM_CONFIG_GRAIN_MODE = FOTUFILM_CONFIG_TONE_GRID_B
        + FOTUFILM_TONE_GRID_CELLS,
    /// Grain radius in pixels. The Boolean path is only taken once this reaches a pixel, below
    /// which the clump field is already the model's own limit and far cheaper.
    FOTUFILM_CONFIG_GRAIN_DISC_RADIUS,
    /// Per-layer density amplitude for the Boolean path, calibrated so the covered fraction read
    /// through a 48 um aperture carries the stock's published granularity.
    FOTUFILM_CONFIG_GRAIN_DISC,
    /// Non-zero to run the three-way grade on the sRGB-encoded signal, the way a grading suite's
    /// three-way corrector does, rather than on display-linear light. Appended last so that adding
    /// it renumbered nothing.
    FOTUFILM_CONFIG_GRADE_SPACE = FOTUFILM_CONFIG_GRAIN_DISC + 3,
    /// The grain-size mixture's second clump field — the soft mottle the coarse
    /// crystal population lays under the sharp grain. Blur sigma and radius in
    /// pixels, the coarse population's own clumps-per-pixel, and per-layer
    /// density amplitudes[3] carrying that component's share of the published
    /// granularity. Appended last so that adding them renumbered nothing.
    FOTUFILM_CONFIG_MOTTLE_SIGMA,
    FOTUFILM_CONFIG_MOTTLE_RADIUS,
    FOTUFILM_CONFIG_MOTTLE_LAMBDA,
    FOTUFILM_CONFIG_MOTTLE,
    /// The paper's red and blue records, six curve parameters each, with the
    /// green record staying in the legacy FOTUFILM_CONFIG_PAPER slot; then the
    /// two records' own calibrated midpoints, the per-channel analogue of
    /// FOTUFILM_CONFIG_PAPER_MIDPOINT. A paper that publishes one curve packs
    /// it in all three slots. Appended last so that adding them renumbered
    /// nothing.
    FOTUFILM_CONFIG_PAPER_RED = FOTUFILM_CONFIG_MOTTLE + 3,
    FOTUFILM_CONFIG_PAPER_BLUE = FOTUFILM_CONFIG_PAPER_RED + 6,
    FOTUFILM_CONFIG_PAPER_MIDPOINT_RED = FOTUFILM_CONFIG_PAPER_BLUE + 6,
    FOTUFILM_CONFIG_PAPER_MIDPOINT_BLUE,
    /// Which granularity-against-density law the emulsion obeys. 0 is a chromogenic negative,
    /// whose measured curve peaks just above D-min and falls (the shape's coefficients are in
    /// FOTUFILM_CONFIG_GRAIN_DENSITY_PROFILE); 1 is opaque silver, whose Boolean aperture
    /// variance goes as `D * 10^(0.21004 D + 0.06114 D^2)`; 2 is a dye-cloud emulsion with no
    /// published curve — a reversal — which keeps Selwyn's plain `sigma ∝ sqrt(D)`. Mirrors
    /// `GrainDensityLaw`.
    FOTUFILM_CONFIG_GRAIN_LAW,
    /// Per-layer net density the stock's published granularity is read at, and the per-layer
    /// developed fog added to both that anchor and the pixel's own density. The fog is what
    /// keeps granularity finite rather than zero where the negative is clear.
    FOTUFILM_CONFIG_GRAIN_ANCHOR,
    FOTUFILM_CONFIG_GRAIN_FOG = FOTUFILM_CONFIG_GRAIN_ANCHOR + 3,
    /// Per-layer blur sigma in pixels for the sharp grain field and for the coarse mottle. The
    /// blue-sensitive layer of a colour negative carries the coarsest crystals, so its grain is
    /// lower in frequency and not merely louder. FOTUFILM_CONFIG_GRAIN_RADIUS and
    /// FOTUFILM_CONFIG_MOTTLE_RADIUS stay scalar: they are the widest of the three kernels, and
    /// the narrower ones have decayed to nothing out there.
    FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER = FOTUFILM_CONFIG_GRAIN_FOG + 3,
    FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER = FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER + 3,
    /// Gaussian sigma and radius, in pixels, of the enlarger lens and the paper's own light
    /// scattering. It acts on the light the negative transmits, so the pipeline applies it in
    /// transmittance rather than in density.
    FOTUFILM_CONFIG_PRINT_MTF_SIGMA = FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER + 3,
    FOTUFILM_CONFIG_PRINT_MTF_RADIUS,
    /// Optional final row-major matrix, transfer, and premultiplication used by
    /// FOTUFILM_FRAME_ENCODE_OUT. Other variants return display-linear light.
    ///
    ///   0  identity — the host's space is already linear.
    ///   1  power law, sign-preserving: |v| <= c4 ? |v| * c0 : c1 * pow(|v|, c2) + c3,
    ///      carried back across zero by the sign. Rec.709 gamma 2.4 and sRGB.
    ///   2  logarithmic, signed: v <= c4 ? v * c0 + c3 : c1 * log2(v + c5) + c2.
    ///      DaVinci Intermediate and ACEScct.
    ///
    /// `fotufilm::outputTransformFor` defines the coefficients.
    FOTUFILM_CONFIG_OUTPUT_MATRIX,
    FOTUFILM_CONFIG_OUTPUT_TRANSFER = FOTUFILM_CONFIG_OUTPUT_MATRIX + 9,
    FOTUFILM_CONFIG_OUTPUT_COEFFICIENTS,
    FOTUFILM_CONFIG_OUTPUT_PREMULTIPLIED = FOTUFILM_CONFIG_OUTPUT_COEFFICIENTS + 6,
    /// The share of the detail under the print MTF's blur the finish returns, 0...1. An
    /// enlarger keeps 0; a scan finish keeps most of it, because a minilab sharpens its read.
    /// Appended after the output transform so that adding it renumbered nothing.
    FOTUFILM_CONFIG_PRINT_SHARPEN,
    /// The lens diffusion filter — mist, fog, black mist — which is the only stage that runs
    /// ahead of the emulsion, because the filter it models is screwed onto the front of the
    /// lens. Appended last so that adding it renumbered nothing.
    ///
    /// The share of the beam that reached the film without meeting a particle. Perfectly sharp,
    /// and what keeps a diffused picture from looking defocused.
    FOTUFILM_CONFIG_DIFFUSION_DIRECT,
    /// How much of the scattered light each of the three scales carries, per record:
    /// `[record * 3 + scale]`, already multiplied by the scattered share. The records differ
    /// because the scattering angle goes as the wavelength, so a red halo is wider than a blue
    /// one; a row summing to less than the scattered share is light that went past the widest
    /// scale, and it has already been added to FOTUFILM_CONFIG_FLARE rather than dropped.
    FOTUFILM_CONFIG_DIFFUSION_KERNEL,
    /// Pixel radius of each scale. Strides and strided radii are derived from these by the same
    /// `fotufilm_halation_stride` rule the halation pyramid uses.
    FOTUFILM_CONFIG_DIFFUSION_RADIUS = FOTUFILM_CONFIG_DIFFUSION_KERNEL + 9,
    /// The donor capture layer — a coated layer that develops and releases inhibitor but forms
    /// no image dye of its own (REALA's 4th Color Layer). Six H&D parameters for its own
    /// development curve, then one release weight per dye-forming receiver, in the engine's
    /// R, G, B record order. Read only when FOTUFILM_FRAME_DONOR_LAYER is set; appended last so
    /// that adding them renumbered nothing.
    FOTUFILM_CONFIG_DONOR_CURVE = FOTUFILM_CONFIG_DIFFUSION_RADIUS + 3,
    FOTUFILM_CONFIG_DONOR_RELEASE = FOTUFILM_CONFIG_DONOR_CURVE + 6,
    /// Reserved legacy annular-basis radii. Continuous physical kernels leave these zero.
    FOTUFILM_CONFIG_HALATION_RING_RADIUS = FOTUFILM_CONFIG_DONOR_RELEASE + 3,
    /// Row-major 3x3 spectral halation return matrix, receiver rows by source columns, in the
    /// mix domain: entry [c][j] is the share of receiver c's developed exposure that arrives as
    /// source record j's base-returned light. Rows sum to the receiver's legacy mix share, so a
    /// diagonal of the old FOTUFILM_CONFIG_HALATION values reproduces the scalar mix exactly;
    /// the off-diagonal terms are what the per-wavelength stack transmission (the orange mask
    /// favouring deep red on the return trip) routes between records. The scalar shares at
    /// FOTUFILM_CONFIG_HALATION are still written but no longer read by the kernels.
    FOTUFILM_CONFIG_HALATION_MATRIX = FOTUFILM_CONFIG_HALATION_RING_RADIUS + 3,
    /// Five parameters per dye-forming record for an optional second coated speed group:
    /// gamma, toe, toe width, shoulder, shoulder width. A zero gamma is the original
    /// six-parameter curve exactly. Appended so no existing configuration offset moves.
    FOTUFILM_CONFIG_CURVE_SECONDARY = FOTUFILM_CONFIG_HALATION_MATRIX + 9,
    /// A second positive Gaussian diffusion scale per record, followed by its radii and the
    /// primary scale's blend shares. Shares of one are the original single-Gaussian MTF exactly.
    FOTUFILM_CONFIG_MTF_SECONDARY_SIGMA = FOTUFILM_CONFIG_CURVE_SECONDARY + 15,
    FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS = FOTUFILM_CONFIG_MTF_SECONDARY_SIGMA + 3,
    FOTUFILM_CONFIG_MTF_PRIMARY_SHARE = FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS + 3,
    /// Hill exponents for normalized inhibitor release by each dye-forming donor, followed by
    /// the optional donor-only layer's exponent. 1 is the historical linear law.
    FOTUFILM_CONFIG_COUPLER_RELEASE_GAMMA = FOTUFILM_CONFIG_MTF_PRIMARY_SHARE + 3,
    FOTUFILM_CONFIG_DONOR_RELEASE_GAMMA = FOTUFILM_CONFIG_COUPLER_RELEASE_GAMMA + 3,
    /// Lens-diffusion scale weights for the optional donor capture record. Kept separate from
    /// the three dye-forming rows above so existing configuration offsets remain fixed.
    FOTUFILM_CONFIG_DONOR_DIFFUSION_KERNEL = FOTUFILM_CONFIG_DONOR_RELEASE_GAMMA + 1,
    /// Whether development complements the formed density to a direct positive: 1 on a genuine
    /// reversal stock, 0 otherwise. Distinct from FOTUFILM_FRAME_REVERSAL, which also routes a
    /// negative shown on a light box or scanner past the paper; that negative is still developed
    /// as a negative, so its density law and its grain are evaluated in its own density.
    FOTUFILM_CONFIG_DEVELOP_COMPLEMENT = FOTUFILM_CONFIG_DONOR_DIFFUSION_KERNEL + 3,
    /// The chromogenic negative's granularity-against-density shape, read only under
    /// FOTUFILM_CONFIG_GRAIN_LAW 0: the coarse sub-layer's variance amplitude, the toe density
    /// over which anything develops at all, and the density over which that coarse population
    /// decays onto the fine one. Mirrors `FilmStock.grainDensityProfile`.
    FOTUFILM_CONFIG_GRAIN_DENSITY_PROFILE = FOTUFILM_CONFIG_DEVELOP_COMPLEMENT + 1,
    /// The knee of the SDR shoulder the host's delivery asks for, applied between the output
    /// matrix and the output transfer — the step `FilmOutputConversion` takes on the host, moved
    /// into the kernel so the encode variants can carry a shouldered delivery rather than only a
    /// bare one. Negative means no shoulder, which is the identity a linear or unshouldered space
    /// wants; 0.9 is the standard print knee and 0.7 the reversal one. Read only under
    /// FOTUFILM_FRAME_ENCODE_OUT; appended without renumbering earlier fields.
    FOTUFILM_CONFIG_OUTPUT_SHOULDER = FOTUFILM_CONFIG_GRAIN_DENSITY_PROFILE + 3,
    /// Enabled flag followed by three host-primary luminance weights. Fits chroma after the
    /// output matrix while preserving luminance and above-white highlights; zero disables it.
    FOTUFILM_CONFIG_OUTPUT_GAMUT = FOTUFILM_CONFIG_OUTPUT_SHOULDER + 1,
};

/// Decode-kernel parameters: row-major scene-space matrix, transfer, and premultiplication flag.
/// Decode transfers are defined independently by `fotufilm::inputTransformFor` and are not the
/// algebraic inverses of output coefficients.
///
///   0  identity — the host's space is already linear.
///   1  power law, sign-preserving: |v| <= c4 ? |v| * c0 : pow(c1 * |v| + c3, c2),
///      carried back across zero by the sign. Rec.709 gamma 2.4 and sRGB.
///   2  exponential, signed: v <= c4 ? (v - c3) * c0 : exp(v * c1 - c2) - c5.
///      DaVinci Intermediate and ACEScct.
enum {
    FOTUFILM_DECODE_MATRIX = 0,
    FOTUFILM_DECODE_TRANSFER = FOTUFILM_DECODE_MATRIX + 9,
    FOTUFILM_DECODE_COEFFICIENTS,
    FOTUFILM_DECODE_PREMULTIPLIED = FOTUFILM_DECODE_COEFFICIENTS + 6,
    FOTUFILM_DECODE_PARAMETER_COUNT,
};

/// Marks the "engine unavailable" fallbacks that FotufilmHalide.cpp and
/// FotufilmHalideMetal.cpp define when they are compiled without Halide.
#define FOTUFILM_FALLBACK __attribute__((weak))

/// Feature mask selecting which physical stages a pipeline variant includes.
enum {
    FOTUFILM_FRAME_FLARE = 1 << 0,
    FOTUFILM_FRAME_MTF = 1 << 1,
    FOTUFILM_FRAME_HALATION = 1 << 2,
    FOTUFILM_FRAME_COUPLERS = 1 << 3,
    FOTUFILM_FRAME_ADJACENCY = 1 << 4,
    FOTUFILM_FRAME_GRAIN = 1 << 5,
    FOTUFILM_FRAME_REVERSAL = 1 << 6,
    FOTUFILM_FRAME_MONOCHROME = 1 << 7,
    /// Selects the scene-referred schedule: linear float in and out, with no sRGB transfer, no
    /// clamp to display white, and no 8-bit quantization.
    FOTUFILM_FRAME_FLOAT_IO = 1 << 8,
    /// Compiles the extended emulsion MTF: its optional second positive scale and the luminance
    /// arm feeding the zero-DC correction at FOTUFILM_CONFIG_MTF_LUMA_SHARE. The historical name
    /// is retained because it is part of the generated AOT variant ABI.
    FOTUFILM_FRAME_MTF_LUMA = 1 << 9,
    /// Compiles the DIR couplers' spatial diffusion.
    FOTUFILM_FRAME_COUPLER_DIFFUSION = 1 << 10,
    /// Selects the realtime schedule rather than the reference one: byte-input variants may use
    /// half-float intermediates; float-input variants retain full storage precision while using
    /// tabulated H&D curves, decimated spatial pyramids, and the table-driven grain draw.
    FOTUFILM_FRAME_REALTIME = 1 << 11,
    /// Exact transcendentals instead of the GPU schedules' fast_* polynomials.
    FOTUFILM_FRAME_EXACT_MATH = 1 << 12,
    /// The hybrid fast develop's two halves.
    FOTUFILM_FRAME_DENSITY_OUT = 1 << 13,
    FOTUFILM_FRAME_DENSITY_IN = 1 << 14,
    /// Compiles the Boolean disc grain alongside the clump field. It is its own variant rather
    /// than a runtime branch because the disc arm is a large unrolled expression: leaving it in
    /// the pipeline costs every render its compile time even when nothing selects it.
    FOTUFILM_FRAME_DISC_GRAIN = 1 << 15,
    /// Compiles the grain-size mixture's second clump field: a coarse crystal
    /// population blurred at its own correlation length and laid under the
    /// sharp one. Deliberately outside every FOTUFILM_AOT_* variant list — the
    /// AOT shims mask unknown bits off, so a mobile render carries the fine
    /// component alone until the realtime variants are regenerated with it.
    FOTUFILM_FRAME_GRAIN_MOTTLE = 1 << 16,
    /// Compiles the enlarger and paper MTF: one blur in transmittance at the end of develop,
    /// which is where the negative stops being the image and starts being the thing an enlarger
    /// projects. Off when the negative itself is what is being viewed, since then nothing
    /// images it. Deliberately outside every FOTUFILM_AOT_* variant list, like the mottle — the
    /// AOT shims mask unknown bits off, so a mobile render prints without it until the realtime
    /// variants are regenerated.
    FOTUFILM_FRAME_PRINT_MTF = 1 << 17,
    /// Measures global veiling glare on-device for a whole staged frame. The float32 GPU reduction
    /// is not bit-identical to the host's ordered double reduction.
    FOTUFILM_FRAME_FLARE_MEASURE = 1 << 18,
    /// Applies the configured output matrix, transfer, and premultiplication in-kernel.
    /// GPU transcendentals may differ from host libm, so callers must use one encode path per
    /// delivery. Hosts that resample must do so in linear light and leave this disabled.
    FOTUFILM_FRAME_ENCODE_OUT = 1 << 19,
    /// Stops the scene-referred pipeline after veiling glare and the emulsion MTF and hands that
    /// light back as interleaved float RGBA — the exact numbers the halation pyramid would read,
    /// in the same full-precision storage the schedule keeps them in. The first half of the
    /// two-pass striped render: a strip of light needs only the MTF's own apron, where a strip
    /// of finished frame needs halation's whole reach.
    FOTUFILM_FRAME_LIGHT_OUT = 1 << 20,
    /// Takes the halation pyramid's three blurred grids as an input — packed behind the
    /// configuration, whole-frame, built once by `fotufilm_halide_metal_halation_fields` from the
    /// light a LIGHT_OUT pass wrote — instead of building them from the strip. The strip then
    /// needs no halation apron at all, and the sampled values are the very numbers the staged
    /// path's own pyramid store holds, so the delivered pixels do not move.
    FOTUFILM_FRAME_FIELDS_IN = 1 << 21,
    /// Realtime output kernels compile only the transfer arm the host needs. Reference kernels
    /// omit these bits and retain the coefficient-driven runtime selection used for parity work.
    FOTUFILM_FRAME_OUTPUT_LINEAR = 1 << 22,
    FOTUFILM_FRAME_OUTPUT_POWER = 1 << 23,
    FOTUFILM_FRAME_OUTPUT_LOG = 1 << 24,
    /// Returns source light multiplied by the transmittance difference between developments with
    /// and without selected spatial stages. Pointwise operations cancel; uniform fields and empty
    /// selections are exact no-ops.
    FOTUFILM_FRAME_TEXTURE = 1 << 25,
    /// Enables a three-scale lens-diffusion halo in scene light before emulsion exposure.
    /// Direct share 1 with zero kernel weights is identity.
    FOTUFILM_FRAME_DIFFUSION = 1 << 26,
    /// Enables a fourth capture layer that releases inhibitor but forms no transported dye.
    /// The host warp already includes its neutral-axis counterweight, so donor stocks require a
    /// matching compiled variant; dropping this bit would retain compensation without release.
    FOTUFILM_FRAME_DONOR_LAYER = 1 << 27,
    /// Legacy annular-basis variant. Current physical profiles use centered continuous fields.
    FOTUFILM_FRAME_HALATION_ANNULAR = 1 << 28,
    /// Develops with no film in the gate: the creative controls — white balance, the
    /// exposure-keyed tone masks, saturation and vibrance — then straight into the print's
    /// delivery basis and the grade. No spectral recovery, no characteristic curve, no couplers,
    /// no grain, no paper. Everything the emulsion would have done falls out of the pipeline,
    /// so a variant carrying this bit should carry no stage bits either.
    ///
    /// It is a variant rather than a configuration because the middle of the pipeline is
    /// replaced, not switched off: there is no setting of the film and paper cubes that turns
    /// the spectral path into a matrix.
    FOTUFILM_FRAME_NO_FILM = 1 << 29,
};

/// Full spatial-stage mask, including post-grain enlarger blur. Zero radius makes enlarger blur
/// identity, avoiding a separate variant family. Capture glare remains opt-in through
/// `FOTUFILM_AOT_FLARE` because most input has already passed through a lens.
#define FOTUFILM_AOT_ALL_STAGES                                              \
    (FOTUFILM_FRAME_MTF | FOTUFILM_FRAME_MTF_LUMA |                           \
     FOTUFILM_FRAME_HALATION | FOTUFILM_FRAME_COUPLERS |                      \
     FOTUFILM_FRAME_COUPLER_DIFFUSION | FOTUFILM_FRAME_ADJACENCY |            \
     FOTUFILM_FRAME_GRAIN | FOTUFILM_FRAME_PRINT_MTF |                        \
     FOTUFILM_FRAME_DIFFUSION)

/// The stages up to but not including grain, which is where the split schedule cuts.
#define FOTUFILM_AOT_HEAD                                                    \
    (FOTUFILM_AOT_ALL_STAGES & ~(FOTUFILM_FRAME_GRAIN | FOTUFILM_FRAME_PRINT_MTF))

/// Grain and the enlarger: the half of develop that runs after the cut.
#define FOTUFILM_AOT_TAIL                                                    \
    (FOTUFILM_FRAME_GRAIN | FOTUFILM_FRAME_PRINT_MTF | FOTUFILM_FRAME_DENSITY_IN)

/// `PipelineStage.negative`: every stage up to and including grain, and nothing that images the
/// negative afterwards. The same cut the hybrid still renderer makes, moved past grain so that
/// what crosses the boundary is a developed negative rather than a latent one.
#define FOTUFILM_AOT_NEGATIVE_SPAN                                            \
    ((FOTUFILM_AOT_ALL_STAGES & ~FOTUFILM_FRAME_PRINT_MTF) |                   \
     FOTUFILM_FRAME_DENSITY_OUT)

/// `PipelineStage.print`: the enlarger and the print medium, reading densities. Everything the
/// negative span already ran is absent, which is what makes the two spans together run each stage
/// exactly once.
#define FOTUFILM_AOT_PRINT_SPAN                                               \
    (FOTUFILM_FRAME_PRINT_MTF | FOTUFILM_FRAME_DENSITY_IN)

/// `PipelineStage.texture`: the same stages the negative span runs, differenced against a
/// development with none of them. The enlarger is in, because it is one of the selectable spatial
/// stages here rather than the print it belongs to in a full render.
#define FOTUFILM_AOT_TEXTURE_SPAN                                             \
    (FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_TEXTURE)

/// Texture span for an empty spatial selection. It requires an exact variant because unused
/// near-identity stages would enter only one side of the density difference. Pointwise glare and
/// coupler inhibition remain on both sides and cancel.
#define FOTUFILM_AOT_TEXTURE_FLAT_SPAN                                        \
    (FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_COUPLERS | FOTUFILM_FRAME_TEXTURE)

/// A colour negative: DIR couplers that diffuse, and no luminance MTF arm. This is a stock that
/// gets printed, not the light-box view of one — that borrows the reversal flag instead.
#define FOTUFILM_AOT_NEGATIVE                                                \
    (FOTUFILM_FRAME_MTF | FOTUFILM_FRAME_HALATION |                           \
     FOTUFILM_FRAME_COUPLERS | FOTUFILM_FRAME_COUPLER_DIFFUSION |             \
     FOTUFILM_FRAME_ADJACENCY | FOTUFILM_FRAME_GRAIN)

/// A transparency or a black-and-white stock without an interimage correction.
#define FOTUFILM_AOT_SLIDE                                                   \
    (FOTUFILM_FRAME_MTF | FOTUFILM_FRAME_HALATION |                           \
     FOTUFILM_FRAME_ADJACENCY | FOTUFILM_FRAME_GRAIN)

/// A transparency whose development carries a pointwise interimage correction.
#define FOTUFILM_AOT_SLIDE_INTERIMAGE                                        \
    (FOTUFILM_AOT_SLIDE | FOTUFILM_FRAME_COUPLERS)

/// The same without the emulsion MTF, which is compiled out when the stock's diffusion does not
/// reach a pixel at the frame's size.
#define FOTUFILM_AOT_SLIDE_NO_MTF (FOTUFILM_AOT_SLIDE & ~FOTUFILM_FRAME_MTF)

#define FOTUFILM_AOT_DISC(mask) ((mask) | FOTUFILM_FRAME_DISC_GRAIN)

/// A measured two-component emulsion MTF uses the existing luminance-MTF arm to carry its
/// second positive blur. Unlike an unused luminance arm, dropping this bit changes the trace.
#define FOTUFILM_AOT_EXTENDED_MTF(mask) ((mask) | FOTUFILM_FRAME_MTF_LUMA)

/// Adds the donor capture layer. Donor stocks require this exact variant because the host-side warp
/// includes its counterweight. Non-donor stocks supply zero release, so donor variants remain valid
/// supersets for plain requests.
#define FOTUFILM_AOT_DONOR(mask) ((mask) | FOTUFILM_FRAME_DONOR_LAYER)

/// The grain-size mixture — a coarse second clump field under the sharp one. Like the donor
/// family this is a *tight* twin: the host splits the published granularity's variance between
/// the two fields before the kernel runs, so a variant that lacks the stage renders the sharp
/// field at its reduced amplitude and never lays the coarse half back. See the `_mottle`
/// entries at the end of the variant list for how the family is scoped.
#define FOTUFILM_AOT_MOTTLE(mask) ((mask) | FOTUFILM_FRAME_GRAIN_MOTTLE)

/// Capture veiling glare, which the stage masks above deliberately leave out.
///
/// The family built from this is intentionally *not* tight: each entry carries every stage, so a
/// glare-on render of a stock that uses no couplers still finds a variant and runs the coupler
/// stage at zero strength. That is the trade the opt-in deserves — a frame that asks for glare is
/// the rare one, and a tight twin of all seventy-eight would cost the shipped library its whole
/// size again to save a stage on a path almost nothing takes.
#define FOTUFILM_AOT_FLARE(mask) ((mask) | FOTUFILM_FRAME_FLARE)

/// A stock that goes through an enlarger onto paper. The slide masks are shared: a colour stock
/// with no couplers at all is a transparency, which is projected rather than printed, but a
/// monochrome stock with no couplers is usually a negative and is printed like any other. So the
/// monochrome slide variants carry the enlarger and the colour ones do not — and a monochrome
/// reversal stock, the one case on the wrong side of that split, falls back to the same variant
/// with the radius at zero. FrameVariantTests holds the assumption that no colour negative reaches
/// a plain slide variant.
#define FOTUFILM_AOT_ENLARGED(mask) ((mask) | FOTUFILM_FRAME_PRINT_MTF)

/// The variants the Mac generates, as (name, mask) pairs.
#define FOTUFILM_AOT_VARIANTS(X)                                             \
    X(color, FOTUFILM_AOT_ALL_STAGES)                                        \
    X(color_disc, FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES))                \
    X(monochrome, FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME)        \
    X(monochrome_disc,                                                      \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME)) \
    X(color_float, FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO)         \
    X(color_float_disc,                                                     \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO))   \
    X(monochrome_float,                                                     \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME |                   \
      FOTUFILM_FRAME_FLOAT_IO)                                               \
    X(monochrome_float_disc,                                                \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
                       FOTUFILM_FRAME_FLOAT_IO))                             \
    X(color_float_exact,                                                    \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |                     \
      FOTUFILM_FRAME_EXACT_MATH)                                             \
    X(color_float_exact_disc,                                               \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
                       FOTUFILM_FRAME_EXACT_MATH))                           \
    X(monochrome_float_exact,                                               \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME |                   \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_EXACT_MATH)                    \
    X(monochrome_float_exact_disc,                                          \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
                       FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_EXACT_MATH))  \
    X(color_float_realtime,                                                 \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |                     \
      FOTUFILM_FRAME_REALTIME)                                               \
    X(color_float_realtime_disc,                                            \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
                       FOTUFILM_FRAME_REALTIME))                             \
    X(monochrome_float_realtime,                                            \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME |                   \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME)                      \
    X(monochrome_float_realtime_disc,                                       \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
                       FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME))    \
    X(color_float_realtime_no_print,                                        \
      FOTUFILM_AOT_SLIDE | FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME) \
    X(monochrome_float_realtime_no_print,                                   \
      FOTUFILM_AOT_SLIDE | FOTUFILM_FRAME_MONOCHROME |                        \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME)                      \
    X(color_float_realtime_encode_linear,                                   \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |                     \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_LINEAR)                                          \
    X(color_float_realtime_encode_linear_disc,                              \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
                       FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |  \
                       FOTUFILM_FRAME_OUTPUT_LINEAR))                        \
    X(monochrome_float_realtime_encode_linear,                              \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME |                   \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LINEAR)               \
    X(monochrome_float_realtime_encode_linear_disc,                         \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
                       FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |    \
                       FOTUFILM_FRAME_ENCODE_OUT |                           \
                       FOTUFILM_FRAME_OUTPUT_LINEAR))                        \
    X(color_float_realtime_encode_power,                                    \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |                     \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_POWER)                                           \
    X(color_float_realtime_encode_power_disc,                               \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
                       FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |  \
                       FOTUFILM_FRAME_OUTPUT_POWER))                         \
    X(monochrome_float_realtime_encode_power,                               \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME |                   \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_POWER)                \
    X(monochrome_float_realtime_encode_power_disc,                          \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
                       FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |    \
                       FOTUFILM_FRAME_ENCODE_OUT |                           \
                       FOTUFILM_FRAME_OUTPUT_POWER))                         \
    X(color_float_realtime_encode_log,                                      \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |                     \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_LOG)                                             \
    X(color_float_realtime_encode_log_disc,                                 \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
                       FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |  \
                       FOTUFILM_FRAME_OUTPUT_LOG))                           \
    X(monochrome_float_realtime_encode_log,                                 \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME |                   \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LOG)                  \
    X(monochrome_float_realtime_encode_log_disc,                            \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
                       FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |    \
                       FOTUFILM_FRAME_ENCODE_OUT |                           \
                       FOTUFILM_FRAME_OUTPUT_LOG))                           \
    X(color_float_realtime_encode_linear_no_print,                          \
      FOTUFILM_AOT_SLIDE | FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME | \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LINEAR)               \
    X(monochrome_float_realtime_encode_linear_no_print,                     \
      FOTUFILM_AOT_SLIDE | FOTUFILM_FRAME_MONOCHROME |                        \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LINEAR)               \
    X(color_float_realtime_encode_power_no_print,                           \
      FOTUFILM_AOT_SLIDE | FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME | \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_POWER)                \
    X(monochrome_float_realtime_encode_power_no_print,                      \
      FOTUFILM_AOT_SLIDE | FOTUFILM_FRAME_MONOCHROME |                        \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_POWER)                \
    X(color_float_realtime_encode_log_no_print,                             \
      FOTUFILM_AOT_SLIDE | FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME | \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LOG)                  \
    X(monochrome_float_realtime_encode_log_no_print,                        \
      FOTUFILM_AOT_SLIDE | FOTUFILM_FRAME_MONOCHROME |                        \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LOG)                  \
    X(color_float_realtime_measure_encode_log,                              \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |                     \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_FLARE_MEASURE |                \
      FOTUFILM_FRAME_FLARE |                                                 \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LOG)                  \
    X(color_float_realtime_measure_encode_log_disc,                         \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
                       FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_FLARE_MEASURE |\
                       FOTUFILM_FRAME_FLARE |                                \
                       FOTUFILM_FRAME_ENCODE_OUT |                           \
                       FOTUFILM_FRAME_OUTPUT_LOG))                           \
    X(monochrome_float_realtime_measure_encode_log,                         \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME |                   \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_FLARE_MEASURE |                                         \
      FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_ENCODE_OUT |                      \
      FOTUFILM_FRAME_OUTPUT_LOG)                                             \
    X(monochrome_float_realtime_measure_encode_log_disc,                    \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
                       FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |    \
                       FOTUFILM_FRAME_FLARE_MEASURE | FOTUFILM_FRAME_FLARE |  \
                       FOTUFILM_FRAME_ENCODE_OUT |                           \
                       FOTUFILM_FRAME_OUTPUT_LOG))                           \
    X(color_float_realtime_measure_encode_log_no_print,                     \
      FOTUFILM_AOT_SLIDE |                                                   \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_FLARE_MEASURE |                                         \
      FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_ENCODE_OUT |                      \
      FOTUFILM_FRAME_OUTPUT_LOG)                                             \
    X(monochrome_float_realtime_measure_encode_log_no_print,                \
      FOTUFILM_AOT_SLIDE | FOTUFILM_FRAME_MONOCHROME |                        \
      FOTUFILM_FRAME_FLOAT_IO |                                              \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_FLARE_MEASURE |                \
      FOTUFILM_FRAME_FLARE |                                                 \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LOG)                  \
    X(color_flare, FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES))               \
    X(color_flare_disc,                                                     \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES)))          \
    X(color_float_flare,                                                    \
      FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO))   \
    X(color_float_flare_disc,                                               \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |           \
      FOTUFILM_FRAME_FLOAT_IO)))                                             \
    X(color_float_exact_flare,                                              \
      FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
      FOTUFILM_FRAME_EXACT_MATH))                                            \
    X(color_float_exact_flare_disc,                                         \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |           \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_EXACT_MATH)))                  \
    X(color_float_realtime_flare,                                           \
      FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
      FOTUFILM_FRAME_REALTIME))                                              \
    X(color_float_realtime_flare_disc,                                      \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |           \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME)))                    \
    X(color_float_realtime_encode_linear_flare,                             \
      FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_LINEAR))                                         \
    X(color_float_realtime_encode_linear_flare_disc,                        \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |           \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LINEAR)))             \
    X(color_float_realtime_encode_power_flare,                              \
      FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_POWER))                                          \
    X(color_float_realtime_encode_power_flare_disc,                         \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |           \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_POWER)))              \
    X(color_float_realtime_encode_log_flare,                                \
      FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_LOG))                                            \
    X(color_float_realtime_encode_log_flare_disc,                           \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |           \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LOG)))                \
    X(monochrome_flare,                                                     \
      FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME)) \
    X(monochrome_flare_disc,                                                \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |           \
      FOTUFILM_FRAME_MONOCHROME)))                                           \
    X(monochrome_float_flare,                                               \
      FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
      FOTUFILM_FRAME_FLOAT_IO))                                              \
    X(monochrome_float_flare_disc,                                          \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |           \
      FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_FLOAT_IO)))                  \
    X(monochrome_float_exact_flare,                                         \
      FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_EXACT_MATH))                   \
    X(monochrome_float_exact_flare_disc,                                    \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |           \
      FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_EXACT_MATH)))                                           \
    X(monochrome_float_realtime_flare,                                      \
      FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME))                     \
    X(monochrome_float_realtime_flare_disc,                                 \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |           \
      FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_REALTIME)))                                             \
    X(monochrome_float_realtime_encode_linear_flare,                        \
      FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LINEAR))              \
    X(monochrome_float_realtime_encode_linear_flare_disc,                   \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |           \
      FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_LINEAR)))                                        \
    X(monochrome_float_realtime_encode_power_flare,                         \
      FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_POWER))               \
    X(monochrome_float_realtime_encode_power_flare_disc,                    \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |           \
      FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_POWER)))                                         \
    X(monochrome_float_realtime_encode_log_flare,                           \
      FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LOG))                 \
    X(monochrome_float_realtime_encode_log_flare_disc,                      \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |           \
      FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_LOG)))                                           \
    X(negative, FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_NEGATIVE))                 \
    X(negative_disc,                                                        \
      FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_DISC(FOTUFILM_AOT_NEGATIVE)))         \
    X(negative_grainless,                                                   \
      FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_NEGATIVE & ~FOTUFILM_FRAME_GRAIN))    \
    X(negative_extended_mtf,                                                \
      FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_EXTENDED_MTF(FOTUFILM_AOT_NEGATIVE)))\
    X(negative_no_adjacency_extended_mtf,                                   \
      FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_EXTENDED_MTF(                        \
          FOTUFILM_AOT_NEGATIVE & ~FOTUFILM_FRAME_ADJACENCY)))               \
    X(negative_grainless_extended_mtf,                                      \
      FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_EXTENDED_MTF(                        \
          FOTUFILM_AOT_NEGATIVE & ~FOTUFILM_FRAME_GRAIN)))                   \
    X(negative_no_adjacency_grainless_extended_mtf,                         \
      FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_EXTENDED_MTF(                        \
          FOTUFILM_AOT_NEGATIVE & ~FOTUFILM_FRAME_ADJACENCY                  \
                               & ~FOTUFILM_FRAME_GRAIN)))                   \
    X(slide, FOTUFILM_AOT_SLIDE)                                             \
    X(slide_disc, FOTUFILM_AOT_DISC(FOTUFILM_AOT_SLIDE))                     \
    X(slide_grainless, FOTUFILM_AOT_SLIDE & ~FOTUFILM_FRAME_GRAIN)            \
    X(slide_interimage, FOTUFILM_AOT_SLIDE_INTERIMAGE)                       \
    X(slide_interimage_grainless,                                           \
      FOTUFILM_AOT_SLIDE_INTERIMAGE & ~FOTUFILM_FRAME_GRAIN)                  \
    X(slide_extended_mtf, FOTUFILM_AOT_EXTENDED_MTF(FOTUFILM_AOT_SLIDE))      \
    X(slide_no_adjacency_extended_mtf,                                      \
      FOTUFILM_AOT_EXTENDED_MTF(FOTUFILM_AOT_SLIDE                           \
                               & ~FOTUFILM_FRAME_ADJACENCY))                 \
    X(slide_grainless_extended_mtf,                                         \
      FOTUFILM_AOT_EXTENDED_MTF(FOTUFILM_AOT_SLIDE                           \
                               & ~FOTUFILM_FRAME_GRAIN))                    \
    X(slide_no_adjacency_grainless_extended_mtf,                            \
      FOTUFILM_AOT_EXTENDED_MTF(FOTUFILM_AOT_SLIDE                           \
                               & ~FOTUFILM_FRAME_ADJACENCY                  \
                               & ~FOTUFILM_FRAME_GRAIN))                    \
    X(slide_mono, FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_SLIDE                    \
                                       | FOTUFILM_FRAME_MONOCHROME))         \
    X(slide_mono_disc,                                                      \
      FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_DISC(FOTUFILM_AOT_SLIDE |            \
                                            FOTUFILM_FRAME_MONOCHROME)))     \
    X(slide_mono_grainless,                                                 \
      FOTUFILM_AOT_ENLARGED((FOTUFILM_AOT_SLIDE & ~FOTUFILM_FRAME_GRAIN)       \
                           | FOTUFILM_FRAME_MONOCHROME))                     \
    X(slide_mono_extended_mtf,                                              \
      FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_EXTENDED_MTF(                        \
          FOTUFILM_AOT_SLIDE | FOTUFILM_FRAME_MONOCHROME)))                  \
    X(slide_mono_extended_mtf_disc,                                         \
      FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_DISC(FOTUFILM_AOT_EXTENDED_MTF(       \
          FOTUFILM_AOT_SLIDE | FOTUFILM_FRAME_MONOCHROME))))                 \
    X(slide_mono_no_adjacency_extended_mtf,                                 \
      FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_EXTENDED_MTF(                        \
          (FOTUFILM_AOT_SLIDE & ~FOTUFILM_FRAME_ADJACENCY)                   \
          | FOTUFILM_FRAME_MONOCHROME)))                                    \
    X(slide_mono_grainless_extended_mtf,                                    \
      FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_EXTENDED_MTF(                        \
          (FOTUFILM_AOT_SLIDE & ~FOTUFILM_FRAME_GRAIN)                       \
          | FOTUFILM_FRAME_MONOCHROME)))                                    \
    X(slide_mono_no_adjacency_grainless_extended_mtf,                       \
      FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_EXTENDED_MTF(                        \
          (FOTUFILM_AOT_SLIDE & ~FOTUFILM_FRAME_ADJACENCY                    \
                               & ~FOTUFILM_FRAME_GRAIN)                     \
          | FOTUFILM_FRAME_MONOCHROME)))                                    \
    X(slide_mono_no_mtf,                                                    \
      FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_SLIDE_NO_MTF |                       \
                           FOTUFILM_FRAME_MONOCHROME))                       \
    X(slide_mono_no_mtf_disc,                                               \
      FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_DISC(FOTUFILM_AOT_SLIDE_NO_MTF |     \
                                            FOTUFILM_FRAME_MONOCHROME)))     \
    X(slide_mono_no_mtf_grainless,                                          \
      FOTUFILM_AOT_ENLARGED((FOTUFILM_AOT_SLIDE_NO_MTF                        \
                            & ~FOTUFILM_FRAME_GRAIN)                         \
                           | FOTUFILM_FRAME_MONOCHROME))                     \
    X(color_float_measure,                                                  \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |                     \
      FOTUFILM_FRAME_FLARE_MEASURE | FOTUFILM_FRAME_FLARE)                    \
    X(color_float_measure_disc,                                             \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
                       FOTUFILM_FRAME_FLARE_MEASURE | FOTUFILM_FRAME_FLARE))  \
    X(monochrome_float_measure,                                             \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME |                   \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_FLARE_MEASURE |                \
      FOTUFILM_FRAME_FLARE)                                                  \
    X(monochrome_float_measure_disc,                                        \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
                       FOTUFILM_FRAME_FLOAT_IO |                             \
                       FOTUFILM_FRAME_FLARE_MEASURE | FOTUFILM_FRAME_FLARE))  \
    X(color_float_encode,                                                   \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |                     \
      FOTUFILM_FRAME_ENCODE_OUT)                                             \
    X(color_float_encode_disc,                                              \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
                       FOTUFILM_FRAME_ENCODE_OUT))                           \
    X(color_float_measure_encode,                                           \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |                     \
      FOTUFILM_FRAME_FLARE_MEASURE |                                         \
      FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_ENCODE_OUT)                       \
    X(color_float_measure_encode_disc,                                      \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
                       FOTUFILM_FRAME_FLARE_MEASURE | FOTUFILM_FRAME_FLARE |  \
                       FOTUFILM_FRAME_ENCODE_OUT))                           \
    X(monochrome_float_encode,                                              \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME |                   \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_ENCODE_OUT)                    \
    X(monochrome_float_encode_disc,                                         \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
                       FOTUFILM_FRAME_FLOAT_IO |                             \
                       FOTUFILM_FRAME_ENCODE_OUT))                           \
    X(monochrome_float_measure_encode,                                      \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME |                   \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_FLARE_MEASURE |                \
      FOTUFILM_FRAME_FLARE |                                                 \
      FOTUFILM_FRAME_ENCODE_OUT)                                             \
    X(monochrome_float_measure_encode_disc,                                 \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
                       FOTUFILM_FRAME_FLOAT_IO |                             \
                       FOTUFILM_FRAME_FLARE_MEASURE | FOTUFILM_FRAME_FLARE |  \
                       FOTUFILM_FRAME_ENCODE_OUT))                           \
    X(color_float_light,                                                    \
      FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_MTF | FOTUFILM_FRAME_MTF_LUMA |    \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_LIGHT_OUT)                     \
    X(monochrome_float_light,                                               \
      FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_MTF | FOTUFILM_FRAME_MTF_LUMA |    \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_LIGHT_OUT |                    \
      FOTUFILM_FRAME_MONOCHROME)                                             \
    X(color_float_fields,                                                   \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |                     \
      FOTUFILM_FRAME_FIELDS_IN)                                              \
    X(color_float_fields_disc,                                              \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
                       FOTUFILM_FRAME_FIELDS_IN))                            \
    X(monochrome_float_fields,                                              \
      FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME |                   \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_FIELDS_IN)                     \
    X(monochrome_float_fields_disc,                                         \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | \
                       FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_FIELDS_IN))   \
    X(color_head, FOTUFILM_AOT_HEAD | FOTUFILM_FRAME_DENSITY_OUT)             \
    X(monochrome_head,                                                      \
      FOTUFILM_AOT_HEAD | FOTUFILM_FRAME_DENSITY_OUT |                        \
      FOTUFILM_FRAME_MONOCHROME)                                             \
    X(color_tail, FOTUFILM_AOT_TAIL)                                         \
    X(color_tail_disc, FOTUFILM_AOT_DISC(FOTUFILM_AOT_TAIL))                  \
    X(monochrome_tail, FOTUFILM_AOT_TAIL | FOTUFILM_FRAME_MONOCHROME)         \
    X(monochrome_tail_disc,                                                 \
      FOTUFILM_AOT_DISC(FOTUFILM_AOT_TAIL | FOTUFILM_FRAME_MONOCHROME))        \
    X(color_float_realtime_negative,                                        \
      FOTUFILM_AOT_NEGATIVE_SPAN | FOTUFILM_FRAME_FLOAT_IO |                  \
      FOTUFILM_FRAME_REALTIME)                                               \
    X(monochrome_float_realtime_negative,                                   \
      FOTUFILM_AOT_NEGATIVE_SPAN | FOTUFILM_FRAME_MONOCHROME |                \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME)                      \
    X(color_float_realtime_print,                                           \
      FOTUFILM_AOT_PRINT_SPAN | FOTUFILM_FRAME_FLOAT_IO |                     \
      FOTUFILM_FRAME_REALTIME)                                               \
    X(monochrome_float_realtime_print,                                      \
      FOTUFILM_AOT_PRINT_SPAN | FOTUFILM_FRAME_MONOCHROME |                   \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME)                      \
    X(color_float_realtime_texture,                                         \
      FOTUFILM_AOT_TEXTURE_SPAN | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_REALTIME)                                               \
    X(monochrome_float_realtime_texture,                                    \
      FOTUFILM_AOT_TEXTURE_SPAN | FOTUFILM_FRAME_MONOCHROME |                 \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME)                      \
    X(color_float_negative,                                                 \
      FOTUFILM_AOT_NEGATIVE_SPAN | FOTUFILM_FRAME_FLOAT_IO)                   \
    X(monochrome_float_negative,                                            \
      FOTUFILM_AOT_NEGATIVE_SPAN | FOTUFILM_FRAME_MONOCHROME |                \
      FOTUFILM_FRAME_FLOAT_IO)                                               \
    X(color_float_print,                                                    \
      FOTUFILM_AOT_PRINT_SPAN | FOTUFILM_FRAME_FLOAT_IO)                      \
    X(monochrome_float_print,                                               \
      FOTUFILM_AOT_PRINT_SPAN | FOTUFILM_FRAME_MONOCHROME |                   \
      FOTUFILM_FRAME_FLOAT_IO)                                               \
    X(color_float_texture,                                                  \
      FOTUFILM_AOT_TEXTURE_SPAN | FOTUFILM_FRAME_FLOAT_IO)                    \
    X(monochrome_float_texture,                                             \
      FOTUFILM_AOT_TEXTURE_SPAN | FOTUFILM_FRAME_MONOCHROME |                 \
      FOTUFILM_FRAME_FLOAT_IO)                                               \
    X(color_float_realtime_texture_flat,                                    \
      FOTUFILM_AOT_TEXTURE_FLAT_SPAN | FOTUFILM_FRAME_FLOAT_IO |              \
      FOTUFILM_FRAME_REALTIME)                                               \
    X(monochrome_float_realtime_texture_flat,                               \
      FOTUFILM_AOT_TEXTURE_FLAT_SPAN | FOTUFILM_FRAME_MONOCHROME |            \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME)                      \
    X(color_float_texture_flat,                                             \
      FOTUFILM_AOT_TEXTURE_FLAT_SPAN | FOTUFILM_FRAME_FLOAT_IO)               \
    X(monochrome_float_texture_flat,                                        \
      FOTUFILM_AOT_TEXTURE_FLAT_SPAN | FOTUFILM_FRAME_MONOCHROME |            \
      FOTUFILM_FRAME_FLOAT_IO)                                               \
    /* The `_donor` twins; see FOTUFILM_AOT_DONOR. */                        \
    X(color_donor, FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ALL_STAGES))               \
    X(color_float_donor,                                                    \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO))   \
    X(color_float_exact_donor,                                              \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
      FOTUFILM_FRAME_EXACT_MATH))                                            \
    X(color_float_realtime_donor,                                           \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
      FOTUFILM_FRAME_REALTIME))                                              \
    X(color_float_realtime_encode_linear_donor,                             \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_LINEAR))                                         \
    X(color_float_realtime_encode_power_donor,                              \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_POWER))                                          \
    X(color_float_realtime_encode_log_donor,                                \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_LOG))                                            \
    X(color_float_realtime_measure_encode_log_donor,                        \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_FLARE_MEASURE |                \
      FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_ENCODE_OUT |                      \
      FOTUFILM_FRAME_OUTPUT_LOG))                                            \
    X(color_flare_donor,                                                    \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES)))         \
    X(color_float_flare_donor,                                              \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |          \
      FOTUFILM_FRAME_FLOAT_IO)))                                             \
    X(color_float_exact_flare_donor,                                        \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |          \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_EXACT_MATH)))                  \
    X(color_float_realtime_flare_donor,                                     \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |          \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME)))                    \
    X(color_float_realtime_encode_linear_flare_donor,                       \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |          \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LINEAR)))             \
    X(color_float_realtime_encode_power_flare_donor,                        \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |          \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_POWER)))              \
    X(color_float_realtime_encode_log_flare_donor,                          \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES |          \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                     \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LOG)))                \
    X(negative_donor,                                                       \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ENLARGED(FOTUFILM_AOT_NEGATIVE)))        \
    X(negative_grainless_donor,                                             \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ENLARGED(                               \
          FOTUFILM_AOT_NEGATIVE & ~FOTUFILM_FRAME_GRAIN)))                    \
    X(negative_extended_mtf_donor,                                          \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ENLARGED(                               \
          FOTUFILM_AOT_EXTENDED_MTF(FOTUFILM_AOT_NEGATIVE))))                \
    X(negative_no_adjacency_extended_mtf_donor,                             \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ENLARGED(                               \
          FOTUFILM_AOT_EXTENDED_MTF(FOTUFILM_AOT_NEGATIVE                    \
                                   & ~FOTUFILM_FRAME_ADJACENCY))))           \
    X(negative_grainless_extended_mtf_donor,                                \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ENLARGED(                               \
          FOTUFILM_AOT_EXTENDED_MTF(FOTUFILM_AOT_NEGATIVE                    \
                                   & ~FOTUFILM_FRAME_GRAIN))))              \
    X(negative_no_adjacency_grainless_extended_mtf_donor,                   \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ENLARGED(                               \
          FOTUFILM_AOT_EXTENDED_MTF(FOTUFILM_AOT_NEGATIVE                    \
                                   & ~FOTUFILM_FRAME_ADJACENCY              \
                                   & ~FOTUFILM_FRAME_GRAIN))))              \
    X(color_float_measure_donor,                                            \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
      FOTUFILM_FRAME_FLARE_MEASURE | FOTUFILM_FRAME_FLARE))                   \
    X(color_float_encode_donor,                                             \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
      FOTUFILM_FRAME_ENCODE_OUT))                                            \
    X(color_float_measure_encode_donor,                                     \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
      FOTUFILM_FRAME_FLARE_MEASURE | FOTUFILM_FRAME_FLARE |                   \
      FOTUFILM_FRAME_ENCODE_OUT))                                            \
    X(color_float_fields_donor,                                             \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO |   \
      FOTUFILM_FRAME_FIELDS_IN))                                             \
    X(color_head_donor,                                                     \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_HEAD | FOTUFILM_FRAME_DENSITY_OUT))      \
    X(color_float_realtime_negative_donor,                                  \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_NEGATIVE_SPAN |                         \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME))                     \
    X(color_float_realtime_texture_donor,                                   \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_TEXTURE_SPAN | FOTUFILM_FRAME_FLOAT_IO | \
      FOTUFILM_FRAME_REALTIME))                                              \
    X(color_float_negative_donor,                                           \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_NEGATIVE_SPAN |                         \
      FOTUFILM_FRAME_FLOAT_IO))                                              \
    X(color_float_texture_donor,                                            \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_TEXTURE_SPAN | FOTUFILM_FRAME_FLOAT_IO)) \
    X(color_float_realtime_texture_flat_donor,                              \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_TEXTURE_FLAT_SPAN |                     \
      FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME))                     \
    X(color_float_texture_flat_donor,                                       \
      FOTUFILM_AOT_DONOR(FOTUFILM_AOT_TEXTURE_FLAT_SPAN |                     \
      FOTUFILM_FRAME_FLOAT_IO))                                              \
    /* The `_mottle` twins: the grain-size mixture, served wherever a caller
       asks for it — today the editor's Mottle control, which reaches a
       still's print as readily as a clip's frames. Tight the way the donor
       family is tight, and for the same shape of reason: the host splits the
       published granularity's variance between the sharp field and the coarse
       one, so a variant without the stage keeps the reduced sharp amplitude
       and loses the coarse half — quieter grain, not merely uncoarsened.

       Seven exact-bit classes per colour arm, each carrying every
       superset-able stage (flare, donor, the full stage set): a plain,
       flare, donor or no-print request is covered by the harmless-extra
       rule, while anything in `select_variant`'s `exact_bits` needs its own
       twin. FOTUFILM_FRAME_FLOAT_IO and FOTUFILM_FRAME_REALTIME are both in
       that set, which is the whole reason the first three classes exist.
       The family shipped realtime-only once, while the eight-bit surfaces —
       `processRGBA8`, preview develops and SDR export frames alike — and the
       staged deep road set neither bit. Those fell through to the degrade
       below, and a phone rendered an explicit mixture about 19% quieter than
       no mixture at all. The engine keeps every other road out of this
       family — the mixture is suppressed for the disc model, and for any
       span but the full one — and `select_variant` degrades a stray mottle
       request to its sharp-only variant rather than refusing the frame. */   \
    X(color_mottle,                                                         \
      FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_DONOR(FOTUFILM_AOT_FLARE(               \
      FOTUFILM_AOT_ALL_STAGES))))                                            \
    X(monochrome_mottle,                                                    \
      FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES) |        \
      FOTUFILM_FRAME_MONOCHROME))                                            \
    X(color_float_mottle,                                                   \
      FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_DONOR(FOTUFILM_AOT_FLARE(               \
      FOTUFILM_AOT_ALL_STAGES)) | FOTUFILM_FRAME_FLOAT_IO))                   \
    X(monochrome_float_mottle,                                              \
      FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES) |        \
      FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_FLOAT_IO))                   \
    X(color_float_realtime_mottle,                                          \
      FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_DONOR(FOTUFILM_AOT_FLARE(               \
      FOTUFILM_AOT_ALL_STAGES)) | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_REALTIME))                                              \
    X(monochrome_float_realtime_mottle,                                     \
      FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES) |        \
      FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_REALTIME))                                              \
    X(color_float_realtime_encode_linear_mottle,                            \
      FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_DONOR(FOTUFILM_AOT_FLARE(               \
      FOTUFILM_AOT_ALL_STAGES)) | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_LINEAR))                                         \
    X(monochrome_float_realtime_encode_linear_mottle,                       \
      FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES) |        \
      FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_LINEAR))                                         \
    X(color_float_realtime_encode_power_mottle,                             \
      FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_DONOR(FOTUFILM_AOT_FLARE(               \
      FOTUFILM_AOT_ALL_STAGES)) | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_POWER))                                          \
    X(monochrome_float_realtime_encode_power_mottle,                        \
      FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES) |        \
      FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_POWER))                                          \
    X(color_float_realtime_encode_log_mottle,                               \
      FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_DONOR(FOTUFILM_AOT_FLARE(               \
      FOTUFILM_AOT_ALL_STAGES)) | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_LOG))                                            \
    X(monochrome_float_realtime_encode_log_mottle,                          \
      FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES) |        \
      FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_ENCODE_OUT |                   \
      FOTUFILM_FRAME_OUTPUT_LOG))                                            \
    X(color_float_realtime_measure_encode_log_mottle,                       \
      FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_DONOR(FOTUFILM_AOT_FLARE(               \
      FOTUFILM_AOT_ALL_STAGES)) | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_FLARE_MEASURE |                \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LOG))                 \
    X(monochrome_float_realtime_measure_encode_log_mottle,                  \
      FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_FLARE(FOTUFILM_AOT_ALL_STAGES) |        \
      FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_FLOAT_IO |                   \
      FOTUFILM_FRAME_REALTIME | FOTUFILM_FRAME_FLARE_MEASURE |                \
      FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LOG))                 \
    /* The split recording road develops grain in the tail span, and the
       tail mask carries the mixture bit through, so the tail needs its own
       twins for the same tight reason the family above exists. */          \
    X(color_tail_mottle, FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_TAIL))              \
    X(monochrome_tail_mottle,                                               \
      FOTUFILM_AOT_MOTTLE(FOTUFILM_AOT_TAIL | FOTUFILM_FRAME_MONOCHROME))      \
    /* No film in the gate: `PlainDevelop` as a kernel. Its own small family rather than a
       corner of the others, because FOTUFILM_FRAME_NO_FILM is an exact bit — a variant that
       develops film is not a richer version of one that develops none, it is a different
       picture — so a request for it can be served by nothing else. Four, because the two
       bits a still varies are whether the host's own last step is taken in the kernel and
       whether the transcendentals are exact; no realtime twin until a preview asks for one,
       and no monochrome twin because `FilmStock.noFilm` is not a monochrome stock. */   \
    X(no_film_float, FOTUFILM_FRAME_NO_FILM | FOTUFILM_FRAME_FLOAT_IO)        \
    X(no_film_float_encode,                                                 \
      FOTUFILM_FRAME_NO_FILM | FOTUFILM_FRAME_FLOAT_IO |                      \
      FOTUFILM_FRAME_ENCODE_OUT)                                             \
    X(no_film_float_exact,                                                  \
      FOTUFILM_FRAME_NO_FILM | FOTUFILM_FRAME_FLOAT_IO |                      \
      FOTUFILM_FRAME_EXACT_MATH)                                             \
    X(no_film_float_exact_encode,                                           \
      FOTUFILM_FRAME_NO_FILM | FOTUFILM_FRAME_FLOAT_IO |                      \
      FOTUFILM_FRAME_EXACT_MATH | FOTUFILM_FRAME_ENCODE_OUT) \
    FOTUFILM_AOT_BASIC_VARIANTS(X)

/// Common float video graphs. AOT windowed twins keep the same arguments and physics,
/// with their intermediate rows stored in bounded circular buffers.
#define FOTUFILM_AOT_BASIC_STAGES ((FOTUFILM_AOT_ALL_STAGES & ~(FOTUFILM_FRAME_MTF_LUMA | FOTUFILM_FRAME_DIFFUSION)) | FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME)
#define FOTUFILM_AOT_BASIC_VARIANTS(X) \
    /* Full float video with ordinary emulsion MTF and no lens diffusion. The selector only
       chooses these when those extra stages are absent; active features retain their variants. */ \
    X(color_float_realtime_basic, FOTUFILM_AOT_BASIC_STAGES) \
    X(color_float_realtime_encode_linear_basic, FOTUFILM_AOT_BASIC_STAGES | FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LINEAR) \
    X(color_float_realtime_encode_power_basic, FOTUFILM_AOT_BASIC_STAGES | FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_POWER) \
    X(color_float_realtime_encode_log_basic, FOTUFILM_AOT_BASIC_STAGES | FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LOG) \
    X(monochrome_float_realtime_basic, FOTUFILM_AOT_BASIC_STAGES | FOTUFILM_FRAME_MONOCHROME) \
    X(monochrome_float_realtime_encode_linear_basic, FOTUFILM_AOT_BASIC_STAGES | FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LINEAR) \
    X(monochrome_float_realtime_encode_power_basic, FOTUFILM_AOT_BASIC_STAGES | FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_POWER) \
    X(monochrome_float_realtime_encode_log_basic, FOTUFILM_AOT_BASIC_STAGES | FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LOG)

/// The bits that select a variant. An allow-list — and since the `_mottle`
/// twins, the grain mixture is one of them: a mottle request must be served
/// by a variant that compiled the stage, because the host has already split
/// the published granularity between the two fields (see the twins above).
/// `FOTUFILM_AOT_ALL_STAGES` carries the enlarger, so it
/// is a selector too, but the only one a request may lack and still match: see the note there.
#define FOTUFILM_AOT_VARIANT_BITS                                            \
    (FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_GRAIN_MOTTLE |                  \
     FOTUFILM_FRAME_FLARE |                                                  \
     FOTUFILM_FRAME_MONOCHROME |                                             \
     FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME |                      \
     FOTUFILM_FRAME_EXACT_MATH | FOTUFILM_FRAME_DENSITY_OUT |                 \
     FOTUFILM_FRAME_DENSITY_IN | FOTUFILM_FRAME_DISC_GRAIN |                  \
     FOTUFILM_FRAME_FLARE_MEASURE | FOTUFILM_FRAME_ENCODE_OUT |               \
     FOTUFILM_FRAME_OUTPUT_LINEAR | FOTUFILM_FRAME_OUTPUT_POWER |             \
     FOTUFILM_FRAME_OUTPUT_LOG | FOTUFILM_FRAME_LIGHT_OUT |                   \
     FOTUFILM_FRAME_FIELDS_IN | FOTUFILM_FRAME_TEXTURE |                      \
     FOTUFILM_FRAME_DONOR_LAYER | FOTUFILM_FRAME_NO_FILM)

/// Sigma of the Gaussian that three iterated box blurs of `radius` approximate.
static inline float fotufilm_halation_box_sigma(int32_t radius) {
    const float width = (float)(2 * radius + 1);
    return sqrtf((width * width - 1.0f) * 0.25f);
}

/// Decimation stride for one halation scale: the largest power of two that keeps the decimated
/// sigma comfortably above the grid (>= 2.5 samples), so the down/up resampling adds spread that
/// stays negligible against the blur itself.
static inline int32_t fotufilm_halation_stride(int32_t radius) {
    const float sigma = fotufilm_halation_box_sigma(radius);
    int32_t stride = 1;
    while (stride < 8 && (float)(2 * stride) * 2.5f <= sigma) stride *= 2;
    return stride;
}

/// Diffusion decimation with a stride ceiling of 64. Keeping decimated sigma near 2.5 samples
/// prevents large mist radii from creating oversized aprons; halation retains its ceiling of 8.
static inline int32_t fotufilm_diffusion_stride(int32_t radius) {
    const float sigma = fotufilm_halation_box_sigma(radius);
    int32_t stride = 1;
    while (stride < 64 && (float)(2 * stride) * 2.5f <= sigma) stride *= 2;
    return stride;
}

/// Box radius on the decimated grid whose three-pass chain, together with the spread the box
/// downsample and bilinear upsample add, matches the full-resolution chain's Gaussian sigma.
static inline int32_t fotufilm_halation_strided_radius(int32_t radius,
                                                      int32_t stride) {
    if (stride <= 1) return radius;
    const float sigma = fotufilm_halation_box_sigma(radius);
    float variance = sigma * sigma / (float)(stride * stride) - 0.25f;
    if (variance < 0.25f) variance = 0.25f;
    const float width = sqrtf(4.0f * variance + 1.0f);
    const int32_t scaled = (int32_t)((width - 1.0f) * 0.5f + 0.5f);
    return scaled < 1 ? 1 : scaled;
}

/// IEEE half from a float, round-to-nearest-even.
static inline uint16_t fotufilm_float_to_half(float value) {
    union { float f; uint32_t u; } bits;
    bits.f = value;
    const uint32_t sign = (bits.u >> 16) & 0x8000u;
    const uint32_t magnitude = bits.u & 0x7fffffffu;
    if (magnitude >= 0x7f800000u) {
        return (uint16_t)(sign | 0x7c00u | (magnitude > 0x7f800000u ? 0x200u : 0u));
    }
    if (magnitude >= 0x477ff000u) return (uint16_t)(sign | 0x7c00u);
    if (magnitude < 0x38800000u) {
        if (magnitude < 0x33000000u) return (uint16_t)sign;
        const uint32_t shifted = (magnitude & 0x7fffffu) | 0x800000u;
        const int shift = 126 - (int)(magnitude >> 23);
        const uint32_t base = shifted >> shift;
        const uint32_t remainder = shifted & ((1u << shift) - 1u);
        const uint32_t halfway = 1u << (shift - 1);
        uint32_t rounded = base;
        if (remainder > halfway || (remainder == halfway && (base & 1))) ++rounded;
        return (uint16_t)(sign | rounded);
    }
    uint32_t half = ((magnitude >> 13) & 0x3ffu)
        | ((uint32_t)((int)(magnitude >> 23) - 112) << 10);
    const uint32_t remainder = magnitude & 0x1fffu;
    if (remainder > 0x1000u || (remainder == 0x1000u && (half & 1))) ++half;
    return (uint16_t)(sign | half);
}

/// Returns 1 when this target was compiled against Halide, otherwise 0.
int32_t fotufilm_halide_available(void);

/// Stages 1-7 of the film model: spectral exposure through the stock's LUT (HDR radiance above 1
/// preserved), veiling glare with the exact frame mean, per-layer emulsion diffusion,
/// base-reflection halation, DIR coupler inhibition + adjacency, H&D development (reversal stocks
/// complemented to their measured direct-positive densities), and calibrated clump grain.
int32_t fotufilm_halide_develop(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height,
    const float *configuration,
    const float *exposure_lut, int32_t lut_dimension,
    int32_t feature_mask, uint32_t seed);

/// Stage 8: developed densities to display-linear RGB.
int32_t fotufilm_halide_print(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height,
    const float *configuration,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, int32_t feature_mask);

/// Both halves at once: scene-linear RGB in, display-linear RGB out.
int32_t fotufilm_halide_process(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    int32_t feature_mask, uint32_t seed);

/// One horizontal strip of a frame, developed and printed.
int32_t fotufilm_halide_process_strip(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height,
    int32_t output_width, int32_t output_height,
    int32_t origin_x, int32_t origin_y,
    int32_t interior_top, int32_t interior_height,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    int32_t feature_mask, uint32_t seed);

/// Single-plane blur kernels used by the public Blur API.
int32_t fotufilm_halide_gaussian(
    const float *input, float *output, int32_t width, int32_t height,
    float sigma, int32_t radius);
int32_t fotufilm_halide_approximate_gaussian(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t radius);

/// Returns 1 when a usable Halide CUDA target is present on this host — a Linux box with a
/// driver the pipeline can reach. The CUDA entry points run the same schedules as the Metal ones,
/// and come in two pairs: host buffers, and the device pointers below.
int32_t fotufilm_halide_cuda_available(void);

/// The CUDA counterpart of `fotufilm_halide_metal_prepare`.
int32_t fotufilm_halide_cuda_prepare(
    int32_t feature_mask,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id);

/// The CUDA counterpart of `fotufilm_halide_metal_process_srgb8`.
int32_t fotufilm_halide_cuda_process_srgb8(
    const uint8_t *input, uint8_t *output, int32_t width, int32_t height,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed);

/// The CUDA counterpart of `fotufilm_halide_metal_process_linear_float`.
int32_t fotufilm_halide_cuda_process_linear_float(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed);

/// Develops tightly packed RGBA from caller-owned CUdeviceptr buffers without device-host copies.
/// Both buffers must belong to the CUDA context current on the engine's first driver call; the
/// caller retains allocation ownership.
int32_t fotufilm_halide_cuda_process_device_srgb8(
    uint64_t input_device_pointer, uint64_t output_device_pointer,
    int32_t width, int32_t height,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed);

/// The float counterpart of `fotufilm_halide_cuda_process_device_srgb8`.
int32_t fotufilm_halide_cuda_process_device_linear_float(
    uint64_t input_device_pointer, uint64_t output_device_pointer,
    int32_t width, int32_t height, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed);

/// Returns 1 when a usable Halide Metal target is present on this host.
int32_t fotufilm_halide_metal_available(void);

/// Whether a variant was generated that can develop `feature_mask`. Asked before setting a bit
/// the build may not carry — FOTUFILM_FRAME_FLARE_MEASURE is generated for the float variants
/// only, and a caller that cannot have it has to measure the glare itself.
int32_t fotufilm_halide_metal_variant_exists(int32_t feature_mask);

/// Prints Halide's per-stage profile of every frame run so far, on a build
/// whose kernels were generated with FOTUFILM_HALIDE_PROFILE set.
void fotufilm_halide_metal_report_profile(void);

/// Compiles the requested feature variant and uploads the stock's spectral
/// tables without processing a frame.
int32_t fotufilm_halide_metal_prepare(
    int32_t feature_mask,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id);

/// Fused RGBA8 frame processing: sRGB decode, the eight-stage spectral film model, and sRGB encode.
int32_t fotufilm_halide_metal_process_srgb8(
    const uint8_t *input, uint8_t *output, int32_t width, int32_t height,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed);

/// Scene-referred processing: interleaved linear float RGBA in and out, with
/// values above 1.0 carried through the whole model.
int32_t fotufilm_halide_metal_process_linear_float(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed);

/// `process_linear_float` delivering only rows [out_y, out_y + out_rows) of the strip: `output`
/// holds `out_rows` tightly packed rows, and the apron rows above and below are computed only
/// through the stages a delivered pixel reads them from. Delivered pixels match the uncropped
/// call's exactly.
int32_t fotufilm_halide_metal_process_linear_float_rows(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t out_y, int32_t out_rows,
    int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed);

/// The first pass of the two-pass striped still path: develops rows [out_y, out_y + out_rows)
/// of the strip only as far as veiling glare and the emulsion MTF, delivering that light as
/// tightly packed interleaved float RGBA — a strip of light needs only the MTF's apron. The
/// caller's mask should carry the stages up to the light (flare, MTF) and the frame's identity
/// bits; FLOAT_IO and LIGHT_OUT are implied.
int32_t fotufilm_halide_metal_process_light_rows(
    const float *input, float *light_out, int32_t width, int32_t height,
    int32_t out_y, int32_t out_rows,
    int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed);

/// Floats a whole-frame halation fields blob occupies for this frame size and these halation
/// radii (FOTUFILM_CONFIG_HALATION_RADIUS values, 3 of them), header included. Negative on a
/// build that cannot serve the fields path.
int32_t fotufilm_halide_metal_halation_fields_floats(
    int32_t width, int32_t height, const int32_t *halation_radii);

/// Builds the halation pyramid's three blurred grids from the whole frame of light a
/// LIGHT_OUT pass wrote, into `fields` (sized by the floats call above), with the same
/// arithmetic a staged develop runs internally.
int32_t fotufilm_halide_metal_halation_fields(
    const float *light, int32_t width, int32_t height,
    const int32_t *halation_radii, float *fields, int32_t fields_floats);

/// The second pass: `process_linear_float_rows`, except halation samples the provided
/// whole-frame fields instead of building a pyramid from the strip, so the strip needs no
/// halation apron. `fields_id` names the blob so the strips of one frame upload it once; it
/// must change when the blob does.
int32_t fotufilm_halide_metal_process_linear_float_fields_rows(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t out_y, int32_t out_rows,
    int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *fields, int32_t fields_floats, uint64_t fields_id,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed);

/// The kStillFast* bits this build's approximate-math float still schedule was generated with
/// (0 where the still path is the untouched reference), for hosts whose memory model follows
/// the schedule.
int32_t fotufilm_halide_metal_still_fast_bits(void);

/// Zero-copy variant for caller-owned MTLBuffers.
int32_t fotufilm_halide_metal_process_buffers(
    uint64_t input_mtl_buffer, uint64_t output_mtl_buffer,
    int32_t width, int32_t height, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed);

/// The zero-copy form of `process_linear_float`, for a stream of high-bit- depth frames:
/// caller-owned MTLBuffers of interleaved linear float RGBA, width * height * 16 bytes each.
int32_t fotufilm_halide_metal_process_buffers_float(
    uint64_t input_mtl_buffer, uint64_t output_mtl_buffer,
    int32_t width, int32_t height, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed);

/// The hybrid fast develop's two halves, both zero-copy over caller-owned MTLBuffers.
int32_t fotufilm_halide_metal_process_buffers_head(
    uint64_t input_mtl_buffer, uint64_t density_mtl_buffer,
    int32_t width, int32_t height, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed);

int32_t fotufilm_halide_metal_process_buffers_tail(
    uint64_t density_mtl_buffer, uint64_t output_mtl_buffer,
    int32_t width, int32_t height,
    int32_t density_width, int32_t density_height,
    int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed);

/// Per-row tone and glare measurements for linear-float RGBA bands. Tone writes `grid_width`
/// log2-luminance sums per row. Glare writes three layer-exposure sums per row after the tone grid
/// is solved. Input is either an MTLBuffer or host rows. Returns 0 or -1 on invalid input/device failure.
int32_t fotufilm_halide_metal_measure_tone_rows(
    uint64_t input_mtl_buffer, const float *input_rows, float *rows_out,
    int32_t grid_width, int32_t width, int32_t rows,
    const float *configuration);

int32_t fotufilm_halide_metal_measure_flare_rows(
    uint64_t input_mtl_buffer, const float *input_rows, float *rows_out,
    int32_t width, int32_t rows, int32_t origin_y,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, uint64_t spectral_cache_id, int32_t feature_mask);

/// Decodes RGBA rows by repairing non-finite values, optionally un-premultiplying, applying the
/// transfer, and converting to scene space. Inputs and outputs may independently use MTLBuffers or
/// host rows. `report_out` stores the pre-repair RGB peak and repair flag per row. Returns 0 or -1.
int32_t fotufilm_halide_metal_decode_rows(
    uint64_t input_mtl_buffer, const float *input_rows,
    uint64_t output_mtl_buffer, float *output_rows, float *report_out,
    int32_t width, int32_t rows, const float *parameters);

/// Realtime spelling of `fotufilm_halide_metal_decode_rows`: identical coefficients, repair, and
/// reporting, with the video schedule's bounded transfer approximations.
int32_t fotufilm_halide_metal_decode_rows_realtime(
    uint64_t input_mtl_buffer, const float *input_rows,
    uint64_t output_mtl_buffer, float *output_rows, float *report_out,
    int32_t width, int32_t rows, const float *parameters);

#ifdef __cplusplus
}
#endif

#endif
