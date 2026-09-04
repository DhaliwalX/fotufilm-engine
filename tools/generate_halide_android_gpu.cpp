#define FOTUFILM_HALIDE_ENABLED 1
#define FOTUFILM_HALIDE_AOT_GENERATOR 1
#include "../Sources/FotufilmHalide/FotufilmHalideMetal.cpp"

#include <filesystem>
#include <iostream>

int main(int argc, char **argv) {
    if (argc != 2) {
        std::cerr << "usage: generate_halide_android_gpu OUTPUT_DIRECTORY\n";
        return 2;
    }
    const std::filesystem::path output(argv[1]);
    std::filesystem::create_directories(output);

    gpu_device_api() = Halide::DeviceAPI::Vulkan;
    Halide::Target target = MetalFramePipeline::android_vulkan_aot_target();
    // FOTUFILM_VK_DEBUG builds the talking runtime: every allocation, binding and dispatch is
    // narrated to logcat. It is far too loud and far too slow to ship, and it is the only way to
    // see which of forty-seven dispatches is the one going wrong.
    if (getenv("FOTUFILM_VK_DEBUG")) target.set_feature(Halide::Target::Debug);

    // Compiled in unconditionally for the same reason the CPU kernel does it: one kernel
    // serves every stock, and the coupler warp carries the donor's neutral share whether or not
    // the stage runs. A stock with no 4th Color Layer releases nothing and pays only the pass.
    constexpr int color_features =
        FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_MTF | FOTUFILM_FRAME_MTF_LUMA |
        FOTUFILM_FRAME_HALATION | FOTUFILM_FRAME_COUPLERS |
        FOTUFILM_FRAME_COUPLER_DIFFUSION | FOTUFILM_FRAME_ADJACENCY |
        FOTUFILM_FRAME_GRAIN | FOTUFILM_FRAME_DONOR_LAYER;
    constexpr int monochrome_features =
        color_features | FOTUFILM_FRAME_MONOCHROME;

    struct Variant { const char *name; int features; bool runtime; };
    const Variant variants[] = {
        {"fotufilm_halide_android_gpu_color", color_features, true},
        {"fotufilm_halide_android_gpu_monochrome", monochrome_features, false},
    };
    for (const Variant &variant : variants) {
        try {
            MetalFramePipeline pipeline(variant.features,
                                        std::string("_") + variant.name);
            pipeline.compile_aot((output / variant.name).string(), variant.name,
                                 variant.runtime, target);
            std::cout << "wrote " << variant.name << "\n";
        } catch (const Halide::Error &error) {
            std::cerr << "COMPILE ERROR (" << variant.name << "): "
                      << error.what() << "\n";
            return 1;
        }
    }
    return 0;
}
