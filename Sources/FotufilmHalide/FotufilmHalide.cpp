
#include "FotufilmHalide.h"

#if defined(FOTUFILM_HALIDE_ENABLED)

#include "FotufilmHalideShared.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <exception>
#include <memory>
#include <mutex>
#include <string>

using Halide::BoundaryConditions::constant_exterior;
using Halide::Buffer;
using Halide::Expr;
using Halide::Float;
using Halide::Func;
using Halide::ImageParam;
using Halide::Param;
using Halide::Pipeline;
using Halide::RDom;
using Halide::Var;

using namespace fotufilm;

namespace {

constexpr int kVectorWidth = 8;
constexpr int kStripHeight = 32;

Expr typed_zero(const Func &function) {
    return Halide::cast(function.value().type(), 0);
}

/// Standard schedule for a full-frame pointwise stage: channels unrolled, rows in parallel,
/// vectorized across x.
void cpu_pointwise(Func function, Var x, Var y, Var c, int planes = 3) {
    function.compute_root().bound(c, 0, planes).reorder(c, x, y).unroll(c)
        .vectorize(x, kVectorWidth, Halide::TailStrategy::GuardWithIf).parallel(y);
}

/// Standard schedule for a separable blur's two passes: a pure Func whose taps accumulate in
/// registers (Halide's inline `sum`) rather than as a zero-fill pass plus a read-modify-write
/// update over a materialized buffer.
void cpu_separable(Func function, Var x, Var y, Var c, int channels) {
    function.compute_root().bound(c, 0, channels).reorder(c, x, y).unroll(c)
        .vectorize(x, kVectorWidth, Halide::TailStrategy::GuardWithIf).parallel(y);
}

/// A separable Gaussian carrying one sigma per channel, over the widest of the three radii — the
/// narrower kernels simply decay to nothing out there.
Func gaussian(Func source, Expr sigma0, Expr sigma1, Expr sigma2,
              Expr radius, Expr width, Expr height,
              const std::string &name, int channels = 3) {
    Var x("x"), y("y"), c("c"), k("k");
    Expr sigma = Halide::select(c == 0, sigma0, c == 1, sigma1, sigma2);
    Func kernel(name + "_kernel");
    kernel(k, c) = Halide::exp(-Halide::cast<float>(k * k) / (2.0f * sigma * sigma));
    kernel.compute_root();
    RDom normalization_taps(-radius, radius * 2 + 1, name + "_norm_taps");
    Func normalization(name + "_normalization");
    normalization(c) = Halide::sum(kernel(normalization_taps.x, c),
                                   name + "_norm_sum");
    normalization.compute_root();

    Func bounded = constant_exterior(source, typed_zero(source),
                                     {{0, width}, {0, height}, {0, channels}});
    RDom horizontal_taps(-radius, radius * 2 + 1, name + "_horizontal_taps");
    Func horizontal(name + "_horizontal");
    Expr horizontal_weight = Halide::sum(
        Halide::select(x + horizontal_taps.x >= 0
                           && x + horizontal_taps.x < width,
                       kernel(horizontal_taps.x, c), 0.0f),
        name + "_horizontal_weight");
    horizontal(x, y, c) = Halide::sum(
        bounded(x + horizontal_taps.x, y, c) * kernel(horizontal_taps.x, c),
        name + "_horizontal_sum") / Halide::max(horizontal_weight, 1.0e-12f);
    cpu_separable(horizontal, x, y, c, channels);

    RDom vertical_taps(-radius, radius * 2 + 1, name + "_vertical_taps");
    Func vertical(name);
    Expr vertical_weight = Halide::sum(
        Halide::select(y + vertical_taps.x >= 0
                           && y + vertical_taps.x < height,
                       kernel(vertical_taps.x, c), 0.0f),
        name + "_vertical_weight");
    vertical(x, y, c) = Halide::sum(
        horizontal(x, y + vertical_taps.x, c) * kernel(vertical_taps.x, c),
        name + "_vertical_sum") / Halide::max(vertical_weight, 1.0e-12f);
    cpu_separable(vertical, x, y, c, channels);
    return vertical;
}

/// Three chained box blurs collapsed into one convolution per direction.
Func triple_box_blur(Func source, Expr radius, Expr width, Expr height,
                     const std::string &name, int channels = 3) {
    Var x("x"), y("y"), c("c"), k("k");
    Expr box_scale = 1.0f / Halide::cast<float>(radius * 2 + 1);
    Func box(name + "_box");
    box(k) = Halide::select(Halide::abs(k) <= radius, box_scale, 0.0f);
    RDom fold_once(-radius, radius * 2 + 1, name + "_fold_once");
    Func box_twice(name + "_box_twice");
    box_twice(k) = Halide::sum(box(k - fold_once.x), name + "_fold_once_sum")
        * box_scale;
    RDom fold_again(-radius, radius * 2 + 1, name + "_fold_again");
    Func kernel(name + "_kernel");
    kernel(k) = Halide::sum(box_twice(k - fold_again.x), name + "_fold_again_sum")
        * box_scale;
    box.compute_root();
    box_twice.compute_root();
    kernel.compute_root();

    Func bounded = constant_exterior(
        source, typed_zero(source), {{0, width}, {0, height}, {0, channels}});
    RDom horizontal_taps(-radius * 3, radius * 6 + 1, name + "_horizontal_taps");
    Func horizontal(name + "_horizontal");
    Expr horizontal_weight = Halide::sum(
        Halide::select(x + horizontal_taps.x >= 0
                           && x + horizontal_taps.x < width,
                       kernel(horizontal_taps.x), 0.0f),
        name + "_horizontal_weight");
    horizontal(x, y, c) = Halide::sum(
        bounded(x + horizontal_taps.x, y, c) * kernel(horizontal_taps.x),
        name + "_horizontal_sum") / Halide::max(horizontal_weight, 1.0e-12f);
    cpu_separable(horizontal, x, y, c, channels);

    RDom vertical_taps(-radius * 3, radius * 6 + 1, name + "_vertical_taps");
    Func vertical(name);
    Expr vertical_weight = Halide::sum(
        Halide::select(y + vertical_taps.x >= 0
                           && y + vertical_taps.x < height,
                       kernel(vertical_taps.x), 0.0f),
        name + "_vertical_weight");
    vertical(x, y, c) = Halide::sum(
        horizontal(x, y + vertical_taps.x, c) * kernel(vertical_taps.x),
        name + "_vertical_sum") / Halide::max(vertical_weight, 1.0e-12f);
    cpu_separable(vertical, x, y, c, channels);
    return vertical;
}

/// One box-blur pass computed with running (prefix) sums, so a wide radius costs O(1) per pixel
/// instead of O(radius).
Func box_blur(Func source, Param<int32_t> &radius,
              Param<int32_t> &width, Param<int32_t> &height,
              const std::string &name) {
    Var x("x"), y("y"), c("c"), xo("xo"), xi("xi"), yo("yo"), yi("yi");
    Func bounded = constant_exterior(
        source, typed_zero(source), {{0, width}, {0, height}, {0, 3}});

    Func hsum(name + "_hsum");
    hsum(x, y, c) = 0.0f;
    RDom rx(0, width + 2 * radius, name + "_rx");
    hsum(rx - radius, y, c) = hsum(rx - radius - 1, y, c) + bounded(rx - radius, y, c);
    Func horizontal(name + "_horizontal");
    Expr horizontal_count = Halide::cast<float>(
        Halide::max(0, Halide::min(width - 1, x + radius)
                           - Halide::max(0, x - radius) + 1));
    horizontal(x, y, c) = (hsum(x + radius, y, c) - hsum(x - radius - 1, y, c))
        / Halide::max(horizontal_count, 1.0f);

    Func hbounded = constant_exterior(horizontal, typed_zero(horizontal),
                                      {{0, width}, {0, height}, {0, 3}});
    Func vsum(name + "_vsum");
    vsum(x, y, c) = 0.0f;
    RDom ry(0, height + 2 * radius, name + "_ry");
    vsum(x, ry - radius, c) = vsum(x, ry - radius - 1, c) + hbounded(x, ry - radius, c);
    Func vertical(name);
    Expr vertical_count = Halide::cast<float>(
        Halide::max(0, Halide::min(height - 1, y + radius)
                           - Halide::max(0, y - radius) + 1));
    vertical(x, y, c) = (vsum(x, y + radius, c) - vsum(x, y - radius - 1, c))
        / Halide::max(vertical_count, 1.0f);

    horizontal.compute_root()
        .split(y, yo, yi, kStripHeight, Halide::TailStrategy::GuardWithIf)
        .reorder(c, x, yi, yo).bound(c, 0, 3).unroll(c)
        .vectorize(x, kVectorWidth, Halide::TailStrategy::GuardWithIf)
        .parallel(yo);
    hsum.compute_at(horizontal, yo);
    hsum.update().reorder(c, rx, y).unroll(c);

    vertical.compute_root()
        .split(x, xo, xi, kStripHeight, Halide::TailStrategy::GuardWithIf)
        .reorder(c, xi, y, xo).bound(c, 0, 3).unroll(c)
        .vectorize(xi, kVectorWidth, Halide::TailStrategy::GuardWithIf)
        .parallel(xo);
    vsum.compute_at(vertical, xo);
    vsum.update().reorder(c, x, ry).unroll(c);
    return vertical;
}

/// A Gaussian whose sigma spans many pixels, run on a frame-anchored decimated grid: box-average
/// down by a power-of-two stride, blur there with the rescaled sigma, and sample back up
/// bilinearly.
Func cpu_gaussian_decimated(Func source, Expr sigma, Expr radius,
                            Expr origin_x, Expr origin_y,
                            Expr width, Expr height, const std::string &name,
                            int channels = 3) {
    Var x("x"), y("y"), c("c");
    Expr stride = gaussian_stride(sigma);
    Expr phase_x = origin_x % stride;
    Expr phase_y = origin_y % stride;
    Expr down_width = (width + phase_x + stride - 1) / stride;
    Expr down_height = (height + phase_y + stride - 1) / stride;
    Func bounded_source = constant_exterior(
        source, typed_zero(source), {{0, width}, {0, height}, {0, channels}});
    RDom cell(0, stride, 0, stride, name + "_cell");
    Func down(name + "_down");
    Expr source_x = x * stride - phase_x + cell.x;
    Expr source_y = y * stride - phase_y + cell.y;
    Expr valid = Halide::select(source_x >= 0 && source_x < width
                                    && source_y >= 0 && source_y < height,
                                1.0f, 0.0f);
    Expr cell_count = Halide::sum(valid, name + "_down_weight");
    down(x, y, c) = Halide::sum(
        bounded_source(x * stride - phase_x + cell.x,
                       y * stride - phase_y + cell.y, c),
        name + "_down_sum") / Halide::max(cell_count, 1.0f);
    cpu_separable(down, x, y, c, channels);

    Expr small_sigma = decimated_gaussian_sigma(sigma, stride);
    Func blurred = gaussian(down, small_sigma, small_sigma, small_sigma,
                            decimated_gaussian_radius(radius, stride),
                            down_width, down_height, name + "_spread", channels);
    Func bounded_blur = constant_exterior(
        blurred, typed_zero(blurred),
        {{0, down_width}, {0, down_height}, {0, channels}});
    Expr sample_x = (Halide::cast<float>(x + phase_x) + 0.5f)
        / Halide::cast<float>(stride) - 0.5f;
    Expr sample_y = (Halide::cast<float>(y + phase_y) + 0.5f)
        / Halide::cast<float>(stride) - 0.5f;
    Expr x0 = Halide::cast<int32_t>(Halide::floor(sample_x));
    Expr y0 = Halide::cast<int32_t>(Halide::floor(sample_y));
    Expr fx = sample_x - Halide::floor(sample_x);
    Expr fy = sample_y - Halide::floor(sample_y);
    Func up(name);
    Expr w00 = (1.0f - fx) * (1.0f - fy), w01 = (1.0f - fx) * fy;
    Expr w10 = fx * (1.0f - fy), w11 = fx * fy;
    auto valid_sample = [&](Expr sx, Expr sy) {
        return Halide::select(sx >= 0 && sx < down_width
                                  && sy >= 0 && sy < down_height, 1.0f, 0.0f);
    };
    Expr sample_weight = w00 * valid_sample(x0, y0) + w01 * valid_sample(x0, y0 + 1)
        + w10 * valid_sample(x0 + 1, y0) + w11 * valid_sample(x0 + 1, y0 + 1);
    up(x, y, c) = (w00 * bounded_blur(x0, y0, c)
                       + w01 * bounded_blur(x0, y0 + 1, c)
                       + w10 * bounded_blur(x0 + 1, y0, c)
                       + w11 * bounded_blur(x0 + 1, y0 + 1, c))
        / Halide::max(sample_weight, 1.0e-12f);
    return up;
}

/// One halation scale, evaluated on its own decimated grid: box-average down by `stride`, run the
/// collapsed triple box there with the rescaled radius, and sample back up bilinearly.
Expr halation_scale(Func light, Expr stride, Expr strided_radius,
                    Expr width, Expr height, Expr origin_x, Expr origin_y,
                    Var x, Var y, Var c, Expr ring_radius, bool annular,
                    const std::string &name, int channels = 3) {
    Expr phase_x = origin_x % stride;
    Expr phase_y = origin_y % stride;
    Expr down_width = (width + phase_x + stride - 1) / stride;
    Expr down_height = (height + phase_y + stride - 1) / stride;
    Func bounded_source = constant_exterior(
        light, typed_zero(light), {{0, width}, {0, height}, {0, channels}});
    RDom cell(0, stride, 0, stride, name + "_cell");
    Func down(name + "_down");
    Expr source_x = x * stride - phase_x + cell.x;
    Expr source_y = y * stride - phase_y + cell.y;
    Expr valid = Halide::select(source_x >= 0 && source_x < width
                                    && source_y >= 0 && source_y < height,
                                1.0f, 0.0f);
    Expr cell_count = Halide::sum(valid, name + "_down_weight");
    down(x, y, c) = Halide::sum(
        bounded_source(x * stride - phase_x + cell.x,
                       y * stride - phase_y + cell.y, c),
        name + "_down_sum") / Halide::max(cell_count, 1.0f);
    cpu_separable(down, x, y, c, channels);

    Func blurred = triple_box_blur(down, strided_radius, down_width, down_height,
                                   name + "_spread", channels);
    Func bounded_blur = constant_exterior(
        blurred, typed_zero(blurred),
        {{0, down_width}, {0, down_height}, {0, channels}});
    Expr sample_x = (Halide::cast<float>(x + phase_x) + 0.5f)
        / Halide::cast<float>(stride) - 0.5f;
    Expr sample_y = (Halide::cast<float>(y + phase_y) + 0.5f)
        / Halide::cast<float>(stride) - 0.5f;
    Expr x0 = Halide::cast<int32_t>(Halide::floor(sample_x));
    Expr y0 = Halide::cast<int32_t>(Halide::floor(sample_y));
    Expr fx = sample_x - Halide::floor(sample_x);
    Expr fy = sample_y - Halide::floor(sample_y);
    Expr w00 = (1.0f - fx) * (1.0f - fy), w01 = (1.0f - fx) * fy;
    Expr w10 = fx * (1.0f - fy), w11 = fx * fy;
    auto valid_sample = [&](Expr sx, Expr sy) {
        return Halide::select(sx >= 0 && sx < down_width
                                  && sy >= 0 && sy < down_height, 1.0f, 0.0f);
    };
    Expr sample_weight = w00 * valid_sample(x0, y0) + w01 * valid_sample(x0, y0 + 1)
        + w10 * valid_sample(x0 + 1, y0) + w11 * valid_sample(x0 + 1, y0 + 1);
    Expr center = (w00 * bounded_blur(x0, y0, c)
                       + w01 * bounded_blur(x0, y0 + 1, c)
                       + w10 * bounded_blur(x0 + 1, y0, c)
                       + w11 * bounded_blur(x0 + 1, y0 + 1, c))
        / Halide::max(sample_weight, 1.0e-12f);
    if (!annular) return center;
    auto at = [&](Expr sx, Expr sy) { return bounded_blur(sx, sy, c); };
    auto valid_ring_sample = [&](Expr sx, Expr sy) {
        return Halide::select(sx >= 0 && sx < down_width
                                  && sy >= 0 && sy < down_height, 1.0f, 0.0f);
    };
    Expr radius_on_grid = ring_radius / Halide::cast<float>(stride);
    return annular_sample(at, sample_x, sample_y, radius_on_grid)
        / Halide::max(annular_sample(valid_ring_sample, sample_x, sample_y,
                                    radius_on_grid), 1.0e-12f);
}

Buffer<float> planar_buffer(const float *r, const float *g, const float *b,
                            int32_t width, int32_t height) {
    Buffer<float> buffer(width, height, 3);
    const int64_t count = static_cast<int64_t>(width) * height;
    std::copy_n(r, count, buffer.data());
    std::copy_n(g, count, buffer.data() + count);
    std::copy_n(b, count, buffer.data() + count * 2);
    return buffer;
}

void copy_planar(const Buffer<float> &buffer, float *r, float *g, float *b,
                 int32_t width, int32_t height) {
    const int64_t count = static_cast<int64_t>(width) * height;
    std::copy_n(buffer.data(), count, r);
    std::copy_n(buffer.data() + count, count, g);
    std::copy_n(buffer.data() + count * 2, count, b);
}

Buffer<float> lut_buffer(const float *values) {
    Buffer<float> buffer(kLutValueCount);
    std::copy_n(values, kLutValueCount, buffer.data());
    return buffer;
}

Buffer<float> configuration_buffer(const float *values) {
    Buffer<float> buffer(FOTUFILM_FRAME_CONFIGURATION_COUNT);
    std::copy_n(values, FOTUFILM_FRAME_CONFIGURATION_COUNT, buffer.data());
    return buffer;
}

/// Stages 1-7: scene-linear planar RGB to developed per-layer density.
class DevelopPipeline {
public:
    DevelopPipeline(int32_t features, const std::string &suffix)
        : input_r_(Float(32), 2, "develop_input_r" + suffix),
          input_g_(Float(32), 2, "develop_input_g" + suffix),
          input_b_(Float(32), 2, "develop_input_b" + suffix),
          configuration_(Float(32), 1, "develop_configuration" + suffix),
          exposure_lut_(Float(32), 1, "develop_exposure_lut" + suffix),
          width_("develop_width" + suffix),
          height_("develop_height" + suffix),
          mtf_sigma_0_("develop_mtf_sigma_0" + suffix),
          mtf_sigma_1_("develop_mtf_sigma_1" + suffix),
          mtf_sigma_2_("develop_mtf_sigma_2" + suffix),
          mtf_radius_0_("develop_mtf_radius_0" + suffix),
          mtf_radius_1_("develop_mtf_radius_1" + suffix),
          mtf_radius_2_("develop_mtf_radius_2" + suffix),
          mtf_luma_sigma_("develop_mtf_luma_sigma" + suffix),
          mtf_luma_radius_("develop_mtf_luma_radius" + suffix),
          halation_stride_0_("develop_halation_stride_0" + suffix),
          halation_stride_1_("develop_halation_stride_1" + suffix),
          halation_stride_2_("develop_halation_stride_2" + suffix),
          halation_strided_radius_0_("develop_halation_strided_radius_0" + suffix),
          halation_strided_radius_1_("develop_halation_strided_radius_1" + suffix),
          halation_strided_radius_2_("develop_halation_strided_radius_2" + suffix),
          diffusion_stride_0_("develop_diffusion_stride_0" + suffix),
          diffusion_stride_1_("develop_diffusion_stride_1" + suffix),
          diffusion_stride_2_("develop_diffusion_stride_2" + suffix),
          diffusion_strided_radius_0_("develop_diffusion_strided_radius_0" + suffix),
          diffusion_strided_radius_1_("develop_diffusion_strided_radius_1" + suffix),
          diffusion_strided_radius_2_("develop_diffusion_strided_radius_2" + suffix),
          coupler_sigma_("develop_coupler_sigma" + suffix),
          coupler_radius_("develop_coupler_radius" + suffix),
          adjacency_sigma_("develop_adjacency_sigma" + suffix),
          adjacency_radius_("develop_adjacency_radius" + suffix),
          grain_sigma_("develop_grain_sigma" + suffix),
          grain_radius_("develop_grain_radius" + suffix),
          grain_lambda_("develop_grain_lambda" + suffix),
          grain_mode_("develop_grain_mode" + suffix),
          mottle_sigma_("develop_mottle_sigma" + suffix),
          mottle_radius_("develop_mottle_radius" + suffix),
          mottle_lambda_("develop_mottle_lambda" + suffix),
          seed_("develop_seed" + suffix),
          reversal_("develop_reversal" + suffix),
          monochrome_("develop_monochrome" + suffix),
          origin_x_("develop_origin_x" + suffix),
          origin_y_("develop_origin_y" + suffix) {
        // The seam. `density_in` starts the schedule at the developed negative — the three input
        // planes are densities rather than scene light, and every stage before the H&D curve is
        // absent rather than skipped. `texture` keeps the scene side but returns the source
        // multiplied by the transmittance the spatial stages moved the density through.
        const bool density_in = features & FOTUFILM_FRAME_DENSITY_IN;
        const bool texture = features & FOTUFILM_FRAME_TEXTURE;
        const bool use_flare = !density_in && (features & FOTUFILM_FRAME_FLARE);
        const bool use_mtf = !density_in && (features & FOTUFILM_FRAME_MTF);
        const bool use_mtf_luma = use_mtf && (features & FOTUFILM_FRAME_MTF_LUMA);
        // Scene-side, so the seam's density path must not run it: `density_in` is handed a
        // developed negative, and there is no scene light left in front of the lens to
        // scatter.
        const bool use_diffusion = !density_in && (features & FOTUFILM_FRAME_DIFFUSION);
        const bool use_halation = !density_in && (features & FOTUFILM_FRAME_HALATION);
        const bool use_annular = use_halation
            && (features & FOTUFILM_FRAME_HALATION_ANNULAR);
        const bool use_couplers = !density_in && (features & FOTUFILM_FRAME_COUPLERS);
        const bool use_donor = !density_in && (features & FOTUFILM_FRAME_DONOR_LAYER);
        const bool use_coupler_diffusion =
            !density_in && (features & FOTUFILM_FRAME_COUPLER_DIFFUSION);
        const bool use_adjacency = !density_in && (features & FOTUFILM_FRAME_ADJACENCY);
        const bool use_grain = !density_in && (features & FOTUFILM_FRAME_GRAIN);
        const bool use_discs = use_grain && (features & FOTUFILM_FRAME_DISC_GRAIN);
        const bool use_mottle = use_grain
            && (features & FOTUFILM_FRAME_GRAIN_MOTTLE);

        Var x("x"), y("y"), c("c");
        exposure_lut_.dim(0).set_bounds(0, kLutValueCount);

        Func curves = film_curve_table(configuration_, "develop_curve_table" + suffix);

        Func exposure("develop_exposure" + suffix);
        exposure(x, y, c) = scene_exposure(
            configuration_, exposure_lut_, input_r_(x, y), input_g_(x, y),
            input_b_(x, y), c, x + origin_x_, y + origin_y_);

        // Lens scattering is linear in spectral radiance, so integration through each record's
        // sensitivity commutes with the spatial convolution. Applying the record-specific kernels
        // here preserves that wavelength dependence instead of treating Rec.2020 primaries as
        // emulsion layers.
        const int exposure_channels = use_donor ? 4 : 3;
        Func light = exposure;
        if (use_diffusion) {
            cpu_pointwise(exposure, x, y, c, exposure_channels);
            Param<int32_t> *strides[3] = {
                &diffusion_stride_0_, &diffusion_stride_1_, &diffusion_stride_2_};
            Param<int32_t> *strided_radii[3] = {
                &diffusion_strided_radius_0_, &diffusion_strided_radius_1_,
                &diffusion_strided_radius_2_};
            Expr scattered[3];
            for (int k = 0; k < 3; ++k) {
                scattered[k] = halation_scale(
                    exposure, *strides[k], *strided_radii[k], width_, height_,
                    origin_x_, origin_y_, x, y, c, 0.0f, false,
                    "develop_diffusion_" + std::to_string(k) + suffix,
                    exposure_channels);
            }
            Func diffused("develop_diffused" + suffix);
            diffused(x, y, c) = diffusion_mix(configuration_, c, exposure(x, y, c),
                                              scattered[0], scattered[1], scattered[2]);
            cpu_pointwise(diffused, x, y, c, exposure_channels);
            light = diffused;
        }

        // The donor capture layer reads the spare fourth channel. Lens diffusion uses its own
        // sensitivity-centroid weights; later image-plane stages pass it by because it forms no
        // dye, while its developed activation joins the coupler release sum.
        Func donor_exposure("develop_donor_exposure" + suffix);
        if (use_donor) {
            if (use_diffusion) {
                donor_exposure(x, y, c) = light(x, y, 3);
            } else {
                donor_exposure(x, y, c) = scene_exposure(
                    configuration_, exposure_lut_,
                    input_r_(x, y), input_g_(x, y), input_b_(x, y), 3,
                    x + origin_x_, y + origin_y_);
            }
        }
        bool light_stored = false;

        if (use_flare) {
            cpu_pointwise(light, x, y, c);
            light_stored = true;
            Func row_sum("develop_flare_row_sum" + suffix);
            row_sum(y, c) = Halide::cast<double>(0);
            RDom row_domain(0, width_, "develop_flare_row_domain" + suffix);
            row_sum(y, c) += Halide::cast<double>(light(row_domain.x, y, c));
            Func total("develop_flare_total" + suffix);
            total(c) = Halide::cast<double>(0);
            RDom column_domain(0, height_, "develop_flare_column_domain" + suffix);
            total(c) += row_sum(column_domain.x, c);
            Func measured("develop_flare_measured" + suffix);
            measured(c) = Halide::cast<float>(
                total(c) / (Halide::cast<double>(width_) * height_));
            row_sum.compute_root().bound(c, 0, 3);
            row_sum.update().parallel(y);
            total.compute_root().bound(c, 0, 3);
            measured.compute_root().bound(c, 0, 3);
            Func mean("develop_flare_mean" + suffix);
            mean(c) = Halide::select(
                configuration_(FOTUFILM_CONFIG_FLARE_MEAN) >= 0.0f,
                configuration_(FOTUFILM_CONFIG_FLARE_MEAN + c), measured(c));
            mean.compute_root().bound(c, 0, 3);

            Func flared("develop_flared" + suffix);
            Expr fraction = configuration_(FOTUFILM_CONFIG_FLARE);
            flared(x, y, c) = (1.0f - fraction) * exposure(x, y, c)
                + fraction * mean(c);
            light = flared;
            light_stored = false;
        }

        // Where `texture` branches: the light the emulsion would have seen if none of the spatial
        // stages existed. Veiling glare stays on this side of the branch because it is not a
        // spatial stage — it mixes in one number for the whole frame — so it appears in both
        // developments and cancels.
        Func flat_light = light;

        if (use_mtf) {
            if (!light_stored) { cpu_pointwise(light, x, y, c); }
            Func pre_mtf = light;
            Expr mtf_radius = Halide::max(
                mtf_radius_0_, Halide::max(mtf_radius_1_, mtf_radius_2_));
            Func combined = gaussian(
                light, mtf_sigma_0_, mtf_sigma_1_, mtf_sigma_2_, mtf_radius,
                width_, height_, "develop_mtf" + suffix);
            light = combined;
            light_stored = true;

            if (use_mtf_luma) {
                Func secondary = gaussian(
                    pre_mtf,
                    Halide::max(configuration_(FOTUFILM_CONFIG_MTF_SECONDARY_SIGMA),
                                0.151f),
                    Halide::max(configuration_(FOTUFILM_CONFIG_MTF_SECONDARY_SIGMA + 1),
                                0.151f),
                    Halide::max(configuration_(FOTUFILM_CONFIG_MTF_SECONDARY_SIGMA + 2),
                                0.151f),
                    mtf_luma_radius_, width_, height_,
                    "develop_mtf_secondary" + suffix);
                Func mixed("develop_mtf_mixed" + suffix);
                Expr primary_share =
                    configuration_(FOTUFILM_CONFIG_MTF_PRIMARY_SHARE + c);
                mixed(x, y, c) = primary_share * combined(x, y, c)
                    + (1.0f - primary_share) * secondary(x, y, c);
                cpu_pointwise(mixed, x, y, c);
                Func luma_direct("develop_mtf_luma_direct" + suffix);
                luma_direct(x, y, c) = record_neutral(pre_mtf, x, y);
                cpu_pointwise(luma_direct, x, y, c, 1);
                Func luma_blurred = gaussian(
                    luma_direct, mtf_luma_sigma_, mtf_luma_sigma_,
                    mtf_luma_sigma_, mtf_luma_radius_, width_, height_,
                    "develop_mtf_luma" + suffix, 1);
                Func separated("develop_mtf_separated" + suffix);
                separated(x, y, c) = mtf_luma_mix(
                    configuration_, mixed(x, y, c),
                    record_neutral(mixed, x, y), luma_blurred(x, y, 0));
                light = separated;
                light_stored = false;
            }
        }

        if (use_halation) {
            if (!light_stored) { cpu_pointwise(light, x, y, c); light_stored = true; }
            Param<int32_t> *strides[3] = {
                &halation_stride_0_, &halation_stride_1_, &halation_stride_2_};
            Param<int32_t> *strided_radii[3] = {
                &halation_strided_radius_0_, &halation_strided_radius_1_,
                &halation_strided_radius_2_};
            Expr scattered[3];
            for (int k = 0; k < 3; ++k) {
                scattered[k] = halation_scale(
                    light, *strides[k], *strided_radii[k], width_, height_,
                    origin_x_, origin_y_, x, y, c,
                    configuration_(FOTUFILM_CONFIG_HALATION_RING_RADIUS + k),
                    use_annular,
                    "develop_halation_" + std::to_string(k) + suffix);
            }
            // Materialized so each receiver's row of the return matrix reads the three source
            // records' returned light without re-sampling the blurred grids per receiver.
            Func returned("develop_halation_returned" + suffix);
            returned(x, y, c) = halation_returned(
                configuration_, c, light(x, y, c), scattered[0], scattered[1],
                scattered[2]);
            cpu_pointwise(returned, x, y, c);
            Func halated("develop_halated" + suffix);
            halated(x, y, c) = halation_mix(
                configuration_, c, light(x, y, c),
                [&](int source) { return returned(x, y, source); });
            light = halated;
            light_stored = false;
        }

        Func log_exposure("develop_log_exposure" + suffix);
        log_exposure(x, y, c) = Halide::log(
            Halide::max(light(x, y, c), 1.0e-6f)) / Halide::log(10.0f);

        Func effective_log = log_exposure;
        Func donor_activation("develop_donor_activation" + suffix);
        Func donor_released("develop_donor_released" + suffix);
        Func donor_diffused = donor_released;
        if (use_couplers || use_adjacency || use_donor) {
            cpu_pointwise(log_exposure, x, y, c);
            Func activation("develop_activation" + suffix);
            Expr base = FOTUFILM_CONFIG_CURVES + c * 6;
            activation(x, y, c) =
                (sample_curve(curves, log_exposure(x, y, c), c)
                 - configuration_(base)) / film_curve_range(configuration_, c);
            cpu_pointwise(activation, x, y, c);
            Func released("develop_released" + suffix);
            released(x, y, c) = coupler_release(configuration_, c, activation(x, y, c));
            if (use_couplers) {
                cpu_pointwise(released, x, y, c);
            }
            Func coupler_diffused = released;
            Func adjacency_diffused = activation;
            if (use_coupler_diffusion && use_couplers) {
                coupler_diffused = cpu_gaussian_decimated(
                    released, coupler_sigma_, coupler_radius_,
                    origin_x_, origin_y_, width_, height_,
                    "develop_coupler_diffused" + suffix);
            }
            if (use_adjacency) {
                adjacency_diffused = cpu_gaussian_decimated(
                    activation, adjacency_sigma_, adjacency_radius_,
                    origin_x_, origin_y_, width_, height_,
                    "develop_adjacency_diffused" + suffix);
            }
            // The donor's development: its own curve on its own exposure, diffused with the
            // other inhibitors — the released species travels the same gelatin.
            if (use_donor) {
                Func donor_curve = curve_table(
                    configuration_, FOTUFILM_CONFIG_DONOR_CURVE, 6, 1,
                    "develop_donor_curve" + suffix);
                Func donor_log("develop_donor_log" + suffix);
                donor_log(x, y, c) = Halide::log(Halide::max(
                    donor_exposure(x, y, c), 1.0e-6f)) / Halide::log(10.0f);
                cpu_pointwise(donor_log, x, y, c, 1);
                // Guarded, unlike the dye-forming layers': a stock that coats no donor
                // arrives with the whole donor block zeroed, and an unguarded 0/0 would
                // hand the release row a NaN to multiply by its zero. The guard is what
                // makes a `_donor` variant a safe superset of the plain one.
                donor_activation(x, y, c) =
                    (sample_curve(donor_curve, donor_log(x, y, c), 0)
                     - configuration_(FOTUFILM_CONFIG_DONOR_CURVE))
                    / Halide::max(
                        curve_range(configuration_, FOTUFILM_CONFIG_DONOR_CURVE),
                        1.0e-6f);
                cpu_pointwise(donor_activation, x, y, c, 1);
                donor_released(x, y, c) = donor_release(
                    configuration_, donor_activation(x, y, c));
                cpu_pointwise(donor_released, x, y, c, 1);
                donor_diffused = donor_released;
                if (use_coupler_diffusion) {
                    donor_diffused = cpu_gaussian_decimated(
                        donor_released, coupler_sigma_, coupler_radius_,
                        origin_x_, origin_y_, width_, height_,
                        "develop_donor_diffused" + suffix, 1);
                }
            }
            Func shifted("develop_inhibited" + suffix);
            Expr inhibited = log_exposure(x, y, c);
            if (use_couplers || use_donor) {
                Expr inhibition = 0.0f;
                if (use_couplers) {
                    inhibition = coupler_inhibition(
                        configuration_, c, coupler_diffused(x, y, 0),
                        coupler_diffused(x, y, 1), coupler_diffused(x, y, 2));
                }
                if (use_donor) {
                    inhibition = inhibition
                        + configuration_(FOTUFILM_CONFIG_DONOR_RELEASE + c)
                        * donor_diffused(x, y, 0)
                        * configuration_(FOTUFILM_CONFIG_COUPLER_SCALE);
                }
                Expr u = log_exposure(x, y, c) - inhibition;
                inhibited = u + coupler_warp(configuration_, c, u);
            }
            Expr shift = 0.0f;
            if (use_adjacency) {
                shift += configuration_(FOTUFILM_CONFIG_ADJACENCY_STRENGTH)
                    * (adjacency_diffused(x, y, c) - activation(x, y, c));
            }
            shifted(x, y, c) = inhibited - shift;
            effective_log = shifted;
        }

        Func density("develop_density" + suffix);
        Expr density_base = FOTUFILM_CONFIG_CURVES + c * 6;
        Expr d_min = configuration_(density_base);
        Expr range = film_curve_range(configuration_, c);
        // The developed negative, complemented on a reversal stock to its measured direct-positive
        // densities. `density_in` is handed exactly this quantity instead of computing it —
        // `NegativeInterchange`, per layer, in the same order. Keyed on the configuration rather
        // than on FOTUFILM_FRAME_REVERSAL: that bit also routes a negative shown on a light box or
        // scanner past the paper, and such a negative is developed as a negative, so everything
        // downstream — the grain's density law included — reads its own density.
        auto developed_density = [&](Func log_exposure_source) {
            Expr formed = sample_curve(curves, log_exposure_source(x, y, c), c);
            return Halide::select(
                configuration_(FOTUFILM_CONFIG_DEVELOP_COMPLEMENT) > 0.5f,
                d_min + range - (formed - d_min), formed);
        };
        if (density_in) {
            density(x, y, c) = Halide::mux(
                c, {input_r_(x, y), input_g_(x, y), input_b_(x, y)});
        } else {
            density(x, y, c) = developed_density(effective_log);
        }

        // The other development `texture` differences against: the same curve, the same couplers'
        // own inhibition, and none of the spatial stages. Everything pointwise appears in both and
        // cancels, which is what leaves the film's spatial character behind on its own.
        Func flat_density("develop_flat_density" + suffix);
        if (texture) {
            Func flat_log("develop_flat_log_exposure" + suffix);
            flat_log(x, y, c) = Halide::log(
                Halide::max(flat_light(x, y, c), 1.0e-6f)) / Halide::log(10.0f);
            Func flat_effective = flat_log;
            if (use_couplers || use_donor) {
                cpu_pointwise(flat_log, x, y, c);
                Func flat_shifted("develop_flat_inhibited" + suffix);
                Expr inhibition = 0.0f;
                if (use_couplers) {
                    Func flat_activation("develop_flat_activation" + suffix);
                    flat_activation(x, y, c) =
                        (sample_curve(curves, flat_log(x, y, c), c)
                         - configuration_(density_base)) / range;
                    cpu_pointwise(flat_activation, x, y, c);
                    Func flat_released("develop_flat_released" + suffix);
                    flat_released(x, y, c) = coupler_release(
                        configuration_, c, flat_activation(x, y, c));
                    cpu_pointwise(flat_released, x, y, c);
                    inhibition = coupler_inhibition(
                        configuration_, c, flat_released(x, y, 0),
                        flat_released(x, y, 1), flat_released(x, y, 2));
                }
                // The donor is pointwise and pre-spatial, so its undiffused activation is
                // its own flat development — with no diffusion selected the two developments
                // carry the identical term and the donor cancels out of the texture, which
                // is the mode's contract.
                if (use_donor) {
                    inhibition = inhibition
                        + configuration_(FOTUFILM_CONFIG_DONOR_RELEASE + c)
                        * donor_released(x, y, 0)
                        * configuration_(FOTUFILM_CONFIG_COUPLER_SCALE);
                }
                Expr u = flat_log(x, y, c) - inhibition;
                flat_shifted(x, y, c) = u + coupler_warp(configuration_, c, u);
                flat_effective = flat_shifted;
            }
            flat_density(x, y, c) = developed_density(flat_effective);
            cpu_pointwise(flat_density, x, y, c);
        }

        Func output("develop_output" + suffix);
        if (use_grain) {
            cpu_pointwise(density, x, y, c);
            Func poisson_table = poisson_inverse_cdf(
                grain_lambda_, "develop_poisson_cdf" + suffix);
            Func normal_table = normal_inverse_cdf(
                "develop_normal_cdf" + suffix);
            Func noise("develop_noise" + suffix);
            Expr own_draw = poisson_sample_lut(
                poisson_table, normal_table, x + origin_x_, y + origin_y_,
                seed_, grain_lambda_, c);
            Expr shared_draw = poisson_sample_lut(
                poisson_table, normal_table, x + origin_x_, y + origin_y_,
                seed_, grain_lambda_, kGrainSharedLayer);
            Expr silver_draw = normal_sample_lut(
                normal_table, x + origin_x_, y + origin_y_, seed_,
                kGrainSharedLayer);
            noise(x, y, c) = Halide::select(
                monochrome_ != 0, silver_draw,
                grain_mix(configuration_, own_draw, shared_draw));
            cpu_pointwise(noise, x, y, c);
            noise.specialize(grain_lambda_ >= 16.0f);
            Func grain_field = gaussian(
                noise,
                configuration_(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER),
                configuration_(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER + 1),
                configuration_(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER + 2),
                grain_radius_, width_, height_,
                "develop_grain_field" + suffix);
            Expr amount = Halide::clamp((density(x, y, c) - d_min) / range, 0.0f, 1.0f);
            Expr modulation = grain_density_modulation(
                configuration_, c, amount * range);
            Expr clump = configuration_(FOTUFILM_CONFIG_GRAIN + c)
                * modulation * grain_field(x, y, c);
            if (use_mottle) {
                // The mixture's coarse crystal population: an independent
                // Poisson field on its own hash streams, blurred at its own
                // correlation length, carrying its share of the published
                // granularity under the same density modulation.
                Func mottle_table = poisson_inverse_cdf(
                    mottle_lambda_, "develop_mottle_cdf" + suffix);
                Func mottle_noise("develop_mottle_noise" + suffix);
                Expr own_mottle = poisson_sample_lut(
                    mottle_table, normal_table, x + origin_x_, y + origin_y_,
                    seed_, mottle_lambda_, c + kGrainMottleLayerBase);
                Expr shared_mottle = poisson_sample_lut(
                    mottle_table, normal_table, x + origin_x_, y + origin_y_,
                    seed_, mottle_lambda_, kGrainMottleSharedLayer);
                Expr silver_mottle = normal_sample_lut(
                    normal_table, x + origin_x_, y + origin_y_, seed_,
                    kGrainMottleSharedLayer);
                mottle_noise(x, y, c) = Halide::select(
                    monochrome_ != 0, silver_mottle,
                    grain_mix(configuration_, own_mottle, shared_mottle));
                cpu_pointwise(mottle_noise, x, y, c);
                mottle_noise.specialize(mottle_lambda_ >= 16.0f);
                Func mottle_field = gaussian(
                    mottle_noise,
                    configuration_(FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER),
                    configuration_(FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER + 1),
                    configuration_(FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER + 2),
                    mottle_radius_, width_, height_,
                    "develop_mottle_field" + suffix);
                clump = clump + configuration_(FOTUFILM_CONFIG_MOTTLE + c)
                    * modulation * mottle_field(x, y, c);
            }

            Expr grain = clump;
            if (use_discs) {
                // The Boolean path carries its own dependence on density — the covered fraction is
                // what fluctuates — so it takes no modulation of its own. What it does take is the
                // relation between the two: the model's premise is that opaque grains hide one
                // another, so coverage follows Nutting rather than tracking density linearly, and
                // the fluctuation in covered area is worth `1 / ((1 - a) ln 10)` in density. Both
                // ends of that were missing, and together they are what makes the path saturate
                // where the film is dense instead of going quiet there.
                Expr disc_radius = configuration_(FOTUFILM_CONFIG_GRAIN_DISC_RADIUS);
                Expr fog = configuration_(FOTUFILM_CONFIG_GRAIN_FOG + c);
                Expr own_coverage = nutting_coverage(amount * range + fog);
                // The field shared between layers is taken at the green record's coverage so that
                // it is one field for all three and the stated correlation survives; on a
                // monochrome stock, where the correlation is forced to one, all three records
                // carry that density anyway.
                Expr green_base = Expr(FOTUFILM_CONFIG_CURVES + 6);
                Expr green_net = Halide::clamp(
                    density(x, y, 1) - configuration_(green_base), 0.0f,
                    film_curve_range(configuration_, 1));
                Expr green_coverage = nutting_coverage(
                    green_net + configuration_(FOTUFILM_CONFIG_GRAIN_FOG + 1));
                Expr disc = configuration_(FOTUFILM_CONFIG_GRAIN_DISC + c)
                    * nutting_density_gain(own_coverage)
                    * grain_mix(configuration_,
                                boolean_coverage(x + origin_x_, y + origin_y_,
                                                 own_coverage,
                                                 disc_radius, seed_, c),
                                boolean_coverage(x + origin_x_, y + origin_y_,
                                                 green_coverage,
                                                 disc_radius, seed_,
                                                 Expr(kGrainSharedLayer)));
                grain = Halide::select(grain_mode_ != 0, disc, clump);
            }
            output(x, y, c) = density(x, y, c) + grain;
        } else {
            output(x, y, c) = density(x, y, c);
        }
        cpu_pointwise(output, x, y, c);

        if (features & FOTUFILM_FRAME_PRINT_MTF) {
            // The enlarger lens images the negative onto the paper, and the paper scatters the
            // light it receives — two apertures in series, one Gaussian between them. Both act on
            // the light the negative transmits, not on its density, so the blur is taken in
            // transmittance and the result read back as density. For the small excursions grain
            // makes the two agree to second order, but the negative's dense highlights are not a
            // small excursion, and it is exactly there that this softens most.
            Func transmittance("develop_print_mtf_transmittance" + suffix);
            transmittance(x, y, c) = Halide::pow(10.0f, -output(x, y, c));
            cpu_pointwise(transmittance, x, y, c);
            Expr sigma = configuration_(FOTUFILM_CONFIG_PRINT_MTF_SIGMA);
            Func spread = gaussian(transmittance, sigma, sigma, sigma,
                                   print_mtf_radius_, width_, height_,
                                   "develop_print_mtf" + suffix);
            // A scan finish returns a share of the detail under the blur — the minilab's own
            // unsharp mask, taken in the same transmittance the aperture averaged. The papers
            // keep 0, and the select returns the spread itself so their output does not move.
            Expr keep = configuration_(FOTUFILM_CONFIG_PRINT_SHARPEN);
            Expr read = Halide::select(
                keep > 0.0f,
                spread(x, y, c) + keep * (transmittance(x, y, c) - spread(x, y, c)),
                spread(x, y, c));
            Func printed("develop_printed" + suffix);
            printed(x, y, c) = -Halide::log(Halide::max(read, 1.0e-6f))
                / Halide::log(10.0f);
            cpu_pointwise(printed, x, y, c);
            output = printed;
            if (texture) {
                // The flat development takes the same path through transmittance and back, minus
                // the blur that is the spatial part of it, so what the two differ by is exactly
                // the enlarger's spread rather than the spread plus a round trip one side took
                // and the other did not.
                Func flat_printed("develop_flat_printed" + suffix);
                Expr flat_transmittance =
                    Halide::pow(10.0f, -flat_density(x, y, c));
                flat_printed(x, y, c) = -Halide::log(
                    Halide::max(flat_transmittance, 1.0e-6f)) / Halide::log(10.0f);
                cpu_pointwise(flat_printed, x, y, c);
                flat_density = flat_printed;
            }
        }

        if (texture) {
            // What the two developments differ by, carried back onto the source as the
            // transmittance a negative of that density difference has. The sign is the system's
            // polarity: a denser patch of a negative prints lighter, where a reversal stock's
            // direct positive *is* the image and a denser patch is darker.
            //
            // The print's own contrast is not applied. It is a colour transform — the paper's
            // curve — and this mode has none, so the character arrives at the negative's own
            // amplitude rather than the amplified one a print would show.
            Func textured("develop_texture" + suffix);
            Expr difference = output(x, y, c) - flat_density(x, y, c);
            Expr signed_difference =
                Halide::select(reversal_ != 0, -difference, difference);
            Expr source = Halide::mux(
                c, {input_r_(x, y), input_g_(x, y), input_b_(x, y)});
            textured(x, y, c) = source
                * Halide::exp(signed_difference * 2.3025851f);
            cpu_pointwise(textured, x, y, c);
            output = textured;
        }
        pipeline_ = Pipeline(output);
    }

