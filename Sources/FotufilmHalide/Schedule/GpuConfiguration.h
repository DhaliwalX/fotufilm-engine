#ifndef FOTUFILM_GPU_CONFIGURATION_H
#define FOTUFILM_GPU_CONFIGURATION_H

#include "FotufilmHalide.h"
#include <Halide.h>
#include <cstdlib>
#include <string>

namespace fotufilm::gpu {

constexpr int kTileSize = 8;
constexpr int kLutVulkanPaddedCount = 147456;
constexpr int32_t kStillFastHalfStore = 1 << 0;
constexpr int32_t kStillFastCurves = 1 << 1;
constexpr int32_t kStillFastHalfLut = 1 << 2;
constexpr int32_t kStillFastHalfTetra = 1 << 3;
constexpr int32_t kStillFastExternMtf = 1 << 4;
constexpr int32_t kStillFastGrainTable = 1 << 5;

/// Resolve once at the host boundary, then pass by value to each pipeline. Environment changes
/// cannot alter a constructed graph's device, storage layout, or compilation identity.
struct GpuConfiguration {
    Halide::DeviceAPI device =
#if defined(FOTUFILM_HALIDE_CUDA)
        Halide::DeviceAPI::CUDA;
#else
        Halide::DeviceAPI::Metal;
#endif
    int tile_x = 32;
    int tile_y = 2;
    int fixed_stride = 2;
    bool half_blur = false;
    bool half_lut = false;
    bool half_tetra = false;
    bool split_down = false;
    bool profile = false;
    int32_t still_fast = 0;
    int32_t ablated = 0;

    Halide::Target target() const {
        auto target = Halide::get_host_target();
        switch (device) {
        case Halide::DeviceAPI::CUDA: target.set_feature(Halide::Target::CUDA); break;
        case Halide::DeviceAPI::Vulkan: target.set_feature(Halide::Target::Vulkan); break;
        case Halide::DeviceAPI::WebGPU: target.set_feature(Halide::Target::WebGPU); break;
        default: target.set_feature(Halide::Target::Metal); break;
        }
        if (profile) target.set_feature(Halide::Target::Profile);
        return target;
    }

    std::string cache_key() const {
        return std::to_string(int(device)) + ":" + std::to_string(tile_x) + ":"
            + std::to_string(tile_y) + ":" + std::to_string(fixed_stride) + ":"
            + std::to_string(half_blur) + std::to_string(half_lut)
            + std::to_string(half_tetra) + std::to_string(split_down)
            + std::to_string(profile) + ":" + std::to_string(still_fast)
            + ":" + std::to_string(ablated);
    }
};

inline GpuConfiguration resolve_gpu_configuration(GpuConfiguration defaults = {}) {
    auto integer = [](const char *name, int fallback) {
        const char *value = std::getenv(name);
        return value ? std::atoi(value) : fallback;
    };
    auto bounded = [&](const char *name, int fallback, int low, int high) {
        const int value = integer(name, fallback);
        return value >= low && value <= high ? value : fallback;
    };
    // Preserve the existing platform defaults and override ranges.
    const int square = bounded("FOTUFILM_GPU_TILE", kTileSize, 2, 32);
    const bool vulkan = defaults.device == Halide::DeviceAPI::Vulkan;
    defaults.tile_x = bounded("FOTUFILM_GPU_TILE_X", vulkan ? square : defaults.tile_x, 2, 64);
    defaults.tile_y = bounded("FOTUFILM_GPU_TILE_Y", vulkan ? square : defaults.tile_y, 1, 64);
    const int stride = integer("FOTUFILM_GPU_STRIDE", defaults.fixed_stride);
    defaults.fixed_stride = stride == 1 || stride == 2 || stride == 4 || stride == 8 ? stride : 2;
    defaults.half_blur = integer("FOTUFILM_F16_BLUR", defaults.half_blur) != 0;
    defaults.half_lut = integer("FOTUFILM_F16_LUT", defaults.half_lut) != 0;
    defaults.half_tetra = integer("FOTUFILM_F16_TETRA", defaults.half_tetra) != 0;
    defaults.split_down = integer("FOTUFILM_SPLIT_DOWN", defaults.split_down) != 0;
    defaults.still_fast = integer("FOTUFILM_STILL_FAST", defaults.still_fast);
    defaults.profile = defaults.profile || std::getenv("FOTUFILM_HALIDE_PROFILE") != nullptr;
    if (const char *env = std::getenv("FOTUFILM_ABLATE")) {
        const struct { const char *name; int32_t bit; } stages[] = {
            {"flare", FOTUFILM_FRAME_FLARE},
            {"mtf", FOTUFILM_FRAME_MTF | FOTUFILM_FRAME_MTF_LUMA},
            {"halation", FOTUFILM_FRAME_HALATION},
            {"couplers", FOTUFILM_FRAME_COUPLERS},
            {"couplerdiffusion", FOTUFILM_FRAME_COUPLER_DIFFUSION},
            {"adjacency", FOTUFILM_FRAME_ADJACENCY},
            {"grain", FOTUFILM_FRAME_GRAIN},
        };
        const std::string list = env;
        for (const auto &stage : stages) {
            if (list.find(stage.name) != std::string::npos) defaults.ablated |= stage.bit;
        }
    }
    return defaults;
}

inline const GpuConfiguration &default_gpu_configuration() {
    static const GpuConfiguration configuration = resolve_gpu_configuration();
    return configuration;
}

} // namespace fotufilm::gpu
#endif
