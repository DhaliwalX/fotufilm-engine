#pragma once

#include "../FotufilmHalideShared.h"
#include "../FotufilmHalideFrameParams.h"
#include "../Schedule/Gpu.h"
#include "../Graph/Frame.h"
#include "../FotufilmCompiledCache.h"
#include "FilmTileStore.h"

#include <algorithm>
#include <cmath>
#include <functional>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>
#include <cstdlib>


namespace fotufilm::pipelines {

using Halide::BoundaryConditions::constant_exterior;
using Halide::Buffer;
using Halide::DeviceAPI;
using Halide::Expr;
using Halide::Float;
using Halide::Func;
using Halide::ImageParam;
using Halide::Param;
using Halide::Pipeline;
using Halide::RDom;
using Halide::Target;
using Halide::UInt;
using Halide::Var;

using namespace fotufilm;
using namespace fotufilm::gpu;

/// The GPU schedule's placement and precision: which frames are stored in half, the decimated
/// pyramids, and the analytic curves and draws the realtime path takes.
struct GpuPolicy {
    bool half_store = false;
    bool approximate = false;
    bool realtime = false;
    bool windowed = false;
    bool tabulated_curves = false;
    bool table_grain = false;
    /// Whether the frame averages its own first stage for the veiling glare rather than reading the
    /// host's mean: the request's runtime bit, or false where a folded graph cannot see the frame.
    Expr measure_flare;
    bool fields_in = false;
    bool monochrome = false;
    bool discs = false;
    bool packed_luts = false;
    bool half_tetra = false;
    int film_lut_base = 0;
    int paper_lut_base = 0;
};

class GpuBackend : public graph::Backend {
public:
    GpuBackend(GpuSchedule &schedule, GpuPolicy policy, FrameParams &p, ImageParam &configuration,
               ImageParam &film_lut, ImageParam &paper_lut)
        : schedule_(schedule), policy_(policy), p_(p), configuration_(configuration), film_lut_(film_lut),
          paper_lut_(paper_lut) {}

    bool approximate() const override { return policy_.approximate; }
    bool half_lut_math() const override { return policy_.half_tetra; }
    bool tabulated_curves() const override { return policy_.tabulated_curves; }
    bool realtime() const override { return policy_.realtime; }
    bool windowed() const override { return policy_.windowed; }
    bool merged_luma() const override { return true; }
    bool grain_on_density_input() const override { return true; }
    DeviceAPI device() const override { return schedule_.gpu_device_api(); }

    using graph::Backend::store;
    Func store(Func values, graph::Store point, int channels, Expr branch) override {
        using graph::Store;
        if (!values.defined() || stored_.count(values.name())) return values;
        const bool half = policy_.half_store;
        switch (point) {
        case Store::Light:
            return remember(values, schedule_.store_frame(values, half, channels, branch));
        case Store::DonorLog:
        case Store::DonorActivation:
        case Store::DonorReleased:
            if (point != Store::DonorActivation || !policy_.tabulated_curves) {
                return remember(values, schedule_.store_frame(values, half, 3));
            }
            return values;
        case Store::Activation:
            return policy_.tabulated_curves
                ? values : remember(values, schedule_.store_frame(values, half, channels));
        case Store::FlatActivation:
            return policy_.realtime
                ? values : remember(values, schedule_.store_frame(values, half, channels));
        case Store::Density:
            return policy_.discs ? remember(values, schedule_.store_frame(values, false, 3)) : values;
        // Reduce crystal bins and chemical inhibition before their final combination.
        // Keeping every field inline exceeds WebGPU's per-stage storage bindings.
        // Native GPU schedules retain the existing fused expression.
        case Store::CrystalGrain:
        case Store::Inhibition:
        case Store::MtfSelected:
        case Store::PrintMtfInput:
            return schedule_.gpu_device_api() == DeviceAPI::WebGPU
                ? remember(values, schedule_.store_frame(values, false, channels)) : values;
        case Store::Exposure:
        case Store::Diffused:
        case Store::TextureLight:
            return remember(values, schedule_.store_frame(values, half, channels, branch));
        case Store::MtfMixed:
        case Store::MtfSeparated:
        case Store::HalationReturned:
        case Store::LogExposure:
        case Store::Released:
        case Store::FlatLog:
        case Store::FlatReleased:
            return remember(values, schedule_.store_frame(values, half, channels, branch));
        case Store::FilmDensity:
        case Store::FilmGrain:
            // Density to the grain's thousandths: never half.
            return remember(values, schedule_.store_frame(values, false, channels, branch));
        case Store::Noise:
        case Store::MottleNoise:
        case Store::CrystalCounts:
        case Store::Transmittance:
        case Store::FlatTransmittance:
            return remember(values, schedule_.store_frame(values, half, channels));
        case Store::MtfLumaDirect:
        case Store::FlatDensity:
        case Store::Printed:
        case Store::FlatPrinted:
        case Store::PrintActivation:
        case Store::PaperActivation:
        case Store::Display:
        case Store::Output:
            return values;
        }
        return values;
    }