    /// Develops into `result`, which the caller owns.
    void run(const float *input_r, const float *input_g, const float *input_b,
             Buffer<float> &result,
             int32_t width, int32_t height, const float *configuration,
             const float *exposure_lut, int32_t feature_mask, uint32_t seed,
             int32_t origin_x = 0, int32_t origin_y = 0) {
        std::lock_guard<std::mutex> lock(mutex_);
        Buffer<float> red(const_cast<float *>(input_r), width, height);
        Buffer<float> green(const_cast<float *>(input_g), width, height);
        Buffer<float> blue(const_cast<float *>(input_b), width, height);
        Buffer<float> config(const_cast<float *>(configuration),
                             FOTUFILM_FRAME_CONFIGURATION_COUNT);
        Buffer<float> lut(const_cast<float *>(exposure_lut), kLutValueCount);
        input_r_.set(red);
        input_g_.set(green);
        input_b_.set(blue);
        configuration_.set(config);
        exposure_lut_.set(lut);
        width_.set(width);
        height_.set(height);
        mtf_sigma_0_.set(std::max(configuration[FOTUFILM_CONFIG_MTF_SIGMA], 0.151f));
        mtf_sigma_1_.set(std::max(configuration[FOTUFILM_CONFIG_MTF_SIGMA + 1], 0.151f));
        mtf_sigma_2_.set(std::max(configuration[FOTUFILM_CONFIG_MTF_SIGMA + 2], 0.151f));
        mtf_radius_0_.set(std::max(0, int(configuration[FOTUFILM_CONFIG_MTF_RADIUS])));
        mtf_radius_1_.set(std::max(0, int(configuration[FOTUFILM_CONFIG_MTF_RADIUS + 1])));
        mtf_radius_2_.set(std::max(0, int(configuration[FOTUFILM_CONFIG_MTF_RADIUS + 2])));
        mtf_luma_sigma_.set(std::max(configuration[FOTUFILM_CONFIG_MTF_LUMA_SIGMA], 0.151f));
        mtf_luma_radius_.set(std::max({
            0,
            int(configuration[FOTUFILM_CONFIG_MTF_LUMA_RADIUS]),
            int(configuration[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS]),
            int(configuration[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS + 1]),
            int(configuration[FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS + 2]),
        }));
        Param<int32_t> *strides[3] = {
            &halation_stride_0_, &halation_stride_1_, &halation_stride_2_};
        Param<int32_t> *strided_radii[3] = {
            &halation_strided_radius_0_, &halation_strided_radius_1_,
            &halation_strided_radius_2_};
        for (int scale = 0; scale < 3; ++scale) {
            const int32_t radius = std::max(
                0, int(configuration[FOTUFILM_CONFIG_HALATION_RADIUS + scale]));
            const int32_t stride = fotufilm_halation_stride(radius);
            strides[scale]->set(stride);
            strided_radii[scale]->set(
                fotufilm_halation_strided_radius(radius, stride));
        }
        Param<int32_t> *diffusion_strides[3] = {
            &diffusion_stride_0_, &diffusion_stride_1_, &diffusion_stride_2_};
        Param<int32_t> *diffusion_strided_radii[3] = {
            &diffusion_strided_radius_0_, &diffusion_strided_radius_1_,
            &diffusion_strided_radius_2_};
        for (int scale = 0; scale < 3; ++scale) {
            const int32_t radius = std::max(
                0, int(configuration[FOTUFILM_CONFIG_DIFFUSION_RADIUS + scale]));
            const int32_t stride = fotufilm_diffusion_stride(radius);
            diffusion_strides[scale]->set(stride);
            diffusion_strided_radii[scale]->set(
                fotufilm_halation_strided_radius(radius, stride));
        }
        coupler_sigma_.set(std::max(configuration[FOTUFILM_CONFIG_COUPLER_SIGMA], 0.151f));
        coupler_radius_.set(std::max(0, int(configuration[FOTUFILM_CONFIG_COUPLER_RADIUS])));
        adjacency_sigma_.set(std::max(configuration[FOTUFILM_CONFIG_ADJACENCY_SIGMA], 0.151f));
        adjacency_radius_.set(std::max(0, int(configuration[FOTUFILM_CONFIG_ADJACENCY_RADIUS])));
        grain_sigma_.set(std::max(configuration[FOTUFILM_CONFIG_GRAIN_SIGMA], 0.151f));
        grain_radius_.set(std::max(0, int(configuration[FOTUFILM_CONFIG_GRAIN_RADIUS])));
        grain_lambda_.set(configuration[FOTUFILM_CONFIG_GRAIN_LAMBDA]);
        grain_mode_.set(int32_t(configuration[FOTUFILM_CONFIG_GRAIN_MODE]));
        mottle_sigma_.set(std::max(configuration[FOTUFILM_CONFIG_MOTTLE_SIGMA], 0.151f));
        mottle_radius_.set(std::max(0, int(configuration[FOTUFILM_CONFIG_MOTTLE_RADIUS])));
        mottle_lambda_.set(configuration[FOTUFILM_CONFIG_MOTTLE_LAMBDA]);
        print_mtf_radius_.set(
            std::max(0, int(configuration[FOTUFILM_CONFIG_PRINT_MTF_RADIUS])));
        seed_.set(seed);
        reversal_.set((feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0);
        monochrome_.set((feature_mask & FOTUFILM_FRAME_MONOCHROME) != 0 ? 1 : 0);
        origin_x_.set(origin_x);
        origin_y_.set(origin_y);
        pipeline_.realize(result);
    }

#if defined(FOTUFILM_HALIDE_AOT_GENERATOR)
    /// The arguments in the order the generated function takes them.
    std::vector<Halide::Argument> arguments() {
        return {
            input_r_, input_g_, input_b_, configuration_, exposure_lut_,
            width_, height_,
            mtf_sigma_0_, mtf_sigma_1_, mtf_sigma_2_, mtf_luma_sigma_,
            mtf_radius_0_, mtf_radius_1_, mtf_radius_2_, mtf_luma_radius_,
            halation_stride_0_, halation_stride_1_, halation_stride_2_,
            halation_strided_radius_0_, halation_strided_radius_1_,
            halation_strided_radius_2_,
            coupler_sigma_, coupler_radius_, adjacency_sigma_, adjacency_radius_,
            grain_sigma_, grain_radius_, grain_lambda_, print_mtf_radius_,
            seed_, reversal_, monochrome_, origin_x_, origin_y_,
        };
    }

    void compile_aot(const std::string &prefix, const std::string &function_name,
                     bool include_runtime, Halide::Target target) {
        if (!include_runtime) target.set_feature(Halide::Target::NoRuntime);
        pipeline_.compile_to_static_library(prefix, arguments(), function_name,
                                            target);
    }
#endif

private:
    ImageParam input_r_, input_g_, input_b_, configuration_, exposure_lut_;
    Param<int32_t> width_, height_;
    Param<float> mtf_sigma_0_, mtf_sigma_1_, mtf_sigma_2_, mtf_luma_sigma_;
    Param<int32_t> mtf_radius_0_, mtf_radius_1_, mtf_radius_2_, mtf_luma_radius_;
    Param<int32_t> halation_stride_0_, halation_stride_1_, halation_stride_2_;
    Param<int32_t> halation_strided_radius_0_, halation_strided_radius_1_,
                   halation_strided_radius_2_;
    // Referenced only when FOTUFILM_FRAME_DIFFUSION is set, which is what keeps them out of the
    // AOT argument list and the pre-generated libraries' signatures unchanged.
    Param<int32_t> diffusion_stride_0_, diffusion_stride_1_, diffusion_stride_2_;
    Param<int32_t> diffusion_strided_radius_0_, diffusion_strided_radius_1_,
                   diffusion_strided_radius_2_;
    Param<float> coupler_sigma_, adjacency_sigma_, grain_sigma_, grain_lambda_;
    Param<int32_t> coupler_radius_, adjacency_radius_, grain_radius_, grain_mode_;
    Param<float> mottle_sigma_, mottle_lambda_;
    Param<int32_t> mottle_radius_, print_mtf_radius_;
    Param<uint32_t> seed_;
    Param<int32_t> reversal_, monochrome_;
    /// Where this call's pixels sit in the whole frame.
    Param<int32_t> origin_x_, origin_y_;
    Pipeline pipeline_;
    std::mutex mutex_;
};

/// Stage 8: developed density to display-linear RGB through the spectral output model.
class PrintPipeline {
public:
    /// `encode` takes the host's own last step in this pipeline rather than leaving it to the
    /// caller. `transfer_shape` then names the shape the host's space takes, compiled in so that
    /// a delivery pays for its own transcendental and not for the two it did not ask for; -1
    /// leaves the shape to be read from the configuration, which is what a caller that has not
    /// asked for a shaped variant gets.
    PrintPipeline(bool reversal, bool monochrome, const std::string &suffix,
                  bool encode = false, int transfer_shape = -1)
        : input_(Float(32), 3, "print_input" + suffix),
          configuration_(Float(32), 1, "print_configuration" + suffix),
          film_lut_(Float(32), 1, "print_film_lut" + suffix),
          paper_lut_(Float(32), 1, "print_paper_lut" + suffix) {
        Var x("x"), y("y"), c("c");
        film_lut_.dim(0).set_bounds(0, kLutValueCount);
        paper_lut_.dim(0).set_bounds(0, kLutValueCount);

        Func activation("print_activation" + suffix);
        Expr base = FOTUFILM_CONFIG_CURVES + c * 6;
        activation(x, y, c) = (input_(x, y, c) - configuration_(base))
            / film_curve_range(configuration_, c);
        cpu_pointwise(activation, x, y, c);

        Func display("print_display" + suffix);
        if (reversal) {
            display(x, y, c) = lut_sample(
                film_lut_, activation(x, y, 0), activation(x, y, 1),
                activation(x, y, 2), c);
        } else {
            Func paper_curve = paper_curve_table(
                configuration_, "print_paper_curve_table" + suffix);
            Expr relative = lut_sample(
                film_lut_, activation(x, y, 0), activation(x, y, 1),
                activation(x, y, 2), c);
            Expr paper_exposure = paper_midpoint(configuration_, c)
                + configuration_(FOTUFILM_CONFIG_MASKING + c) * relative;
            Expr paper_base = paper_curve_base(c);
            Expr paper_min = configuration_(paper_base);
            Expr paper_range = curve_range(configuration_, paper_base);
            Func paper_activation("print_paper_activation" + suffix);
            paper_activation(x, y, c) =
                (sample_curve(paper_curve, paper_exposure, c) - paper_min)
                / paper_range;
            cpu_pointwise(paper_activation, x, y, c);
            display(x, y, c) = lut_sample(
                paper_lut_, paper_activation(x, y, 0), paper_activation(x, y, 1),
                paper_activation(x, y, 2), c);
        }

        Func graded("print_graded" + suffix);
        if (monochrome) {
            cpu_pointwise(display, x, y, c);
            Func neutral("print_neutral" + suffix);
            neutral(x, y) = (display(x, y, 0) + display(x, y, 1)
                             + display(x, y, 2)) / 3.0f;
            neutral.compute_root()
                .vectorize(x, kVectorWidth, Halide::TailStrategy::GuardWithIf).parallel(y);
            graded(x, y, c) = neutral(x, y);
        } else {
            graded(x, y, c) = display(x, y, c);
        }

        Func printed("print_printed" + suffix);
        printed(x, y, c) = color_grade(configuration_, c, graded(x, y, c));

        Func output("print_output" + suffix);
        if (!encode) {
            output(x, y, c) = printed(x, y, c);
        } else {
            // The same last step the fused GPU pipeline takes, from the same expression, so that
            // a frame delivered by this road and one delivered by that road are the same frame.
            // Floored before the matrix for the same reason the GPU road floors it: a print
            // carries no negative light, and the delivery basis is where that is decided.
            cpu_pointwise(printed, x, y, c);
            Expr r = Halide::max(printed(x, y, 0), 0.0f);
            Expr g = Halide::max(printed(x, y, 1), 0.0f);
            Expr b = Halide::max(printed(x, y, 2), 0.0f);
            // No alpha on this road, so no premultiplication: the staged CPU pipeline prints
            // three planes and the coverage a still carries is the caller's own.
            output(x, y, c) = Halide::mux(
                c, {host_output_encode(configuration_, r, g, b, 0, false,
                                       transfer_shape),
                    host_output_encode(configuration_, r, g, b, 1, false,
                                       transfer_shape),
                    host_output_encode(configuration_, r, g, b, 2, false,
                                       transfer_shape)});
        }
        cpu_pointwise(output, x, y, c);
        pipeline_ = Pipeline(output);
    }

