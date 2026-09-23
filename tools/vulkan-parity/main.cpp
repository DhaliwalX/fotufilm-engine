#include "render.h"
#include "compare.h"
#include "cases.h"
#include "cpu_negative.h"
#include "vk_negative.h"
#include "FotufilmAotVariants.h"
#include <cstdlib>
#include <string>
#include <limits>

extern "C" int fotufilm_wasm_cpu_render(float *, float *, int32_t, int32_t, int32_t, int32_t,
                                        float *,float *,float *,float *,float *,int32_t,uint32_t);
int main(int argc, char **argv) {
    if (argc != 5 && (argc != 6 || std::string(argv[5]) != "--exact")) return 2;
    const bool exact = argc == 6;
    try {
        // Mali requires allocation padding for the scalar uniform block.
        setenv("HL_VK_ALLOC_CONFIG", "0:1:0:0:256", 0);
        halide_reuse_device_allocations(nullptr, true);
        Fixture f(argv[1]);
        if (f.config[FOTUFILM_CONFIG_GRAIN_MODE] == 3)
            throw std::runtime_error("Film grain tiles are not supported by these AOT variants; prepare a standard, particle or organic fixture");
        std::string test=argv[2]; int w=std::stoi(argv[3]), h=std::stoi(argv[4]);
        if (w<1 || h<1 || w>4096 || h>4096) return 2;
        if((test=="stage-disc" && f.config[FOTUFILM_CONFIG_GRAIN_MODE]!=1)
            || (test=="stage-crystal" && f.config[FOTUFILM_CONFIG_GRAIN_MODE]!=2))
            throw std::runtime_error("This grain mode requires a fixture prepared with --grain-model");
        f.config[FOTUFILM_CONFIG_FRAME_WIDTH]=w;
        f.config[FOTUFILM_CONFIG_FRAME_HEIGHT]=h;
        for(int c=0;c<3;++c) f.config[FOTUFILM_CONFIG_FLARE_MEAN+c]=.18f;
        auto input=scene(w,h);
        Buffer<float> planar(w,h,3), output(w,h,3), density(w,h,3);
        auto gpu=Buffer<float>::make_interleaved(w,h,4);
        auto cpu=Buffer<float>::make_interleaved(w,h,4);
        for(int y=0;y<h;++y) for(int x=0;x<w;++x) for(int c=0;c<3;++c)
            planar(x,y,c)=input(x,y,c);
        int cs=0,gs=0,ox=test=="viewport"?113:0,oy=test=="viewport"?71:0;
        int mask=f.mask;
        if(test=="negative" || test=="negative-mono") {
            float params[]={.04f,.025f,0,.7f,.35f,.15f,.6f,test=="negative-mono"?1.f:0.f};
            Buffer<float> p(params,8), gp(w,h,3);
            for(int c=0;c<3;++c) for(int y=0;y<h;++y) for(int x=0;x<w;++x)
                planar(x,y,c)=params[c]*.5f+(params[c+3]-params[c]*.5f)*float(x+y*w)/float(std::max(1,w*h-1));
            // Exercise invalid scans and valid wide-gamut channel excursions.
            planar(0,0,0)=std::numeric_limits<float>::quiet_NaN();
            if(w>1) for(int c=0;c<3;++c) planar(1,0,c)=0;
            if(w>2) planar(2,0,2)=-.008f;
            if(w>3) planar(3,0,2)=0;
            planar.set_host_dirty(); p.set_host_dirty();
            cs=cpu_negative(planar,p,output); gs=vk_negative(planar,p,gp);
            if(!gs) gs=gp.copy_to_host();
            if(!gs) for(int y=0;y<h;++y) for(int x=0;x<w;++x) for(int c=0;c<3;++c)
                gpu(x,y,c)=gp(x,y,c);
        } else {
            mask=case_mask(test,f.mask);
            cs=fotufilm_wasm_cpu_render(planar.data(),output.data(),w,h,ox,oy,f.config.data(),
                f.exposure.data(),f.film.data(),f.paper.data(),density.data(),mask,f.seed);
            gs=render_gpu(f,input,gpu,mask,ox,oy);
        }
        for(int y=0;y<h;++y) for(int x=0;x<w;++x) {
            for(int c=0;c<3;++c) cpu(x,y,c)=output(x,y,c);
            cpu(x,y,3)=gpu(x,y,3)=1;
        }
        // host alpha assignment also changes buffer ownership after GPU readback.
        gpu.set_host_dirty();
        if (getenv("FOTUFILM_PARITY_DEBUG")) for(int x : {0,w/2,w-1})
            fprintf(stderr,"pixel %d: cpu %.9g %.9g %.9g gpu %.9g %.9g %.9g\n",x,
                cpu(x,h/2,0),cpu(x,h/2,1),cpu(x,h/2,2),gpu(x,h/2,0),gpu(x,h/2,1),gpu(x,h/2,2));
        Difference d;
        if(!cs && !gs) d=compare(cpu,gpu,f.seed,ox,oy);
        report(test.c_str(),d,cs,gs);
        return !cs && !gs && (exact ? d.exact() : d.acceptable())?0:1;
    } catch(const std::exception &e) { fprintf(stderr,"%s\n",e.what()); return 2; }
}