    Func gaussian(Func source, Expr sigma0, Expr sigma1, Expr sigma2, Expr radius,
                  Expr width, Expr height, const std::string &name, int channels,
                  Expr luma_sigma, Expr luma_radius) override {
        Func blurred = schedule_.gpu_gaussian(source, sigma0, sigma1, sigma2, radius, width, height,
                                    policy_.half_store, name, channels, true, luma_sigma,
                                    luma_radius);
        stored_.insert(blurred.name());
        return blurred;
    }

    Func gaussian_decimated(Func source, Expr sigma, Expr radius, Expr origin_x,
                            Expr origin_y, Expr width, Expr height,
                            const std::string &name, int) override {
        return schedule_.gpu_gaussian_decimated(source, sigma, radius, origin_x, origin_y, width,
                                      height, policy_.half_store, name);
    }

    std::array<Expr, 3> scattered(Func light, std::array<Expr, 3> strides,
                                  std::array<Expr, 3> strided_radii, Expr width, Expr height,
                                  Expr origin_x, Expr origin_y, Var x, Var y, Var channel,
                                  int ring_config_base, bool annular, const std::string &name,
                                  int channels) override {
        std::array<Expr, 3> scattered_at;
        const bool halation = ring_config_base >= 0;
        const bool separate_weights = !halation || schedule_.gpu_device_api() == DeviceAPI::WebGPU;
        // A scale's spread read back at the pixel. The grid is addressed in *frame* cells and
        // the sample position formed from the frame coordinate, whatever part of the frame this
        // graph is developing: a ring tap's position is `frame + radius * direction`, and the
        // rounding of that sum depends on the magnitude it is formed at, so a strip that formed
        // it from its own local coordinate would land its taps a bit away from where the whole
        // frame lands them. `grid_at` and `grid_valid` take frame cells; a grid built over a
        // strip translates them by where its own cell lattice starts.
        auto read_scale = [&](int scale_index, Expr stride,
                              const std::function<Expr(Expr, Expr)> &grid_at,
                              const std::function<Expr(Expr, Expr)> &grid_valid) {
            Expr sample_x = (Halide::cast<float>(x + origin_x) + 0.5f)
                / Halide::cast<float>(stride) - 0.5f;
            Expr sample_y = (Halide::cast<float>(y + origin_y) + 0.5f)
                / Halide::cast<float>(stride) - 0.5f;
            auto at = [&](Expr sx, Expr sy) { return grid_at(sx, sy); };
            auto valid_sample = [&](Expr sx, Expr sy) { return grid_valid(sx, sy); };
            Expr center = bilinear_sample(at, sample_x, sample_y, separate_weights)
                / Halide::max(bilinear_sample(valid_sample, sample_x, sample_y,
                                              separate_weights), 1.0e-12f);
            if (halation && annular) {
                Expr ring_radius = configuration_(ring_config_base + scale_index)
                    / Halide::cast<float>(stride);
                return annular_sample(at, sample_x, sample_y, ring_radius)
                    / Halide::max(annular_sample(valid_sample, sample_x, sample_y,
                                                 ring_radius), 1.0e-12f);
            }
            return center;
        };
        if (halation && policy_.fields_in) {
            // The grids arrive whole-frame behind the configuration: frame cells are their own
            // cells, and a cell off the grid reads zero and weighs nothing, as a cell off a
            // strip's grid does below.
            const int header_base = FOTUFILM_FRAME_CONFIGURATION_COUNT;
            const int data_base = header_base + 11;
            Expr config_last = configuration_.dim(0).extent() - 1;
            Expr grid_channel = Halide::min(channel, 2);
            for (int scale_index = 0; scale_index < 3; ++scale_index) {
                Expr grid_width = Halide::cast<int32_t>(
                    configuration_(header_base + 2 + scale_index * 3));
                Expr grid_height = Halide::cast<int32_t>(
                    configuration_(header_base + 3 + scale_index * 3));
                Expr grid_offset = Halide::cast<int32_t>(
                    configuration_(header_base + 4 + scale_index * 3));
                auto inside = [&](Expr cx, Expr cy) {
                    return cx >= 0 && cx < grid_width && cy >= 0 && cy < grid_height;
                };
                auto grid_at = [&](Expr cx, Expr cy) {
                    Expr index = data_base + grid_offset
                        + (Halide::clamp(cy, 0, grid_height - 1) * grid_width
                           + Halide::clamp(cx, 0, grid_width - 1)) * 3 + grid_channel;
                    return Halide::select(
                        inside(cx, cy), configuration_(Halide::clamp(index, 0, config_last)),
                        0.0f);
                };
                auto grid_valid = [&](Expr cx, Expr cy) {
                    return Halide::select(inside(cx, cy), 1.0f, 0.0f);
                };
                scattered_at[scale_index] = read_scale(scale_index, strides[scale_index],
                                                       grid_at, grid_valid);
            }
            return scattered_at;
        }
        const bool half = policy_.half_store;
        Func previous = light;
        Expr previous_stride = 1;
        Expr previous_phase_x = 0, previous_phase_y = 0;
        Expr previous_width = width, previous_height = height;
        for (int scale_index = 0; scale_index < 3; ++scale_index) {
            const std::string scale_name = name + std::to_string(scale_index);
            Expr stride = strides[scale_index];
            Expr phase_x = origin_x % stride;
            Expr phase_y = origin_y % stride;
            Expr down_width = (width + phase_x + stride - 1) / stride;
            Expr down_height = (height + phase_y + stride - 1) / stride;
            Expr factor = stride / previous_stride;
            Expr offset_x = (phase_x - previous_phase_x) / previous_stride;
            Expr offset_y = (phase_y - previous_phase_y) / previous_stride;
            Func down = schedule_.gpu_decimate_level(previous, factor, offset_x, offset_y,
                                           previous_width, previous_height, channels,
                                           scale_name);
            Func down_view = schedule_.store_frame(down, half, channels);
            if (schedule_.gpu_device_api() != DeviceAPI::WebGPU) {
                previous = down_view;
                previous_stride = stride;
                previous_phase_x = phase_x;
                previous_phase_y = phase_y;
                previous_width = down_width;
                previous_height = down_height;
            }
            Func blurred = schedule_.gpu_triple_box_blur(
                down_view, strided_radii[scale_index], down_width, down_height, half,
                scale_name + "_spread", channels);
            Func bounded_blur = constant_exterior(
                blurred, typed_zero(blurred),
                {{0, down_width}, {0, down_height}, {0, channels}});
            // Where this strip's cell lattice starts, in frame cells: its first cell holds the
            // frame rows from `origin - phase`, which is a whole number of cells in.
            Expr grid_origin_x = (origin_x - phase_x) / stride;
            Expr grid_origin_y = (origin_y - phase_y) / stride;
            auto grid_at = [&](Expr cx, Expr cy) {
                return bounded_blur(cx - grid_origin_x, cy - grid_origin_y, channel);
            };
            auto grid_valid = [&](Expr cx, Expr cy) {
                Expr lx = cx - grid_origin_x, ly = cy - grid_origin_y;
                return Halide::select(lx >= 0 && lx < down_width && ly >= 0 && ly < down_height,
                                      1.0f, 0.0f);
            };
            scattered_at[scale_index] = read_scale(scale_index, stride, grid_at, grid_valid);
        }
        return scattered_at;
    }