    /// Prints `density` — the buffer the develop pass just filled — into
    /// `result`, both caller-owned.
    void run(Buffer<float> &density, Buffer<float> &result,
             int32_t width, int32_t height, const float *configuration,
             const float *film_lut, const float *paper_lut, int32_t feature_mask) {
        std::lock_guard<std::mutex> lock(mutex_);
        Buffer<float> config(const_cast<float *>(configuration),
                             FOTUFILM_FRAME_CONFIGURATION_COUNT);
        Buffer<float> film(const_cast<float *>(film_lut), kLutValueCount);
        Buffer<float> paper(const_cast<float *>(paper_lut), kLutValueCount);
        input_.set(density);
        configuration_.set(config);
        film_lut_.set(film);
        paper_lut_.set(paper);
        pipeline_.realize(result);
    }

#if defined(FOTUFILM_HALIDE_AOT_GENERATOR)
    void compile_aot(const std::string &prefix, const std::string &function_name,
                     bool include_runtime, Halide::Target target) {
        if (!include_runtime) target.set_feature(Halide::Target::NoRuntime);
        std::vector<Halide::Argument> arguments = {
            input_, configuration_, film_lut_, paper_lut_};
        pipeline_.compile_to_static_library(prefix, arguments, function_name,
                                            target);
    }
#endif

private:
    ImageParam input_, configuration_, film_lut_, paper_lut_;
    Pipeline pipeline_;
    std::mutex mutex_;
};

/// No film in the gate: the creative controls, the delivery basis, the grade — and, when the
/// caller asked for it, the host's own last step. See FOTUFILM_FRAME_NO_FILM.
///
/// Its own pipeline rather than a branch in `DevelopPipeline`, because it shares nothing with
/// one: no spectral recovery, no curve, no cube, no density at all. What it does share is
/// `creative_exposure`, which is the point — the controls have to mean the same thing with and
/// without a stock loaded, and there is only one expression of them.
class PlainPipeline {
public:
    PlainPipeline(bool monochrome, const std::string &suffix, bool encode,
                  int transfer_shape)
        : input_r_(Float(32), 2, "plain_input_r" + suffix),
          input_g_(Float(32), 2, "plain_input_g" + suffix),
          input_b_(Float(32), 2, "plain_input_b" + suffix),
          configuration_(Float(32), 1, "plain_configuration" + suffix) {
        Var x("x"), y("y"), c("c");
        CreativeScene scene = creative_exposure(
            configuration_, input_r_(x, y), input_g_(x, y), input_b_(x, y),
            x + origin_x_, y + origin_y_);
        // As on the fused road: with no emulsion there are no records to average, so the
        // neutral is the luminance of the light.
        Expr neutral = kLumaR * scene.r + kLumaG * scene.g + kLumaB * scene.b;
        CreativeScene delivered = monochrome
            ? CreativeScene{neutral, neutral, neutral} : scene;

        Func printed("plain_printed" + suffix);
        printed(x, y, c) = plain_print(configuration_, delivered, c);

        Func output("plain_output" + suffix);
        if (!encode) {
            output(x, y, c) = printed(x, y, c);
        } else {
            cpu_pointwise(printed, x, y, c);
            Expr r = Halide::max(printed(x, y, 0), 0.0f);
            Expr g = Halide::max(printed(x, y, 1), 0.0f);
            Expr b = Halide::max(printed(x, y, 2), 0.0f);
            output(x, y, c) = Halide::mux(
                c, {host_output_encode(configuration_, r, g, b, 0, false,
                                       transfer_shape),
                    host_output_encode(configuration_, r, g, b, 1, false,
                                       transfer_shape),
                    host_output_encode(configuration_, r, g, b, 2, false,
                                       transfer_shape)});
        }
        cpu_pointwise(output, x, y, c);
        pipeline_ = Pipeline(output);
    }

