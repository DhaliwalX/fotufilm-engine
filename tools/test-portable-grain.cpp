// Compile the actual portable GPU graphs without running a browser or device.
#define FOTUFILM_HALIDE_ENABLED 1
#define FOTUFILM_HALIDE_AOT_GENERATOR 1
#include "Pipeline/Gpu.h"
#include <fstream>
#include <iostream>
#include <iterator>
int main(int argc, char **argv) {
    using namespace fotufilm::pipelines;
    using namespace fotufilm::gpu;
    using namespace Halide;
    if (argc != 2) return 2;
    for (bool web : {false, true}) for (bool realtime : {false, true}) {
        GpuConfiguration configuration;
        configuration.device = web ? DeviceAPI::WebGPU : DeviceAPI::Vulkan;
        Target target = web ? Target("wasm-32-wasmrt-webgpu-wasm_simd128-wasm_bulk_memory")
                            : GpuFramePipeline::android_vulkan_aot_target();
        std::string name = std::string(web ? "webgpu" : "vulkan") + (realtime ? "_preview" : "_still");
        int features = FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_GRAIN | FOTUFILM_FRAME_GRAIN_MOTTLE;
        features |= realtime ? FOTUFILM_FRAME_REALTIME : FOTUFILM_FRAME_EXACT_MATH;
        GpuFramePipeline pipeline(features, "_" + name, false, configuration);
        std::string prefix = std::string(argv[1]) + "/" + name;
        pipeline.compile_aot(prefix, name, false, target);
        std::ifstream file(prefix + ".a", std::ios::binary);
        if (!file) return 2;
        std::string binary((std::istreambuf_iterator<char>(file)), {});
        // Generated table allocation/kernel names survive in both SPIR-V and WGSL
        // archives. Check both modes so a missing/empty archive cannot pass.
        if (binary.empty()) return 2;
        bool hasFine = binary.find("poisson_cdf") != std::string::npos;
        bool hasCoarse = binary.find("mottle_cdf") != std::string::npos;
        std::cout << name << ": fine table=" << hasFine << ", coarse table=" << hasCoarse << std::endl;
        if (hasFine != realtime || hasCoarse != realtime) return 1;
    }
}
