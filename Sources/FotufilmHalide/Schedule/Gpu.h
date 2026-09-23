#ifndef FOTUFILM_HALIDE_SCHEDULE_GPU_H
#define FOTUFILM_HALIDE_SCHEDULE_GPU_H

#include "FotufilmHalide.h"
#include "GpuConfiguration.h"
#include "../FotufilmHalideGeometry.h"
#include "../Stages/Halation.h"

#include <Halide.h>
#include <cstdlib>
#include <string>
#include <vector>

namespace fotufilm {
namespace gpu {

using Halide::BoundaryConditions::constant_exterior;
using Halide::Buffer;
using Halide::DeviceAPI;
using Halide::Expr;
using Halide::Float;
using Halide::Func;
using Halide::RDom;
using Halide::Target;
using Halide::Var;


inline Expr typed_zero(const Func &function) {
    return Halide::cast(function.value().type(), 0);
}

/// Scheduling state belongs to one graph; folded stores never leak into another build.
class GpuSchedule {
public:
    explicit GpuSchedule(GpuConfiguration configuration = default_gpu_configuration(),
                         bool windowed = false)
        : configuration_(std::move(configuration)), windowed_(windowed) {}
    const GpuConfiguration &configuration() const { return configuration_; }
    Target gpu_target() const { return configuration_.target(); }
    DeviceAPI gpu_device_api() const { return configuration_.device; }
    // Preserve the CPU model's sampling and operation order on portable GPU backends.
    bool reference_sampling() const {
        return gpu_device_api() == DeviceAPI::WebGPU || gpu_device_api() == DeviceAPI::Vulkan;
    }
    int gpu_tile_x() const { return configuration_.tile_x; }
    int gpu_tile_y() const { return configuration_.tile_y; }
    int lut_bound() const {
        return configuration_.device == DeviceAPI::Vulkan ? kLutVulkanPaddedCount : kLutValueCount;
    }
    bool f16_blur_compute() const { return configuration_.half_blur; }
    bool f16_lut_compute() const { return configuration_.half_lut; }
    bool f16_tetra_compute() const { return configuration_.half_tetra; }
    bool split_down_compute() const { return configuration_.split_down; }
    int32_t still_fast_bits() const { return configuration_.still_fast; }
    int32_t ablated_features() const { return configuration_.ablated; }
    const std::vector<Func> &window_stores() const { return window_stores_; }

private:
    const GpuConfiguration configuration_;
    const bool windowed_;
    std::vector<Func> window_stores_;

public:
    /// A per-frame kernel table, computed on the GPU rather than the host.
    void gpu_table(Func table, Var index, Var channel, int channels,
                   const std::string &name) {
        Var block(name + "_table_block"), thread(name + "_table_thread");
        table.compute_root()
            .bound(channel, 0, channels)
            .reorder(channel, index)
            .unroll(channel)
            .gpu_tile(index, block, thread, 32, Halide::TailStrategy::GuardWithIf,
                      gpu_device_api());
    }

    /// The single-dimension form, for the halation pyramid's box kernels.
    void gpu_table(Func table, Var index, const std::string &name) {
        Var block(name + "_table_block"), thread(name + "_table_thread");
        table.compute_root()
            .gpu_tile(index, block, thread, 32, Halide::TailStrategy::GuardWithIf,
                      gpu_device_api());
    }

    /// Samples in the sRGB transfer tables below.
    static constexpr int kTransferSamples = 1024;

    /// sRGB's electro-optical transfer function, tabulated.
    Buffer<float> srgb_decode_values() {
        Buffer<float> table(kTransferSamples, "srgb_decode_values");
        for (int index = 0; index < kTransferSamples; ++index) {
            const float encoded = float(index) / float(kTransferSamples - 1);
            table(index) = encoded <= 0.04045f
                ? encoded / 12.92f
                : std::pow((encoded + 0.055f) / 1.055f, 2.4f);
        }
        return table;
    }

    /// The inverse, indexed by the square root of the display-linear value rather
    /// than by the value itself.
    Buffer<float> srgb_encode_values() {
        Buffer<float> table(kTransferSamples, "srgb_encode_values");
        for (int index = 0; index < kTransferSamples; ++index) {
            const float root = float(index) / float(kTransferSamples - 1);
            const float linear = root * root;
            table(index) = linear <= 0.0031308f
                ? linear * 12.92f
                : 1.055f * std::pow(linear, 1.0f / 2.4f) - 0.055f;
        }
        return table;
    }

