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
        if (device != DeviceAPI::None) {
            Var bx, by, tx, ty;
            output.reorder(c, x, y).unroll(c)
                .gpu_tile(x, y, bx, by, tx, ty, 16, 8, TailStrategy::GuardWithIf, device);
        } else {
            output.reorder(x, c, y).vectorize(x, 8, TailStrategy::GuardWithIf).parallel(y);
        }
    }
};
}
#endif
