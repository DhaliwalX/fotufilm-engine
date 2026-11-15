#ifndef FOTUFILM_HALIDE_SCHEDULE_GPU_H
#define FOTUFILM_HALIDE_SCHEDULE_GPU_H

#include "FotufilmHalide.h"
#include "GpuConfiguration.h"
#include "../FotufilmHalideGeometry.h"
#include "../Stages/Halation.h"

#include <Halide.h>
#include <cstdlib>
#include <set>
#include <string>
#include <unordered_map>
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

/// Blocks cross-stage fast-math FMA/reassociation/reciprocal folding across fused float stages
/// while compiling to a single uniform integer predicate on GPU registers.
inline Expr fp_store_barrier(Expr value, Expr runtime_true) {
    return Halide::reinterpret<float>(
        Halide::select(std::move(runtime_true),
                       Halide::reinterpret<uint32_t>(std::move(value)),
                       Halide::Expr(uint32_t(1))));
}

/// Scheduling state belongs to one graph; row-window stores never leak into another build.
class GpuSchedule {
public:
    explicit GpuSchedule(GpuConfiguration configuration = default_gpu_configuration(),
                         bool windowed = false)
        : configuration_(std::move(configuration)), windowed_(windowed) {}
    const GpuConfiguration &configuration() const { return configuration_; }
    bool windowed() const { return windowed_; }
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

    /// A per-pixel stage whose channels each consumer reads together. Inline, every channel of
    /// the consumer recomputes all of its channels — the print's cube lookups nine times a
    /// pixel — and stored, it costs a frame of memory traffic. Where one kernel is its only
    /// reader, `place_register_stages` computes it there once per pixel, in registers.
    void register_stage(Func stage, int channels = 0, std::vector<Func> helpers = {},
                        Expr specialize_home = Expr()) {
        register_stages_.push_back(
            {std::move(stage), channels, std::move(helpers), std::move(specialize_home)});
    }

    /// Records a kernel the graph stores and the thread loop a register stage would join.
    void note_root(Func function, Var thread) { root_kernels_.push_back({function, thread}); }

    /// Places each register stage in the kernels that evaluate it. A kernel that reads the stage
    /// itself, rather than through a function it inlines, takes a copy of its own; the stage is
    /// then computed in the one kernel left, and stays inline where more than one is.
    void place_register_stages() {
        std::unordered_map<std::string, std::vector<Halide::Stage>> home_specs;
        for (RegisterStage &entry : register_stages_) {
            Func &stage = entry.stage;
            RootKernel *home = nullptr;
            int readers = 0;
            for (RootKernel &root : root_kernels_) {
                if (!reaches_inline(root.function, stage.name())) continue;
                if (entry.helpers.empty() && reads_only_directly(root.function, stage.name())) {
                    Func copy = stage.clone_in(root.function);
                    Var copy_c = copy.args()[2];
                    if (entry.channels > 0) {
                        copy.compute_at(root.function, root.thread)
                            .bound(copy_c, 0, entry.channels).unroll(copy_c);
                    } else {
                        copy.compute_at(root.function, root.thread).unroll(copy_c);
                    }
                } else {
                    home = &root;
                    ++readers;
                }
            }
            if (readers != 1) continue;
            Var c = stage.args()[2];
            if (entry.channels > 0) {
                stage.compute_at(home->function, home->thread).bound(c, 0, entry.channels).unroll(c);
            } else {
                stage.compute_at(home->function, home->thread).unroll(c);
            }
            for (Func &helper : entry.helpers) {
                helper.compute_at(stage, c);
            }
            if (entry.specialize_home.defined()) {
                auto &specs = home_specs[home->function.name()];
                const size_t prior = specs.size();
                for (size_t i = 0; i < prior; ++i) {
                    specs.push_back(specs[i].specialize(entry.specialize_home));
                }
                specs.push_back(home->function.specialize(entry.specialize_home));
            }
        }
        register_stages_.clear();
    }

private:
    const GpuConfiguration configuration_;
    const bool windowed_;
    std::vector<Func> window_stores_;
    /// Every kernel the graph stores, with the thread loop its body runs in.
    struct RootKernel {
        Func function;
        Var thread;
    };
    struct RegisterStage {
        Func stage;
        int channels = 0;
        std::vector<Func> helpers;
        Expr specialize_home;
    };
    std::vector<RootKernel> root_kernels_;
    std::vector<RegisterStage> register_stages_;
    Expr last_decimated_stride_one_;

    /// Whether `from` calls `target` itself and through none of the functions it inlines.
    bool reads_only_directly(const Func &from, const std::string &target) const {
        std::set<std::string> roots;
        for (const RootKernel &root : root_kernels_) roots.insert(root.function.name());
        bool direct = false;
        for (const auto &call : Halide::Internal::find_direct_calls(from.function())) {
            if (call.first == target) { direct = true; continue; }
            if (roots.count(call.first)) continue;
            if (reaches_inline(Func(call.second), target)) return false;
        }
        return direct;
    }

