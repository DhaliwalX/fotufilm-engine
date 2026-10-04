#ifndef FOTUFILM_TRANSPORT_PIPELINE_H
#define FOTUFILM_TRANSPORT_PIPELINE_H

#include "../FotufilmHalideShared.h"
#include "../Stages/Exposure.h"

#include <Halide.h>
#include <string>
#include <vector>

namespace fotufilm::pipelines {

/// Power-of-two strides a component's stencils may sit at: 1 through 4096.
constexpr int kTransportLevels = 13;
constexpr int kTransportStencilRadius = 12;
constexpr int kTransportStencilSide = 2 * kTransportStencilRadius + 1;
constexpr int kTransportStencilFloats = kTransportStencilSide * kTransportStencilSide;
/// The stencil table: one radius per level (0 leaves the level out), then each level's weights
/// in a centred 25 x 25 slot, row-major, the band's weight already in them. The pipeline takes
/// the radii again as scalar parameters.
constexpr int kTransportTableFloats = kTransportLevels + kTransportLevels * kTransportStencilFloats;

/// One Layered Transport component's radial kernel applied to that component's exposure and
/// added to the running sum. Level `l` averages the exposure over 2^l x 2^l cells (edge pixels
/// repeated past the frame), convolves the cell grid with its stencil (grid cells repeated
/// past the grid), reconstructs at the pixel centres with the cubic B-spline, and adds.
///
/// The averages come from a 2 x 2 pyramid. Each level is defined everywhere by the same
/// formula, so a cell past the grid averages repeated edge pixels exactly as the direct box
/// does, and a coarse level never makes one thread sum the whole frame.
///
/// `from_scene` exposes the component itself: `exposure` is then the frame's
/// `TransportDomainPipeline`, and the component's light the frame graph's scene exposure through
/// `exposure_lut` and the camera gate — the head of a component whose lens adds no flare or
/// diffusion — so a frame's components share one scene and never leave the device.
struct TransportPipeline {
    Halide::ImageParam exposure{Halide::Float(32), 3, "transport_exposure"};
    Halide::ImageParam accumulated{Halide::Float(32), 3, "transport_accumulated"};
    Halide::ImageParam stencils{Halide::Float(32), 1, "transport_stencils"};
    Halide::ImageParam configuration{Halide::Float(32), 1, "transport_configuration"};
    Halide::ImageParam exposure_lut{Halide::Float(32), 1, "transport_exposure_lut"};
    /// A frame's first component writes the sum rather than adding to it, so the sum never has
    /// to reach the device. From the scene only.
    Halide::Param<bool> first{"transport_first"};
    const bool from_scene;
    /// The table's radii again, as scalars: a reduction's extent may not come from a buffer.
    std::vector<Halide::Param<int32_t>> radii;
    Halide::Func output{"transport_sum"};
    Halide::Var x{"x"}, y{"y"}, c{"c"};

