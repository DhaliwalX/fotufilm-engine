// Emits the reference CPU pipeline as WebAssembly.
//
// This is the same schedule the command line runs, so a frame developed in a browser tab and a
// frame developed by `fotufilm` come off the same code. It provides the CPU fallback and
// the plain pipeline used for Normal; the WebGPU generator supplies the GPU film renderer.
//
// The develop stage is compiled per spatial feature mask and the print stage per
// (reversal, monochrome) pair, matching `develop_pipeline_for` and `print_pipeline_for` — the
// browser must pick the same variant the mask asks for or stages silently go missing.

#define FOTUFILM_HALIDE_ENABLED 1
#define FOTUFILM_HALIDE_AOT_GENERATOR 1
#include "../Sources/FotufilmHalide/FotufilmHalide.cpp"

#include <filesystem>
#include <iostream>
#include <string>
#include <vector>

namespace {

Halide::Target wasm_target() {
    Halide::Target target;
    target.os = Halide::Target::WebAssemblyRuntime;
    target.arch = Halide::Target::WebAssembly;
    target.bits = 32;
    target.set_feature(Halide::Target::WasmSimd128);
    target.set_feature(Halide::Target::WasmBulkMemory);
    target.set_feature(Halide::Target::StrictFloat);
    return target;
}

}  // namespace

int main(int argc, char **argv) {
    if (argc < 3) {
        std::cerr << "usage: generate_halide_wasm_cpu OUTPUT_DIRECTORY MASK [MASK...] | --plain-only\n"
                     "  MASK is a stock's feature mask, as printed by --dump-wasm-pack\n";
        return 2;
    }
    const std::filesystem::path output(argv[1]);
    std::filesystem::create_directories(output);

    std::vector<int> variants;
    const bool plain_only = std::string(argv[2]) == "--plain-only";
    for (int i = 2; !plain_only && i < argc; ++i) {
        const int32_t features = fotufilm_develop_features(int32_t(strtol(argv[i], nullptr, 0)));
        const int variant = fotufilm_develop_variant(features);
        if (std::find(variants.begin(), variants.end(), variant) != variants.end()) continue;
        variants.push_back(variant);

        const std::string name = "develop_" + std::to_string(variant);
        std::cout << "  " << name << std::flush;
        DevelopPipeline pipeline(features, "_variant_" + std::to_string(variant));
        // The first module carries the Halide runtime; the rest link against it.
        pipeline.compile_aot((output / name).string(), name, variants.size() == 1,
                             wasm_target(), true);
        std::cout << " ok\n";
    }

    // All four print variants: there are only four, and they are cheap next to the develop stage.
    for (int variant = 0; !plain_only && variant < 4; ++variant) {
        const bool reversal = (variant & 1) != 0;
        const bool monochrome = (variant & 2) != 0;
        const std::string name = "print_" + std::to_string(variant);
        std::cout << "  " << name << std::flush;
        PrintPipeline pipeline(reversal, monochrome,
                               "_print_variant_" + std::to_string(variant));
        pipeline.compile_aot((output / name).string(), name, false, wasm_target());
        std::cout << " ok\n";
    }
    PlainPipeline plain(false, "_browser_plain", false, 0);
    plain.compile_aot((output / "plain_float").string(), "plain_float", false, wasm_target());
    return 0;
}