    void run(const float *input_r, const float *input_g, const float *input_b,
             Buffer<float> &result, int32_t width, int32_t height,
             const float *configuration, int32_t origin_x, int32_t origin_y) {
        std::lock_guard<std::mutex> lock(mutex_);
        Buffer<float> red(const_cast<float *>(input_r), width, height);
        Buffer<float> green(const_cast<float *>(input_g), width, height);
        Buffer<float> blue(const_cast<float *>(input_b), width, height);
        Buffer<float> config(const_cast<float *>(configuration),
                             FOTUFILM_FRAME_CONFIGURATION_COUNT);
        input_r_.set(red);
        input_g_.set(green);
        input_b_.set(blue);
        configuration_.set(config);
        origin_x_.set(origin_x);
        origin_y_.set(origin_y);
        pipeline_.realize(result);
    }

#if defined(FOTUFILM_HALIDE_AOT_GENERATOR)
    void compile_aot(const std::string &prefix, const std::string &function_name,
                     bool include_runtime, Halide::Target target) {
        if (!include_runtime) target.set_feature(Halide::Target::NoRuntime);
        std::vector<Halide::Argument> arguments = {
            input_r_, input_g_, input_b_, configuration_, origin_x_, origin_y_};
        pipeline_.compile_to_static_library(prefix, arguments, function_name,
                                            target);
    }
#endif

private:
    ImageParam input_r_, input_g_, input_b_, configuration_;
    Param<int32_t> origin_x_, origin_y_;
    Pipeline pipeline_;
    std::mutex mutex_;
};

class GaussianPipeline {
public:
    GaussianPipeline() : input_(Float(32), 3, "gaussian_input") {
        Var x("x"), y("y"), c("c");
        Func source("gaussian_source");
        source(x, y, c) = input_(x, y, c);
        Func output = gaussian(source, sigma_, sigma_, sigma_, radius_, width_,
                               height_, "gaussian_output");
        pipeline_ = Pipeline(output);
    }