    /// Linear interpolation into a transfer table, over a value already in [0, 1].
    Expr sample_transfer(Buffer<float> table, Expr position) {
        Expr q = position * float(kTransferSamples - 1);
        Expr index = Halide::min(Halide::cast<int32_t>(q), kTransferSamples - 2);
        Expr fraction = q - Halide::cast<float>(index);
        Expr low = table(index);
        return low + fraction * (table(index + 1) - low);
    }

    /// `branch`, when given, is a stage gate the pass reads through a select: the pass is compiled
    /// once per side so each side is the exact graph — the bypass side never loads the skipped
    /// stage's field and the staged side never recomputes the bypass.
    void gpu_pointwise(Func function, Var x, Var y, Var channel, int channels,
                              Expr branch = Expr()) {
        Var block_x, block_y, thread_x, thread_y;
        if (windowed_) window_stores_.push_back(function);
        function.compute_root()
            .bound(channel, 0, channels)
            .reorder(channel, x, y)
            .unroll(channel)
            .gpu_tile(x, y, block_x, block_y, thread_x, thread_y,
                      gpu_tile_x(), gpu_tile_y(),
                      Halide::TailStrategy::GuardWithIf, gpu_device_api());
        // Keep the boundary guards in the kernel. Splitting this dynamic geometry into
        // edge/interior loops costs seconds per JIT variant without improving Metal throughput.
        if (gpu_device_api() == DeviceAPI::Metal) function.never_partition_all();
        if (branch.defined()) function.specialize(branch);
    }

    /// Materializes `values` as one full-frame GPU pass and returns the view its consumers read.
    Func store_frame(Func values, bool half, int channels = 3, Expr branch = Expr()) {
        Var x("x"), y("y"), channel("channel");
        if (!half) {
            gpu_pointwise(values, x, y, channel, channels, branch);
            return values;
        }
        Func packed(values.name() + "_packed");
        packed(x, y, channel) = Halide::cast(Float(16), values(x, y, channel));
        gpu_pointwise(packed, x, y, channel, channels, branch);
        Func stored(values.name() + "_stored");
        stored(x, y, channel) = Halide::cast<float>(packed(x, y, channel));
        return stored;
    }

    /// Separable Gaussian with a per-channel sigma, each direction a single dispatch: the taps run as
    /// an in-register reduction inside each thread (Halide's inline sum) rather than as a zero-fill
    /// pass plus a read-modify-write update over the output buffer.
    Func gpu_gaussian(Func source, Expr sigma0, Expr sigma1, Expr sigma2,
                      Expr radius, Expr width, Expr height, bool half,
                      const std::string &name, int channels = 3,
                      bool store_result = true,
                      Expr sigma3 = Expr(), Expr radius3 = Expr()) {
        Var x("x"), y("y"), channel("channel"), k("k");
        const bool merged = sigma3.defined();
        const bool taps16 = half && f16_blur_compute();
        auto tap = [&](Expr value) {
            return taps16 ? Halide::cast(Float(16), value) : value;
        };
        Expr sigma = merged
            ? Halide::select(channel == 0, sigma0, channel == 1, sigma1,
                             channel == 2, sigma2, sigma3)
            : Halide::select(channel == 0, sigma0,
                             channel == 1, sigma1, sigma2);
        Expr extent = merged ? Halide::max(radius, radius3) : radius;
        Expr denominator = 2.0f * sigma * sigma;
        RDom normalization_taps(-extent, extent * 2 + 1, name + "_norm_taps");
        Func kernel(name + "_kernel");
        if (merged) {
            Expr window = Halide::select(channel == 3, radius3, radius);
            Expr total = Halide::sum(
                Halide::select(
                    Halide::abs(normalization_taps.x) <= window,
                    Halide::exp(-Halide::cast<float>(normalization_taps.x
                                                     * normalization_taps.x)
                                / denominator),
                    0.0f),
                name + "_norm_sum");
            Expr weight = Halide::exp(-Halide::cast<float>(k * k) / denominator);
            kernel(k, channel) = tap(Halide::select(
                Halide::abs(k) <= window,
                reference_sampling() ? weight : weight / total,
                0.0f));
        } else {
            Expr total = Halide::sum(
                Halide::exp(-Halide::cast<float>(normalization_taps.x
                                                 * normalization_taps.x)
                            / denominator),
                name + "_norm_sum");
            Expr weight = Halide::exp(-Halide::cast<float>(k * k) / denominator);
            // Match the CPU's unnormalized taps on portable GPUs. Both directional passes already
            // divide by the sum of the valid weights; normalizing twice adds rounding.
            kernel(k, channel) = tap(reference_sampling()
                ? weight : weight / total);
        }
        gpu_table(kernel, k, channel, channels, name);

        Func bounded = constant_exterior(source, typed_zero(source),
                                         {{0, width}, {0, height}, {0, channels}});
        RDom horizontal_taps(-extent, extent * 2 + 1, name + "_horizontal_taps");
        Func horizontal(name + "_horizontal");
        Expr horizontal_weight = Halide::sum(
            Halide::select(x + horizontal_taps.x >= 0
                               && x + horizontal_taps.x < width,
                           Halide::cast<float>(kernel(horizontal_taps.x, channel)), 0.0f),
            name + "_horizontal_weight");
        horizontal(x, y, channel) = Halide::sum(
            tap(bounded(x + horizontal_taps.x, y, channel))
                * kernel(horizontal_taps.x, channel),
            name + "_horizontal_sum") / Halide::max(horizontal_weight, 1.0e-12f);
        Func horizontal_view = store_frame(horizontal, half, channels);
        RDom vertical_taps(-extent, extent * 2 + 1, name + "_vertical_taps");
        Func vertical(name);
        Expr vertical_weight = Halide::sum(
            Halide::select(y + vertical_taps.x >= 0
                               && y + vertical_taps.x < height,
                           Halide::cast<float>(kernel(vertical_taps.x, channel)), 0.0f),
            name + "_vertical_weight");
        vertical(x, y, channel) = Halide::sum(
            tap(horizontal_view(x, y + vertical_taps.x, channel))
                * kernel(vertical_taps.x, channel),
            name + "_vertical_sum") / Halide::max(vertical_weight, 1.0e-12f);
        if (!store_result && taps16) {
            Func widened(name + "_widened");
            widened(x, y, channel) = Halide::cast<float>(vertical(x, y, channel));
            return widened;
        }
        return store_result ? store_frame(vertical, half, channels) : vertical;
    }

