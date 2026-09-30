// Full-quality CPU/AOT must use the same analytic PCG streams as UIKit Metal.
#include "Pipeline/Cpu.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdint>

static uint32_t pcg(uint32_t value) {
    uint32_t state = value * 747796405u + 2891336453u;
    uint32_t word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
static uint32_t hash(int x, int y, uint32_t seed, int layer) {
    return pcg(uint32_t(x) ^ pcg(uint32_t(y) ^ pcg(seed ^ (uint32_t(layer) * 0x9E3779B9u))));
}
static float normal(uint32_t value) {
    float first = float(value >> 8u) * (1.0f / 16777216.0f) + 1.0e-7f;
    float second = float(pcg(value) >> 8u) * (1.0f / 16777216.0f);
    return std::sqrt(-2.0f * std::log(first)) * std::cos(2.0f * float(M_PI) * second);
}
static float poisson(uint32_t value, float lambda) {
    if (lambda >= 16.0f) return normal(value);
    float product = 1.0f, limit = std::exp(-lambda);
    int trials = 0;
    for (int i = 0; i < 32 && product > limit; ++i) {
        value = pcg(value);
        product *= float(value >> 8u) * (1.0f / 16777216.0f);
        ++trials;
    }
    return (float(std::max(trials - 1, 0)) - lambda) / std::sqrt(std::max(lambda,1.0e-4f));
}
int main() {
    using namespace Halide;
    constexpr int width=17, height=11;
    ImageParam config(Float(32),1,"config");
    Buffer<float> values(FOTUFILM_FRAME_CONFIGURATION_COUNT); values.fill(0);
    for (int c=0;c<3;++c) {
        values(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER+c)=1;
        values(FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER+c)=1;
    }
    config.set(values);
    fotufilm::FrameParams p("grain_test_","");
    p.grain_radius_.set(0);p.mottle_radius_.set(0);
    Param<int> mono("mono");
    Var x("x"),y("y"),c("c");
    fotufilm::pipelines::CpuBackend backend;
    auto fields=backend.grain_fields(config,p,mono,true,x,y,c,width,height,"grain_test_","");
    Pipeline pipeline({fields.grain,fields.mottle});
    Buffer<float> fine(width,height,3),coarse(width,height,3);
    float maximum=0;int samples=0,cases=0;
    for (uint32_t seed:{0u,1179208781u,0xffffffffu}) for (int origin:{0,83})
    for (int silver:{0,1}) for (float rho:{0.0f,0.6f,1.0f})
    for (float lambda:{0.01f,0.8f,4.0f,15.99f,16.0f,36.0f}) {
        p.seed_.set(seed);p.origin_x_.set(origin);p.origin_y_.set(origin+7);
        p.grain_lambda_.set(lambda);p.mottle_lambda_.set(lambda*.5f);
        mono.set(silver);values(FOTUFILM_CONFIG_GRAIN_CORRELATION)=rho;
        pipeline.realize(Realization({fine,coarse}));
        for (int band=0;band<2;++band) for (int channel=0;channel<3;++channel)
        for (int y=0;y<height;++y) for (int x=0;x<width;++x) {
            float rate=lambda*(band?.5f:1);
            auto shared=hash(x+origin,y+origin+7,seed,band?7:3);
            float expected=silver?normal(shared):std::sqrt(1-rho)*poisson(hash(x+origin,y+origin+7,seed,channel+(band?4:0)),rate)
                +std::sqrt(rho)*poisson(shared,rate);
            float actual=(band?coarse:fine)(x,y,channel);
            if (!std::isfinite(actual)) return 2;
            maximum=std::max(maximum,std::abs(actual-expected));++samples;
        }
        ++cases;
    }
    std::printf("CPU grain: %d cases, %d analytic reference samples, maximum error %.9g\n",cases,samples,maximum);
    return maximum < 0.0001f ? 0 : 1;
}