    void run(const float *input, float *output, int32_t width, int32_t height,
             float sigma, int32_t radius) {
        std::lock_guard<std::mutex> lock(mutex_);
        Buffer<float> source(width, height, 3);
        const int64_t count = static_cast<int64_t>(width) * height;
        for (int c = 0; c < 3; ++c) std::copy_n(input, count, source.data() + count * c);
        input_.set(source);
        width_.set(width);
        height_.set(height);
        sigma_.set(sigma);
        radius_.set(radius);
        Buffer<float> result(width, height, 3);
        pipeline_.realize(result);
        std::copy_n(result.data(), count, output);
    }

private:
    ImageParam input_;
    Param<int32_t> width_{"standalone_gaussian_width"};
    Param<int32_t> height_{"standalone_gaussian_height"};
    Param<float> sigma_{"standalone_gaussian_sigma"};
    Param<int32_t> radius_{"standalone_gaussian_radius"};
    Pipeline pipeline_;
    std::mutex mutex_;
};

class ApproximateGaussianPipeline {
public:
    ApproximateGaussianPipeline() : input_(Float(32), 3, "approximate_input") {
        Var x("x"), y("y"), c("c");
        Func source("approximate_source");
        source(x, y, c) = input_(x, y, c);
        Func box1 = box_blur(source, radius_, width_, height_, "approximate_box_1");
        Func box2 = box_blur(box1, radius_, width_, height_, "approximate_box_2");
        Func output = box_blur(box2, radius_, width_, height_, "approximate_box_3");
        pipeline_ = Pipeline(output);
    }