    Func frame_mean(Func light, int channels, Expr width, Expr height,
                    const std::string &name) override {
        Var y("y"), channel("channel");
        const bool merged = channels == 4;
        Func mean(name + "_mean");
        Expr provided = merged
            ? Halide::select(
                  channel == 3,
                  (configuration_(FOTUFILM_CONFIG_FLARE_MEAN)
                       + configuration_(FOTUFILM_CONFIG_FLARE_MEAN + 1)
                       + configuration_(FOTUFILM_CONFIG_FLARE_MEAN + 2)) / 3.0f,
                  configuration_(FOTUFILM_CONFIG_FLARE_MEAN + Halide::min(channel, 2)))
            : configuration_(FOTUFILM_CONFIG_FLARE_MEAN + channel);
        if (Halide::Internal::is_const_zero(policy_.measure_flare)) {
            mean(channel) = provided;
        } else {
            // The whole-frame reduction, run only when the request asks for it: the total is
            // read under the gate alone, so the rows behind it are skipped, not just unread.
            // Summed in spans of 64 pixels first so the frame's rows spread over enough threads
            // to keep the device busy: a thread per row was a thirtieth of that.
            constexpr int kSpan = 64;
            Var span(name + "_span"), block_x, block_y, thread_x, thread_y;
            RDom within(0, kSpan, name + "_within");
            Expr column = span * kSpan + within;
            Func spans(name + "_spans");
            spans(channel, span, y) = Halide::sum(
                Halide::select(column < width, light(Halide::min(column, width - 1), y, channel),
                               0.0f),
                name + "_span_sum");
            Expr span_count = (width + kSpan - 1) / kSpan;
            spans.compute_root()
                .bound(channel, 0, channels)
                .reorder(channel, span, y)
                .unroll(channel)
                .gpu_tile(span, y, block_x, block_y, thread_x, thread_y, 4, 16,
                          Halide::TailStrategy::GuardWithIf, schedule_.gpu_device_api());
            Var row_block(name + "_row_block");
            Var row_thread(name + "_row_thread");
            RDom across(0, span_count, name + "_across");
            Func rows(name + "_rows");
            rows(channel, y) = Halide::sum(spans(channel, across, y), name + "_row_sum");
            rows.compute_root()
                .bound(channel, 0, channels)
                .reorder(channel, y)
                .unroll(channel)
                .gpu_tile(y, row_block, row_thread, 32,
                          Halide::TailStrategy::GuardWithIf, schedule_.gpu_device_api());
            RDom down(0, height, name + "_down");
            Func total(name + "_total");
            total(channel) = Halide::sum(rows(channel, down), name + "_total_sum")
                / (Halide::cast<float>(width) * Halide::cast<float>(height));
            total.compute_root().bound(channel, 0, channels).unroll(channel)
                .gpu_single_thread(schedule_.gpu_device_api());
            mean(channel) = graph::gated(policy_.measure_flare, total(channel), provided);
        }
        mean.compute_root().bound(channel, 0, channels).unroll(channel)
            .gpu_single_thread(schedule_.gpu_device_api());
        return mean;
    }

