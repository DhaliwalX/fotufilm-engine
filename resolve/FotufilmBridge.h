#ifndef FOTUFILM_BRIDGE_H
#define FOTUFILM_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#include "Generated/FotufilmBridgeSlots.h"

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

/// Camera choices follow the eight working spaces in the Resolve Input Color Space menu.
/// Shared core curves decode full-range RGB to scene-linear Rec.2020 (grey = 0.18).
int32_t fotufilm_bridge_camera_input_count(void);
int32_t fotufilm_bridge_camera_input_name(int32_t index, char *out, int32_t capacity);
/// 1 = clean, 0 = repaired non-finite pixels, -1 = invalid arguments. Rows may be decoded concurrently.
int32_t fotufilm_bridge_decode_camera(int32_t index, const float *input, float *output,
                                    int32_t count, int32_t premultiplied);

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
int32_t fotufilm_bridge_development_basis(int32_t stock, char *out, int32_t capacity);
/// The nearest listed condition, including reference development at zero. This keeps Resolve's
/// numeric OFX parameter from creating an interpolated process the engine does not carry.
float fotufilm_bridge_stock_snap_push(int32_t stock, float requested);

/// Capabilities of the effective stock/output, for control availability.
enum {
    FOTUFILM_CONTROL_COLOUR_NEGATIVE = 1,
    FOTUFILM_CONTROL_COUPLER_GEOMETRY = 2,
    FOTUFILM_CONTROL_RECIPROCITY = 4,
    FOTUFILM_CONTROL_VIEWING_LIGHT = 8,
    FOTUFILM_CONTROL_PRINT_CORRECTION = 16,
    FOTUFILM_CONTROL_COLOUR_FILM = 32,
    FOTUFILM_CONTROL_COUPLERS = 64,
    FOTUFILM_CONTROL_ENLARGER = 128,
    FOTUFILM_CONTROL_INTERLAYER_INHIBITION = 256,
    FOTUFILM_CONTROL_SCREEN_CONVERSION = 512,
    FOTUFILM_CONTROL_SCREEN_GRADE = 1024,
    FOTUFILM_CONTROL_LAB_SCAN = 2048,
    FOTUFILM_CONTROL_PRINTER_LIGHTS = 4096,
    FOTUFILM_CONTROL_PRINT_DETAIL = 8192,
};
int32_t fotufilm_bridge_control_capabilities(int32_t stock, int32_t paper);

enum {
    FOTUFILM_HOST_RESOLVE = 0,
    FOTUFILM_HOST_FINALCUT = 1,
};

enum {
    FOTUFILM_HOST_KIND_DOUBLE = 0,
    FOTUFILM_HOST_KIND_INTEGER = 1,
    FOTUFILM_HOST_KIND_BOOLEAN = 2,
    FOTUFILM_HOST_KIND_CHOICE = 3,
    FOTUFILM_HOST_KIND_MENU = 4,
    FOTUFILM_HOST_KIND_LABEL = 5,
    FOTUFILM_HOST_KIND_HIDDEN_STRING = 6,
    FOTUFILM_HOST_KIND_PUSH_BUTTON = 7,
    FOTUFILM_HOST_KIND_GROUP = 8,
    FOTUFILM_HOST_KIND_TEXTURE_TOGGLES = 9,
};

enum {
    FOTUFILM_HOST_MENU_NONE = 0,
    FOTUFILM_HOST_MENU_STOCKS = 1,
    FOTUFILM_HOST_MENU_GAUGES = 2,
    FOTUFILM_HOST_MENU_PAPERS = 3,
    FOTUFILM_HOST_MENU_STAGES = 4,
    FOTUFILM_HOST_MENU_LENS_FILTERS = 5,
    FOTUFILM_HOST_MENU_METERINGS = 6,
    FOTUFILM_HOST_MENU_DIFFUSION_FAMILIES = 7,
    FOTUFILM_HOST_MENU_DIFFUSION_GRADES = 8,
    FOTUFILM_HOST_MENU_NEGATIVE_VIEWINGS = 9,
    FOTUFILM_HOST_MENU_COLOUR_SPACES = 10,
    FOTUFILM_HOST_MENU_PUSH_CONDITIONS = 11,
    FOTUFILM_HOST_MENU_TEXTURE_STAGES = 12,
};

