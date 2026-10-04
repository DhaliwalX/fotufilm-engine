#ifndef FOTUFILM_TRANSPORT_PIPELINE_H
#define FOTUFILM_TRANSPORT_PIPELINE_H

#include "../FotufilmHalideShared.h"

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
struct TransportPipeline {
    Halide::ImageParam exposure{Halide::Float(32), 3, "transport_exposure"};
    Halide::ImageParam accumulated{Halide::Float(32), 3, "transport_accumulated"};
    Halide::ImageParam stencils{Halide::Float(32), 1, "transport_stencils"};
    /// The table's radii again, as scalars: a reduction's extent may not come from a buffer.
    std::vector<Halide::Param<int32_t>> radii;
    Halide::Func output{"transport_sum"};
    Halide::Var x{"x"}, y{"y"}, c{"c"};

    explicit TransportPipeline(Halide::DeviceAPI device = Halide::DeviceAPI::None) {
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

        Func level(std::string("transport_cells0"));
        level(x, y, c) = exposure(clamp(x, 0, width - 1), clamp(y, 0, height - 1), c);
        Expr total = accumulated(x, y, c);
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
            Func spread("transport_spread" + tag);
            spread(x, y, c) = 0.0f;
            spread(x, y, c) += stencils(base + (dy + kTransportStencilRadius) * kTransportStencilSide
                                        + dx + kTransportStencilRadius)
                * level(clamp(x + dx, 0, grid_width - 1), clamp(y + dy, 0, grid_height - 1), c);
            schedule(spread);
            if (gpu) {
                Var bx, by, tx, ty;
                spread.update().gpu_tile(x, y, bx, by, tx, ty, 16, 8, TailStrategy::GuardWithIf,
                                         device);
            } else {
                spread.update().vectorize(x, 8, TailStrategy::GuardWithIf).parallel(y);
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
    }

    std::vector<Halide::Argument> arguments() {
        std::vector<Halide::Argument> arguments{exposure, accumulated, stencils};
        arguments.insert(arguments.end(), radii.begin(), radii.end());
        return arguments;
    }
};

}

#endif