    /// One level of a box-averaged pyramid: `previous` (a frame or a coarser grid, `previous_width`
    /// by `previous_height`) averaged over `factor` x `factor` cells whose lattice starts `offset`
    /// cells before the source's origin, cells cut by the source's edge averaged over what they hold.
    /// The halation pyramid in the frame, the light pass that feeds the fields road and the fields
    /// build all decimate through this one definition, so the grids they produce hold the same bits
    /// wherever the cells came from.
    Func gpu_decimate_level(Func previous, Expr factor, Expr offset_x, Expr offset_y,
                                   Expr previous_width, Expr previous_height, int channels,
                                   const std::string &name) {
        Var x("x"), y("y"), channel("channel");
        Func bounded_source = constant_exterior(
            previous, typed_zero(previous),
            {{0, previous_width}, {0, previous_height}, {0, channels}});
        RDom cell(0, factor, 0, factor, name + "_cell");
        Func down(name + "_down");
        Expr source_x = x * factor - offset_x + cell.x;
        Expr source_y = y * factor - offset_y + cell.y;
        Expr valid = Halide::select(source_x >= 0 && source_x < previous_width
                                        && source_y >= 0 && source_y < previous_height,
                                    1.0f, 0.0f);
        Expr cell_count = Halide::sum(valid, name + "_down_weight");
        down(x, y, channel) = Halide::sum(
            bounded_source(x * factor - offset_x + cell.x,
                           y * factor - offset_y + cell.y, channel),
            name + "_down_sum") / Halide::max(cell_count, 1.0f);
        return down;
    }

