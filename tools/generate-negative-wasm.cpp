#include "../Sources/FotufilmHalide/Pipeline/NegativeScan.h"
#include <iostream>
#include <string>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    try {
        Halide::Target target("wasm-32-wasmrt-wasm_bulk_memory-wasm_simd128");
        target.set_feature(Halide::Target::StrictFloat);
        fotufilm::pipelines::ScanPreparePipeline pipeline;
        pipeline.output.compile_to_static_library(
            std::string(argv[1]) + "/scan_prepare",
            {pipeline.input, pipeline.light, pipeline.parameters}, "scan_prepare", target);
    } catch (const Halide::Error &e) { std::cerr << e.what() << "\n"; return 1; }
    catch (const std::exception &e) { std::cerr << e.what() << "\n"; return 1; }
}
