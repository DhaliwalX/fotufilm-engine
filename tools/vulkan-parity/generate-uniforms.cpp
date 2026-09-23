#include <Halide.h>
int main(int argc, char **argv) {
    if(argc!=3) return 2;
    using namespace Halide;
    ImageParam input(UInt(32),1,"input");
    Param<bool> add("add"), invert("invert");
    Param<uint32_t> amount("amount");
    Var x("x"), block("block"), thread("thread");
    Func output("uniforms");
    Expr value=select(add,input(x)+amount,input(x)-amount);
    output(x)=select(invert,~value,value);
    output.gpu_tile(x,block,thread,32,TailStrategy::GuardWithIf,DeviceAPI::Vulkan);
    Target target(argv[2]);target.set_feature(Target::Vulkan);target.set_feature(Target::NoRuntime);
    output.compile_to_static_library(argv[1],{input,add,invert,amount},"uniforms",target);
}
