#ifndef FOTUFILM_LIBRARY_THUMBNAIL_PIPELINE_H
#define FOTUFILM_LIBRARY_THUMBNAIL_PIPELINE_H
#include "Halide.h"

namespace fotufilm::pipelines {
// Library thumbnails: interleaved sRGB RGBA8 in, a smaller RGBA8 out.
// Each output pixel averages the exact source area it covers, in linear light, so fine
// detail neither aliases nor darkens. `orientation` is the EXIF value (1-8) and `width` x
// `height` the thumbnail before it; for 5-8 the output buffer swaps them.
struct LibraryThumbnailPipeline {
    Halide::ImageParam input{Halide::UInt(8), 3, "thumbnail_input"};
    Halide::Param<int> width{"thumbnail_width"}, height{"thumbnail_height"};
    Halide::Param<int> orientation{"thumbnail_orientation", 1, 1, 8};
    Halide::Func output{"thumbnail"};
    Halide::Var x{"x"}, y{"y"}, c{"c"};

    LibraryThumbnailPipeline() {
        using namespace Halide;
        Expr sourceWidth = input.dim(1).extent(), sourceHeight = input.dim(2).extent();

        Var i{"i"};
        Func linear{"thumbnail_linear"};
        Expr v = cast<float>(i) / 255.0f;
        linear(i) = select(v <= 0.04045f, v / 12.92f, pow((v + 0.055f) / 1.055f, 2.4f));

        // Source pixel k covers [k, k+1); output pixel o covers [o*scale, (o+1)*scale).
        auto coverage = [](Expr o, Expr scale, Expr extent, RDom r, Expr &weight) {
            Expr start = o * scale, first = cast<int>(floor(start));
            Expr k = first + r;
            weight = max(0.0f, min(cast<float>(k) + 1.0f, start + scale) - max(cast<float>(k), start));
            return clamp(k, 0, extent - 1);
        };
        Expr scaleX = cast<float>(sourceWidth) / cast<float>(width);
        Expr scaleY = cast<float>(sourceHeight) / cast<float>(height);
        RDom rx(0, cast<int>(ceil(scaleX)) + 1, "thumbnail_rx");
        RDom ry(0, cast<int>(ceil(scaleY)) + 1, "thumbnail_ry");

        Expr wx;
        Expr kx = coverage(x, scaleX, sourceWidth, rx, wx);
        Func columns{"thumbnail_columns"};
        columns(c, x, y) = 0.0f;
        columns(c, x, y) += wx * linear(cast<int>(input(c, kx, clamp(y, 0, sourceHeight - 1))));

        Expr wy;
        Expr ky = coverage(y, scaleY, sourceHeight, ry, wy);
        Func area{"thumbnail_area"};
        area(c, x, y) = 0.0f;
        area(c, x, y) += wy * columns(c, x, ky);

        // Output (x, y) reads the unoriented thumbnail at (u, v).
        Expr W = width - 1, H = height - 1;
        Expr u = select(orientation == 1, x, orientation == 2, W - x, orientation == 3, W - x,
                        orientation == 4, x, orientation == 5, y, orientation == 6, y,
                        orientation == 7, W - y, W - y);
        Expr vv = select(orientation == 1, y, orientation == 2, y, orientation == 3, H - y,
                         orientation == 4, H - y, orientation == 5, x, orientation == 6, H - x,
                         orientation == 7, H - x, x);
        Expr value = area(min(c, 2), u, vv) / (scaleX * scaleY);
        Expr encoded = select(value <= 0.0031308f, value * 12.92f,
                              1.055f * pow(value, 1.0f / 2.4f) - 0.055f);
        output(c, x, y) = select(c == 3, cast<uint8_t>(255),
                                 cast<uint8_t>(clamp(encoded * 255.0f + 0.5f, 0.0f, 255.0f)));

        input.dim(0).set_bounds(0, 4).set_stride(1);
        input.dim(1).set_stride(4);
        output.output_buffer().dim(0).set_bounds(0, 4).set_stride(1);
        output.output_buffer().dim(1).set_stride(4);

        // Everything fits in cache at thumbnail sizes; wasm has no threads here.
        linear.compute_root().bound(i, 0, 256);
        columns.compute_root().reorder(c, x, y).bound(c, 0, 3).unroll(c)
            .vectorize(x, 4, TailStrategy::GuardWithIf);
        columns.update().reorder(c, x, rx, y).unroll(c)
            .vectorize(x, 4, TailStrategy::GuardWithIf);
        // Rotated outputs read the thumbnail by column, so it is built whole first.
        area.compute_root().reorder(c, x, y).bound(c, 0, 3).unroll(c)
            .vectorize(x, 4, TailStrategy::GuardWithIf);
        area.update().reorder(c, x, ry, y).unroll(c)
            .vectorize(x, 4, TailStrategy::GuardWithIf);
        output.bound(c, 0, 4).reorder(c, x, y).unroll(c);
    }
};
}
#endif