    /// Three chained box blurs collapsed into one convolution per direction.
    Func gpu_triple_box_blur(Func source, Expr radius, Expr width, Expr height,
                             bool half, const std::string &name, int channels = 3) {
        Var x("x"), y("y"), channel("channel"), k("k");
        const bool taps16 = half && f16_blur_compute();
        auto tap = [&](Expr value) {
            return taps16 ? Halide::cast(Float(16), value) : value;
        };
        Expr box_scale = 1.0f / Halide::cast<float>(radius * 2 + 1);
        RDom fold(-radius, radius * 2 + 1, -radius, radius * 2 + 1, name + "_fold");
        Func kernel(name + "_kernel");
        Expr inner = k - fold.x - fold.y;
        if (reference_sampling()) {
            // Preserve the CPU's rounding at each of the three box convolutions.
            Func box(name + "_box"), box_twice(name + "_box_twice");
            box(k) = Halide::select(Halide::abs(k) <= radius, box_scale, 0.0f);
            RDom fold_once(-radius, radius * 2 + 1, name + "_fold_once");
            box_twice(k) = Halide::sum(box(k - fold_once.x), name + "_fold_once_sum")
                * box_scale;
            RDom fold_again(-radius, radius * 2 + 1, name + "_fold_again");
            kernel(k) = Halide::sum(box_twice(k - fold_again.x), name + "_fold_again_sum")
                * box_scale;
            gpu_table(box, k, name + "_box");
            gpu_table(box_twice, k, name + "_box_twice");
        } else {
            kernel(k) = tap(Halide::sum(
                Halide::select(Halide::abs(inner) <= radius, 1.0f, 0.0f),
                name + "_fold_sum") * box_scale * box_scale * box_scale);
        }
        gpu_table(kernel, k, name + "_kernel");

        Func bounded = constant_exterior(
            source, typed_zero(source), {{0, width}, {0, height}, {0, channels}});
        RDom horizontal_taps(-radius * kTripleBoxPasses, radius * (2 * kTripleBoxPasses) + 1, name + "_horizontal_taps");
        Func horizontal(name + "_horizontal");
        Expr horizontal_weight = Halide::sum(
            Halide::select(x + horizontal_taps.x >= 0
                               && x + horizontal_taps.x < width,
                           Halide::cast<float>(kernel(horizontal_taps.x)), 0.0f),
            name + "_horizontal_weight");
        horizontal(x, y, channel) = Halide::sum(
            tap(bounded(x + horizontal_taps.x, y, channel))
                * kernel(horizontal_taps.x),
            name + "_horizontal_sum") / Halide::max(horizontal_weight, 1.0e-12f);
        Func horizontal_view = store_frame(horizontal, half, channels);
        RDom vertical_taps(-radius * kTripleBoxPasses, radius * (2 * kTripleBoxPasses) + 1, name + "_vertical_taps");
        Func vertical(name);
        Expr vertical_weight = Halide::sum(
            Halide::select(y + vertical_taps.x >= 0
                               && y + vertical_taps.x < height,
                           Halide::cast<float>(kernel(vertical_taps.x)), 0.0f),
            name + "_vertical_weight");
        vertical(x, y, channel) = Halide::sum(
            tap(horizontal_view(x, y + vertical_taps.x, channel))
                * kernel(vertical_taps.x),
            name + "_vertical_sum") / Halide::max(vertical_weight, 1.0e-12f);
        return store_frame(vertical, half, channels);
    }

    /// A frame-anchored box-averaged grid: `source` decimated by `stride`, with the grid's phase
    /// carried from the strip's origin so every strip of a frame decimates on the same cell boundaries
    /// (see the halation pyramid's note).
    struct DecimatedGrid {
        Func view;
        Expr stride, phase_x, phase_y, width, height;
    };

    DecimatedGrid decimated_grid(Func source, Expr stride, Expr origin_x,
                                 Expr origin_y, Expr width, Expr height, bool half,
                                 const std::string &name) {
        using Halide::cast;
        Var x("x"), y("y"), channel("channel");
        Expr phase_x = origin_x % stride;
        Expr phase_y = origin_y % stride;
        Expr down_width = (width + phase_x + stride - 1) / stride;
        Expr down_height = (height + phase_y + stride - 1) / stride;
        Func bounded_source = constant_exterior(
            source, typed_zero(source), {{0, width}, {0, height}, {0, 3}});
        Func down(name + "_down");
        if (split_down_compute()) {
            RDom row_cell(0, stride, name + "_row_cell");
            Func down_rows(name + "_down_rows");
            down_rows(x, y, channel) = Halide::sum(
                bounded_source(x * stride - phase_x + row_cell.x, y, channel),
                name + "_down_rows_sum");
            Func rows_view = store_frame(down_rows, half);
            RDom column_cell(0, stride, name + "_column_cell");
            Func bounded_rows = constant_exterior(
                rows_view, typed_zero(rows_view),
                {{0, down_width}, {0, height}, {0, 3}});
            Expr source_y = y * stride - phase_y + column_cell.x;
            Expr row_count = Halide::cast<float>(
                Halide::max(0, Halide::min(width - 1, x * stride - phase_x + stride - 1)
                                   - Halide::max(0, x * stride - phase_x) + 1));
            Expr column_count = Halide::sum(
                Halide::select(source_y >= 0 && source_y < height, 1.0f, 0.0f),
                name + "_down_column_weight");
            down(x, y, channel) = Halide::sum(
                bounded_rows(x, y * stride - phase_y + column_cell.x, channel),
                name + "_down_columns_sum")
                / Halide::max(row_count * column_count, 1.0f);
        } else {
            RDom cell(0, stride, 0, stride, name + "_cell");
            Expr source_x = x * stride - phase_x + cell.x;
            Expr source_y = y * stride - phase_y + cell.y;
            Expr valid = Halide::select(source_x >= 0 && source_x < width
                                            && source_y >= 0 && source_y < height,
                                        1.0f, 0.0f);
            Expr cell_count = Halide::sum(valid, name + "_down_weight");
            down(x, y, channel) = Halide::sum(
                bounded_source(x * stride - phase_x + cell.x,
                               y * stride - phase_y + cell.y, channel),
                name + "_down_sum") / Halide::max(cell_count, 1.0f);
        }
        return {store_frame(down, half), stride, phase_x, phase_y,
                down_width, down_height};
    }

