#include "../Sources/FotufilmHalide/Pipeline/NegativeScan.h"
#include <string>
#include <iostream>
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    try {
    bool gpu = std::string(argv[2]) == "gpu";
    // As in generate_halide_wasm.cpp: the browser GPU uses native float32. Strict WGSL emulates
    // every operation in software, a shader Mali drivers fail to compile.
    Halide::Target target("wasm-32-wasmrt-wasm_bulk_memory-wasm_simd128");
    target.set_feature(gpu ? Halide::Target::WebGPU : Halide::Target::StrictFloat);
    fotufilm::pipelines::NegativeScanPipeline pipeline(gpu ? Halide::DeviceAPI::WebGPU : Halide::DeviceAPI::None, true);
    pipeline.output.compile_to_static_library(argv[1], {pipeline.input, pipeline.parameters}, "negative_scan", target);
    } catch (const Halide::Error &e) { std::cerr << e.what() << "\n"; return 1; }
    catch (const std::exception &e) { std::cerr << e.what() << "\n"; return 1; }
}
