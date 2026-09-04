#ifndef FOTUFILM_HALIDE_SHARED_H
#define FOTUFILM_HALIDE_SHARED_H

#include "FotufilmHalide.h"

#include <Halide.h>
#include <cmath>

namespace fotufilm {

constexpr int kLutDimension = 33;
constexpr int kLutValueCount = kLutDimension * kLutDimension * kLutDimension * 4;

/// Bilinear sampling shared by the CPU and GPU halation schedules.
template<typename Sample>
inline Halide::Expr bilinear_sample(Sample sample, Halide::Expr px, Halide::Expr py) {
    using Halide::Expr;
    Expr x0 = Halide::cast<int32_t>(Halide::floor(px));
    Expr y0 = Halide::cast<int32_t>(Halide::floor(py));
    Expr fx = px - Halide::floor(px);
    Expr fy = py - Halide::floor(py);
    return (1.0f - fx) * ((1.0f - fy) * sample(x0, y0)
                          + fy * sample(x0, y0 + 1))
        + fx * ((1.0f - fy) * sample(x0 + 1, y0)
                + fy * sample(x0 + 1, y0 + 1));
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

/// One source record's returned light at a pixel: the scale mixture for record `channel`, less
/// its direct light. On a flat field this is zero, which is what keeps sensitometry — where the
/// uniform return is already inside the characteristic curves — untouched by halation.
inline Halide::Expr halation_returned(Halide::ImageParam &configuration,
                                      Halide::Expr channel, Halide::Expr direct,
                                      Halide::Expr blurred_0, Halide::Expr blurred_1,
                                      Halide::Expr blurred_2) {
    Halide::Expr kernel = FOTUFILM_CONFIG_HALATION_KERNEL + channel * 3;
    Halide::Expr scattered = configuration(kernel) * blurred_0
        + configuration(kernel + 1) * blurred_1
        + configuration(kernel + 2) * blurred_2;
    return scattered - direct;
}

/// Folds the base-reflected light back into a receiver's exposure through the spectral return
/// matrix: `direct_c + sum_j M[c][j] * returned_j`. `returned` maps a source record index to
/// that record's `halation_returned` value at this pixel. A diagonal matrix of the legacy
/// shares reproduces the old `(1 - s) * direct + s * scattered` mix exactly; the off-diagonal
/// entries are the cross-record returns the per-wavelength stack transmission routes — the
/// orange mask handing a green- or blue-lit source's surviving deep red to the red record.
template <typename Returned>
inline Halide::Expr halation_mix(Halide::ImageParam &configuration,
                                 Halide::Expr channel, Halide::Expr direct,
                                 Returned returned) {
    Halide::Expr row = FOTUFILM_CONFIG_HALATION_MATRIX + channel * 3;
    return direct + configuration(row) * returned(0)
        + configuration(row + 1) * returned(1)
        + configuration(row + 2) * returned(2);
}

/// The lens diffusion filter's mix, at one pixel of one record.
///
/// Unlike halation's, this is not a blend between a direct and a scattered term: the two shares
/// are independent, because the light that met a particle and the light that did not are
/// different light. What is missing from `direct + sum(kernel)` is what the particles absorbed
/// and what scattered past the widest scale, and neither of those belongs at this pixel — the
/// first is gone and the second is already in the glare stage.
inline Halide::Expr diffusion_mix(Halide::ImageParam &configuration,
                                  Halide::Expr channel, Halide::Expr direct,
                                  Halide::Expr blurred_0, Halide::Expr blurred_1,
                                  Halide::Expr blurred_2) {
    Halide::Expr kernel = Halide::select(
        channel == 3, FOTUFILM_CONFIG_DONOR_DIFFUSION_KERNEL,
        FOTUFILM_CONFIG_DIFFUSION_KERNEL + channel * 3);
    return configuration(FOTUFILM_CONFIG_DIFFUSION_DIRECT) * direct
        + configuration(kernel) * blurred_0
        + configuration(kernel + 1) * blurred_1
        + configuration(kernel + 2) * blurred_2;
}

/// Largest power of two keeping a Gaussian's decimated sigma at one sample or more.
inline Halide::Expr gaussian_stride(Halide::Expr sigma) {
    return Halide::select(sigma >= 8.0f, 8,
                          sigma >= 4.0f, 4,
                          sigma >= 2.0f, 2, 1);
}

/// Sigma to blur with on a grid decimated by `stride`.
inline Halide::Expr decimated_gaussian_sigma(Halide::Expr sigma,
                                             Halide::Expr stride) {
    return Halide::select(
        stride == 1, sigma,
        Halide::sqrt(Halide::max(
            sigma * sigma / Halide::cast<float>(stride * stride) - 0.25f,
            0.0625f)));
}

inline Halide::Expr decimated_gaussian_radius(Halide::Expr radius,
                                              Halide::Expr stride) {
    return Halide::max((radius + stride - 1) / stride, 1);
}

/// Transcendental policy.
inline Halide::Expr fs_exp(Halide::Expr value, bool approximate) {
    return approximate ? Halide::fast_exp(value) : Halide::exp(value);
}

inline Halide::Expr fs_log(Halide::Expr value, bool approximate) {
    return approximate ? Halide::fast_log(value) : Halide::log(value);
}

inline Halide::Expr fs_pow(Halide::Expr base, Halide::Expr exponent,
                           bool approximate) {
    return approximate
        ? Halide::fast_pow(Halide::max(base, 1.0e-8f), exponent)
        : Halide::pow(base, exponent);
}

inline Halide::Expr fs_cos(Halide::Expr value, bool approximate) {
    return approximate ? Halide::fast_cos(value) : Halide::cos(value);
}

inline Halide::Expr softplus(Halide::Expr value, bool approximate = false) {
    return Halide::select(value > 20.0f, value,
                          value < -20.0f, fs_exp(value, approximate),
                          fs_log(1.0f + fs_exp(value, approximate), approximate));
}

/// Soft display shoulder: rolls a display-linear channel off toward the gamut
/// ceiling instead of hard-clamping it at 1.
inline Halide::Expr display_shoulder(Halide::Expr x, Halide::Expr knee) {
    Halide::Expr room = 1.0f - knee;
    Halide::Expr over = x - knee;
    Halide::Expr rolled = knee + room * over / (over + room);
    return Halide::select(x > knee, rolled, x);
}

/// The sRGB transfer's slope where it reaches white, which is what continues it above white.
#define FOTUFILM_SRGB_SLOPE_AT_WHITE (1.055f / 2.4f)

/// The sRGB transfer, forward and back — the signal a grading suite's three-way corrector works on.
///
/// Over 0…1 this is sRGB exactly, so the three-way lands where a colourist expects. Outside it the
/// curve is continued by its own end slopes rather than clamped, which keeps the pair an exact
/// inverse over the whole range: a neutral grade has to stay a neutral grade, and the light a print
/// carries above display white has to survive to meet the shoulder that rolls it.
/// Mirrors ColorScience.gradingEncode / gradingDecode expression for expression.
inline Halide::Expr srgb_encode(Halide::Expr linear, bool approximate = false) {
    Halide::Expr curve =
        1.055f * fs_pow(Halide::max(linear, 0.0031308f), 1.0f / 2.4f,
                        approximate) - 0.055f;
    return Halide::select(
        linear <= 0.0031308f, linear * 12.92f,
        linear >= 1.0f, 1.0f + (linear - 1.0f) * FOTUFILM_SRGB_SLOPE_AT_WHITE,
        curve);
}

inline Halide::Expr srgb_decode(Halide::Expr coded, bool approximate = false) {
    Halide::Expr curve = fs_pow(
        Halide::max((coded + 0.055f) / 1.055f, 0.0f), 2.4f, approximate);
    return Halide::select(
        coded <= 0.04045f, coded / 12.92f,
        coded >= 1.0f, 1.0f + (coded - 1.0f) / FOTUFILM_SRGB_SLOPE_AT_WHITE,
        curve);
}

/// Host transfer for FOTUFILM_FRAME_ENCODE_OUT. Coefficient-driven transfer shapes avoid evaluating
/// one GPU branch per colour space. Logarithmic coefficients include the change of base.
inline Halide::Expr host_transfer_encode(Halide::ImageParam &configuration,
                                         Halide::Expr value,
                                         bool approximate = false,
                                         int transfer_shape = -1) {
    auto coefficient = [&](int index) {
        return configuration(FOTUFILM_CONFIG_OUTPUT_COEFFICIENTS + index);
    };
    Halide::Expr magnitude = Halide::abs(value);
    Halide::Expr power = Halide::select(value < 0.0f, -1.0f, 1.0f)
        * Halide::select(magnitude <= coefficient(4),
                         magnitude * coefficient(0),
                         coefficient(1) * fs_pow(magnitude, coefficient(2), approximate)
                             + coefficient(3));
    Halide::Expr logarithmic = Halide::select(
        value <= coefficient(4),
        value * coefficient(0) + coefficient(3),
        coefficient(1) * fs_log(value + coefficient(5), approximate) + coefficient(2));
    if (transfer_shape == 0) return value;
    if (transfer_shape == 1) return power;
    if (transfer_shape == 2) return logarithmic;
    Halide::Expr shape = configuration(FOTUFILM_CONFIG_OUTPUT_TRANSFER);
    return Halide::select(shape < 0.5f, value, shape < 1.5f, power, logarithmic);
}

/// The host's own transfer undone, applied to an arriving channel on its way into the engine —
/// `host_transfer_encode` read backwards, and coefficient-driven for the same reason: both sides
/// of a Halide `select` are evaluated, so a branch per colour space would have the GPU compute
/// every space's transcendental to keep one. See `fotufilm::inputTransformFor`, which is the only
/// definition of which coefficients a space takes, for the shapes.
///
/// Reference schedules use exact transcendentals. Realtime schedules may request the same bounded
/// approximations used by their film stages; the shape and coefficients remain identical.
inline Halide::Expr host_transfer_decode(Halide::ImageParam &parameters,
                                         Halide::Expr value,
                                         bool approximate = false) {
    auto coefficient = [&](int index) {
        return parameters(FOTUFILM_DECODE_COEFFICIENTS + index);
    };
    Halide::Expr magnitude = Halide::abs(value);
    Halide::Expr power = Halide::select(value < 0.0f, -1.0f, 1.0f)
        * Halide::select(magnitude <= coefficient(4),
                         magnitude * coefficient(0),
                         fs_pow(coefficient(1) * magnitude + coefficient(3),
                                coefficient(2), approximate));
    // The branch is on the signed value, not its magnitude: a negative DaVinci Intermediate code
    // stays on the linear toe rather than being reflected through the log arm.
    Halide::Expr exponential = Halide::select(
        value <= coefficient(4),
        (value - coefficient(3)) * coefficient(0),
        fs_exp(value * coefficient(1) - coefficient(2), approximate) - coefficient(5));
    Halide::Expr shape = parameters(FOTUFILM_DECODE_TRANSFER);
    return Halide::select(shape < 0.5f, value, shape < 1.5f, power, exponential);
}

/// The host's own last step as one expression: out of the print's Display P3 delivery basis into
/// the host's primaries, through the SDR shoulder that delivery asked for, and into the host's
/// transfer. `row` selects the output channel, so the caller muxes three of these rather than
/// evaluating a matrix per channel.
///
/// The shoulder sits between the matrix and the transfer because that is where the host takes it:
/// `FilmOutputConversion.sRGBSDR` shoulders the converted sRGB value, not the P3 one it started
/// from, and `FilmDisplayP3SDRConversion` — whose matrix is the identity — cannot tell the
/// difference. A negative knee is no shoulder at all, which is what the linear and unshouldered
/// spaces want; every other value rolls off toward 1 exactly as `ColorScience.displayShoulder`
/// does, because it is the same curve.
///
/// The single definition of the step, shared by the fused GPU pipeline and the staged CPU one, so
/// that a delivery cannot mean two things depending on which road developed it.
inline Halide::Expr host_output_encode(Halide::ImageParam &configuration,
                                       Halide::Expr r, Halide::Expr g,
                                       Halide::Expr b, int row,
                                       bool approximate = false,
                                       int transfer_shape = -1) {
    Halide::Expr in_host_primaries =
        configuration(FOTUFILM_CONFIG_OUTPUT_MATRIX + 3 * row) * r
        + configuration(FOTUFILM_CONFIG_OUTPUT_MATRIX + 3 * row + 1) * g
        + configuration(FOTUFILM_CONFIG_OUTPUT_MATRIX + 3 * row + 2) * b;
    Halide::Expr knee = configuration(FOTUFILM_CONFIG_OUTPUT_SHOULDER);
    Halide::Expr shouldered = Halide::select(
        knee < 0.0f, in_host_primaries,
        display_shoulder(in_host_primaries,
                         Halide::clamp(knee, 0.0f, 1.0f)));
    return host_transfer_encode(configuration, shouldered, approximate,
                                transfer_shape);
}

/// The print grade: lift, gamma and gain applied per channel.
///
/// By default it works on the display-linear print value. When
/// FOTUFILM_CONFIG_GRADE_SPACE is set it instead works on the sRGB-encoded signal and hands linear
/// light back, which is where a grading suite's three-way corrector operates — the encode is the
/// grading space, not the output transfer, so SDR and HDR still grade alike.
inline Halide::Expr color_grade(Halide::ImageParam &configuration,
                                Halide::Expr channel, Halide::Expr value,
                                bool approximate = false) {
    Halide::Expr lift = configuration(FOTUFILM_CONFIG_GRADE_LIFT + channel);
    Halide::Expr gain = configuration(FOTUFILM_CONFIG_GRADE_GAIN + channel);
    Halide::Expr inverse_gamma =
        configuration(FOTUFILM_CONFIG_GRADE_INV_GAMMA + channel);
    Halide::Expr encoded = configuration(FOTUFILM_CONFIG_GRADE_SPACE) != 0.0f;
    Halide::Expr working =
        Halide::select(encoded, srgb_encode(value, approximate), value);
    Halide::Expr lifted = working * (gain - lift) + lift;
    Halide::Expr graded =
        Halide::select(inverse_gamma == 1.0f, lifted,
                       fs_pow(Halide::max(lifted, 0.0f), inverse_gamma,
                              approximate));
    return Halide::select(encoded, srgb_decode(graded, approximate), graded);
}

/// Analytic H&D density at `log_exposure` for the six-parameter curve stored
/// at `base` in the packed configuration.
inline Halide::Expr curve_density(Halide::ImageParam &configuration,
                                  Halide::Expr base, Halide::Expr log_exposure,
                                  bool approximate = false) {
    Halide::Expr d_min = configuration(base);
    Halide::Expr gamma = configuration(base + 1);
    Halide::Expr toe = configuration(base + 2);
    // Guarded like `curve_component_density`'s widths, so a curve left uncoated —
    // the donor block is zeroed outright for most stocks — tabulates a finite zero
    // rather than `0 * softplus(±Inf)`, the NaN that then rides the release row
    // into the densities.
    Halide::Expr toe_width = Halide::max(configuration(base + 3), 1.0e-6f);
    Halide::Expr shoulder = configuration(base + 4);
    Halide::Expr shoulder_width = Halide::max(configuration(base + 5), 1.0e-6f);
    Halide::Expr toe_term = toe_width
        * softplus((log_exposure - toe) / toe_width, approximate);
    Halide::Expr shoulder_term = shoulder_width
        * softplus((log_exposure - shoulder) / shoulder_width, approximate);
    return d_min + gamma * Halide::min(
        Halide::max(toe_term - shoulder_term, 0.0f), shoulder - toe);
}

/// Density contributed by the optional second coated speed group. Its five slots omit dMin;
/// density populations add above the same support and fog floor.
inline Halide::Expr curve_component_density(Halide::ImageParam &configuration,
                                            Halide::Expr base,
                                            Halide::Expr log_exposure,
                                            bool approximate = false) {
    Halide::Expr gamma = configuration(base);
    Halide::Expr toe = configuration(base + 1);
    Halide::Expr toe_width = Halide::max(configuration(base + 2), 1.0e-6f);
    Halide::Expr shoulder = configuration(base + 3);
    Halide::Expr shoulder_width = Halide::max(configuration(base + 4), 1.0e-6f);
    Halide::Expr toe_term = toe_width
        * softplus((log_exposure - toe) / toe_width, approximate);
    Halide::Expr shoulder_term = shoulder_width
        * softplus((log_exposure - shoulder) / shoulder_width, approximate);
    return gamma * Halide::min(
        Halide::max(toe_term - shoulder_term, 0.0f), shoulder - toe);
}

inline Halide::Expr film_density(Halide::ImageParam &configuration,
                                 Halide::Expr channel, Halide::Expr log_exposure,
                                 bool approximate = false) {
    return curve_density(configuration, FOTUFILM_CONFIG_CURVES + channel * 6,
                         log_exposure, approximate)
        + curve_component_density(
            configuration, FOTUFILM_CONFIG_CURVE_SECONDARY + channel * 5,
            log_exposure, approximate);
}

/// Sampling grid for the tabulated H&D curves below.
constexpr int kCurveSamples = 2048;
constexpr float kCurveMin = -8.0f;
constexpr float kCurveMax = 8.0f;

/// Tabulates a six-parameter H&D curve so the per-pixel cost is one load pair and a lerp instead of
/// the analytic form's two exponentials and two logarithms.
inline Halide::Func curve_table(Halide::ImageParam &configuration, int offset,
                                int stride, int channels,
                                const std::string &name,
                                Halide::DeviceAPI gpu = Halide::DeviceAPI::None) {
    Halide::Var i(name + "_i"), c(name + "_c");
    Halide::Func table(name);
    Halide::Expr log_exposure = kCurveMin
        + (kCurveMax - kCurveMin) * (Halide::cast<float>(i)
                                     / float(kCurveSamples - 1));
    table(i, c) = curve_density(configuration, offset + c * stride,
                                log_exposure,
                                gpu != Halide::DeviceAPI::None);
    table.compute_root().bound(i, 0, kCurveSamples).bound(c, 0, channels);
    if (gpu != Halide::DeviceAPI::None) {
        Halide::Var block_i(name + "_block_i"), thread_i(name + "_thread_i");
        table.reorder(c, i).unroll(c)
            .gpu_tile(i, block_i, thread_i, 64,
                      Halide::TailStrategy::GuardWithIf,
                      gpu);
    } else {
        table.reorder(i, c).unroll(c);
    }
    return table;
}

/// The three film curves, indexed (sample, layer).
inline Halide::Func film_curve_table(Halide::ImageParam &configuration,
                                     const std::string &name,
                                Halide::DeviceAPI gpu = Halide::DeviceAPI::None) {
    Halide::Var i(name + "_i"), c(name + "_c");
    Halide::Func table(name);
    Halide::Expr log_exposure = kCurveMin
        + (kCurveMax - kCurveMin) * (Halide::cast<float>(i)
                                     / float(kCurveSamples - 1));
    table(i, c) = film_density(configuration, c, log_exposure,
                               gpu != Halide::DeviceAPI::None);
    table.compute_root().bound(i, 0, kCurveSamples).bound(c, 0, 3);
    if (gpu != Halide::DeviceAPI::None) {
        Halide::Var block_i(name + "_block_i"), thread_i(name + "_thread_i");
        table.reorder(c, i).unroll(c)
            .gpu_tile(i, block_i, thread_i, 64,
                      Halide::TailStrategy::GuardWithIf, gpu);
    } else {
        table.reorder(i, c).unroll(c);
    }
    return table;
}

/// Where one paper record's six curve parameters sit: the green record in the
/// legacy FOTUFILM_CONFIG_PAPER slot, red and blue in the appended ones.
inline Halide::Expr paper_curve_base(Halide::Expr channel) {
    return Halide::select(channel == 0, FOTUFILM_CONFIG_PAPER_RED,
                          channel == 1, FOTUFILM_CONFIG_PAPER,
                          FOTUFILM_CONFIG_PAPER_BLUE);
}

/// One paper record's calibrated midpoint — the log exposure its anchor
/// density sits at, so a neutral mid-grey prints neutral through three
/// records that do not share a curve.
inline Halide::Expr paper_midpoint(Halide::ImageParam &configuration,
                                   Halide::Expr channel) {
    return Halide::select(
        channel == 0, configuration(FOTUFILM_CONFIG_PAPER_MIDPOINT_RED),
        channel == 1, configuration(FOTUFILM_CONFIG_PAPER_MIDPOINT),
        configuration(FOTUFILM_CONFIG_PAPER_MIDPOINT_BLUE));
}

/// The paper's three records, indexed (sample, channel). The bases are not
/// evenly strided, so this lays out `curve_table`'s body over
/// `paper_curve_base` rather than sharing its offset arithmetic.
inline Halide::Func paper_curve_table(Halide::ImageParam &configuration,
                                      const std::string &name,
                                Halide::DeviceAPI gpu = Halide::DeviceAPI::None) {
    Halide::Var i(name + "_i"), c(name + "_c");
    Halide::Func table(name);
    Halide::Expr log_exposure = kCurveMin
        + (kCurveMax - kCurveMin) * (Halide::cast<float>(i)
                                     / float(kCurveSamples - 1));
    table(i, c) = curve_density(configuration, paper_curve_base(c),
                                log_exposure,
                                gpu != Halide::DeviceAPI::None);
    table.compute_root().bound(i, 0, kCurveSamples).bound(c, 0, 3);
    if (gpu != Halide::DeviceAPI::None) {
        Halide::Var block_i(name + "_block_i"), thread_i(name + "_thread_i");
        table.reorder(c, i).unroll(c)
            .gpu_tile(i, block_i, thread_i, 64,
                      Halide::TailStrategy::GuardWithIf,
                      gpu);
    } else {
        table.reorder(i, c).unroll(c);
    }
    return table;
}

/// Reads a table built by `curve_table`.
inline Halide::Expr sample_curve(Halide::Func table, Halide::Expr log_exposure,
                                 Halide::Expr channel) {
    Halide::Expr q = Halide::clamp(
        (log_exposure - kCurveMin)
            * (float(kCurveSamples - 1) / (kCurveMax - kCurveMin)),
        0.0f, float(kCurveSamples - 1));
    Halide::Expr index = Halide::min(Halide::cast<int32_t>(q), kCurveSamples - 2);
    Halide::Expr frac = q - Halide::cast<float>(index);
    Halide::Expr low = table(index, channel);
    return low + frac * (table(index + 1, channel) - low);
}

/// dMax - dMin for the curve at `base`: gamma * (shoulder - toe).
inline Halide::Expr curve_range(Halide::ImageParam &configuration, Halide::Expr base) {
    return configuration(base + 1) * (configuration(base + 4) - configuration(base + 2));
}

/// dMax - dMin for one dye-forming film record, including its optional second population.
inline Halide::Expr film_curve_range(Halide::ImageParam &configuration,
                                     Halide::Expr channel) {
    Halide::Expr base = FOTUFILM_CONFIG_CURVES + channel * 6;
    Halide::Expr secondary = FOTUFILM_CONFIG_CURVE_SECONDARY + channel * 5;
    return curve_range(configuration, base)
        + configuration(secondary)
            * (configuration(secondary + 3) - configuration(secondary + 1));
}

/// Normalized Hill law for development-inhibitor release. It is applied before diffusion because
/// the released species diffuses, not the donor layer's latent activation. Gamma 1 preserves the
/// historical linear path exactly.
inline Halide::Expr inhibitor_release(Halide::Expr activation, Halide::Expr gamma) {
    Halide::Expr a = Halide::clamp(activation, 0.0f, 1.0f);
    Halide::Expr released = Halide::pow(a, gamma);
    Halide::Expr retained = Halide::pow(1.0f - a, gamma);
    Halide::Expr nonlinear = released / Halide::max(released + retained, 1.0e-8f);
    return Halide::select(gamma == 1.0f, a, nonlinear);
}

inline Halide::Expr coupler_release(Halide::ImageParam &configuration,
                                    Halide::Expr donor, Halide::Expr activation) {
    return inhibitor_release(
        activation, configuration(FOTUFILM_CONFIG_COUPLER_RELEASE_GAMMA + donor));
}

inline Halide::Expr donor_release(Halide::ImageParam &configuration,
                                  Halide::Expr activation) {
    return inhibitor_release(
        activation, configuration(FOTUFILM_CONFIG_DONOR_RELEASE_GAMMA));
}

/// DIR coupler inhibition applied to `channel`, in log-exposure units: the inhibitor released by
/// each donor layer, weighted by K[channel][donor].
inline Halide::Expr coupler_inhibition(Halide::ImageParam &configuration,
                                       Halide::Expr channel, Halide::Expr donor0,
                                       Halide::Expr donor1, Halide::Expr donor2) {
    Halide::Expr base = FOTUFILM_CONFIG_COUPLER + channel * 3;
    Halide::Expr released = configuration(base) * donor0
                          + configuration(base + 1) * donor1
                          + configuration(base + 2) * donor2;
    return released * configuration(FOTUFILM_CONFIG_COUPLER_SCALE);
}

/// Neutral anchor for the coupler stage: the log-exposure offset that undoes the inhibition a
/// neutral subject of the same luminance would have released.
inline Halide::Expr coupler_warp(Halide::ImageParam &configuration,
                                 Halide::Expr channel, Halide::Expr u) {
    constexpr int samples = FOTUFILM_COUPLER_WARP_SAMPLES;
    constexpr float low = float(FOTUFILM_COUPLER_WARP_MIN);
    constexpr float high = float(FOTUFILM_COUPLER_WARP_MAX);
    Halide::Expr q = Halide::clamp((u - low) * (float(samples - 1) / (high - low)),
                                   0.0f, float(samples - 1));
    Halide::Expr index = Halide::min(Halide::cast<int32_t>(q), samples - 2);
    Halide::Expr frac = q - Halide::cast<float>(index);
    Halide::Expr base = FOTUFILM_CONFIG_COUPLER_WARP + channel * samples;
    Halide::Expr low_sample = configuration(base + index);
    Halide::Expr high_sample = configuration(base + index + 1);
    Halide::Expr linear = low_sample + frac * (high_sample - low_sample);

    // The nonlinear release curve bends the inverse more strongly between samples. A monotone
    // cubic keeps the 128-sample ABI precise enough for the neutral anchor, while gamma 1 takes
    // the original linear interpolation bit-for-bit.
    Halide::Expr previous = configuration(base + Halide::max(index - 1, 0));
    Halide::Expr following = configuration(base + Halide::min(index + 2, samples - 1));
    Halide::Expr delta = Halide::max(high_sample - low_sample, 0.0f);
    Halide::Expr low_slope = Halide::clamp(
        0.5f * (high_sample - previous), 0.0f, 3.0f * delta);
    Halide::Expr high_slope = Halide::clamp(
        0.5f * (following - low_sample), 0.0f, 3.0f * delta);
    Halide::Expr frac2 = frac * frac;
    Halide::Expr frac3 = frac2 * frac;
    Halide::Expr cubic = (2.0f * frac3 - 3.0f * frac2 + 1.0f) * low_sample
                       + (frac3 - 2.0f * frac2 + frac) * low_slope
                       + (-2.0f * frac3 + 3.0f * frac2) * high_sample
                       + (frac3 - frac2) * high_slope;
    Halide::Expr nonlinear =
        configuration(FOTUFILM_CONFIG_COUPLER_RELEASE_GAMMA) != 1.0f
        || configuration(FOTUFILM_CONFIG_COUPLER_RELEASE_GAMMA + 1) != 1.0f
        || configuration(FOTUFILM_CONFIG_COUPLER_RELEASE_GAMMA + 2) != 1.0f
        || configuration(FOTUFILM_CONFIG_DONOR_RELEASE_GAMMA) != 1.0f;
    return Halide::select(nonlinear, cubic, linear);
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

/// Stage 1: scene-linear RGB to normalized per-layer film exposure, where 1 is metered mid-grey.
///
/// Buffers arrive in linear Rec.2020, the engine's one scene basis, and every ingest boundary
/// converts into it at decode. Wide sources (ACEScg, DaVinci Wide Gamut, S-Gamut3.Cine, camera
/// matrices) land inside it whole. Its primaries sit on the spectral locus, but the locus bulges
/// outward between them, so narrow-band light — a laser, an LED, a gas discharge — can leave the
/// cube while still being real; nothing on the scene path clamps it. The exposure table is
/// indexed in a wider basis that encloses the whole locus (`kRec2020ToExposureDomain`), and the
/// only boundary sits at that basis's edge, where physical light actually ends.
///
/// The BT.2020 luminance weights, the Y row of its RGB-to-XYZ matrix: exact CIE luminance of
/// the 2020-basis components, negatives included.
constexpr float kLumaR = 0.2627002f;
constexpr float kLumaG = 0.6779981f;
constexpr float kLumaB = 0.0593017f;

/// Linear Display P3 to linear Rec.2020, D65 to D65, rows summing to exactly 1 so P3 white is
/// working white. The ingest conversion for the encoded-byte frame path, whose buffers arrive
/// as transfer-encoded Display P3: after the transfer decode they step into the working space
/// here. Must match ColorScience.linearDisplayP3ToRec2020 digit for digit — the Swift
/// reference path converts the same buffers with it.
constexpr float kP3ToRec2020[9] = {
     0.753833034f, 0.198597369f, 0.047569597f,
     0.045743849f, 0.941777220f, 0.012478931f,
    -0.001210340f, 0.017601717f, 0.983608623f,
};

/// Linear Rec.2020 to linear Display P3, D65 to D65 — `kP3ToRec2020` the other way. The film
/// path never needs it: the paper integrates its dyes straight to Display P3, so the step out of
/// the working space is something the emulsion does. With no film in the gate there is no paper
/// to do it, and the same re-expression has to happen as a matrix. Must match
/// ColorScience.linearRec2020ToDisplayP3 digit for digit — the Swift reference path is
/// `PlainDevelop`, which applies exactly this.
constexpr float kRec2020ToP3[9] = {
     1.343578253f, -0.282179671f, -0.061398582f,
    -0.065297453f,  1.075787916f, -0.010490463f,
     0.002821787f, -0.019598495f,  1.016776707f,
};

/// Linear Rec.2020 to the exposure table's own basis: the ACES AP0 primaries about the D65
/// working white, whose chromaticity triangle encloses the whole spectral locus. Rows sum to
/// exactly 1, so the neutral axis is the same line in both bases and a walk toward it means the
/// same thing on either side. Must match ColorScience.linearRec2020ToExposureDomain digit for
/// digit — the Swift reference path and the handwritten Metal shaders apply the same seam.
constexpr float kRec2020ToExposureDomain[9] = {
     0.670231843f, 0.152168745f, 0.177599412f,
     0.044501114f, 0.854482372f, 0.101016514f,
     0.0f,         0.025777047f, 0.974222953f,
};

/// The local key the tone masks read: the pixel's regional brightness in stops from metered
/// mid-grey, from the guided-filter model base = a * stops + b with (a, b) bilinearly sampled from
/// the coarse whole-frame grid packed at FOTUFILM_CONFIG_TONE_GRID_A/_B (solved by
/// FilmEngineInvocation's tone-base measurement) and `stops` the pixel's own metered luminance.
inline Halide::Expr tone_base(Halide::ImageParam &configuration,
                              Halide::Expr stops, Halide::Expr frame_x,
                              Halide::Expr frame_y) {
    using Halide::Expr;
    Expr grid_w = Halide::cast<int32_t>(
        configuration(FOTUFILM_CONFIG_TONE_GRID_WIDTH));
    Expr grid_h = Halide::cast<int32_t>(
        configuration(FOTUFILM_CONFIG_TONE_GRID_HEIGHT));
    Expr frame_w = Halide::max(configuration(FOTUFILM_CONFIG_FRAME_WIDTH), 1.0f);
    Expr frame_h = Halide::max(configuration(FOTUFILM_CONFIG_FRAME_HEIGHT), 1.0f);
    Expr gx = Halide::clamp(
        (Halide::cast<float>(frame_x) + 0.5f) * Halide::cast<float>(grid_w)
            / frame_w - 0.5f,
        0.0f, Halide::cast<float>(grid_w - 1));
    Expr gy = Halide::clamp(
        (Halide::cast<float>(frame_y) + 0.5f) * Halide::cast<float>(grid_h)
            / frame_h - 0.5f,
        0.0f, Halide::cast<float>(grid_h - 1));
    Expr x0 = Halide::clamp(Halide::cast<int32_t>(gx), 0,
                            Halide::max(grid_w - 2, 0));
    Expr y0 = Halide::clamp(Halide::cast<int32_t>(gy), 0,
                            Halide::max(grid_h - 2, 0));
    Expr x1 = Halide::min(x0 + 1, grid_w - 1);
    Expr y1 = Halide::min(y0 + 1, grid_h - 1);
    Expr fx = Halide::clamp(gx - Halide::cast<float>(x0), 0.0f, 1.0f);
    Expr fy = Halide::clamp(gy - Halide::cast<float>(y0), 0.0f, 1.0f);
    auto bilinear = [&](int plane) {
        Expr c00 = configuration(plane + y0 * grid_w + x0);
        Expr c10 = configuration(plane + y0 * grid_w + x1);
        Expr c01 = configuration(plane + y1 * grid_w + x0);
        Expr c11 = configuration(plane + y1 * grid_w + x1);
        return (1.0f - fy) * ((1.0f - fx) * c00 + fx * c10)
            + fy * ((1.0f - fx) * c01 + fx * c11);
    };
    return bilinear(FOTUFILM_CONFIG_TONE_GRID_A) * stops
        + bilinear(FOTUFILM_CONFIG_TONE_GRID_B);
}

/// Scene RGB after the creative controls, before any spectral recovery.
struct CreativeScene {
    Halide::Expr r, g, b;
};

/// The creative half of the exposure stage: the white-balance gains, then the exposure-keyed tone
/// masks, then saturation and vibrance — everything a user moves, applied to scene RGB exactly as
/// `scene_exposure` always has. Domain-independent: it neither knows nor cares how the light will
/// be turned into layer exposure.
///
/// The gains go on first so that everything after them reads the adapted scene: the metering the
/// tone masks key to, the luminance the chroma is taken about, and the colourfulness vibrance
/// weighs. A grey card lit by the declared illuminant is then grey to all three, and desaturating
/// it leaves it grey rather than the colour of the adaptation. Gains of exactly 1 change no bit.
inline CreativeScene creative_exposure(Halide::ImageParam &configuration,
                                       Halide::Expr red, Halide::Expr green,
                                       Halide::Expr blue, Halide::Expr frame_x,
                                       Halide::Expr frame_y,
                                       bool approximate = false) {
    using Halide::Expr;
    // No clamp: the only clamp on the scene path is the exposure domain's physical-light
    // boundary. Everything here — tone gain, the luma lerp, the white-balance gains — is linear,
    // so rare out-of-Rec.2020 components pass through intact to be judged there.
    Expr r0 = red * configuration(FOTUFILM_CONFIG_WHITE_BALANCE);
    Expr g0 = green * configuration(FOTUFILM_CONFIG_WHITE_BALANCE + 1);
    Expr b0 = blue * configuration(FOTUFILM_CONFIG_WHITE_BALANCE + 2);

    constexpr float kToneEV = 3.0f;
    constexpr float kToneWindowStops = 6.0f;
    Expr metered = (kLumaR * r0 + kLumaG * g0 + kLumaB * b0)
        * configuration(FOTUFILM_CONFIG_EXPOSURE_GAIN) * (1.0f / 0.18f);
    Expr stops = fs_log(Halide::max(metered, 1.0e-6f), approximate)
        * (1.0f / 0.6931472f);
    Expr keyed = tone_base(configuration, stops, frame_x, frame_y);
    Expr high = Halide::clamp(keyed * (1.0f / kToneWindowStops), 0.0f, 1.0f);
    Expr low = Halide::clamp(-keyed * (1.0f / kToneWindowStops), 0.0f, 1.0f);
    Expr highlight_mask = high * high * (3.0f - 2.0f * high);
    Expr shadow_mask = low * low * (3.0f - 2.0f * low);
    Expr tone_ev = kToneEV * (configuration(FOTUFILM_CONFIG_HIGHLIGHTS) * highlight_mask
                              + configuration(FOTUFILM_CONFIG_SHADOWS) * shadow_mask);
    Expr tone_gain = approximate ? Halide::fast_exp(tone_ev * 0.6931472f)
                                 : Halide::pow(2.0f, tone_ev);
    Expr r1 = r0 * tone_gain;
    Expr g1 = g0 * tone_gain;
    Expr b1 = b0 * tone_gain;

    Expr luma1 = kLumaR * r1 + kLumaG * g1 + kLumaB * b1;
    Expr peak = Halide::max(r1, Halide::max(g1, b1));
    Expr colourfulness = (peak - Halide::min(r1, Halide::min(g1, b1)))
        / Halide::max(peak, 1.0e-6f);
    Expr chroma = configuration(FOTUFILM_CONFIG_SATURATION)
        * (1.0f + configuration(FOTUFILM_CONFIG_VIBRANCE) * (1.0f - colourfulness));
    Expr r2 = luma1 + chroma * (r1 - luma1);
    Expr g2 = luma1 + chroma * (g1 - luma1);
    Expr b2 = luma1 + chroma * (b1 - luma1);

    return {r2, g2, b2};
}

/// The film-free print: creative scene RGB, re-expressed in the print's delivery basis and
/// graded. What `FOTUFILM_FRAME_NO_FILM` puts where the emulsion, the couplers and the paper were.
///
/// Out-of-gamut components are left alone. The grade is a bijection over the whole line and the
/// delivery encoder owns the clip, exactly as the film path clamps only at the exposure domain's
/// physical-light boundary — so a colour too saturated for P3 arrives at the encoder to be judged
/// there rather than being flattened here.
///
/// Mirrors `PlainDevelop.printed` expression for expression, and shares `creative_exposure` with
/// the film path so the controls mean the same thing with and without a stock loaded.
inline Halide::Expr plain_print(Halide::ImageParam &configuration,
                                const CreativeScene &scene,
                                Halide::Expr channel) {
    // The exposure gain goes on here, and only here. `creative_exposure` deliberately leaves it
    // out — on the film path it is the emulsion that is exposed, and the gain reaches the light
    // through `recover_exposure` — so with no emulsion in the way there is nothing else left to
    // apply it. It is the same multiplication `PlainDevelop.printed` makes, in the same place:
    // after the tone and chroma controls, before the step into the delivery basis.
    Halide::Expr gain = configuration(FOTUFILM_CONFIG_EXPOSURE_GAIN);
    Halide::Expr r = scene.r * gain, g = scene.g * gain, b = scene.b * gain;
    auto row = [&](int index) {
        return kRec2020ToP3[3 * index] * r
            + kRec2020ToP3[3 * index + 1] * g
            + kRec2020ToP3[3 * index + 2] * b;
    };
    return color_grade(configuration, channel,
                       Halide::mux(channel, {row(0), row(1), row(2)}));
}

/// The recovery half: creative scene RGB to normalized per-layer film exposure through the
/// spectral LUT, the chromaticity evaluated at the radiance anchor and the radiance scaled back
/// out. Domain-dependent — this is the seam a direct film-layer-exposure input replaces.
///
/// The LUT's domain is a cube whose chromaticity triangle encloses the spectral locus — the AP0
/// primaries about the working white, `kRec2020ToExposureDomain` — so every real light has cells
/// of its own, monochromatic sources included; beyond Rec.2020 the table holds the cube-edge
/// reflectance mixed with light at the hue's dominant wavelength. The boundary below is the only
/// one on the scene path and it sits at that triangle's edge: what it gives up is colour outside
/// the locus, which no light can carry, rather than anything a display or a working space cannot
/// hold — and it gives it up as purity, never as a channel, so the hue and the luminance a wide
/// source stated are the hue and luminance the emulsion is shown.
inline Halide::Expr recover_exposure(Halide::ImageParam &configuration,
                                     Halide::ImageParam &exposure_lut,
                                     Halide::Expr r, Halide::Expr g,
                                     Halide::Expr b, Halide::Expr channel,
                                     bool half_lut_math = false) {
    using Halide::Expr;
    // Luminance is basis-invariant, so it is read once on the Rec.2020 components; the seam's
    // rows sum to 1, so y on the neutral axis is the same point in the table's basis.
    Expr y = kLumaR * r + kLumaG * g + kLumaB * b;
    Expr dr = kRec2020ToExposureDomain[0] * r + kRec2020ToExposureDomain[1] * g
        + kRec2020ToExposureDomain[2] * b;
    Expr dg = kRec2020ToExposureDomain[3] * r + kRec2020ToExposureDomain[4] * g
        + kRec2020ToExposureDomain[5] * b;
    Expr db = kRec2020ToExposureDomain[7] * g + kRec2020ToExposureDomain[8] * b;
    // A component the seam leaves negative names a chromaticity outside the locus-enclosing
    // triangle — colour no physical light can carry. Zeroing that channel alone would *add*
    // light the scene never had and shift the ratio between the survivors, which appears as a
    // hue flip on saturated sources. Instead the colour is walked toward its own luminance axis
    // until the binding channel reaches zero: the most saturated real light of the same CIE
    // luminance and hue. A colour whose luminance is not even positive is no light at all
    // and develops as darkness. In-cube colours take the untouched expressions bit for bit.
    Expr tr = Halide::select(dr < 0.0f, y / (y - dr), 1.0f);
    Expr tg = Halide::select(dg < 0.0f, y / (y - dg), 1.0f);
    Expr tb = Halide::select(db < 0.0f, y / (y - db), 1.0f);
    Expr s = Halide::min(Halide::min(tr, tg), tb);
    Expr outside = dr < 0.0f || dg < 0.0f || db < 0.0f;
    Expr pr = Halide::select(y <= 0.0f, 0.0f,
                             Halide::select(outside, y + s * (dr - y), dr));
    Expr pg = Halide::select(y <= 0.0f, 0.0f,
                             Halide::select(outside, y + s * (dg - y), dg));
    Expr pb = Halide::select(y <= 0.0f, 0.0f,
                             Halide::select(outside, y + s * (db - y), db));
    Expr wr = Halide::max(pr, 0.0f);
    Expr wg = Halide::max(pg, 0.0f);
    Expr wb = Halide::max(pb, 0.0f);
    Expr radiance_scale = Halide::max(Halide::max(wr, Halide::max(wg, wb)), 1.0e-6f);
    return Halide::max(
        lut_sample(exposure_lut, wr / radiance_scale, wg / radiance_scale,
                   wb / radiance_scale, channel, half_lut_math)
            * (radiance_scale * configuration(FOTUFILM_CONFIG_EXPOSURE_GAIN) / 0.18f),
        0.0f);
}

inline Halide::Expr scene_exposure(Halide::ImageParam &configuration,
                                   Halide::ImageParam &exposure_lut,
                                   Halide::Expr red, Halide::Expr green,
                                   Halide::Expr blue, Halide::Expr channel,
                                   Halide::Expr frame_x, Halide::Expr frame_y,
                                   bool approximate = false,
                                   bool half_lut_math = false) {
    CreativeScene scene = creative_exposure(configuration, red, green, blue,
                                            frame_x, frame_y, approximate);
    return recover_exposure(configuration, exposure_lut, scene.r, scene.g,
                            scene.b, channel, half_lut_math);
}

/// Luminance of a three-plane Func at one pixel, in the renderer's working primaries.
inline Halide::Expr luminance(Halide::Func planes, Halide::Expr x, Halide::Expr y) {
    return kLumaR * planes(x, y, 0) + kLumaG * planes(x, y, 1)
        + kLumaB * planes(x, y, 2);
}

/// Projection onto the neutral axis of film-record exposure. These planes are emulsion records,
/// not RGB primaries, so display-space luminance coefficients do not apply.
inline Halide::Expr record_neutral(Halide::Func planes, Halide::Expr x, Halide::Expr y) {
    return (planes(x, y, 0) + planes(x, y, 1) + planes(x, y, 2)) / 3.0f;
}

/// Luminance/chrominance recombination for the emulsion MTF. `per_layer` is each record blurred at
/// its own diffusion sigma — the opponent detail — and `luma_blurred` is the film-record neutral
/// axis blurred at the shared sigma.
inline Halide::Expr mtf_luma_mix(Halide::ImageParam &configuration,
                                 Halide::Expr per_layer,
                                 Halide::Expr per_layer_luma,
                                 Halide::Expr luma_blurred) {
    return per_layer + configuration(FOTUFILM_CONFIG_MTF_LUMA_SHARE)
        * (luma_blurred - per_layer_luma);
}

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

/// Granularity relative to the stock's reference density, under whichever law the emulsion
/// obeys. Fog is included at both densities.
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
    // No reversal sheet publishes a granularity-against-density curve, so a dye-cloud reversal
    // keeps Selwyn's plain law rather than borrowing a negative's measured shape.
    Expr selwyn = here / anchor;
    Expr law = configuration(FOTUFILM_CONFIG_GRAIN_LAW);
    Expr ratio = Halide::select(law > 1.5f, selwyn,
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
    for (int dy = -1; dy <= 2; ++dy) {
        for (int dx = -1; dx <= 2; ++dx) {
            Expr cell_x = base_cell_x + dx;
            Expr cell_y = base_cell_y + dy;
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
        }
    }

    Expr total = 0.0f;
    for (int k = 0; k < kBooleanSamplesPerAxis * kBooleanSamplesPerAxis; ++k) {
        total += Halide::select(hit[k], 1.0f, 0.0f);
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

inline Halide::Expr grain_correlate(Halide::ImageParam &configuration,
                                    Halide::Func base_noise, Halide::Expr x,
                                    Halide::Expr y, Halide::Expr channel) {
    return grain_mix(configuration, base_noise(x, y, channel),
                     base_noise(x, y, kGrainSharedLayer));
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