    /// Whether every decimated Gaussian of a frame lands on the same grid, whatever sigma asked for.
    /// True exactly when `decimated_gaussian_stride` ignores its sigma, which is what lets two of them
    /// over one source share a single downsample.
    bool decimated_stride_is_fixed() {
        return gpu_device_api() == DeviceAPI::Vulkan && configuration_.fixed_stride > 0;
    }

    /// The stride a decimated Gaussian of this sigma decimates by.
    Expr decimated_gaussian_stride(Expr sigma) {
        // Fixed strides are a diagnostic override. The default uses the same geometry
        // as the CPU: forcing every blur to stride two changes the image model.
        return decimated_stride_is_fixed() ? Expr(configuration_.fixed_stride) : gaussian_stride(sigma);
    }

    /// Applies Gaussian blur and resampling to an existing decimated grid.
    Func gpu_gaussian_on_grid(const DecimatedGrid &grid, Expr sigma, Expr radius,
                              bool half, const std::string &name) {
        using Halide::cast;
        Var x("x"), y("y"), channel("channel");
        Expr stride = grid.stride;
        Expr phase_x = grid.phase_x;
        Expr phase_y = grid.phase_y;
        Expr down_width = grid.width;
        Expr down_height = grid.height;
        Expr decimated_sigma = decimated_gaussian_sigma(sigma, stride);
        Expr decimated_radius = decimated_gaussian_radius(radius, stride);
        Func blurred = gpu_gaussian(
            grid.view, decimated_sigma, decimated_sigma, decimated_sigma,
            decimated_radius, down_width, down_height, half, name + "_spread");
        Func bounded_blur = constant_exterior(
            blurred, typed_zero(blurred),
            {{0, down_width}, {0, down_height}, {0, 3}});
        Expr sample_x = (cast<float>(x + phase_x) + 0.5f) / cast<float>(stride)
            - 0.5f;
        Expr sample_y = (cast<float>(y + phase_y) + 0.5f) / cast<float>(stride)
            - 0.5f;
        Expr x0 = cast<int32_t>(Halide::floor(sample_x));
        Expr y0 = cast<int32_t>(Halide::floor(sample_y));
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
        up(x, y, channel) = (w00 * bounded_blur(x0, y0, channel)
                                 + w01 * bounded_blur(x0, y0 + 1, channel)
                                 + w10 * bounded_blur(x0 + 1, y0, channel)
                                 + w11 * bounded_blur(x0 + 1, y0 + 1, channel))
            / Halide::max(sample_weight, 1.0e-12f);
        return up;
    }

    /// A Gaussian whose sigma spans many pixels, run on a decimated grid: box average down by a
    /// power-of-two stride, blur there with the rescaled sigma, and sample back up bilinearly.
    Func gpu_gaussian_decimated(Func source, Expr sigma, Expr radius,
                                Expr origin_x, Expr origin_y,
                                Expr width, Expr height, bool half,
                                const std::string &name) {
        DecimatedGrid grid = decimated_grid(
            source, decimated_gaussian_stride(sigma), origin_x, origin_y,
            width, height, half, name);
        return gpu_gaussian_on_grid(grid, sigma, radius, half, name);
    }
}; // GpuSchedule
}
}

#endif