    explicit TransportPipeline(Halide::DeviceAPI device = Halide::DeviceAPI::None,
                               bool from_scene = false)
        : from_scene(from_scene) {
        using namespace Halide;
        stencils.dim(0).set_bounds(0, kTransportTableFloats);
        for (int l = 0; l < kTransportLevels; ++l)
            radii.emplace_back("transport_radius" + std::to_string(l), 0, 0, kTransportStencilRadius);
        const Expr width = exposure.dim(0).extent(), height = exposure.dim(1).extent();
        const bool gpu = device != DeviceAPI::None;
        auto schedule = [&](Func f) {
            f.compute_root();
            if (gpu) {
                Var bx, by, tx, ty;
                f.gpu_tile(x, y, bx, by, tx, ty, 16, 8, TailStrategy::GuardWithIf, device);
            } else {
                f.vectorize(x, 8, TailStrategy::GuardWithIf).parallel(y);
            }
        };

        Func light("transport_light");
        if (from_scene) {
            exposure.dim(0).set_stride(4);
            exposure.dim(2).set_stride(1).set_bounds(0, 4);
            configuration.dim(0).set_bounds(0, FOTUFILM_FRAME_CONFIGURATION_COUNT);
            exposure_lut.dim(0).set_bounds(0, kLutValueCount);
            // `scene_exposure` for a head, which never takes a record input.
            Expr raw = domain_exposure(exposure_lut, {exposure(x, y, 0), exposure(x, y, 1),
                                                      exposure(x, y, 2), exposure(x, y, 3)}, c);
            Expr flash = configuration(FOTUFILM_CONFIG_CAMERA_PREFLASH);
            light(x, y, c) = select(flash > 0.0f, raw + flash, raw)
                * gate_transmission(configuration, x, y);
            light.bound(x, 0, width).bound(y, 0, height);
            schedule(light);
        } else {
            light(x, y, c) = exposure(x, y, c);
        }
        Func level(std::string("transport_cells0"));
        level(x, y, c) = light(clamp(x, 0, width - 1), clamp(y, 0, height - 1), c);
        Expr total = from_scene ? select(first, 0.0f, accumulated(x, y, c)) : accumulated(x, y, c);
        for (int l = 0; l < kTransportLevels; ++l) {
            const int stride = 1 << l;
            const std::string tag = std::to_string(l);
            if (l > 0) {
                Func coarser("transport_cells" + tag);
                coarser(x, y, c) = 0.25f * ((level(2 * x, 2 * y, c) + level(2 * x + 1, 2 * y, c))
                                            + (level(2 * x, 2 * y + 1, c)
                                               + level(2 * x + 1, 2 * y + 1, c)));
                schedule(coarser);
                level = coarser;
            }
            Expr radius = clamp(radii[l], 0, kTransportStencilRadius);
            Expr side = 2 * radius + 1;
            Expr grid_width = (width + stride - 1) / stride;
            Expr grid_height = (height + stride - 1) / stride;
            const int base = kTransportLevels + l * kTransportStencilFloats;
            RDom tap(0, side, 0, side, "transport_tap" + tag);
            Expr dx = tap.x - radius, dy = tap.y - radius;
            // Summed in the update's order, taps along x innermost, so a GPU tile can stage the
            // cells it reads in its threadgroup's memory.
            Func cells("transport_staged" + tag), taps("transport_taps" + tag),
                spread("transport_spread" + tag);
            cells(x, y, c) = level(clamp(x, 0, grid_width - 1), clamp(y, 0, grid_height - 1), c);
            taps(x, y, c) = 0.0f;
            taps(x, y, c) += stencils(base + (dy + kTransportStencilRadius) * kTransportStencilSide
                                       + dx + kTransportStencilRadius)
                * cells(x + dx, y + dy, c);
            spread(x, y, c) = taps(x, y, c);
            if (gpu) {
                // Each thread sums four neighbouring cells in registers, so one stencil load
                // serves four; at the widest stencil a row's taps unroll, and the cells the
                // four share are read once.
                Var bx, by, tx, ty, tv, tw;
                spread.compute_root()
                    .tile(x, y, bx, by, tx, ty, 64, 16, TailStrategy::GuardWithIf)
                    .split(tx, tx, tv, 4, TailStrategy::GuardWithIf)
                    .split(ty, ty, tw, 2, TailStrategy::GuardWithIf)
                    .reorder(tv, tw, tx, ty, bx, by).vectorize(tv).unroll(tw)
                    .gpu_blocks(bx, by, device).gpu_threads(tx, ty, device);
                taps.compute_at(spread, tx).store_in(MemoryType::Register).vectorize(x).unroll(y);
                taps.update().vectorize(x).unroll(y);
                taps.update().specialize(radii[l] == kTransportStencilRadius).unroll(tap.x);
                Var cx, cy, cxi, cyi;
                cells.compute_at(spread, bx).store_in(MemoryType::GPUShared)
                    .tile(x, y, cx, cy, cxi, cyi, 16, 16, TailStrategy::GuardWithIf)
                    .gpu_threads(cxi, cyi, device);
            } else {
                spread.compute_root().vectorize(x, 8, TailStrategy::GuardWithIf).parallel(y);
                taps.compute_at(spread, x).vectorize(x);
                taps.update().vectorize(x);
            }
            Expr reconstructed;
            if (stride == 1) {
                reconstructed = spread(x, y, c);
            } else {
                auto at = [&](Expr sx, Expr sy) {
                    return spread(clamp(sx, 0, grid_width - 1), clamp(sy, 0, grid_height - 1), c);
                };
                Expr px = (cast<float>(x) + 0.5f) / float(stride) - 0.5f;
                Expr py = (cast<float>(y) + 0.5f) / float(stride) - 0.5f;
                reconstructed = bicubic_sample(at, px, py);
            }
            total = total + select(radius > 0, reconstructed, 0.0f);
        }
        output(x, y, c) = total;
        if (gpu) {
            Var bx, by, tx, ty;
            output.gpu_tile(x, y, bx, by, tx, ty, 16, 8, TailStrategy::GuardWithIf, device);
        } else {
            output.vectorize(x, 8, TailStrategy::GuardWithIf).parallel(y);
        }
        // A variant per finest unused level: a component reconstructs only the levels it has.
        Stage unused = output;
        for (int l = kTransportLevels - 1; l > 0; --l) unused = unused.specialize(radii[l] == 0);
    }

    std::vector<Halide::Argument> arguments() {
        std::vector<Halide::Argument> arguments{exposure, accumulated, stencils};
        if (from_scene) arguments.insert(arguments.begin() + 1, {configuration, exposure_lut});
        arguments.insert(arguments.end(), radii.begin(), radii.end());
        if (from_scene) arguments.push_back(first);
        return arguments;
    }
};

/// A frame's scene where every component's exposure LUT samples it: the creative exposure's
/// domain point and scale, `ExposureDomain`, from the scene's RGBA. Both interleaved.
struct TransportDomainPipeline {
    Halide::ImageParam scene{Halide::Float(32), 3, "transport_scene"};
    Halide::ImageParam configuration{Halide::Float(32), 1, "transport_scene_configuration"};
    Halide::Func output{"transport_domain"};
    Halide::Var x{"x"}, y{"y"}, c{"c"};

    explicit TransportDomainPipeline(Halide::DeviceAPI device = Halide::DeviceAPI::None) {
        using namespace Halide;
        scene.dim(0).set_stride(4);
        scene.dim(2).set_stride(1).set_bounds(0, 4);
        configuration.dim(0).set_bounds(0, FOTUFILM_FRAME_CONFIGURATION_COUNT);
        CreativeScene creative = creative_exposure(configuration, scene(x, y, 0), scene(x, y, 1),
                                                   scene(x, y, 2), x, y, false);
        ExposureDomain domain = exposure_domain(configuration, creative.r, creative.g, creative.b);
        output(x, y, c) = mux(c, {domain.x, domain.y, domain.z, domain.scale});
        output.output_buffer().dim(0).set_stride(4);
        output.output_buffer().dim(2).set_stride(1).set_bounds(0, 4);
        output.bound(c, 0, 4).reorder(c, x, y).unroll(c);
        if (device != DeviceAPI::None) {
            Var bx, by, tx, ty;
            output.gpu_tile(x, y, bx, by, tx, ty, 16, 8, TailStrategy::GuardWithIf, device);
        } else {
            output.vectorize(x, 8, TailStrategy::GuardWithIf).parallel(y);
        }
    }

    std::vector<Halide::Argument> arguments() { return {scene, configuration}; }
};

}

#endif
