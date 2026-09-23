#include "fixture.h"
#include "cpu_spatial.h"
#include "vk_spatial.h"
#include <cstdio>
#include <cmath>
int main(int argc,char **argv) {
    if(argc!=2 && argc!=3) return 2;
    const bool exact = argc==3 && std::string(argv[2])=="--exact";
    if(argc==3 && !exact) return 2;
    setenv("HL_VK_ALLOC_CONFIG","0:1:0:0:256",0);
    Fixture f(argv[1]); Buffer<float> config(f.config.data(),int(f.config.size()));
    config.set_host_dirty();
    int failed=0;
    for(int w : {65,257}) {
        int h=w==65?49:193; auto interleaved=scene(w,h);
        Buffer<float> input(w,h,3),cpu(w,h,3),gpu(w,h,3);
        for(int y=0;y<h;++y)for(int x=0;x<w;++x)for(int c=0;c<3;++c)input(x,y,c)=interleaved(x,y,c);
        input.set_host_dirty();
        for(int s=0;s<3;++s) {
            int cs=cpu_spatial(input,config,s,0,0,cpu),gs=vk_spatial(input,config,s,0,0,gpu);
            if(!gs)gs=gpu.copy_to_host();
            if(cs || gs) { fprintf(stderr,"spatial failed: CPU %d Vulkan %d\n",cs,gs); failed=1; continue; }
            float peak = 0;
            double squared = 0;
            size_t different = 0, nonfinite = 0;
            for (int i = 0; i < w*h*3; ++i) {
                const float reference = cpu.data()[i], actual = gpu.data()[i];
                nonfinite += !std::isfinite(reference) || !std::isfinite(actual);
                different += memcmp(&reference, &actual, sizeof(float)) != 0;
                const double error = double(reference) - double(actual);
                squared += error * error;
                peak = std::max(peak, float(std::abs(error)));
            }
            const double rmse = std::sqrt(squared / (w*h*3));
            const bool quality = !nonfinite && peak <= 0.0001f && rmse <= 0.00001;
            printf("{\"width\":%d,\"scale\":%d,\"cpu_status\":%d,\"gpu_status\":%d,"
                   "\"values_different\":%zu,\"nonfinite\":%zu,\"maximum_error\":%.9g,"
                   "\"linear_rmse\":%.9g,\"quality_pass\":%s}\n",
                   w, s, cs, gs, different, nonfinite, peak, rmse, quality ? "true" : "false");
            failed |= exact ? (nonfinite || different) : !quality;
        }
    }
    return failed;
}
