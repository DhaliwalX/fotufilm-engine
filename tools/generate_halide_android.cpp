#define FOTUFILM_HALIDE_ENABLED 1
#define FOTUFILM_HALIDE_AOT_GENERATOR 1
#include "../Sources/FotufilmHalide/FotufilmHalide.cpp"

#include <cstdlib>
#include <filesystem>
#include <iostream>

namespace {

Halide::Target android_target(int bits) {
    Halide::Target target;
    target.os = Halide::Target::Android;
    target.arch = Halide::Target::ARM;
    target.bits = bits;
    return target;
}

}

int main(int argc, char **argv) {
    if (argc < 2) {
        std::cerr << "usage: generate_halide_android OUTPUT_DIRECTORY "
                     "[--arm32] [--no-runtime]\n";
        return 2;
    }
    bool arm32 = false;
    // A library that also carries the Vulkan kernels already has a Halide runtime, and that one is
    // the superset: a Vulkan target's runtime is the CPU runtime plus the device interface. Two of
    // them in one link is a duplicate-symbol error, so the GPU build asks these kernels to go
    // without and share it.
    bool include_runtime = true;
    for (int i = 2; i < argc; ++i) {
        const std::string flavour = argv[i];
        if (flavour == "--arm32") arm32 = true;
        else if (flavour == "--no-runtime") include_runtime = false;
        else {
            std::cerr << "unknown flavour: " << flavour << "\n";
            return 2;
        }
    }
    const std::filesystem::path output(argv[1]);
    std::filesystem::create_directories(output);
    const Halide::Target target = android_target(arm32 ? 32 : 64);

    // One kernel serves every stock here, so the donor capture layer is compiled in
    // unconditionally rather than selected: its counterweight lives in the coupler warp the
    // host builds, and a path that drops the stage keeps the add-back and develops the five
    // stocks that coat a 4th Color Layer red. A stock without one arrives with its release row
    // at zero and the stage sums to nothing, which is what makes always-on affordable.
    //
    // Stage names in FOTUFILM_ABLATE ("grain,halation,…") clear their bits first, the same
    // diagnostic the Metal generator carries, so a misbehaving stage can be compiled out
    // without editing this file.
    int32_t features =
        FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_MTF | FOTUFILM_FRAME_MTF_LUMA |
        FOTUFILM_FRAME_HALATION | FOTUFILM_FRAME_COUPLERS |
        FOTUFILM_FRAME_COUPLER_DIFFUSION | FOTUFILM_FRAME_ADJACENCY |
        FOTUFILM_FRAME_GRAIN | FOTUFILM_FRAME_DONOR_LAYER;
    if (const char *env = std::getenv("FOTUFILM_ABLATE")) {
        const struct { const char *name; int32_t bit; } stages[] = {
            {"flare", FOTUFILM_FRAME_FLARE},
            {"mtf", FOTUFILM_FRAME_MTF | FOTUFILM_FRAME_MTF_LUMA},
            {"halation", FOTUFILM_FRAME_HALATION},
            {"couplers", FOTUFILM_FRAME_COUPLERS},
            {"couplerdiffusion", FOTUFILM_FRAME_COUPLER_DIFFUSION},
            {"adjacency", FOTUFILM_FRAME_ADJACENCY},
            {"grain", FOTUFILM_FRAME_GRAIN},
            {"donor", FOTUFILM_FRAME_DONOR_LAYER},
        };
        const std::string list = env;
        for (const auto &stage : stages) {
            if (list.find(stage.name) != std::string::npos) features &= ~stage.bit;
        }
        std::cout << "Ablating: " << list << "\n";
    }

    DevelopPipeline develop(features, "_android_develop");
    develop.compile_aot((output / "fotufilm_halide_android_develop").string(),
                        "fotufilm_halide_android_develop", include_runtime, target);

    struct PrintVariant { const char *name; bool reversal, monochrome; };
    const PrintVariant prints[] = {
        {"fotufilm_halide_android_print", false, false},
        {"fotufilm_halide_android_print_reversal", true, false},
        {"fotufilm_halide_android_print_monochrome", false, true},
        {"fotufilm_halide_android_print_reversal_monochrome", true, true},
    };
    for (const PrintVariant &variant : prints) {
        PrintPipeline pipeline(variant.reversal, variant.monochrome,
                               std::string("_android_") + variant.name);
        pipeline.compile_aot((output / variant.name).string(), variant.name,
                             false, target);
    }
    std::cout << "Wrote Android kernels to " << output << "\n";
    return 0;
}
