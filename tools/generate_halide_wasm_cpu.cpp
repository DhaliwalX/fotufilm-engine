// Emits the reference CPU pipeline as WebAssembly.
//
// This is the same schedule the command line runs, so a frame developed in a browser tab and a
// frame developed by `fotufilm` come off the same code. It needs no GPU runtime, which is what
// makes it buildable today: the WebGPU path (tools/generate_halide_wasm.cpp) generates valid WGSL
// but cannot be linked, because Halide's WebGPU runtime, Halide's own LLVM and Emscripten's
// Asyncify have no mutually compatible versions.
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
    return target;
}

/// Mirrors the variant number `develop_pipeline_for` derives from a feature mask.
int develop_variant(int32_t features) {
    constexpr int32_t stage_bits = FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_MTF
        | FOTUFILM_FRAME_HALATION | FOTUFILM_FRAME_COUPLERS
        | FOTUFILM_FRAME_ADJACENCY | FOTUFILM_FRAME_GRAIN;
    return (features & stage_bits)
        | ((features & FOTUFILM_FRAME_MTF_LUMA) ? 64 : 0)
        | ((features & FOTUFILM_FRAME_COUPLER_DIFFUSION) ? 128 : 0)
        | ((features & FOTUFILM_FRAME_DISC_GRAIN) ? 256 : 0);
}

constexpr int32_t kSpatialBits = FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_MTF
    | FOTUFILM_FRAME_HALATION | FOTUFILM_FRAME_COUPLERS | FOTUFILM_FRAME_ADJACENCY
    | FOTUFILM_FRAME_GRAIN | FOTUFILM_FRAME_MTF_LUMA | FOTUFILM_FRAME_COUPLER_DIFFUSION
    | FOTUFILM_FRAME_DISC_GRAIN;

}  // namespace

int main(int argc, char **argv) {
    if (argc < 3) {
        std::cerr << "usage: generate_halide_wasm_cpu OUTPUT_DIRECTORY MASK [MASK...]\n"
                     "  MASK is a stock's feature mask, as printed by --dump-wasm-pack\n";
        return 2;
    }
    const std::filesystem::path output(argv[1]);
    std::filesystem::create_directories(output);

    std::vector<int> variants;
    for (int i = 2; i < argc; ++i) {
        const int32_t features = int32_t(strtol(argv[i], nullptr, 0)) & kSpatialBits;
        const int variant = develop_variant(features);
        if (std::find(variants.begin(), variants.end(), variant) != variants.end()) continue;
        variants.push_back(variant);

        const std::string name = "develop_" + std::to_string(variant);
        std::cout << "  " << name << std::flush;
        DevelopPipeline pipeline(features, "_variant_" + std::to_string(variant));
        // The first module carries the Halide runtime; the rest link against it.
        pipeline.compile_aot((output / name).string(), name, variants.size() == 1,
                             wasm_target());
        std::cout << " ok\n";
    }

    // All four print variants: there are only four, and they are cheap next to the develop stage.
    for (int variant = 0; variant < 4; ++variant) {
        const bool reversal = (variant & 1) != 0;
        const bool monochrome = (variant & 2) != 0;
        const std::string name = "print_" + std::to_string(variant);
        std::cout << "  " << name << std::flush;
        PrintPipeline pipeline(reversal, monochrome,
                               "_print_variant_" + std::to_string(variant));
        pipeline.compile_aot((output / name).string(), name, false, wasm_target());
        std::cout << " ok\n";
    }
    return 0;
}
