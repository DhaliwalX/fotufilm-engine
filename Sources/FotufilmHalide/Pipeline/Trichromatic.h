#ifndef FOTUFILM_TRICHROMATIC_PIPELINE_H
#define FOTUFILM_TRICHROMATIC_PIPELINE_H
#include <Halide.h>
#include <array>

namespace fotufilm::pipelines {
// One exposure of a trichromatic scan as the layer it records. Under one narrow light every
// pixel's colour is that light's, scaled by the film's transmittance, whatever the camera's
// white balance or matrix did to it; the layer is that scale. Interleaved samples in (RGBA float
// from the hosts' decoders, RGB 16-bit from the browser's RAW decoder), a float plane out.
// Parameters: the light's colour over its squared length.
struct TrichromaticLayerPipeline {
    Halide::ImageParam input;
    Halide::ImageParam parameters{Halide::Float(32), 1, "trichromatic_weights"};
    Halide::Func output{"trichromatic_layer"};
    Halide::Var x{"x"}, y{"y"};
    explicit TrichromaticLayerPipeline(Halide::Type sample = Halide::Float(32), int channels = 4)
        : input(sample, 3, "trichromatic_exposure") {
        using namespace Halide;
        auto at = [&](int c) { return cast<float>(input(x, y, c)); };
        output(x, y) = at(0) * parameters(0) + at(1) * parameters(1) + at(2) * parameters(2);
        parameters.dim(0).set_bounds(0, 3);
        input.dim(0).set_stride(channels);
        input.dim(2).set_stride(1).set_bounds(0, channels);
        output.vectorize(x, 8, TailStrategy::GuardWithIf).parallel(y, 8);
    }
};

// Catmull-Rom interpolation: passes through the samples, so a lined-up layer keeps its detail.
template<typename Sample>
inline Halide::Expr catmull_rom_sample(Sample sample, Halide::Expr px, Halide::Expr py) {
    using Halide::Expr;
    Expr x0 = Halide::cast<int32_t>(Halide::floor(px)), y0 = Halide::cast<int32_t>(Halide::floor(py));
    Expr tx = px - Halide::floor(px), ty = py - Halide::floor(py);
    auto weights = [](Expr t) {
        Expr t2 = t * t, t3 = t2 * t;
        return std::array<Expr, 4>{0.5f * (-t + 2.0f * t2 - t3), 0.5f * (2.0f - 5.0f * t2 + 3.0f * t3),
                                   0.5f * (t + 4.0f * t2 - 3.0f * t3), 0.5f * (t3 - t2)};
    };
    auto wx = weights(tx), wy = weights(ty);
    Expr value = 0.0f;
    for (int j = 0; j < 4; ++j) {
        Expr row = 0.0f;
        for (int i = 0; i < 4; ++i) row += wx[i] * sample(x0 + i - 1, y0 + j - 1);
        value += wy[j] * row;
    }
    return value;
}

// The three layers merged into a scan: red as it is, green and blue sampled through their
// registrations (FotufilmTrichromatic.h), each scaled to 16 bits. Planes in, interleaved 16-bit RGB
// out. Parameters: green's affine[6], blue's affine[6], scale[3].
struct TrichromaticMergePipeline {
    Halide::ImageParam red{Halide::Float(32), 2, "trichromatic_red"};
    Halide::ImageParam green{Halide::Float(32), 2, "trichromatic_green"};
    Halide::ImageParam blue{Halide::Float(32), 2, "trichromatic_blue"};
    Halide::ImageParam parameters{Halide::Float(32), 1, "trichromatic_parameters"};
    Halide::Func output{"trichromatic_merged"};
    Halide::Var x{"x"}, y{"y"}, c{"c"};
    TrichromaticMergePipeline() {
        using namespace Halide;
        Func r = BoundaryConditions::repeat_edge(red);
        Func g = BoundaryConditions::repeat_edge(green);
        Func b = BoundaryConditions::repeat_edge(blue);
        Expr fx = cast<float>(x), fy = cast<float>(y);
        auto placed = [&](Func layer, int at) {
            return catmull_rom_sample(layer, parameters(at) * fx + parameters(at + 1) * fy + parameters(at + 2),
                                      parameters(at + 3) * fx + parameters(at + 4) * fy + parameters(at + 5));
        };
        Expr value = select(c == 0, r(x, y), c == 1, placed(g, 0), placed(b, 6));
        Expr scaled = value * parameters(12 + c);
        output(x, y, c) = cast<uint16_t>(clamp(select(is_nan(scaled), 0.0f, scaled) + 0.5f,
                                               0.0f, 65535.0f));

        parameters.dim(0).set_bounds(0, 15);
        output.output_buffer().dim(0).set_stride(3);
        output.output_buffer().dim(2).set_stride(1).set_bounds(0, 3);
        output.bound(c, 0, 3).reorder(c, x, y).unroll(c)
            .vectorize(x, 8, TailStrategy::GuardWithIf).parallel(y, 8);
    }
};
}
#endif