    Expr film_curve(ImageParam &configuration, Func table, Expr channel,
                    Expr log_exposure) override {
        return policy_.tabulated_curves
            ? sample_film_curve(configuration, table, log_exposure, channel)
            : film_density(configuration, channel, log_exposure, policy_.approximate);
    }

    Expr donor_curve(ImageParam &configuration, Func table, Expr log_exposure) override {
        return policy_.tabulated_curves
            ? sample_curve(table, log_exposure, 0)
            : curve_density(configuration, FOTUFILM_CONFIG_DONOR_CURVE, log_exposure,
                            policy_.approximate);
    }

    graph::GrainFields grain_fields(ImageParam &configuration, FrameParams &p, Expr,
                                    bool use_mottle, Var x, Var y, Var channel, Expr width,
                                    Expr height, const std::string &prefix,
                                    const std::string &suffix) override {
        graph::GrainFields fields;
        const bool monochrome = policy_.monochrome;
        const bool approximate = policy_.approximate;
        const int noise_channels = monochrome ? 1 : 3;
        const bool half = policy_.half_store;
        Func noise(prefix + "poisson_noise" + suffix);
        if (!policy_.table_grain) {
            Expr shared_draw = monochrome
                ? normal_sample(x + p.origin_x_, y + p.origin_y_, p.seed_, kGrainSharedLayer,
                                approximate)
                : poisson_sample(x + p.origin_x_, y + p.origin_y_, p.seed_, p.grain_lambda_,
                                 kGrainSharedLayer, approximate);
            noise(x, y, channel) = monochrome
                ? shared_draw
                : grain_mix(configuration,
                            poisson_sample(x + p.origin_x_, y + p.origin_y_, p.seed_,
                                           p.grain_lambda_, channel, approximate),
                            shared_draw);
        } else {
            Func poisson_table = poisson_inverse_cdf(
                p.grain_lambda_, prefix + "poisson_cdf" + suffix, schedule_.gpu_device_api());
            Func normal_table = normal_inverse_cdf(prefix + "normal_cdf" + suffix,
                                                   schedule_.gpu_device_api());
            Expr shared_draw = monochrome
                ? normal_sample_lut(normal_table, x + p.origin_x_, y + p.origin_y_,
                                    p.seed_, kGrainSharedLayer)
                : poisson_sample_lut(poisson_table, normal_table, x + p.origin_x_,
                                     y + p.origin_y_, p.seed_, p.grain_lambda_,
                                     kGrainSharedLayer);
            noise(x, y, channel) = monochrome
                ? shared_draw
                : grain_mix(configuration,
                            poisson_sample_lut(poisson_table, normal_table,
                                               x + p.origin_x_, y + p.origin_y_,
                                               p.seed_, p.grain_lambda_, channel),
                            shared_draw);
        }
        Func noise_view = schedule_.store_frame(noise, half, noise_channels);
        fields.grain = schedule_.gpu_gaussian(
            noise_view,
            configuration(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER),
            configuration(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER + 1),
            configuration(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER + 2),
            p.grain_radius_, width, height, half, prefix + "grain_field" + suffix,
            noise_channels);
        if (use_mottle) {
            Func mottle_noise(prefix + "mottle_noise" + suffix);
            if (!policy_.table_grain) {
                Expr shared_draw = monochrome
                    ? normal_sample(x + p.origin_x_, y + p.origin_y_, p.seed_,
                                    kGrainMottleSharedLayer, approximate)
                    : poisson_sample(x + p.origin_x_, y + p.origin_y_, p.seed_,
                                     p.mottle_lambda_, kGrainMottleSharedLayer, approximate);
                mottle_noise(x, y, channel) = monochrome
                    ? shared_draw
                    : grain_mix(configuration,
                                poisson_sample(x + p.origin_x_, y + p.origin_y_, p.seed_,
                                               p.mottle_lambda_,
                                               channel + kGrainMottleLayerBase, approximate),
                                shared_draw);
            } else {
                Func mottle_table = poisson_inverse_cdf(
                    p.mottle_lambda_, prefix + "mottle_cdf" + suffix, schedule_.gpu_device_api());
                Func mottle_normal = normal_inverse_cdf(prefix + "mottle_normal_cdf" + suffix,
                                                        schedule_.gpu_device_api());
                Expr shared_draw = monochrome
                    ? normal_sample_lut(mottle_normal, x + p.origin_x_, y + p.origin_y_,
                                        p.seed_, kGrainMottleSharedLayer)
                    : poisson_sample_lut(mottle_table, mottle_normal, x + p.origin_x_,
                                         y + p.origin_y_, p.seed_, p.mottle_lambda_,
                                         kGrainMottleSharedLayer);
                mottle_noise(x, y, channel) = monochrome
                    ? shared_draw
                    : grain_mix(configuration,
                                poisson_sample_lut(mottle_table, mottle_normal,
                                                   x + p.origin_x_, y + p.origin_y_,
                                                   p.seed_, p.mottle_lambda_,
                                                   channel + kGrainMottleLayerBase),
                                shared_draw);
            }
            fields.mottle = schedule_.gpu_gaussian(
                schedule_.store_frame(mottle_noise, half, noise_channels),
                configuration(FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER),
                configuration(FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER + 1),
                configuration(FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER + 2),
                p.mottle_radius_, width, height, half, prefix + "mottle_field" + suffix,
                noise_channels);
        }
        fields.channels = noise_channels;
        return fields;
    }

