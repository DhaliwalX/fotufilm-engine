#include "../Sources/FotufilmHalide/Pipeline/NegativeScan.h"
#include <string>
#include <iostream>
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    try {
    bool gpu = std::string(argv[2]) == "gpu";
    Halide::Target target("wasm-32-wasmrt-wasm_bulk_memory-wasm_simd128-strict_float");
    if (gpu) target.set_feature(Halide::Target::WebGPU);
    fotufilm::pipelines::NegativeScanPipeline pipeline(gpu ? Halide::DeviceAPI::WebGPU : Halide::DeviceAPI::None, true);
    pipeline.output.compile_to_static_library(argv[1], {pipeline.input, pipeline.parameters}, "negative_scan", target);
    } catch (const Halide::Error &e) { std::cerr << e.what() << "\n"; return 1; }
    catch (const std::exception &e) { std::cerr << e.what() << "\n"; return 1; }
}
