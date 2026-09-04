#ifndef FOTUFILM_BRIDGE_H
#define FOTUFILM_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Indices into the parameter array.
enum {
    FOTUFILM_BRIDGE_EXPOSURE_EV = 0,
    /// The illuminant the scene was lit by, in kelvin.
    FOTUFILM_BRIDGE_TEMPERATURE,
    FOTUFILM_BRIDGE_TINT,
    FOTUFILM_BRIDGE_HIGHLIGHTS,
    FOTUFILM_BRIDGE_SHADOWS,
    FOTUFILM_BRIDGE_SATURATION,
    FOTUFILM_BRIDGE_VIBRANCE,
    FOTUFILM_BRIDGE_GRAIN_SCALE,
    FOTUFILM_BRIDGE_HALATION_SCALE,
    FOTUFILM_BRIDGE_COUPLER_SCALE,
    FOTUFILM_BRIDGE_PRINT_CORRECTION,
    /// Non-zero keys the highlight/shadow shifts to an edge-aware regional
    /// base rather than to each pixel's own luminance.
    FOTUFILM_BRIDGE_LOCAL_TONE,
    /// Stops of push (positive) or pull (negative) development.
    FOTUFILM_BRIDGE_PUSH_PULL,
    /// How much of the developed silver the bleach leaves in the negative, 0...1.
    FOTUFILM_BRIDGE_BLEACH_BYPASS,
    /// Years the roll sat past its process-by date, 0 up.
    FOTUFILM_BRIDGE_EXPIRED_YEARS,
    /// The illuminant a physical print is viewed under, in kelvin. Zero uses the medium reference:
    /// D50 for reflection paper or calibrated 5400 K xenon for projection. Digital media ignore it.
    FOTUFILM_BRIDGE_PRINT_LIGHT,
    /// Which span of the pipeline this render performs, as a `fotufilm_bridge_stage_*` index.
    /// Not a lever: it changes what the frames on both sides of the call mean. See the stage
    /// contract below.
    FOTUFILM_BRIDGE_STAGE,
    /// Which spatial stages the texture span lays over the frame, as an OR of the masks
    /// `fotufilm_bridge_texture_stage_mask` hands out. Read only by that span.
    FOTUFILM_BRIDGE_TEXTURE_STAGES,
    /// Multiplier on the taking lens's veiling glare. 0 — the default — leaves
    /// the stage out: a photographed clip already carries its own lens's glare.
    FOTUFILM_BRIDGE_FLARE_SCALE,
    /// Non-zero renders halation through a stock's provisional annular profile where no
    /// independently calibrated one exists. 0 — the default, and the slot an older project
    /// never filled — is the exact legacy model, so existing renders do not move.
    FOTUFILM_BRIDGE_ESTIMATED_HALATION,
    /// How much the halo keeps the source's own colour instead of the stock's layered red,
    /// 0–1. The dimmer records are raised to the strongest record's return, so the ring
    /// brightens toward the light's colour. 0 — the default, and the slot an older project
    /// never filled — is the film.
    FOTUFILM_BRIDGE_HALATION_COLOUR,
    /// Up to three absorbing filters screwed onto the front of the lens, in the order the light
    /// meets them, each as a `fotufilm_bridge_lens_filter_*` index plus one. 0 — the default, and
    /// the slot an older project never filled — is an empty thread. No filter is not a clear
    /// filter: a clear filter would still cost light and still make a ghost.
    FOTUFILM_BRIDGE_LENS_FILTER_1,
    FOTUFILM_BRIDGE_LENS_FILTER_2,
    FOTUFILM_BRIDGE_LENS_FILTER_3,
    /// How the exposure was set with those filters fitted, as a `fotufilm_bridge_metering_*` index
    /// plus one. 0 is the engine's own default, through-the-lens metering, so the slot an older
    /// project never filled reads as it always did. Ignored when no filter is fitted.
    FOTUFILM_BRIDGE_LENS_METERING,
    /// A diffusion filter on the front of the lens, as a `fotufilm_bridge_diffusion_family_*`
    /// index plus one. 0 — the default, and the slot an older project never filled — is none.
    FOTUFILM_BRIDGE_DIFFUSION_FAMILY,
    /// Its grade — what a product line's 1/8, 1/4, 1/2, 1 and 2 name, one formulation at
    /// increasing particle loadings — as a bare `fotufilm_bridge_diffusion_grade_*` index, not
    /// offset. Read only when a family is chosen, which is what keeps zero an off position for
    /// the pair rather than for this slot on its own.
    FOTUFILM_BRIDGE_DIFFUSION_GRADE,
    /// The taking lens's focal length in millimetres. Read only by the diffusion filter, which
    /// needs it because a ray deviated by an angle ahead of the lens lands `focal length × angle`
    /// off its unscattered position — so the same filter glows bigger on a longer lens, exactly
    /// as it does in the world. 0 — the default, and the slot an older project never filled — is
    /// the gauge's own normal lens.
    FOTUFILM_BRIDGE_FOCAL_LENGTH,
    /// How a developed negative is read, as a `fotufilm_bridge_negative_viewing_*` index plus one.
    /// 0 — the default, and the slot an older project never filled — leaves the choice to the
    /// engine, which reads a negative on a light box.
    ///
    /// Applied only where the negative medium was explicitly chosen. A viewing mode is not a
    /// look: to the engine a stated one *is* the instruction to show the negative, so carrying
    /// this slot into a print render would replace the print with the film.
    FOTUFILM_BRIDGE_NEGATIVE_VIEWING,
    FOTUFILM_BRIDGE_PARAMETER_COUNT,
};

