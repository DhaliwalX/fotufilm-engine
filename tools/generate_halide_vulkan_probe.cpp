// Measures Vulkan pass and arithmetic overhead using the engine's Halide runtime, tiling, and f16
// storage without film-processing work.
//
//   probe_copy1  one pass:      out = in
//   probe_copy8  eight passes:  out = in, seven times over, each one materialized
//   probe_math8  eight passes, each with a hundred transcendentals per pixel
//
// copy1 measures one-pass cost, copy8 exposes dispatch overhead, and math8 separates arithmetic
// cost from memory cost.
//
// Built by android/tools/probe-passes.sh.

#include <Halide.h>

#include <filesystem>
#include <iostream>
#include <string>

using Halide::Expr;
using Halide::Func;
using Halide::Var;

namespace {

Halide::Target vulkan_target() {
    Halide::Target target;
    target.os = Halide::Target::Android;
    target.arch = Halide::Target::ARM;
    target.bits = 64;
    target.set_feature(Halide::Target::Vulkan);
    target.set_feature(Halide::Target::VulkanV12);
    target.set_feature(Halide::Target::VulkanFloat16);
    target.set_feature(Halide::Target::VulkanInt8);
    target.set_feature(Halide::Target::VulkanInt16);
    target.set_feature(Halide::Target::VulkanInt64);
    return target;
}

/// The engine stores every intermediate as f16 through `store_frame`, and schedules it as one
/// pointwise pass tiled 16x16. Same here, or the control is not controlling for anything.
Func materialize(Func values, const std::string &name) {
    Var x("x"), y("y"), channel("channel");
    Var block_x, block_y, thread_x, thread_y;
    Func packed(name + "_packed");
    packed(x, y, channel) = Halide::cast(Halide::Float(16), values(x, y, channel));
    packed.compute_root()
        .bound(channel, 0, 3)
        .reorder(channel, x, y)
        .unroll(channel)
        .gpu_tile(x, y, block_x, block_y, thread_x, thread_y, 16, 16,
                  Halide::TailStrategy::GuardWithIf, Halide::DeviceAPI::Vulkan);
    Func stored(name + "_stored");
    stored(x, y, channel) = Halide::cast<float>(packed(x, y, channel));
    return stored;
}

/// Twenty dependent transcendentals — the order of magnitude a stage of the engine carries, not a
/// stress test — arranged so nothing can be folded away: each one feeds the next, and the whole
/// chain is anchored on a value the compiler cannot know.
Expr arithmetic_load(Expr value) {
    Expr accumulated = value;
    for (int i = 0; i < 10; ++i) {
        accumulated = Halide::fast_log(Halide::max(accumulated, 1.0e-6f) + 1.0f);
        accumulated = Halide::fast_exp(accumulated * 1.0009765625f);
    }
    return accumulated;
}

void emit(const std::string &name, int passes, bool arithmetic,
          const std::filesystem::path &output, bool include_runtime) {
    Var x("x"), y("y"), channel("channel");
    Halide::ImageParam input(Halide::Float(32), 3, "input");

    Func source("source");
    source(x, y, channel) = input(x, y, channel);
    Func stage = source;
    for (int pass = 0; pass < passes; ++pass) {
        const std::string pass_name = name + "_pass" + std::to_string(pass);
        Func next(pass_name);
        Expr value = stage(x, y, channel);
        next(x, y, channel) = arithmetic ? arithmetic_load(value) : value;
        stage = materialize(next, pass_name);
    }
    Func result(name + "_result");
    result(x, y, channel) = stage(x, y, channel);

    Var block_x, block_y, thread_x, thread_y;
    result.compute_root()
        .bound(channel, 0, 3)
        .reorder(channel, x, y)
        .unroll(channel)
        .gpu_tile(x, y, block_x, block_y, thread_x, thread_y, 16, 16,
                  Halide::TailStrategy::GuardWithIf, Halide::DeviceAPI::Vulkan);

    Halide::Target target = vulkan_target();
    if (!include_runtime) target.set_feature(Halide::Target::NoRuntime);
    result.compile_to_static_library((output / name).string(), {input}, name,
                                     target);
    std::cout << "wrote " << name << "\n";
}

}  // namespace

int main(int argc, char **argv) {
    if (argc != 2) {
        std::cerr << "usage: generate_halide_vulkan_probe OUTPUT_DIRECTORY\n";
        return 2;
    }
    const std::filesystem::path output(argv[1]);
    std::filesystem::create_directories(output);
    try {
        emit("probe_copy1", 1, false, output, true);
        emit("probe_copy8", 8, false, output, false);
        emit("probe_math8", 8, true, output, false);
    } catch (const Halide::Error &error) {
        std::cerr << "COMPILE ERROR: " << error.what() << "\n";
        return 1;
    }
    return 0;
}