    /// Whether `from`'s kernel evaluates `target` itself: reaches it through functions it
    /// inlines, without passing through another stored kernel.
    bool reaches_inline(const Func &from, const std::string &target) const {
        std::set<std::string> roots;
        for (const RootKernel &root : root_kernels_) roots.insert(root.function.name());
        std::vector<Halide::Internal::Function> pending{from.function()};
        std::set<std::string> seen{from.name()};
        while (!pending.empty()) {
            Halide::Internal::Function next = pending.back();
            pending.pop_back();
            for (const auto &call : Halide::Internal::find_direct_calls(next)) {
                if (call.first == target) return true;
                if (roots.count(call.first) || !seen.insert(call.first).second) continue;
                pending.push_back(call.second);
            }
        }
        return false;
    }

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

    /// The innermost GPU thread loop of a pass `gpu_pointwise` scheduled.
    static Var thread_var(const Func &function) { return Var(function.name() + "_thread_x"); }

    /// `branch`, when given, is a stage gate the pass reads through a select: the pass is compiled
    /// once per side so each side is the exact graph — the bypass side never loads the skipped
    /// stage's field and the staged side never recomputes the bypass.
    void gpu_pointwise(Func function, Var x, Var y, Var channel, int channels,
                              Expr branch = Expr()) {
        Var block_x, block_y, thread_y;
        Var thread_x = gpu_device_api() == DeviceAPI::WebGPU || gpu_device_api() == DeviceAPI::Metal
            ? thread_var(function) : Var();
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
        note_root(function, thread_x);
    }

    /// Materializes a two-output Tuple pass in full float, evaluating `helper0` and `helper1`
    /// once per pixel inside the thread loop.
    void store_frame_pair(Func pair, Func helper0, Func helper1, Expr branch = Expr()) {
        Var x = pair.args()[0], y = pair.args()[1], channel = pair.args()[2];
        gpu_pointwise(pair, x, y, channel, 3, branch);
        Var tx = thread_var(pair);
        Var c0 = helper0.args()[2];
        helper0.compute_at(pair, tx).bound(c0, 0, 3).unroll(c0);
        Var c1 = helper1.args()[2];
        helper1.compute_at(pair, tx).bound(c1, 0, 3).unroll(c1);
    }

