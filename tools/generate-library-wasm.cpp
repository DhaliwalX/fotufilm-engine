#include "../Sources/FotufilmHalide/Pipeline/LibraryThumbnail.h"
#include <iostream>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    try {
        Halide::Target target("wasm-32-wasmrt-wasm_bulk_memory-wasm_simd128");
        fotufilm::pipelines::LibraryThumbnailPipeline pipeline;
        pipeline.output.compile_to_static_library(
            argv[1], {pipeline.input, pipeline.width, pipeline.height, pipeline.orientation}, "library_thumbnail", target);
    } catch (const Halide::Error &e) { std::cerr << e.what() << "\n"; return 1; }
}
