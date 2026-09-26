// Packed 32-bit storage avoids WGSL's emulated byte stores. The film result stays
// on the GPU through display encoding; only final RGBA8/RGBA16 pixels return.
#pragma once
#include "../Sources/FotufilmHalide/Stages/Transfer.h"
#include "../Sources/FotufilmHalide/Stages/Exposure.h"
#include "../Sources/FotufilmHalide/Stages/Random.h"

inline void generate_webgpu_display(const std::filesystem::path &directory,
                                    const Halide::Target &target,
                                    Halide::DeviceAPI device = Halide::DeviceAPI::WebGPU,
                                    const std::string &prefix = "") {
    using namespace Halide;
    ImageParam input(Float(32), 3, "input");
    input.dim(0).set_stride(4);
    input.dim(2).set_stride(1).set_bounds(0, 4);
    Param<int32_t> origin_x("origin_x"), origin_y("origin_y"), frame_width("frame_width"), p3("p3");
    Param<uint32_t> seed("seed");
    // The material's SDR knee (`FilmSDRDelivery`): 1 for everything bounded by its own white,
    // 0.7 for a directly viewed transparency.
    Param<float> shoulder_knee("shoulder_knee");
    Var x("x"), y("y"), xi("xi"), yi("yi");
    for (int depth : {8, 16}) {
        const int words = depth == 8 ? 1 : 2;
        Expr px = x / words;
        Expr encoded[3];
        // Into the delivery's primaries and gamut first, then the shoulder, as every native
        // delivery.
        Expr srgb[3];
        for (int c = 0; c < 3; ++c) {
            srgb[c] = fotufilm::kP3ToSRGB[c * 3] * input(px, y, 0)
                + fotufilm::kP3ToSRGB[c * 3 + 1] * input(px, y, 1)
                + fotufilm::kP3ToSRGB[c * 3 + 2] * input(px, y, 2);
        }
        const Expr srgb_luma[3] = {fotufilm::kSRGBLuma[0], fotufilm::kSRGBLuma[1],
                                   fotufilm::kSRGBLuma[2]};
        for (int c = 0; c < 3; ++c) {
            Expr delivered = select(p3 != 0, input(px, y, c),
                                    fotufilm::fit_to_gamut(srgb, srgb_luma, c));
            Expr value = fotufilm::srgb_encode(clamp(
                fotufilm::display_shoulder(delivered, clamp(shoulder_knee, 0.0f, 1.0f)),
                0.0f, 1.0f));
            const float maximum = depth == 8 ? 255.0f : 65535.0f;
            Expr noise = depth == 8
                ? fotufilm::triangular_dither(px + origin_x, y + origin_y, c, frame_width, seed)
                : Expr(0.0f);
            encoded[c] = cast<uint32_t>(clamp(floor(value * maximum + 0.5f + noise), 0.0f, maximum));
        }
        const std::string name = prefix + (depth == 8 ? "display_rgba8" : "display_rgba16");
        Func output(name);
        if (depth == 8) {
            output(x, y) = encoded[0] | (encoded[1] << 8) | (encoded[2] << 16) | Expr(uint32_t{0xff000000});
        } else {
            output(x, y) = select(x % 2 == 0, encoded[0] | (encoded[1] << 16),
                                  encoded[2] | Expr(uint32_t{0xffff0000}));
        }
        if (device == DeviceAPI::None)
            output.vectorize(x, 8, TailStrategy::GuardWithIf).parallel(y);
        else
            output.gpu_tile(x, y, xi, yi, 32, 2, TailStrategy::GuardWithIf, device);
        output.compile_to_static_library((directory / name).string(),
            {input, origin_x, origin_y, frame_width, p3, seed, shoulder_knee}, name, target.with_feature(Target::NoRuntime));
    }
}
