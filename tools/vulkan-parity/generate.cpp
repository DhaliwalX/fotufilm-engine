// Real production graphs, cross-compiled for the device running both references.
#define FOTUFILM_HALIDE_ENABLED 1
#define FOTUFILM_HALIDE_AOT_GENERATOR 1
#include "../../Sources/FotufilmHalide/Pipeline/Gpu.h"
#include "../../Sources/FotufilmHalide/Pipeline/NegativeScan.h"
#include <filesystem>
#include <iostream>
#include "../generate_webgpu_display.h"

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    try {
        using namespace Halide;
        using namespace fotufilm;
        using namespace fotufilm::pipelines;
        std::filesystem::create_directories(argv[1]);
        Target target(argv[2]);
        const std::string name = argv[3];
        const std::string prefix = (std::filesystem::path(argv[1]) / name).string();
        if (name == "cpu_display" || name == "vk_display") {
            bool gpu = name == "vk_display";
            target.set_feature(gpu ? Target::Vulkan : Target::StrictFloat);
            generate_webgpu_display(argv[1], target, gpu ? DeviceAPI::Vulkan : DeviceAPI::None,
                                    gpu ? "vk_" : "cpu_");
        } else if (name == "cpu_negative" || name == "vk_negative") {
            const bool gpu = name == "vk_negative";
            target.set_feature(Target::NoRuntime);
            if (gpu) target.set_feature(Target::Vulkan);
            else target.set_feature(Target::StrictFloat);
            NegativeScanPipeline pipeline(gpu ? DeviceAPI::Vulkan : DeviceAPI::None, true);
            pipeline.output.compile_to_static_library(prefix,
                {pipeline.input, pipeline.parameters}, name, target);
        } else {
            int mask = FOTUFILM_AOT_FULL_STAGES;
            if (name == "vk_plain") mask = FOTUFILM_FRAME_NO_FILM;
            else if (name == "vk_print") mask = FOTUFILM_FRAME_DENSITY_IN | FOTUFILM_FRAME_PRINT_MTF;
            else if (name == "vk_mono") mask |= FOTUFILM_FRAME_MONOCHROME;
            else if (name == "vk_annular") mask |= FOTUFILM_FRAME_HALATION_ANNULAR;
            else if (name != "vk_color") return 2;
            mask |= FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_EXACT_MATH;
            gpu::GpuConfiguration config;
            config.device = DeviceAPI::Vulkan;
            config.tile_x = config.tile_y = 8;
            target.set_feature(Target::Vulkan);
            // Full float32 reference path: no optional half-precision capabilities.
            GpuFramePipeline pipeline(mask, "_" + name, false, config);
            pipeline.compile_aot(prefix, name, name == "vk_color", target);
        }
        std::cout << name << " compiled\n";
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