    /// Materializes `values` as one full-frame GPU pass with an explicit threadgroup tile.
    Func store_frame_tiled(Func values, int channels, int tile_x, int tile_y,
                           Expr branch = Expr()) {
        Var x = values.args()[0], y = values.args()[1], channel = values.args()[2];
        Var block_x, block_y, thread_y;
        Var thread_x = gpu_device_api() == DeviceAPI::WebGPU || gpu_device_api() == DeviceAPI::Metal
            ? thread_var(values) : Var();
        if (windowed_) window_stores_.push_back(values);
        values.compute_root()
            .bound(channel, 0, channels)
            .reorder(channel, x, y)
            .unroll(channel)
            .gpu_tile(x, y, block_x, block_y, thread_x, thread_y, tile_x, tile_y,
                      Halide::TailStrategy::GuardWithIf, gpu_device_api());
        if (gpu_device_api() == DeviceAPI::Metal) values.never_partition_all();
        if (branch.defined()) values.specialize(branch);
        note_root(values, thread_x);
        return values;
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

    /// Defines `f` as the sum of `data` over its taps divided by the sum of `weight`, the weight of
    /// the taps inside the frame. On WebGPU and in Metal's row-window graphs both sums run in one
    /// loop, which shares each tap's bounds test and kernel load: as two loops, the weights cost
    /// most of what the blur itself did. Each
    /// accumulator adds the same terms in the same order as its own sum would, so the result is
    /// the same. `stored` says `f` is scheduled as its own pass, the accumulators' home.
    void normalized_taps(Func f, Var x, Var y, Var channel, Expr data, Expr weight,
                         bool stored, const std::string &name) {
        const bool fused = gpu_device_api() == DeviceAPI::WebGPU
            || (gpu_device_api() == DeviceAPI::Metal && windowed_);
        if (!fused || !stored) {
            f(x, y, channel) = Halide::sum(data, name + "_sum")
                / Halide::max(Halide::sum(weight, name + "_weight"), 1.0e-12f);
            return;
        }
        Func sums(name + "_sums");
        sums(x, y, channel) = {Halide::cast(data.type(), 0), Halide::cast(weight.type(), 0)};
        sums(x, y, channel) = {sums(x, y, channel)[0] + data, sums(x, y, channel)[1] + weight};
        f(x, y, channel) = sums(x, y, channel)[0] / Halide::max(sums(x, y, channel)[1], 1.0e-12f);
        sums.compute_at(f, thread_var(f));
    }

    /// How many of the `cells` samples from `start` fall inside `[0, size)`.
    static Expr cells_inside(Expr start, Expr cells, Expr size) {
        return Halide::max(0, Halide::min(size - 1, start + cells - 1) - Halide::max(0, start) + 1);
    }

    /// A cell's valid samples, counted. The sum of a 1 per valid sample is that same integer, exact
    /// in float, and a loop over the cell computing it costs a decimation kernel as much again as
    /// the samples do; WebGPU and Metal's row-window graphs read the count instead.
    Expr cell_count(Expr valid, Expr start_x, Expr start_y, Expr cells, Expr width, Expr height,
                    const std::string &name) {
        const bool counted = gpu_device_api() == DeviceAPI::WebGPU
            || (gpu_device_api() == DeviceAPI::Metal && windowed_);
        if (!counted) return Halide::sum(valid, name);
        return Halide::cast<float>(cells_inside(start_x, cells, width)
                                   * cells_inside(start_y, cells, height));
    }

    /// Separable Gaussian with a per-channel sigma, each direction a single dispatch: the taps run as
    /// an in-register reduction inside each thread (Halide's inline sum) rather than as a zero-fill
    /// pass plus a read-modify-write update over the output buffer.
    Func gpu_gaussian(Func source, Expr sigma0, Expr sigma1, Expr sigma2,
                      Expr radius, Expr width, Expr height, bool half,
                      const std::string &name, int channels = 3,
                      bool store_result = true,
                      Expr sigma3 = Expr(), Expr radius3 = Expr(),
                      Expr source_specialize = Expr(),
                      std::vector<Func> *deferred_helpers_out = nullptr) {
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
        normalized_taps(horizontal, x, y, channel,
            tap(bounded(x + horizontal_taps.x, y, channel))
                * kernel(horizontal_taps.x, channel),
            Halide::select(x + horizontal_taps.x >= 0
                               && x + horizontal_taps.x < width,
                           Halide::cast<float>(kernel(horizontal_taps.x, channel)), 0.0f),
            !half, name + "_horizontal");
        Func horizontal_view = (!half && windowed_ && gpu_device_api() == DeviceAPI::Metal)
            ? store_frame_tiled(horizontal, channels, 128, 1)
            : store_frame(horizontal, half, channels);
        if (source_specialize.defined()) {
            horizontal.specialize(source_specialize);
        }
        RDom vertical_taps(-extent, extent * 2 + 1, name + "_vertical_taps");
        Expr vertical_data = tap(horizontal_view(x, y + vertical_taps.x, channel))
            * kernel(vertical_taps.x, channel);
        Expr vertical_weight = Halide::select(y + vertical_taps.x >= 0
                                                  && y + vertical_taps.x < height,
                                              Halide::cast<float>(kernel(vertical_taps.x, channel)),
                                              0.0f);
        if (windowed_ && gpu_device_api() == DeviceAPI::Metal
            && (store_result || deferred_helpers_out) && !half && !merged) {
            return gpu_gaussian_three(bounded, kernel, vertical_data, vertical_weight, extent,
                                      width, height, channels, name, source_specialize,
                                      deferred_helpers_out);
        }
        if (deferred_helpers_out) {
            Func sums(name + "_vertical_sums");
            sums(x, y, channel) = {Halide::cast(vertical_data.type(), 0),
                                   Halide::cast(vertical_weight.type(), 0)};
            sums(x, y, channel) = {sums(x, y, channel)[0] + vertical_data,
                                   sums(x, y, channel)[1] + vertical_weight};
            Func vertical(name);
            vertical(x, y, channel) = sums(x, y, channel)[0]
                / Halide::max(sums(x, y, channel)[1], 1.0e-12f);
            *deferred_helpers_out = {sums};
            return vertical;
        }
        Func vertical(name);
        normalized_taps(vertical, x, y, channel, vertical_data, vertical_weight,
                        store_result && !half, name + "_vertical");
        if (!store_result && taps16) {
            Func widened(name + "_widened");
            widened(x, y, channel) = Halide::cast<float>(vertical(x, y, channel));
            return widened;
        }
        return store_result ? store_frame(vertical, half, channels) : vertical;
    }

    /// The separable blur's second pass in a kernel that, at a one-pixel radius, runs the first
    /// pass in registers and reads the stored first pass for wider radii (or defers helper
    /// scheduling to a consumer stage when `deferred_helpers_out` is supplied).
    Func gpu_gaussian_three(Func bounded, Func kernel, Expr vertical_data, Expr vertical_weight,
                            Expr extent, Expr width, Expr height, int channels,
                            const std::string &name, Expr source_specialize = Expr(),
                            std::vector<Func> *deferred_helpers_out = nullptr) {
        Var x("x"), y("y"), channel("channel");
        auto sum_taps = [](const std::vector<std::pair<Expr, Expr>> &taps) {
            Expr data = taps[0].first, weight = taps[0].second;
            for (size_t index = 1; index < taps.size(); ++index) {
                data = data + taps[index].first;
                weight = weight + taps[index].second;
            }
            return data / Halide::max(weight, 1.0e-12f);
        };
        auto row = [&](Expr row_y) {
            std::vector<std::pair<Expr, Expr>> taps;
            for (int offset = -1; offset <= 1; ++offset) {
                taps.push_back({bounded(x + offset, row_y, channel) * kernel(offset, channel),
                                Halide::select(x + offset >= 0 && x + offset < width,
                                               Halide::cast<float>(kernel(offset, channel)),
                                               0.0f)});
            }
            return sum_taps(taps);
        };
        std::vector<std::pair<Expr, Expr>> taps;
        for (int offset = -1; offset <= 1; ++offset) {
            taps.push_back({row(y + offset) * kernel(offset, channel),
                            Halide::select(y + offset >= 0 && y + offset < height,
                                           Halide::cast<float>(kernel(offset, channel)), 0.0f)});
        }
        Func sums(name + "_vertical_sums");
        sums(x, y, channel) = {Halide::cast(vertical_data.type(), 0),
                               Halide::cast(vertical_weight.type(), 0)};
        sums(x, y, channel) = {sums(x, y, channel)[0] + vertical_data,
                               sums(x, y, channel)[1] + vertical_weight};
        if (deferred_helpers_out) {
            Func blurred(name);
            blurred(x, y, channel) = Halide::select(
                extent == 1, sum_taps(taps),
                sums(x, y, channel)[0] / Halide::max(sums(x, y, channel)[1], 1.0e-12f));
            *deferred_helpers_out = {sums};
            return blurred;
        }
        Func blurred(name);
        blurred(x, y, channel) = Halide::select(
            extent == 1, sum_taps(taps),
            sums(x, y, channel)[0] / Halide::max(sums(x, y, channel)[1], 1.0e-12f));
        Var bx(name + "_bx"), by(name + "_by"), ty(name + "_ty");
        Var tx = thread_var(blurred);
        if (windowed_) window_stores_.push_back(blurred);
        blurred.compute_root()
            .bound(channel, 0, channels)
            .reorder(channel, x, y)
            .unroll(channel)
            .gpu_tile(x, y, bx, by, tx, ty, 32, 8,
                      Halide::TailStrategy::GuardWithIf, gpu_device_api());
        blurred.never_partition_all();
        note_root(blurred, tx);
        sums.compute_at(blurred, tx);
        auto one_tap = blurred.specialize(extent == 1);
        if (source_specialize.defined()) {
            one_tap.specialize(source_specialize);
        }
        return blurred;
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
        Expr count = cell_count(valid, x * factor - offset_x, y * factor - offset_y, factor,
                                previous_width, previous_height, name + "_down_weight");
        down(x, y, channel) = Halide::sum(
            bounded_source(x * factor - offset_x + cell.x,
                           y * factor - offset_y + cell.y, channel),
            name + "_down_sum") / Halide::max(count, 1.0f);
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
        normalized_taps(horizontal, x, y, channel,
            tap(bounded(x + horizontal_taps.x, y, channel))
                * kernel(horizontal_taps.x),
            Halide::select(x + horizontal_taps.x >= 0
                               && x + horizontal_taps.x < width,
                           Halide::cast<float>(kernel(horizontal_taps.x)), 0.0f),
            !half, name + "_horizontal");
        Func horizontal_view = store_frame(horizontal, half, channels);
        RDom vertical_taps(-radius * kTripleBoxPasses, radius * (2 * kTripleBoxPasses) + 1, name + "_vertical_taps");
        Func vertical(name);
        normalized_taps(vertical, x, y, channel,
            tap(horizontal_view(x, y + vertical_taps.x, channel))
                * kernel(vertical_taps.x),
            Halide::select(y + vertical_taps.x >= 0
                               && y + vertical_taps.x < height,
                           Halide::cast<float>(kernel(vertical_taps.x)), 0.0f),
            !half, name + "_vertical");
        return store_frame(vertical, half, channels);
    }

    /// A frame-anchored box-averaged grid: `source` decimated by `stride`, with the grid's phase
    /// carried from the strip's origin so every strip of a frame decimates on the same cell boundaries
    /// (see the halation pyramid's note).
    struct DecimatedGrid {
        Func view;
        Func raw_source;
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
            Expr count = cell_count(valid, x * stride - phase_x, y * stride - phase_y, stride,
                                    width, height, name + "_down_weight");
            down(x, y, channel) = Halide::sum(
                bounded_source(x * stride - phase_x + cell.x,
                               y * stride - phase_y + cell.y, channel),
                name + "_down_sum") / Halide::max(count, 1.0f);
        }
        return {store_frame(down, half), source, stride, phase_x, phase_y,
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

    Expr last_decimated_stride_one() const { return last_decimated_stride_one_; }

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
        Func grid_input = grid.view;
        Expr stride_one;
        if (windowed_ && gpu_device_api() == DeviceAPI::Metal && !half
            && grid.raw_source.defined() && name.find("coupler_diffused") != std::string::npos) {
            stride_one = (stride == 1);
            Func muxed(name + "_grid_in");
            muxed(x, y, channel) = Halide::select(
                stride_one, fp_store_barrier(grid.raw_source(x, y, channel), down_width > 0),
                grid.view(x, y, channel));
            grid_input = muxed;
        }
        last_decimated_stride_one_ = stride_one;
        Func blurred = gpu_gaussian(
            grid_input, decimated_sigma, decimated_sigma, decimated_sigma,
            decimated_radius, down_width, down_height, half, name + "_spread",
            3, true, Expr(), Expr(), stride_one);
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
        Expr bilinear = (w00 * bounded_blur(x0, y0, channel)
                             + w01 * bounded_blur(x0, y0 + 1, channel)
                             + w10 * bounded_blur(x0 + 1, y0, channel)
                             + w11 * bounded_blur(x0 + 1, y0 + 1, channel))
            / Halide::max(sample_weight, 1.0e-12f);
        up(x, y, channel) = stride_one.defined()
            ? Halide::select(stride_one, bounded_blur(x, y, channel), bilinear)
            : bilinear;
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

    struct FusedMtfGaussians {
        Func per_layer;
        std::vector<Func> per_helpers;
        Func secondary;
        std::vector<Func> sec_helpers;
        Expr one_tap_sec;
    };

    /// Builds primary (4ch) and secondary (3ch) MTF Gaussians for `fused_mtf_luma`.
    /// When `luma_radius > 1` and `extent <= 8`, the combined 7-channel horizontal pass stages
    /// `raw_pre_mtf` directly in 1D `128 x 1` `GPUShared` SRAM (`2.25 KB`), skipping the
    /// standalone `light_gate` DRAM pass completely.
    FusedMtfGaussians gpu_fused_mtf_gaussians(
        Func pre_mtf, Func raw_pre_mtf,
        Expr sigma0, Expr sigma1, Expr sigma2, Expr radius,
        Expr luma_sigma, Expr luma_radius,
        Expr sec_sigma0, Expr sec_sigma1, Expr sec_sigma2,
        Expr width, Expr height, const std::string &prefix, const std::string &suffix) {
        Var x("x"), y("y"), channel("channel"), k("k");
        const std::string pri_name = prefix + "mtf" + suffix;
        const std::string sec_name = prefix + "mtf_secondary" + suffix;

        Expr pri_sigma = Halide::select(
            channel == 0, sigma0, channel == 1, sigma1, channel == 2, sigma2, luma_sigma);
        Expr extent = Halide::max(radius, luma_radius);
        Expr pri_denom = 2.0f * pri_sigma * pri_sigma;
        RDom pri_norm(-extent, extent * 2 + 1, pri_name + "_norm_taps");
        Expr pri_window = Halide::select(channel == 3, luma_radius, radius);
        Expr pri_total = Halide::sum(
            Halide::select(
                Halide::abs(pri_norm.x) <= pri_window,
                Halide::exp(-Halide::cast<float>(pri_norm.x * pri_norm.x) / pri_denom),
                0.0f),
            pri_name + "_norm_sum");
        Expr pri_weight = Halide::exp(-Halide::cast<float>(k * k) / pri_denom);
        Func pri_kernel(pri_name + "_kernel");
        pri_kernel(k, channel) = Halide::select(
            Halide::abs(k) <= pri_window,
            reference_sampling() ? pri_weight : pri_weight / pri_total, 0.0f);
        gpu_table(pri_kernel, k, channel, 4, pri_name);

        Expr sec_sigma = Halide::select(
            channel == 0, sec_sigma0, channel == 1, sec_sigma1, sec_sigma2);
        Expr sec_denom = 2.0f * sec_sigma * sec_sigma;
        RDom sec_norm(-luma_radius, luma_radius * 2 + 1, sec_name + "_norm_taps");
        Expr sec_total = Halide::sum(
            Halide::exp(-Halide::cast<float>(sec_norm.x * sec_norm.x) / sec_denom),
            sec_name + "_norm_sum");
        Expr sec_weight = Halide::exp(-Halide::cast<float>(k * k) / sec_denom);
        Func sec_kernel(sec_name + "_kernel");
        sec_kernel(k, channel) = reference_sampling() ? sec_weight : sec_weight / sec_total;
        gpu_table(sec_kernel, k, channel, 3, sec_name);

        Func bounded4 = constant_exterior(pre_mtf, 0.0f, {{0, width}, {0, height}, {0, 4}});
        Func bounded3 = constant_exterior(pre_mtf, 0.0f, {{0, width}, {0, height}, {0, 3}});

        // 4-channel primary horizontal pass (used when `one_tap_sec` runs secondary inline).
        RDom pri_htaps(-extent, extent * 2 + 1, pri_name + "_horizontal_taps");
        Func pri_horiz(pri_name + "_horizontal");
        normalized_taps(
            pri_horiz, x, y, channel,
            bounded4(x + pri_htaps.x, y, channel) * pri_kernel(pri_htaps.x, channel),
            Halide::select(x + pri_htaps.x >= 0 && x + pri_htaps.x < width,
                           Halide::cast<float>(pri_kernel(pri_htaps.x, channel)), 0.0f),
            true, pri_name + "_horizontal");
        Func pri_horiz_view = (windowed_ && gpu_device_api() == DeviceAPI::Metal)
            ? store_frame_tiled(pri_horiz, 4, 128, 1)
            : store_frame(pri_horiz, false, 4);

        // 7-channel combined horizontal pass (used when `luma_radius > 1`).
        RDom both_pri_htaps(-extent, extent * 2 + 1, pri_name + "_both_htaps");
        Func pri_hsums(pri_name + "_both_hsums");
        pri_hsums(x, y, channel) = {0.0f, 0.0f};
        pri_hsums(x, y, channel) = {
            pri_hsums(x, y, channel)[0]
                + bounded4(x + both_pri_htaps.x, y, channel)
                      * pri_kernel(both_pri_htaps.x, channel),
            pri_hsums(x, y, channel)[1]
                + Halide::select(x + both_pri_htaps.x >= 0 && x + both_pri_htaps.x < width,
                                 Halide::cast<float>(pri_kernel(both_pri_htaps.x, channel)),
                                 0.0f)};

        RDom both_sec_htaps(-luma_radius, luma_radius * 2 + 1, sec_name + "_both_htaps");
        Func sec_hsums(sec_name + "_both_hsums");
        sec_hsums(x, y, channel) = {0.0f, 0.0f};
        sec_hsums(x, y, channel) = {
            sec_hsums(x, y, channel)[0]
                + bounded3(x + both_sec_htaps.x, y, channel)
                      * sec_kernel(both_sec_htaps.x, channel),
            sec_hsums(x, y, channel)[1]
                + Halide::select(x + both_sec_htaps.x >= 0 && x + both_sec_htaps.x < width,
                                 Halide::cast<float>(sec_kernel(both_sec_htaps.x, channel)),
                                 0.0f)};

        auto pri_h = [&](int ch) {
            return pri_hsums(x, y, ch)[0] / Halide::max(pri_hsums(x, y, ch)[1], 1.0e-12f);
        };
        auto sec_h = [&](int ch) {
            return sec_hsums(x, y, ch)[0] / Halide::max(sec_hsums(x, y, ch)[1], 1.0e-12f);
        };
        Expr dram_mux = Halide::mux(
            channel, {pri_h(0), pri_h(1), pri_h(2), pri_h(3), sec_h(0), sec_h(1), sec_h(2)});

        Func both_horiz(pri_name + "_both_horizontal");
        if (windowed_ && gpu_device_api() == DeviceAPI::Metal && raw_pre_mtf.defined()) {
            // 240 output pixels + up to 2*8 = 16 halo pixels <= 256 threads: `pre_sh` computes
            // `scene_exposure` in ONE single wave across 8 SIMD32 warps without a second tail wave.
            constexpr int kHorizOutX = 240;
            constexpr int kHorizThreads = 256;
            constexpr int kMaxPreShExtent = 8;
            Expr sh_ext = Halide::clamp(extent, 1, kMaxPreShExtent);
            Expr sh_sec = Halide::clamp(luma_radius, 1, kMaxPreShExtent);
            Expr use_pre_sh = extent <= kMaxPreShExtent;

            Func pre_sh(pri_name + "_pre_sh");
            Expr sh_inside = x >= 0 && x < width && y >= 0 && y < height;
            pre_sh(x, y, channel) = Halide::select(
                sh_inside,
                raw_pre_mtf(Halide::clamp(x, 0, width - 1), Halide::clamp(y, 0, height - 1),
                            channel),
                0.0f);

            RDom htaps_sh(-sh_ext, sh_ext * 2 + 1, pri_name + "_htaps_sh");
            Expr tx_coord = x + htaps_sh.x;
            Expr tap_in_bounds = tx_coord >= 0 && tx_coord < width;
            Expr tap_in_sec = Halide::abs(htaps_sh.x) <= sh_sec;
            Expr s_in0 = pre_sh(tx_coord, y, 0);
            Expr s_in1 = pre_sh(tx_coord, y, 1);
            Expr s_in2 = pre_sh(tx_coord, y, 2);
            Expr s_in3 = pre_sh(tx_coord, y, 3);
            Expr pk0 = pri_kernel(htaps_sh.x, 0);
            Expr pk1 = pri_kernel(htaps_sh.x, 1);
            Expr pk2 = pri_kernel(htaps_sh.x, 2);
            Expr pk3 = pri_kernel(htaps_sh.x, 3);
            Expr sk0 = Halide::select(tap_in_sec, sec_kernel(htaps_sh.x, 0), 0.0f);
            Expr sk1 = Halide::select(tap_in_sec, sec_kernel(htaps_sh.x, 1), 0.0f);
            Expr sk2 = Halide::select(tap_in_sec, sec_kernel(htaps_sh.x, 2), 0.0f);

            Func hsums_sh(pri_name + "_all_hsums_sh");
            hsums_sh(x, y) = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
                              0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
            hsums_sh(x, y) = {
                hsums_sh(x, y)[0] + s_in0 * pk0,
                hsums_sh(x, y)[1] + Halide::select(tap_in_bounds, pk0, 0.0f),
                hsums_sh(x, y)[2] + s_in1 * pk1,
                hsums_sh(x, y)[3] + Halide::select(tap_in_bounds, pk1, 0.0f),
                hsums_sh(x, y)[4] + s_in2 * pk2,
                hsums_sh(x, y)[5] + Halide::select(tap_in_bounds, pk2, 0.0f),
                hsums_sh(x, y)[6] + s_in3 * pk3,
                hsums_sh(x, y)[7] + Halide::select(tap_in_bounds, pk3, 0.0f),
                hsums_sh(x, y)[8] + s_in0 * sk0,
                hsums_sh(x, y)[9] + Halide::select(tap_in_bounds, sk0, 0.0f),
                hsums_sh(x, y)[10] + s_in1 * sk1,
                hsums_sh(x, y)[11] + Halide::select(tap_in_bounds, sk1, 0.0f),
                hsums_sh(x, y)[12] + s_in2 * sk2,
                hsums_sh(x, y)[13] + Halide::select(tap_in_bounds, sk2, 0.0f)};

            auto norm_sh = [&](int idx) {
                return hsums_sh(x, y)[idx * 2]
                    / Halide::max(hsums_sh(x, y)[idx * 2 + 1], 1.0e-12f);
            };
            Expr sh_mux = Halide::mux(
                channel, {norm_sh(0), norm_sh(1), norm_sh(2), norm_sh(3),
                          norm_sh(4), norm_sh(5), norm_sh(6)});

            both_horiz(x, y, channel) = Halide::select(use_pre_sh, sh_mux, dram_mux);
            Var bbx(both_horiz.name() + "_bx"), bby(both_horiz.name() + "_by"),
                bty(both_horiz.name() + "_ty");
            Var btx = thread_var(both_horiz);
            window_stores_.push_back(both_horiz);
            both_horiz.compute_root()
                .bound(channel, 0, 7)
                .unroll(channel)
                .split(y, bby, bty, 1, Halide::TailStrategy::GuardWithIf)
                .split(x, bbx, btx, kHorizOutX, Halide::TailStrategy::GuardWithIf)
                .reorder(channel, btx, bty, bbx, bby)
                .gpu_blocks(bbx, bby, gpu_device_api())
                .gpu_threads(btx, bty, gpu_device_api());
            both_horiz.never_partition_all();
            note_root(both_horiz, btx);

            Var px = pre_sh.args()[0], py = pre_sh.args()[1], pc = pre_sh.args()[2];
            Var pxo(pre_sh.name() + "_pxo"), pyo(pre_sh.name() + "_pyo"),
                ptx(pre_sh.name() + "_ptx"), pty(pre_sh.name() + "_pty");
            pre_sh.store_in(Halide::MemoryType::GPUShared)
                .compute_at(both_horiz, bbx)
                .bound(pc, 0, 4)
                .split(py, pyo, pty, 1, Halide::TailStrategy::GuardWithIf)
                .split(px, pxo, ptx, kHorizThreads, Halide::TailStrategy::GuardWithIf)
                .reorder(pc, pxo, pyo, ptx, pty)
                .unroll(pc)
                .gpu_threads(ptx, pty, gpu_device_api());

            hsums_sh.compute_at(both_horiz, btx);
            pri_hsums.compute_at(both_horiz, btx).bound(channel, 0, 4).unroll(channel);
            pri_hsums.update(0).unroll(channel);
            sec_hsums.compute_at(both_horiz, btx).bound(channel, 0, 3).unroll(channel);
            sec_hsums.update(0).unroll(channel);
            both_horiz.specialize(use_pre_sh);
        } else {
            both_horiz(x, y, channel) = dram_mux;
            if (windowed_ && gpu_device_api() == DeviceAPI::Metal) {
                store_frame_tiled(both_horiz, 7, 128, 1);
            } else {
                store_frame(both_horiz, false, 7);
            }
            Var btx = thread_var(both_horiz);
            pri_hsums.compute_at(both_horiz, btx).bound(channel, 0, 4).unroll(channel);
            pri_hsums.update(0).unroll(channel);
            sec_hsums.compute_at(both_horiz, btx).bound(channel, 0, 3).unroll(channel);
            sec_hsums.update(0).unroll(channel);
        }

        Expr one_tap_sec = (windowed_ && gpu_device_api() == DeviceAPI::Metal)
            ? Expr(luma_radius == 1)
            : Expr(Halide::Internal::const_false());

        RDom pri_vtaps(-extent, extent * 2 + 1, pri_name + "_vertical_taps");
        Expr pri_h_sample = Halide::select(
            one_tap_sec, pri_horiz_view(x, y + pri_vtaps.x, channel),
            both_horiz(x, y + pri_vtaps.x, channel));
        Expr pri_vdata = pri_h_sample * pri_kernel(pri_vtaps.x, channel);
        Expr pri_vweight = Halide::select(
            y + pri_vtaps.x >= 0 && y + pri_vtaps.x < height,
            Halide::cast<float>(pri_kernel(pri_vtaps.x, channel)), 0.0f);
        Func pri_vsums(pri_name + "_vertical_sums");
        pri_vsums(x, y, channel) = {0.0f, 0.0f};
        pri_vsums(x, y, channel) = {pri_vsums(x, y, channel)[0] + pri_vdata,
                                    pri_vsums(x, y, channel)[1] + pri_vweight};
        Func per_layer(pri_name);
        per_layer(x, y, channel) =
            pri_vsums(x, y, channel)[0] / Halide::max(pri_vsums(x, y, channel)[1], 1.0e-12f);
        std::vector<Func> per_helpers{pri_vsums};

        RDom sec_vtaps(-luma_radius, luma_radius * 2 + 1, sec_name + "_vertical_taps");
        Expr sec_vdata = both_horiz(x, y + sec_vtaps.x, channel + 4)
            * sec_kernel(sec_vtaps.x, channel);
        Expr sec_vweight = Halide::select(
            y + sec_vtaps.x >= 0 && y + sec_vtaps.x < height,
            Halide::cast<float>(sec_kernel(sec_vtaps.x, channel)), 0.0f);
        std::vector<Func> sec_helpers;
        Func secondary(sec_name);
        if (windowed_ && gpu_device_api() == DeviceAPI::Metal) {
            secondary = gpu_gaussian_three(
                bounded3, sec_kernel, sec_vdata, sec_vweight, luma_radius, width, height, 3,
                sec_name, Expr(), &sec_helpers);
        } else {
            Func sec_vsums(sec_name + "_vertical_sums");
            sec_vsums(x, y, channel) = {0.0f, 0.0f};
            sec_vsums(x, y, channel) = {sec_vsums(x, y, channel)[0] + sec_vdata,
                                        sec_vsums(x, y, channel)[1] + sec_vweight};
            secondary(x, y, channel) =
                sec_vsums(x, y, channel)[0] / Halide::max(sec_vsums(x, y, channel)[1], 1.0e-12f);
            sec_helpers = {sec_vsums};
        }

        return {per_layer, std::move(per_helpers), secondary, std::move(sec_helpers), one_tap_sec};
    }

    void schedule_fused_mtf_separated(Func separated, FusedMtfGaussians &mtf, Func mixed) {
        Var x = separated.args()[0], y = separated.args()[1], c = separated.args()[2];
        Var bx(separated.name() + "_bx"), by(separated.name() + "_by"),
            ty(separated.name() + "_ty");
        Var tx = thread_var(separated);
        if (windowed_) window_stores_.push_back(separated);
        const int tile_x = (gpu_device_api() == DeviceAPI::Metal) ? 32 : gpu_tile_x();
        const int tile_y = (gpu_device_api() == DeviceAPI::Metal) ? 8 : gpu_tile_y();
        separated.compute_root()
            .bound(c, 0, 3)
            .reorder(c, x, y)
            .unroll(c)
            .gpu_tile(x, y, bx, by, tx, ty, tile_x, tile_y,
                      Halide::TailStrategy::GuardWithIf, gpu_device_api());
        if (gpu_device_api() == DeviceAPI::Metal) separated.never_partition_all();
        note_root(separated, tx);

        Var per_c = mtf.per_layer.args()[2];
        mtf.per_layer.compute_at(separated, tx).bound(per_c, 0, 4).unroll(per_c);
        for (Func &h : mtf.per_helpers) {
            h.compute_at(mtf.per_layer, per_c);
        }
        Var sec_c = mtf.secondary.args()[2];
        mtf.secondary.compute_at(separated, tx).bound(sec_c, 0, 3).unroll(sec_c);
        for (Func &h : mtf.sec_helpers) {
            h.compute_at(mtf.secondary, sec_c);
        }
        Var mix_c = mixed.args()[2];
        mixed.compute_at(separated, tx).bound(mix_c, 0, 3).unroll(mix_c);

        if (windowed_ && gpu_device_api() == DeviceAPI::Metal) {
            separated.specialize(mtf.one_tap_sec);
        }
    }
}; // GpuSchedule
}
}

#endif