enum {
    FOTUFILM_HOST_FLAG_ANIMATES = 1,
    FOTUFILM_HOST_FLAG_SECRET = 2,
    FOTUFILM_HOST_FLAG_PERSISTENT = 4,
    FOTUFILM_HOST_FLAG_OPENS_EXPANDED = 8,
    FOTUFILM_HOST_FLAG_COMPOSED = 16,
    FOTUFILM_HOST_FLAG_ZERO_LEAVES_ENGINE_DEFAULT = 32,
    FOTUFILM_HOST_FLAG_COLLAPSED_IN_FINAL_CUT = 64,
};

int32_t fotufilm_bridge_host_parameter_count(int32_t host);
int32_t fotufilm_bridge_host_parameter_kind(int32_t host, int32_t index);
int32_t fotufilm_bridge_host_parameter_slot(int32_t host, int32_t index);
int32_t fotufilm_bridge_host_parameter_menu(int32_t host, int32_t index);
int32_t fotufilm_bridge_host_parameter_flags(int32_t host, int32_t index);
int32_t fotufilm_bridge_host_parameter_fxplug_id(int32_t host, int32_t index);
int32_t fotufilm_bridge_host_parameter_fxplug_group(int32_t host, int32_t index);
double fotufilm_bridge_host_parameter_minimum(int32_t host, int32_t index);
double fotufilm_bridge_host_parameter_maximum(int32_t host, int32_t index);
double fotufilm_bridge_host_parameter_hard_maximum(int32_t host, int32_t index);
double fotufilm_bridge_host_parameter_default(int32_t host, int32_t index);
double fotufilm_bridge_host_parameter_delta(int32_t host, int32_t index);
double fotufilm_bridge_host_parameter_scale(int32_t host, int32_t index);
double fotufilm_bridge_host_parameter_offset(int32_t host, int32_t index);
int32_t fotufilm_bridge_host_parameter_name(int32_t host, int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_host_parameter_label(int32_t host, int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_host_parameter_hint(int32_t host, int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_host_parameter_parent(int32_t host, int32_t index, char *out, int32_t capacity);
int32_t fotufilm_bridge_host_parameter_choice_count(int32_t host, int32_t index);
int32_t fotufilm_bridge_host_parameter_choice(int32_t host, int32_t index, int32_t choice, char *out,
                                              int32_t capacity);
double fotufilm_bridge_host_parameter_choice_value(int32_t host, int32_t index, int32_t choice);
int32_t fotufilm_bridge_control_capabilities_mask_for(int32_t host, int32_t index);
/// Every slot at its control's resting value, as a host would write it. A host seeds its block
/// with this so the controls it does not offer render at rest rather than at zero.
void fotufilm_bridge_resting_parameters(float *parameters, int32_t count);
int32_t fotufilm_bridge_resolved_format(int32_t stock, int32_t format, char *out, int32_t capacity);
int32_t fotufilm_bridge_resolved_paper(int32_t stock, int32_t paper, char *out, int32_t capacity);
int32_t fotufilm_bridge_development_count(int32_t stock);
float fotufilm_bridge_development_stop(int32_t stock, int32_t index);
/// Uses the same per-node policy for decoding, kernel selection, and development.
int32_t fotufilm_bridge_effective_realtime(const float *parameters);

/// Point the engine at the resources it ships with, before anything else is called.
int32_t fotufilm_bridge_initialize(const char *resources);

/// Whether a usable Halide device was found: Metal on the Mac, CUDA or Vulkan on Linux. The
/// host-facing OFX path uses CPU image pointers; this describes the internal compute backend, not
/// an OFX GPU-render capability.
int32_t fotufilm_bridge_available(void);

/// Whether the host's colour encoding is decoded and encoded on the device
/// (`fotufilm_bridge_decode_rows`, `_decode_staged`, `_encodes_output`). Where it is not (Linux),
/// the host decodes and encodes every frame itself and never asks.
int32_t fotufilm_bridge_transforms_on_device(void);

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

/// Whether `paper`, as `stock` resolves it, delivers Cineon code values (code value / 1023) rather
/// than light. The host must pass them through untouched — no matrix, transfer or gamut fit — and
/// tag them Raw, so the grade reads them as Cineon Film Log.
int32_t fotufilm_bridge_delivers_code_values(int32_t stock, int32_t paper);

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
    /// Host-primary luminance weights for gamut fitting; all zero disables the fit.
    float gamutLuminance[3];
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

/// Queue-aware variant of `fotufilm_bridge_frame_staging`: pass the host's `MTLCommandQueue*`
/// when borrowing staging for a GPU Metal frame (or NULL for CPU frames) so the 2-slot pool can
/// reuse an in-flight slot on the same serial queue without stalling the CPU.
int32_t fotufilm_bridge_frame_staging_for_queue(FotufilmBridgeContext context,
                                               int32_t width, int32_t height,
                                               void *queue,
                                               float **input, float **output);

/// Returns the context's borrowed staging after the host has copied the developed output. Safe to
/// call when no staging was borrowed. A render that aborts after decode must still call this.
void fotufilm_bridge_release_staging(FotufilmBridgeContext context);

/// A host that renders through the OFX Metal extension hands its images over as `id<MTLBuffer>`
/// with an `id<MTLCommandQueue>` to order work on. These move the frame between those buffers and
/// the engine's staging on the GPU, so it never crosses into CPU memory. Mac only; on Linux every
/// call reports it cannot.

/// 1 when the queue and both buffers are on the device the engine develops on.
int32_t fotufilm_bridge_host_metal_usable(void *queue, void *source, void *output);

/// The claimed staging's buffers as `id<MTLBuffer>`: `scene` is what `scenePixels` views and
/// `developed` what `developedPixels` views. Returns 0 when no staging is claimed.
int32_t fotufilm_bridge_host_metal_staging(FotufilmBridgeContext context,
                                          void **scene, void **developed);

/// Copies `rows` rows of `width` RGBA-float pixels from `source` to `destination` inside the open
/// host Metal scope, whose command buffer the scope commits: nothing here waits on the host's
/// queue. Pixel (x, row) of each side is at `base + step * row + x`, counted in pixels; a negative
/// step walks rows in the other direction, which is how the host's bottom-up rows become the
/// engine's top-down ones. Returns 1 when encoded and 0 when it could not be, including when no
/// scope is open.
int32_t fotufilm_bridge_host_metal_copy(void *source, int64_t source_base, int64_t source_step,
                                       void *destination, int64_t destination_base,
                                       int64_t destination_step, int32_t width, int32_t rows);

/// A host Metal frame on its way through the CPU: one that needs resampling, a decode or an
/// encode the kernels do not carry, strips, Layered Transport, or a measurement read back.
typedef void *FotufilmMirroredFrame;

/// Commits, on the host's `queue`, the copy of both host buffers into CPU-visible mirrors — the
/// output as well, so whatever the render window leaves alone is the host's own — and returns
/// their CPU views. Rows are `stride` pixels apart and copied whole. Returns NULL when the frame
/// cannot be mirrored. The frame must be ended with exactly one of finish, defer or cancel.
FotufilmMirroredFrame fotufilm_bridge_host_mirror_begin(
    void *queue,
    void *source, int32_t source_stride, int32_t source_rows,
    void *output, int32_t output_stride, int32_t output_rows,
    float **source_pixels, float **output_pixels);

/// Waits up to `milliseconds` for the host's pixels. Returns 1 once they are in the mirrors, 0
/// while the host's queue has not reached the copy — a host can hold a command buffer on its
/// queue until the render call returns, so this must not be waited on for long — and -1 when the
/// GPU failed the copy.
int32_t fotufilm_bridge_host_mirror_wait(FotufilmMirroredFrame frame, int32_t milliseconds);

/// The frame was developed into the output mirror inside the render call: commits the copy back
/// to the host's buffer without waiting for it. Returns 1 when committed.
int32_t fotufilm_bridge_host_mirror_finish(FotufilmMirroredFrame frame);

/// The host is holding its queue. Reserves the copy back's place on the queue now, ahead of
/// anything the host commits after the render call returns, and calls `work(context, arrived)`
/// on another thread once the host's pixels are in the mirrors; the copy back is committed when
/// `work` returns. `arrived` is 0 when the GPU failed the copy in, and the frame is then black.
/// Returns 1 when deferred; 0, without ever calling `work`, when it could not be.
int32_t fotufilm_bridge_host_mirror_defer(FotufilmMirroredFrame frame,
                                         void (*work)(void *context, int32_t arrived),
                                         void *context);

/// Ends a mirrored frame that failed before anything was to be copied back.
void fotufilm_bridge_host_mirror_cancel(FotufilmMirroredFrame frame);

/// Whether `fotufilm_bridge_render_staged_to_metal` develops this frame in the kernels, from
/// device buffers into device buffers, so that it can be encoded inside a host Metal scope.
/// Layered Transport develops on the host instead, through the staging's CPU views, and its
/// frame goes through CPU mirrors.
int32_t fotufilm_bridge_develops_on_device(int32_t stock, int32_t format, int32_t paper,
                                          const float *parameters);

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

/// Fills `transform`'s transfer, matrix and coefficients with camera input `index`'s decode — its
/// log curve as the exponential transfer, its gamut into Rec.2020 — when the curve has that shape,
/// so the frame decodes in the kernel; `premultiplied` is left as it was. Returns 0 for a curve
/// the kernels cannot state (Apple Log, HLG), which `fotufilm_bridge_decode_camera` decodes on the
/// host instead.
int32_t fotufilm_bridge_camera_input_transform(int32_t index,
                                              struct FotufilmInputTransform *transform);

/// Decodes tightly packed host pixels from staging output into scene-linear staging input.
/// `peak` receives the largest finite pre-repair RGB value; `repaired` reports any non-finite
/// replacement. Either may be NULL. When an async host Metal compute encoder is open, non-finite
/// pixels are still clamped in the kernel but `peak` and `repaired` cannot be read back before
/// the call returns and are written as 0; `fotufilm_bridge_decode_report_later` delivers them
/// once the command buffer has run. Returns 1 on success and 0 when
/// staging, Metal, or the kernel is unavailable. `realtime` must use the same effective policy as
/// the following render. Arithmetic order matches `fotufilm::decodePixels` but GPU transcendentals
/// may differ.
int32_t fotufilm_bridge_decode_staged(FotufilmBridgeContext context,
                                     int32_t width, int32_t height,
                                     const struct FotufilmInputTransform *transform,
                                     float *peak, int32_t *repaired, int32_t realtime);

/// Decodes tightly packed bottom-up RGBA float rows directly from `source_buffer` (`id<MTLBuffer>`)
/// at offset 0 into top-down scene-linear `staging.sceneBuffer`, flipping Y inside the decode
/// kernel to eliminate `copyFrameIn` on full-frame Metal renders. Non-finite pixels are clamped in
/// the kernel; `peak` and `repaired` cannot be read back before the call returns and are written
/// as 0 (`fotufilm_bridge_decode_report_later` delivers them once the command buffer has run).
/// Returns 1 on success and 0 when unavailable (the caller falls
/// back to `copyFrameIn` + `fotufilm_bridge_decode_staged`).
int32_t fotufilm_bridge_decode_staged_from_metal(FotufilmBridgeContext context,
                                                void *source_buffer,
                                                int32_t width, int32_t height,
                                                const struct FotufilmInputTransform *transform,
                                                float *peak, int32_t *repaired, int32_t realtime);

/// Decodes a non-overlapping band of tightly packed, top-first RGBA host rows with the staged
/// decode kernel. Results are independent of band size. Combine per-band `peak` by maximum and
/// `repaired` by logical OR. Returns 1 on success and 0 on failure.
int32_t fotufilm_bridge_decode_rows(const float *in, float *out,
                                   int32_t width, int32_t rows,
                                   const struct FotufilmInputTransform *transform,
                                   float *peak, int32_t *repaired, int32_t realtime);

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

/// Develops borrowed staging input, optionally writing finished bottom-up RGBA float rows directly
/// into `direct_output_buffer` (`id<MTLBuffer>`, or NULL) at offset 0 to eliminate `copyFrameOut`
/// on full-frame Metal renders. Sets `*wrote_direct_output` (when non-NULL) to 1 if the kernel
/// wrote `direct_output_buffer` directly, or 0 if the result landed in `staging.developedBuffer`
/// (so the caller must still copy it out). Same return status codes as `fotufilm_bridge_render`.
int32_t fotufilm_bridge_render_staged_to_metal(FotufilmBridgeContext context,
                                              int32_t stock, int32_t format, int32_t paper,
                                              const float *parameters, uint32_t seed,
                                              int32_t width, int32_t height, uint64_t frame,
                                              int32_t interactive,
                                              struct FotufilmOutputTransform *output_transform,
                                              void *direct_output_buffer,
                                              int32_t *wrote_direct_output,
                                              fotufilm_bridge_should_continue should_continue,
                                              void *abort_context);

/// Copies the most recent failure into `out`.
int32_t fotufilm_bridge_last_error(FotufilmBridgeContext context,
                                  char *out, int32_t capacity);


/// Begins a single-command-buffer host Metal scope on `queue` (a `MTLCommandQueue*`).
/// Calls `fotufilm_halide_metal_host_queue_begin(queue)` and records the queue identity so the
/// staging pool can avoid unnecessary waits between consecutive GPU frames on the same queue.
/// Must be paired with `fotufilm_bridge_host_metal_end` even on early exit.
void fotufilm_bridge_host_metal_begin(FotufilmBridgeContext context, void *queue);

/// Ends the host Metal scope opened by `fotufilm_bridge_host_metal_begin`.
/// Calls `fotufilm_halide_metal_host_queue_end()` to retrieve the +1-retained command buffer
/// that was committed asynchronously on the host queue, then attaches it as a fence on the
/// borrowed staging so recycling can avoid stalling the GPU unnecessarily.
/// Returns 1 when the frame the scope encoded stands. Returns 0 when something inside the scope
/// — a metered frame's measurement — asked for results back on the CPU and the host's queue did
/// not deliver them within FOTUFILM_HOST_QUEUE_PATIENCE_MS (250 by default): the host is holding
/// its queue across the render call, the wait was given up, and the frame has to be developed
/// outside the call instead (through `fotufilm_bridge_host_mirror_defer`).
int32_t fotufilm_bridge_host_metal_end(FotufilmBridgeContext context);

/// Calls `done(context, failed)` on another thread once the open host Metal scope's command
/// buffer has run on the GPU, with `failed` non-zero when the GPU reported an error — which is
/// after the render call that encoded it has returned. Returns 1 when registered; 0, without
/// ever calling `done`, when no scope is open.
int32_t fotufilm_bridge_host_metal_notify(void (*done)(void *context, int32_t failed),
                                         void *context);

/// The next kernel decode on this thread inside a host Metal scope reports its peak and repairs
/// through `sink` once its command buffer has run, since they cannot be read back inside the
/// scope. `sink` is called exactly once, on another thread or, when no such decode follows,
/// with zeros.
void fotufilm_bridge_decode_report_later(
    void (*sink)(void *context, float peak, int32_t repaired), void *context);

/// Returns 1 on arm64 macOS when the bridge has a Metal device and `cameraIndex` names a camera
/// log format that the 0-ULP GPU Apple Log kernel supports (Apple Log or Apple Log 2), 0 otherwise.
int32_t fotufilm_bridge_camera_gpu_decode_supported(int32_t cameraIndex);

/// GPU Apple Log / Apple Log 2 decode using the context's current frame staging buffers.
/// Reads from staging.developedBuffer (which must be filled by the caller via copyRows into
/// stagedOutput before this call) and writes the decoded scene-linear result to staging.sceneBuffer.
/// For CPU OFX host paths (no open host Metal encoder required; uses its own cached queue + CB).
/// Returns 1 on success, 0 on failure.
int32_t fotufilm_bridge_camera_gpu_decode_staged(
    FotufilmBridgeContext context,
    int32_t width, int32_t height,
    int32_t premultiplied, int32_t cameraIndex,
    uint32_t *repairedOut);

/// Dispatches the fused 0-ULP GPU Apple Log / Apple Log 2 decode kernel between `MTLBuffer*`s.
/// `sourceBuffer` and `destinationBuffer` are unretained `MTLBuffer*` pointers of float4 RGBA.
/// `sourceBase + sourceStep * row + x` addresses source pixel (x, row) -- use a negative
/// `sourceStep` with `sourceBase = (height - 1) * |step|` to flip bottom-up rows top-down.
/// `destinationBase + destinationStep * row + x` addresses the output (top-down, step >= 0).
/// Non-zero `premultiplied` un-premultiplies alpha before decode. `cameraIndex` selects the gamut
/// matrix (`encoding.gamut.toRec2020` cast to Float).
/// When an async host Metal compute encoder is open (`fotufilm_halide_metal_host_compute_encoder`),
/// encodes directly onto it without `endEncoding` / `commit` / wait (`repairedOut` is ignored and
/// `fotufilm_bridge_host_metal_end` commits the CB), and whether any non-finite pixel was clamped
/// reaches `repairedLater(laterContext, 0, repaired)` once that command buffer has run; otherwise
/// executes synchronously on a cached command queue and writes 1 to `*repairedOut` (when
/// non-NULL) if any non-finite pixel was clamped. `repairedLater`, when given, is called exactly
/// once on every path. Returns 1 on success, 0 on failure.
int32_t fotufilm_bridge_camera_gpu_decode(
    FotufilmBridgeContext context,
    void *sourceBuffer, int64_t sourceBase, int64_t sourceStep,
    void *destinationBuffer, int64_t destinationBase, int64_t destinationStep,
    int32_t width, int32_t rows,
    int32_t premultiplied, int32_t cameraIndex,
    uint32_t *repairedOut,
    void (*repairedLater)(void *context, float peak, int32_t repaired),
    void *laterContext);

#ifdef __cplusplus
}
#endif

#endif