/// The id a host persists for the "None" entry its filter and diffusion menus open with. The
/// engine has no name for an empty filter thread, so the name is this contract's, spelled once:
/// it is a persisted project id, and two hosts spelling it differently would each orphan the
/// other's saved filter choices.
#define FOTUFILM_BRIDGE_NO_FILTER_ID "none"

/// Per-effect bridge state. Separate OFX instances may render concurrently; each context owns its
/// Metal argument/LUT cache, borrowed staging, and most recent error.
typedef void *FotufilmBridgeContext;

FotufilmBridgeContext fotufilm_bridge_context_create(void);
void fotufilm_bridge_context_destroy(FotufilmBridgeContext context);

/// Pipeline spans in stable index order; hosts persist the stage ID.
/// Full maps scene light to a finished print. Negative maps scene light to diffuse base-10 layer
/// density. Print maps those densities to a finished print. Texture returns scene-linear Rec.2020
/// with selected spatial effects only.
///
/// Negative interchange stores R/G/B-sensitive layer densities in [-0.5, 8], transmits as `10^-D`,
/// and preserves alpha. It must not be transformed, resampled, or transfer-encoded, and both spans
/// must use the same stock and lab settings. Print input must bypass scene decode. Texture output
/// transforms must convert from the scene basis rather than the Display P3 print basis.
enum {
    FOTUFILM_BRIDGE_STAGE_FULL = 0,
    FOTUFILM_BRIDGE_STAGE_NEGATIVE = 1,
    FOTUFILM_BRIDGE_STAGE_PRINT = 2,
    FOTUFILM_BRIDGE_STAGE_TEXTURE = 3,
};

