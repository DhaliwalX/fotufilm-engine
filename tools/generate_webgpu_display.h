// Packed 32-bit storage avoids WGSL's emulated byte stores. The film result stays
// on the GPU through display encoding; only final RGBA8/RGBA16 pixels return.
#pragma once
#include "../Sources/FotufilmHalide/Stages/Transfer.h"
#include "../Sources/FotufilmHalide/Stages/Exposure.h"
#include "../Sources/FotufilmHalide/Stages/Random.h"

inline void generate_webgpu_display(const std::filesystem::path &directory,
                                    const Halide::Target &target) {
    using namespace Halide;
    ImageParam input(Float(32), 3, "input");
    input.dim(0).set_stride(4);
    input.dim(2).set_stride(1).set_bounds(0, 4);
    Param<int32_t> origin_x("origin_x"), origin_y("origin_y"), frame_width("frame_width"), p3("p3");
    Param<uint32_t> seed("seed");
    Var x("x"), y("y"), xi("xi"), yi("yi");
    for (int depth : {8, 16}) {
        const int words = depth == 8 ? 1 : 2;
        Expr px = x / words;
        Expr rgb[3];
        for (int c = 0; c < 3; ++c) {
            rgb[c] = clamp(fotufilm::display_shoulder(input(px, y, c), 0.9f), 0.0f, 1.0f);
        }
        Expr encoded[3];
        for (int c = 0; c < 3; ++c) {
            Expr srgb = fotufilm::kP3ToSRGB[c * 3] * rgb[0]
                + fotufilm::kP3ToSRGB[c * 3 + 1] * rgb[1]
                + fotufilm::kP3ToSRGB[c * 3 + 2] * rgb[2];
            Expr value = fotufilm::srgb_encode(clamp(select(p3 != 0, rgb[c], srgb), 0.0f, 1.0f));
            const float maximum = depth == 8 ? 255.0f : 65535.0f;
            Expr noise = depth == 8
                ? fotufilm::triangular_dither(px + origin_x, y + origin_y, c, frame_width, seed)
                : Expr(0.0f);
            encoded[c] = cast<uint32_t>(clamp(floor(value * maximum + 0.5f + noise), 0.0f, maximum));
        }
        const std::string name = depth == 8 ? "display_rgba8" : "display_rgba16";
        Func output(name);
        if (depth == 8) {
            output(x, y) = encoded[0] | (encoded[1] << 8) | (encoded[2] << 16) | Expr(uint32_t{0xff000000});
        } else {
            output(x, y) = select(x % 2 == 0, encoded[0] | (encoded[1] << 16),
                                  encoded[2] | Expr(uint32_t{0xffff0000}));
        }
        output.gpu_tile(x, y, xi, yi, 32, 2, TailStrategy::GuardWithIf, DeviceAPI::WebGPU);
        output.compile_to_static_library((directory / name).string(),
            {input, origin_x, origin_y, frame_width, p3, seed}, name, target.with_feature(Target::NoRuntime));
    }
}
