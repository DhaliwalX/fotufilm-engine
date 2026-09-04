// Emits the frame pipeline as WebAssembly, so a browser can develop a frame with the same
// schedule the phones run. Two targets come out of one generator: `wasm-32-wasmrt-webgpu`,
// whose kernels dispatch through WGSL compute shaders, and a plain `wasm-32-wasmrt` fallback
// for machines without a WebGPU adapter.
//
// The GPU schedule reads `gpu_device_api()` everywhere it tiles, so pointing that at
// DeviceAPI::WebGPU retargets the whole file. The two Metal-only arms — the hand-written grain
// and MTF externs — are already guarded on `== DeviceAPI::Metal` in the schedule and fall away
// on their own.

#define FOTUFILM_HALIDE_ENABLED 1
#define FOTUFILM_HALIDE_AOT_GENERATOR 1
#include "../Sources/FotufilmHalide/FotufilmHalideMetal.cpp"

#include <filesystem>
#include <iostream>
#include <string>

namespace {

/// WGSL has no 8- or 16-bit numeric storage without extensions, and Halide's WebGPU backend
/// emits f32 throughout. The half-precision schedule flags must stay off: they are the phones'
/// bandwidth win, not a portable one.
Halide::Target wasm_target(bool webgpu) {
    Halide::Target target;
    target.os = Halide::Target::WebAssemblyRuntime;
    target.arch = Halide::Target::WebAssembly;
    target.bits = 32;
    if (webgpu) {
        target.set_feature(Halide::Target::WebGPU);
        // No WasmMvpOnly here. It used to be needed because Halide's WebGPU runtime wanted the
        // pre-Future webgpu.h, which pinned the link to Emscripten 3.1.x, whose bundled binaryen
        // rejected the wasm features Halide's own LLVM stamps into the object. A Halide that
        // speaks the promise-based API links against a current Emscripten, and a current
        // binaryen knows those features — so the module need not be held to the MVP.
        target.set_feature(Halide::Target::WasmSimd128);
        target.set_feature(Halide::Target::WasmBulkMemory);
        // FOTUFILM_WASM_DEBUG=1 compiles in the runtime's own tracing, which is the only way to
        // see what the WebGPU device is doing from inside a browser tab.
        if (const char *debug = getenv("FOTUFILM_WASM_DEBUG")) {
            if (atoi(debug) != 0) target.set_feature(Halide::Target::Debug);
        }
    } else {
        // The CPU fallback earns its keep only with SIMD; bulk memory keeps the copies cheap.
        target.set_feature(Halide::Target::WasmSimd128);
        target.set_feature(Halide::Target::WasmBulkMemory);
    }
    return target;
}

}  // namespace

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) {
        std::cerr << "usage: generate_halide_wasm OUTPUT_DIRECTORY [--cpu|--webgpu]\n";
        return 2;
    }
    const std::string mode = argc == 3 ? argv[2] : "--webgpu";
    if (mode != "--cpu" && mode != "--webgpu") {
        std::cerr << "unknown mode: " << mode << "\n";
        return 2;
    }
    const bool webgpu = mode == "--webgpu";
    const std::filesystem::path output(argv[1]);
    std::filesystem::create_directories(output);

    if (webgpu) gpu_device_api() = Halide::DeviceAPI::WebGPU;

    // Float IO only. The uint8 variants the phones use cannot cross to WGSL: it has no 8-bit
    // numeric storage, so Halide emulates a uint8 buffer with atomics — it warns as much — and
    // then fails to generate the shader. That costs nothing here, because the browser wants
    // linear float out regardless: the sRGB encode and the 8-bit quantisation happen once in
    // JavaScript on the way to the canvas, where the dither would otherwise be paid twice.
    struct Variant {
        const char *name;
        int features;
        bool runtime;
    };
    const Variant variants[] = {
        // The donor capture layer joins the colour kernel rather than doubling the pair:
        // the browser compiles one variant per colour mode, and a path that drops the stage
        // keeps the warp's add-back and develops the donor stocks red. Monochrome coats no
        // 4th Color Layer, so its kernel stays as it was.
        {"color_float",
         FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_FLOAT_IO
             | FOTUFILM_FRAME_DONOR_LAYER, true},
        {"monochrome_float",
         FOTUFILM_AOT_ALL_STAGES | FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_FLOAT_IO, false},
    };

    const Halide::Target target = wasm_target(webgpu);
    std::cout << "target: " << target.to_string() << "\n";

    int failures = 0;
    for (const Variant &variant : variants) {
        std::cout << "  " << variant.name << std::flush;
        try {
            MetalFramePipeline pipeline(variant.features, std::string("_") + variant.name);
            pipeline.compile_aot((output / variant.name).string(), variant.name,
                                 variant.runtime, target);
            std::cout << " ok\n";
        } catch (const std::exception &error) {
            std::cout << " FAILED\n" << error.what() << "\n";
            ++failures;
        }
    }
    return failures == 0 ? 0 : 1;
}
