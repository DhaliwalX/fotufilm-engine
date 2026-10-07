#ifndef FOTUFILM_NEGATIVE_SCAN_PIPELINE_H
#define FOTUFILM_NEGATIVE_SCAN_PIPELINE_H
#include "../Stages/NegativeScan.h"

namespace fotufilm::pipelines {
// Planar float RGB. Parameters: low[3], high[3], contrast, monochrome.
// Both input and output are linear sRGB. Colour-space adaptation belongs to ingest/delivery.
struct NegativeScanPipeline {
    Halide::ImageParam input{Halide::Float(32), 3, "negative_input"};
    Halide::ImageParam parameters{Halide::Float(32), 1, "negative_parameters"};
    Halide::Func output{"negative_positive"};
    Halide::Var x{"x"}, y{"y"}, c{"c"};
    explicit NegativeScanPipeline(Halide::DeviceAPI device = Halide::DeviceAPI::None, bool rec2020 = false) {
        using namespace Halide;
        Expr channel = select(parameters(7) > 0.5f, 1, c);
        Func samples("negative_samples");
        Expr r = input(x,y,0), g = input(x,y,1), b = input(x,y,2);
        if (rec2020) {
            samples(x,y,c) = select(c == 0, 1.660491f*r - .5876411f*g - .0728499f*b,
                c == 1, -.1245505f*r + 1.1328999f*g - .0083494f*b,
                -.0181508f*r - .1005789f*g + 1.1187297f*b);
        } else { samples(x,y,c) = input(x,y,c); }
        Expr valid = negative_scan_valid(samples(x,y,0), samples(x,y,1), samples(x,y,2));
        Func positive("negative_linear_srgb");
        positive(x, y, c) = select(valid,
            negative_scan_channel(samples(x, y, channel), parameters(channel),
                                  parameters(channel + 3), parameters(6)), 0.0f);
        if (rec2020) {
            Expr pr = positive(x,y,0), pg = positive(x,y,1), pb = positive(x,y,2);
            output(x,y,c) = select(c == 0, .6274039f*pr + .3292830f*pg + .0433131f*pb,
                c == 1, .0690973f*pr + .9195404f*pg + .0113623f*pb,
                .0163914f*pr + .0880133f*pg + .8955953f*pb);
        } else { output(x,y,c) = positive(x,y,c); }
        output.bound(c, 0, 3);
        parameters.dim(0).set_bounds(0, 8);
        input.dim(2).set_bounds(0, 3);
        // Each output channel of the Rec.2020 road mixes all three positive channels,
        // so compute them once per pixel rather than once per output channel.
        positive.bound(c, 0, 3);
        if (device != DeviceAPI::None) {
            Var bx, by, tx, ty;
            output.reorder(c, x, y).unroll(c)
                .gpu_tile(x, y, bx, by, tx, ty, 16, 8, TailStrategy::GuardWithIf, device);
            positive.compute_at(output, tx).reorder(c, x, y).unroll(c);
        } else {
            output.reorder(x, c, y).vectorize(x, 8, TailStrategy::GuardWithIf).parallel(y);
            positive.compute_at(output, y).reorder(x, c, y).vectorize(x, 8, TailStrategy::GuardWithIf);
        }
    }
};
// A scanned negative's scan made ready for the editor, interleaved linear Rec. 2020 RGBA in and
// out, alpha passed through. Parameters: lit, plain, clear film[3], gains[3], reference.
// Lit divides out the light source's unevenness, `light` (interleaved RGB cells, bilinear
// between cell centres, the edges holding their outermost cell, as NegativeLightFrame.gain), in
// linear sRGB. Plain then reads the scan as a plain positive's scene light (PlainNegativeScan),
// a pixel passing no light in any channel black.
struct ScanPreparePipeline {
    Halide::ImageParam input{Halide::Float(32), 3, "scan_prepare_input"};
    Halide::ImageParam light{Halide::Float(32), 3, "scan_prepare_light"};
    Halide::ImageParam parameters{Halide::Float(32), 1, "scan_prepare_parameters"};
    Halide::Func output{"scan_prepared"};
    Halide::Var x{"x"}, y{"y"}, c{"c"};
    explicit ScanPreparePipeline(bool approximate = false) {
        using namespace Halide;
        Expr width = cast<float>(input.dim(0).extent()), height = cast<float>(input.dim(1).extent());
        Expr cells_x = light.dim(0).extent(), cells_y = light.dim(1).extent();
        Func cells = BoundaryConditions::repeat_edge(light);
        Expr fx = clamp((cast<float>(x - input.dim(0).min()) + 0.5f) / width
                            * cast<float>(cells_x) - 0.5f, 0.0f, cast<float>(cells_x - 1));
        Expr fy = clamp((cast<float>(y - input.dim(1).min()) + 0.5f) / height
                            * cast<float>(cells_y) - 0.5f, 0.0f, cast<float>(cells_y - 1));
        Expr x0 = cast<int>(fx), y0 = cast<int>(fy);
        Expr tx = fx - cast<float>(x0), ty = fy - cast<float>(y0);
        Func gain("scan_light_gain");
        Expr top = cells(x0, y0, c) * (1.0f - tx) + cells(x0 + 1, y0, c) * tx;
        Expr bottom = cells(x0, y0 + 1, c) * (1.0f - tx) + cells(x0 + 1, y0 + 1, c) * tx;
        gain(x, y, c) = top * (1.0f - ty) + bottom * ty;

        Expr r = input(x, y, 0), g = input(x, y, 1), b = input(x, y, 2);
        Func srgb("scan_light_srgb");
        srgb(x, y, c) = select(c == 0, 1.660491f * r - 0.5876411f * g - 0.0728499f * b,
                               c == 1, -0.1245505f * r + 1.1328999f * g - 0.0083494f * b,
                               -0.0181508f * r - 0.1005789f * g + 1.1187297f * b)
            / gain(x, y, c);
        Expr sr = srgb(x, y, 0), sg = srgb(x, y, 1), sb = srgb(x, y, 2);
        Func lit("scan_lit");
        lit(x, y, c) = select(parameters(0) > 0.5f,
            select(c == 0, 0.627403896f * sr + 0.329283038f * sg + 0.043313066f * sb,
                   c == 1, 0.069097289f * sr + 0.919540395f * sg + 0.011362316f * sb,
                   0.016391439f * sr + 0.088013308f * sg + 0.895595253f * sb),
            input(x, y, c));
        Expr lr = lit(x, y, 0), lg = lit(x, y, 1), lb = lit(x, y, 2);
        Expr passes = is_finite(lr) && is_finite(lg) && is_finite(lb)
            && lr > 0.0f && lg > 0.0f && lb > 0.0f;
        Expr plain = select(passes,
            plain_negative_light(lit(x, y, c), parameters(2 + c), parameters(5 + c),
                                 parameters(8), approximate), 0.0f);
        Func prepared("scan_prepared_rgb");
        prepared(x, y, c) = select(parameters(1) > 0.5f, plain, lit(x, y, c));
        output(x, y, c) = select(c == 3, input(x, y, 3), prepared(x, y, min(c, 2)));

        parameters.dim(0).set_bounds(0, 9);
        input.dim(0).set_stride(4);
        input.dim(2).set_stride(1).set_bounds(0, 4);
        light.dim(0).set_stride(3);
        light.dim(2).set_stride(1).set_bounds(0, 3);
        output.output_buffer().dim(0).set_stride(4);
        output.output_buffer().dim(2).set_stride(1).set_bounds(0, 4);
        output.bound(c, 0, 4).reorder(c, x, y).unroll(c)
            .vectorize(x, 8, TailStrategy::GuardWithIf).parallel(y);
        lit.bound(c, 0, 3).compute_at(output, x).reorder(c, x, y).unroll(c);
        srgb.bound(c, 0, 3).compute_at(output, x).reorder(c, x, y).unroll(c);
    }
};
}
#endif
