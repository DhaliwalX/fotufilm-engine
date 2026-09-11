#include <Halide.h>
#include "FotufilmHalideShared.h"
#include <filesystem>
#include <iostream>
using namespace Halide;
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    const std::string mode = argv[2];
    if (mode != "cpu" && mode != "gpu") return 2;
    const bool gpu = mode == "gpu";
    ImageParam input(Float(32), 2, "input");
    Var x("x"), op("op"), block("block"), thread("thread");
    Func output("output");
    Expr a = input(x, 0), b = input(x, 1), c = input(x, 2);
    output(x, op) = mux(op, {a+b, a-b, a*b, a/b, a*b+c, a+b*c,
        exp(a), log(a), pow(a,b), sqrt(a), (a-b)/c,
        fotufilm::softplus(a), exp(-a), log(1.0f+a)});
    output.bound(op, 0, 14).reorder(op,x).unroll(op);
    Target target("wasm-32-wasmrt-wasm_simd128-wasm_bulk_memory");
    target.set_feature(Target::StrictFloat);
    if (gpu) {
        target.set_feature(Target::WebGPU);
        output.gpu_tile(x,block,thread,64,TailStrategy::GuardWithIf,DeviceAPI::WebGPU);
    } else output.vectorize(x,8,TailStrategy::GuardWithIf);
    std::filesystem::create_directories(argv[1]);
    Pipeline(output).compile_to_static_library(std::string(argv[1])+"/parity_math", {input}, "math_kernel",target);
    if (!gpu) Pipeline(output).compile_to_llvm_assembly(std::string(argv[1])+"/parity_math.ll", {input}, "math_kernel", target);
    std::cout << target.to_string() << "\n";
}