    Expr film_lut_sample(Expr ar, Expr ag, Expr ab, Expr channel) override {
        return policy_.packed_luts
            ? lut_sample_at(configuration_, policy_.film_lut_base, ar, ag, ab, channel,
                            policy_.half_tetra)
            : lut_sample(film_lut_, ar, ag, ab, channel, policy_.half_tetra);
    }

    Expr paper_lut_sample(Expr ax, Expr ay, Expr az, Expr channel) override {
        return policy_.packed_luts
            ? lut_sample_at(configuration_, policy_.paper_lut_base, ax, ay, az, channel,
                            policy_.half_tetra)
            : lut_sample(paper_lut_, ax, ay, az, channel, policy_.half_tetra);
    }

    Expr paper_grain_hash(ImageParam &, Expr x, Expr y, Expr channel,
                          bool monochrome) override {
        return pixel_hash(x + p_.origin_x_, y + p_.origin_y_, p_.seed_,
                          kCrystalPaperStreamBase + (monochrome ? Expr(0) : channel));
    }

private:
    Func remember(Func original, Func view) {
        stored_.insert(original.name());
        stored_.insert(view.name());
        return view;
    }

    GpuSchedule &schedule_;
    GpuPolicy policy_;
    FrameParams &p_;
    ImageParam &configuration_;
    ImageParam &film_lut_;
    ImageParam &paper_lut_;
    std::set<std::string> stored_;
};


} // namespace fotufilm::pipelines
