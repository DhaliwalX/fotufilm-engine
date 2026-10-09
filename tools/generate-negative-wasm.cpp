#include "../Sources/FotufilmHalide/Pipeline/NegativeScan.h"
#include "../Sources/FotufilmHalide/Pipeline/Trichromatic.h"
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
        // A trichromatic scan: layers from the TIFF decoder's float RGBA and the RAW decoder's
        // 16-bit RGB, and their merge.
        const std::string out(argv[1]);
        fotufilm::pipelines::TrichromaticLayerPipeline rgba;
        rgba.output.compile_to_static_library(out + "/trichromatic_layer_rgba_kernel",
            {rgba.input, rgba.parameters}, "trichromatic_layer_rgba_kernel", target);
        fotufilm::pipelines::TrichromaticLayerPipeline rgb16(Halide::UInt(16), 3);
        rgb16.output.compile_to_static_library(out + "/trichromatic_layer_rgb16_kernel",
            {rgb16.input, rgb16.parameters}, "trichromatic_layer_rgb16_kernel", target);
        fotufilm::pipelines::TrichromaticMergePipeline merge;
        merge.output.compile_to_static_library(out + "/trichromatic_merge_kernel",
            {merge.red, merge.green, merge.blue, merge.parameters}, "trichromatic_merge_kernel", target);
    } catch (const Halide::Error &e) { std::cerr << e.what() << "\n"; return 1; }
    catch (const std::exception &e) { std::cerr << e.what() << "\n"; return 1; }
}