/// The spans, in the order above.
int32_t fotufilm_bridge_stage_count(void);
int32_t fotufilm_bridge_stage_id(int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_stage_name(int32_t index, char *out, int32_t capacity);

/// The spatial stages the texture span can be asked for, in a fixed order. `mask` is the bit to
/// OR into FOTUFILM_BRIDGE_TEXTURE_STAGES; it is handed out rather than published as a constant so
/// that the two sides cannot drift apart.
int32_t fotufilm_bridge_texture_stage_count(void);
int32_t fotufilm_bridge_texture_stage_id(int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_texture_stage_name(int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_texture_stage_mask(int32_t index);

/// Whether `stock` has anything to give the `index`-th spatial stage: 1 where its own
/// measurements put something behind it, 0 where they do not. A remjet-backed stock returns no
/// light from its base, a coupler-free stock has no adjacency, and a reversal stock never meets
/// an enlarger — selecting one of those would be inert rather than wrong, which is worse.
///
/// Asked of the engine rather than worked out by the host, for the same reason the masks are:
/// what a film has is the film's own data, and a second copy of that judgement would drift.
int32_t fotufilm_bridge_texture_stage_available(int32_t stock, int32_t index);

/// Whether `stock` goes through a print at all. A reversal stock is its own positive: it is
/// viewed directly, has no print, and the print span therefore performs only the film's own
/// read of it rather than an enlarger and a paper.
int32_t fotufilm_bridge_stock_prints(int32_t stock);

/// Whether the stock carries at least one measured non-reference development condition.
int32_t fotufilm_bridge_stock_pushes(int32_t stock);
/// The nearest measured condition, including reference development at zero. This keeps Resolve's
/// numeric OFX parameter from creating an interpolated process the engine does not carry.
float fotufilm_bridge_stock_snap_push(int32_t stock, float requested);

/// Point the engine at the resources it ships with, before anything else is called.
int32_t fotufilm_bridge_initialize(const char *resources);

/// Whether a usable Halide Metal device was found. The host-facing OFX path uses CPU image
/// pointers; this describes the internal compute backend, not an OFX GPU-render capability.
int32_t fotufilm_bridge_available(void);

/// Whether Resolve renders with the default realtime schedule. Set `FOTUFILM_REALTIME=0` in the
/// host's environment before launch to restore the reference path for comparison.
int32_t fotufilm_bridge_realtime_enabled(void);

/// The loaded stocks, in the engine's display order (by id).
int32_t fotufilm_bridge_stock_count(void);
/// Copies the id/display name of `index` into `out` as a NUL-terminated string.
int32_t fotufilm_bridge_stock_id(int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_stock_name(int32_t index, char *out, int32_t capacity);

/// The film gauges, in FilmFormat.presets order.
int32_t fotufilm_bridge_format_count(void);
int32_t fotufilm_bridge_format_id(int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_format_name(int32_t index, char *out, int32_t capacity);

/// The output media, in PrintPaper.allCases order. A reversal stock is viewed directly and has no
/// negative or print, so unsupported choices resolve to its direct positive.
int32_t fotufilm_bridge_paper_count(void);
int32_t fotufilm_bridge_paper_id(int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_paper_name(int32_t index, char *out, int32_t capacity);

/// The filter drawer, in `LensFilter.catalogue` order: conversion, light balancing, contrast,
/// ultraviolet, neutral density, colour compensating. The id is the durable one — the same
/// string the engine's own command line takes for `--filter` — and it is what a host must
/// persist: a catalogue that gains an entry renumbers every index after it, and a project that
/// saved a position would then be graded through a different piece of glass.
int32_t fotufilm_bridge_lens_filter_count(void);
int32_t fotufilm_bridge_lens_filter_id(int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_lens_filter_name(int32_t index, char *out, int32_t capacity);

/// How the exposure was set behind a filter, in `LensFilterCompensation.allCases` order: no
/// compensation, through-the-lens metering, published filter factor.
int32_t fotufilm_bridge_metering_count(void);
int32_t fotufilm_bridge_metering_id(int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_metering_name(int32_t index, char *out, int32_t capacity);

/// The diffusion families, in `DiffusionFilter.Family.allCases` order, and the grades they are
/// sold in, in `DiffusionFilter.Grade.allCases` order. The family fixes particle size and whether
/// the particles are transparent or absorbing; the grade is the loading.
int32_t fotufilm_bridge_diffusion_family_count(void);
int32_t fotufilm_bridge_diffusion_family_id(int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_diffusion_family_name(int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_diffusion_grade_count(void);
int32_t fotufilm_bridge_diffusion_grade_id(int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_diffusion_grade_name(int32_t index, char *out, int32_t capacity);
/// The grade a host should offer as its default, which is the one the engine's command line
/// takes when `--diffusion-grade` is not given.
int32_t fotufilm_bridge_diffusion_default_grade(void);

/// How a developed negative is read, in `NegativeViewing.allCases` order: normalised on the
/// viewing light, or on the film's own base so only the image's inversion is left.
int32_t fotufilm_bridge_negative_viewing_count(void);
int32_t fotufilm_bridge_negative_viewing_id(int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_negative_viewing_name(int32_t index, char *out, int32_t capacity);

/// Whether the output medium at `index` is the developed negative itself — the one medium the
/// negative-viewing slot is read for. Asked of the engine rather than matched against an id here,
/// for the same reason the texture masks are.
int32_t fotufilm_bridge_paper_is_negative(int32_t index);

/// Compile the schedule and upload the stock's spectral tables without rendering.
int32_t fotufilm_bridge_prepare(FotufilmBridgeContext context,
                               int32_t stock, int32_t format, int32_t paper,
                               const float *parameters,
                               int32_t width, int32_t height);

/// Asked between engine passes whether the host still wants the frame; return 0 to stop.
typedef int32_t (*fotufilm_bridge_should_continue)(void *context);

/// Receives finished rows `[row_begin, row_end)` as they leave the engine, top row first —
/// `(row_end - row_begin) * width * 4` interleaved RGBA floats. Every row of the frame is
/// delivered exactly once, in order.
///
/// What the floats are is the span's: the developed print in its display-linear Display P3
/// delivery basis for `full` and `print`, per-layer density for `negative`, and scene-linear
/// Rec.2020 light for `texture`. See the stage contract above.
typedef void (*fotufilm_bridge_write_rows)(void *context, int32_t row_begin,
                                          int32_t row_end, const float *rows);

/// Optional final matrix, transfer, and premultiplication applied in the producing kernel.
/// Both render paths apply it identically. Pass NULL for display-linear light or when the host must
/// resample, because resampling requires linear light. Check `fotufilm_bridge_encodes_output` first.
struct FotufilmOutputTransform {
    /// 0 identity, 1 sign-preserving power law, 2 signed logarithm; fotufilm::outputTransformFor
    /// fills this and `coefficients` from the timeline's colour space.
    int32_t transfer;
    int32_t premultiplied;
    /// Row-major, out of the print's Display P3 delivery basis into the host's primaries.
    float matrix[9];
    float coefficients[6];
};

/// Returns whether the render call this frame will take can apply an output transform for these
/// settings. Query before streaming begins; a promised transform causes render failure if its
/// kernel becomes unavailable. This performs feature-mask setup without processing pixels.
///
/// Ask it *after* `fotufilm_bridge_frame_staging` has claimed or refused staging for the frame:
/// the answer is for the road that staging implies. A staged render may take the kernel that
/// measures its own glare — `interactive` here must be what `fotufilm_bridge_render_staged` will
/// be given — and a striped render never does, so with no staging held the flag is ignored and
/// the question is asked as `fotufilm_bridge_render` will ask it.
int32_t fotufilm_bridge_encodes_output(FotufilmBridgeContext context,
                                      int32_t stock, int32_t format, int32_t paper,
                                      const float *parameters,
                                      int32_t width, int32_t height, int32_t interactive);

/// Develops one frame. `input` is interleaved RGBA, `width * height * 4` floats: scene-linear
/// Rec.2020 — the engine's working space — for every span but `print`, which is handed per-layer
/// density instead. The result is streamed to `write_rows` rather than materialised, so no
/// whole-frame output buffer exists on either side. Returns 1 when the frame completed, -1 when
/// `should_continue` stopped it early (not a failure; no error is recorded), and 0 on failure.
/// Both callbacks are invoked on the calling thread, before this returns. `should_continue` may
/// be NULL for a render that cannot be interrupted.
int32_t fotufilm_bridge_render(FotufilmBridgeContext context,
                              int32_t stock, int32_t format, int32_t paper,
                              const float *parameters, uint32_t seed,
                              const float *input,
                              int32_t width, int32_t height, uint64_t frame,
                              fotufilm_bridge_write_rows write_rows,
                              void *write_context,
                              struct FotufilmOutputTransform *output_transform,
                              fotufilm_bridge_should_continue should_continue,
                              void *abort_context);

/// Borrows tightly packed, top-first GPU input/output buffers for a `width * height` RGBA-float
/// frame. Returns 1 when one-pass staging is available, otherwise 0 and the caller must use striped
/// rendering. Buffers remain valid until release or the next staging request on this context.
int32_t fotufilm_bridge_frame_staging(FotufilmBridgeContext context,
                                     int32_t width, int32_t height,
                                     float **input, float **output);

/// Returns the context's borrowed staging after the host has copied the developed output. Safe to
/// call when no staging was borrowed. A render that aborts after decode must still call this.
void fotufilm_bridge_release_staging(FotufilmBridgeContext context);

/// Host-to-engine matrix, transfer decode, and premultiplication state.
/// Input and output transfer coefficients are defined independently and are not algebraic inverses.
///
///   transfer 0  identity — the host's space is already linear.
///            1  power law, sign-preserving: |v| <= c4 ? |v| * c0 : pow(c1 * |v| + c3, c2).
///            2  exponential, signed: v <= c4 ? (v - c3) * c0 : exp(v * c1 - c2) - c5, the gain
///               carrying the change of base so a natural exponential reaches a base-two curve.
///
/// `fotufilm::inputTransformFor` fills it, and is the only definition of which coefficients a
/// space takes.
struct FotufilmInputTransform {
    int32_t transfer;
    int32_t premultiplied;
    /// Row-major, out of the host's primaries into the engine's scene working space.
    float matrix[9];
    float coefficients[6];
};

/// Decodes tightly packed host pixels from staging output into scene-linear staging input.
/// `peak` receives the largest finite pre-repair RGB value; `repaired` reports any non-finite
/// replacement. Either may be NULL. Returns 1 on success and 0 when staging, Metal, or the kernel
/// is unavailable. Arithmetic order matches `fotufilm::decodePixels` but GPU transcendentals may differ.
int32_t fotufilm_bridge_decode_staged(FotufilmBridgeContext context,
                                     int32_t width, int32_t height,
                                     const struct FotufilmInputTransform *transform,
                                     float *peak, int32_t *repaired);

/// Decodes a non-overlapping band of tightly packed, top-first RGBA host rows with the staged
/// decode kernel. Results are independent of band size. Combine per-band `peak` by maximum and
/// `repaired` by logical OR. Returns 1 on success and 0 on failure.
int32_t fotufilm_bridge_decode_rows(const float *in, float *out,
                                   int32_t width, int32_t rows,
                                   const struct FotufilmInputTransform *transform,
                                   float *peak, int32_t *repaired);

/// Develops borrowed staging input into output with the same status codes as
/// `fotufilm_bridge_render`. Nonzero `interactive` enables a faster float32 GPU glare reduction
/// that differs from the host reduction by about 1.3×10⁻⁵; use zero for retained output.
/// `output_transform` returns host encoding instead of display-linear Display P3 when supported.
int32_t fotufilm_bridge_render_staged(FotufilmBridgeContext context,
                                     int32_t stock, int32_t format, int32_t paper,
                                     const float *parameters, uint32_t seed,
                                     int32_t width, int32_t height, uint64_t frame,
                                     int32_t interactive,
                                     struct FotufilmOutputTransform *output_transform,
                                     fotufilm_bridge_should_continue should_continue,
                                     void *abort_context);

/// Copies the most recent failure into `out`.
int32_t fotufilm_bridge_last_error(FotufilmBridgeContext context,
                                  char *out, int32_t capacity);

#ifdef __cplusplus
}
#endif

#endif
