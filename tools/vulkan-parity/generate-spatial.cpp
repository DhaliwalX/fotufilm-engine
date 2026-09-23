#define FOTUFILM_HALIDE_ENABLED 1
#define FOTUFILM_HALIDE_AOT_GENERATOR 1
#include "../../Sources/FotufilmHalide/Pipeline/GpuBackend.h"
#include "../../Sources/FotufilmHalide/Pipeline/Cpu.h"
#include <filesystem>
int main(int argc,char **argv) {
    if(argc!=3) return 2;
    using namespace Halide; using namespace fotufilm; using namespace fotufilm::pipelines;
    for(bool gpu : {false,true}) {
        std::string name=gpu?"vk_spatial":"cpu_spatial";
        ImageParam input(Float(32),3,"input"), config(Float(32),1,"config"), lut(Float(32),1,"lut");
        Param<int> scale("scale"), ox("ox"),oy("oy");
        Var x("x"),y("y"),c("c"); Func light("light"),output(name);
        light(x,y,c)=input(x,y,c);
        Expr w=input.dim(0).extent(), h=input.dim(1).extent();
        FrameParams params("spatial_","");
        gpu::GpuConfiguration conf; conf.device=DeviceAPI::Vulkan; conf.tile_x=conf.tile_y=8;
        gpu::GpuSchedule schedule(conf);
        GpuBackend gb(schedule,{},params,config,lut,lut);
        CpuBackend cb; cb.bind_configuration(config);
        graph::Backend &backend=gpu?static_cast<graph::Backend &>(gb):static_cast<graph::Backend &>(cb);
        auto s=backend.scattered(light,{Expr(1),Expr(2),Expr(4)},{Expr(6),Expr(5),Expr(4)},
                                w,h,ox,oy,x,y,c,-1,false,"scatter_",3);
        output(x,y,c)=mux(scale,{s[0],s[1],s[2]});
        if(gpu) schedule.gpu_pointwise(output,x,y,c,3);
        else cpu::cpu_pointwise(output,x,y,c);
        Target t(argv[2]); t.set_feature(Target::StrictFloat);t.set_feature(Target::NoRuntime);
        if(gpu)t.set_feature(Target::Vulkan);
        output.compile_to_static_library((std::filesystem::path(argv[1])/name).string(),
                                         {input,config,scale,ox,oy},name,t);
    }
}