    void run(const float *input, float *output, int32_t width, int32_t height,
             int32_t radius) {
        std::lock_guard<std::mutex> lock(mutex_);
        Buffer<float> source(width, height, 3);
        const int64_t count = static_cast<int64_t>(width) * height;
        for (int c = 0; c < 3; ++c) std::copy_n(input, count, source.data() + count * c);
        input_.set(source);
        width_.set(width);
        height_.set(height);
        radius_.set(radius);
        Buffer<float> result(width, height, 3);
        pipeline_.realize(result);
        std::copy_n(result.data(), count, output);
    }

private:
    ImageParam input_;
    Param<int32_t> width_{"standalone_approximate_width"};
    Param<int32_t> height_{"standalone_approximate_height"};
    Param<int32_t> radius_{"standalone_approximate_radius"};
    Pipeline pipeline_;
    std::mutex mutex_;
};

template<typename Function>
int32_t translate_exceptions(Function &&function) {
    try {
        function();
        return 0;
    } catch (const Halide::Error &error) {
        std::fprintf(stderr, "Fotufilm Halide error: %s\n", error.what());
        return -1;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Fotufilm Halide error: %s\n", error.what());
        return -1;
    } catch (...) {
        std::fprintf(stderr, "Fotufilm Halide error: unknown exception\n");
        return -2;
    }
}

}

extern "C" int32_t fotufilm_halide_available(void) { return 1; }

namespace {

DevelopPipeline *develop_pipeline_for(int32_t feature_mask) {
    constexpr int32_t spatial_bits = FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_MTF
        | FOTUFILM_FRAME_HALATION | FOTUFILM_FRAME_COUPLERS
        | FOTUFILM_FRAME_ADJACENCY | FOTUFILM_FRAME_GRAIN
        | FOTUFILM_FRAME_MTF_LUMA | FOTUFILM_FRAME_COUPLER_DIFFUSION
        | FOTUFILM_FRAME_DISC_GRAIN | FOTUFILM_FRAME_GRAIN_MOTTLE
        | FOTUFILM_FRAME_PRINT_MTF | FOTUFILM_FRAME_DENSITY_IN
        | FOTUFILM_FRAME_TEXTURE | FOTUFILM_FRAME_DIFFUSION
        | FOTUFILM_FRAME_DONOR_LAYER | FOTUFILM_FRAME_HALATION_ANNULAR;
    const int32_t features = feature_mask & spatial_bits;
    constexpr int32_t stage_bits = FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_MTF
        | FOTUFILM_FRAME_HALATION | FOTUFILM_FRAME_COUPLERS
        | FOTUFILM_FRAME_ADJACENCY | FOTUFILM_FRAME_GRAIN;
    const int variant = (features & stage_bits)
        | ((features & FOTUFILM_FRAME_MTF_LUMA) ? 64 : 0)
        | ((features & FOTUFILM_FRAME_COUPLER_DIFFUSION) ? 128 : 0)
        | ((features & FOTUFILM_FRAME_DISC_GRAIN) ? 256 : 0)
        | ((features & FOTUFILM_FRAME_GRAIN_MOTTLE) ? 512 : 0)
        | ((features & FOTUFILM_FRAME_PRINT_MTF) ? 1024 : 0)
        | ((features & FOTUFILM_FRAME_DENSITY_IN) ? 2048 : 0)
        | ((features & FOTUFILM_FRAME_TEXTURE) ? 4096 : 0)
        | ((features & FOTUFILM_FRAME_DIFFUSION) ? 8192 : 0)
        | ((features & FOTUFILM_FRAME_DONOR_LAYER) ? 16384 : 0)
        | ((features & FOTUFILM_FRAME_HALATION_ANNULAR) ? 32768 : 0);
    static std::unique_ptr<DevelopPipeline> pipelines[65536];
    static std::mutex pipelines_mutex;
    std::lock_guard<std::mutex> lock(pipelines_mutex);
    if (!pipelines[variant]) {
        pipelines[variant] = std::make_unique<DevelopPipeline>(
            features, "_variant_" + std::to_string(variant));
    }
    return pipelines[variant].get();
}

/// The shape the host's space takes, or -1 to read it from the configuration per pixel.
int output_transfer_shape_for(int32_t feature_mask) {
    if ((feature_mask & FOTUFILM_FRAME_ENCODE_OUT) == 0) return -1;
    if (feature_mask & FOTUFILM_FRAME_OUTPUT_LINEAR) return 0;
    if (feature_mask & FOTUFILM_FRAME_OUTPUT_POWER) return 1;
    if (feature_mask & FOTUFILM_FRAME_OUTPUT_LOG) return 2;
    return -1;
}

PlainPipeline *plain_pipeline_for(int32_t feature_mask) {
    const bool monochrome = (feature_mask & FOTUFILM_FRAME_MONOCHROME) != 0;
    const bool encode = (feature_mask & FOTUFILM_FRAME_ENCODE_OUT) != 0;
    const int shape = output_transfer_shape_for(feature_mask);
    static std::unique_ptr<PlainPipeline> pipelines[16];
    static std::mutex pipelines_mutex;
    std::lock_guard<std::mutex> lock(pipelines_mutex);
    const int variant = (monochrome ? 1 : 0) | (encode ? 2 : 0)
        | ((shape + 1) << 2);
    if (!pipelines[variant]) {
        pipelines[variant] = std::make_unique<PlainPipeline>(
            monochrome, "_plain_variant_" + std::to_string(variant), encode,
            shape);
    }
    return pipelines[variant].get();
}

PrintPipeline *print_pipeline_for(int32_t feature_mask) {
    const bool reversal = (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0;
    const bool monochrome = (feature_mask & FOTUFILM_FRAME_MONOCHROME) != 0;
    // The host's own last step, when it asked for it. This road JITs its pipelines and keeps
    // them, so a shape costs a cache slot rather than a shipped variant; the ahead-of-time
    // generators construct `PrintPipeline` directly and keep their four non-encoding variants.
    const bool encode = (feature_mask & FOTUFILM_FRAME_ENCODE_OUT) != 0;
    // A shape bit is a promise that every frame this pipeline serves takes that shape, so it may
    // be compiled in; without one the shape is read per pixel, exactly as the fused GPU pipeline
    // reads it when the caller asked for no shaped variant.
    const int shape = output_transfer_shape_for(feature_mask);
    static std::unique_ptr<PrintPipeline> pipelines[32];
    static std::mutex pipelines_mutex;
    std::lock_guard<std::mutex> lock(pipelines_mutex);
    const int variant = (reversal ? 1 : 0) | (monochrome ? 2 : 0)
        | (encode ? 4 : 0) | ((shape + 1) << 3);
    if (!pipelines[variant]) {
        pipelines[variant] = std::make_unique<PrintPipeline>(
            reversal, monochrome, "_print_variant_" + std::to_string(variant),
            encode, shape);
    }
    return pipelines[variant].get();
}

}

extern "C" int32_t fotufilm_halide_develop(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height, const float *configuration,
    const float *exposure_lut, int32_t lut_dimension,
    int32_t feature_mask, uint32_t seed) {
    if (!input_r || !input_g || !input_b || !output_r || !output_g || !output_b ||
        !configuration || !exposure_lut || width <= 0 || height <= 0 ||
        lut_dimension != kLutDimension) return -1;
    // The negative on its own, which is what this stage is for: no enlarger images it, so the
    // print's optics are cleared however the frame would have been finished. A microdensitometer
    // reading the granularity of this film is not looking through a lens either. The full frame
    // path keeps the bit, because there the print really does follow.
    const int32_t film_only = feature_mask & ~FOTUFILM_FRAME_PRINT_MTF;
    return translate_exceptions([&] {
        Buffer<float> density(width, height, 3);
        develop_pipeline_for(film_only)->run(
            input_r, input_g, input_b, density, width, height, configuration,
            exposure_lut, film_only, seed);
        copy_planar(density, output_r, output_g, output_b, width, height);
    });
}

extern "C" int32_t fotufilm_halide_print(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height, const float *configuration,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, int32_t feature_mask) {
    if (!input_r || !input_g || !input_b || !output_r || !output_g || !output_b ||
        !configuration || !film_output_lut || !paper_output_lut ||
        width <= 0 || height <= 0 || lut_dimension != kLutDimension) return -1;
    return translate_exceptions([&] {
        Buffer<float> density = planar_buffer(input_r, input_g, input_b,
                                              width, height);
        Buffer<float> result(width, height, 3);
        print_pipeline_for(feature_mask)->run(
            density, result, width, height, configuration, film_output_lut,
            paper_output_lut, feature_mask);
        copy_planar(result, output_r, output_g, output_b, width, height);
    });
}

extern "C" int32_t fotufilm_halide_process(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height, const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    int32_t feature_mask, uint32_t seed) {
    return fotufilm_halide_process_strip(
        input_r, input_g, input_b, output_r, output_g, output_b, width, height,
        width, height, 0, 0, 0, height, configuration, exposure_lut,
        film_output_lut, paper_output_lut, lut_dimension, feature_mask, seed);
}

extern "C" int32_t fotufilm_halide_process_strip(
    const float *input_r, const float *input_g, const float *input_b,
    float *output_r, float *output_g, float *output_b,
    int32_t width, int32_t height, int32_t output_width, int32_t output_height,
    int32_t origin_x, int32_t origin_y, int32_t interior_top,
    int32_t interior_height,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, int32_t feature_mask, uint32_t seed) {
    if (!input_r || !input_g || !input_b || !output_r || !output_g || !output_b ||
        !configuration || !exposure_lut || !film_output_lut ||
        !paper_output_lut || width <= 0 || height <= 0 ||
        output_width < width || interior_top < 0 || interior_height < 0 ||
        interior_top + interior_height > height ||
        lut_dimension != kLutDimension) return -1;
    return translate_exceptions([&] {
        // The strip's interior, wherever it came from, laid into the caller's frame planes.
        auto copy_out = [&](Buffer<float> &result) {
            const int64_t strip_plane = static_cast<int64_t>(width) * interior_height;
            const int64_t frame_plane =
                static_cast<int64_t>(output_width) * output_height;
            float *destination[3] = {output_r, output_g, output_b};
            for (int channel = 0; channel < 3; ++channel) {
                for (int row = 0; row < interior_height; ++row) {
                    const float *source = result.data() + channel * strip_plane
                        + static_cast<int64_t>(row) * width;
                    const int64_t target =
                        static_cast<int64_t>(origin_y + interior_top + row)
                            * output_width
                        + origin_x;
                    if (target + width > frame_plane) break;
                    std::copy_n(source, width, destination[channel] + target);
                }
            }
        };
        if (feature_mask & FOTUFILM_FRAME_NO_FILM) {
            // No emulsion to develop and no paper to print: the strip goes straight through the
            // creative controls into the delivery basis. Its rows are still the strip's own, so
            // the tone masks land where the whole frame measured them.
            Buffer<float> plain(width, interior_height, 3);
            plain.translate(1, interior_top);
            plain_pipeline_for(feature_mask)->run(
                input_r, input_g, input_b, plain, width, interior_height,
                configuration, origin_x, origin_y);
            copy_out(plain);
            return;
        }
        Buffer<float> density(width, height, 3);
        develop_pipeline_for(feature_mask)->run(
            input_r, input_g, input_b, density, width, height, configuration,
            exposure_lut, feature_mask, seed, origin_x, origin_y);
        // `PipelineStage.negative` and `PipelineStage.texture` end here: the first returns the
        // developed negative itself and the second the source the develop's two passes differed
        // on, and neither is a thing the paper prints. The strip's interior is copied out of the
        // develop buffer exactly where the print's result would have been read from.
        const bool develop_is_the_result =
            feature_mask & (FOTUFILM_FRAME_DENSITY_OUT | FOTUFILM_FRAME_TEXTURE);
        Buffer<float> result(width, interior_height, 3);
        result.translate(1, interior_top);
        if (develop_is_the_result) {
            for (int channel = 0; channel < 3; ++channel) {
                for (int row = 0; row < interior_height; ++row) {
                    const int y = interior_top + row;
                    std::copy_n(&density(0, y, channel), width,
                                &result(0, y, channel));
                }
            }
        } else {
            print_pipeline_for(feature_mask)->run(
                density, result, width, interior_height, configuration,
                film_output_lut, paper_output_lut, feature_mask);
        }
        copy_out(result);
    });
}

extern "C" int32_t fotufilm_halide_gaussian(
    const float *input, float *output, int32_t width, int32_t height,
    float sigma, int32_t radius) {
    return translate_exceptions([&] {
        static GaussianPipeline pipeline;
        pipeline.run(input, output, width, height, sigma, radius);
    });
}

extern "C" int32_t fotufilm_halide_approximate_gaussian(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t radius) {
    return translate_exceptions([&] {
        static ApproximateGaussianPipeline pipeline;
        pipeline.run(input, output, width, height, radius);
    });
}

#else

extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_available(void) { return 0; }

extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_develop(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, const float *, const float *, int32_t, int32_t,
    uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_print(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, const float *, const float *, const float *, int32_t,
    int32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_process(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, const float *, const float *, const float *,
    const float *, int32_t, int32_t, uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_process_strip(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    const float *, const float *, const float *, const float *, int32_t,
    int32_t, uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_gaussian(
    const float *, float *, int32_t, int32_t, float, int32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_approximate_gaussian(
    const float *, float *, int32_t, int32_t, int32_t) { return -1; }

#endif
