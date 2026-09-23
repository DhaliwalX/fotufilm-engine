#pragma once
#include "fixture.h"
#include "quality.h"
#include "cpu_display_rgba8.h"
#include "cpu_display_rgba16.h"
#include "vk_display_rgba8.h"
#include "vk_display_rgba16.h"
#include <cmath>
#include <cstdio>

inline size_t different_bytes(const void *a, const void *b, size_t size) {
    auto x=static_cast<const uint8_t *>(a), y=static_cast<const uint8_t *>(b);
    size_t n=0;
    for (size_t i=0; i<size; ++i) n += x[i] != y[i];
    return n;
}
struct Difference {
    Quality quality;
    size_t float_bytes=0, float_values=0, nonfinite=0, rgba8_bytes=0, rgba16_bytes=0;
    size_t cpu_nonfinite=0, gpu_nonfinite=0;
    float maximum=0, reference_at_maximum=0, vulkan_at_maximum=0;
    int worst_x=0, worst_y=0, worst_channel=0;
    int encoding_status=0;
    bool exact() const { return !float_bytes && !nonfinite && !rgba8_bytes && !rgba16_bytes && !encoding_status; }
    bool acceptable() const { return !nonfinite && !encoding_status && quality.accepts(maximum); }
};
inline Difference compare(Buffer<float> &cpu, Buffer<float> &gpu, uint32_t seed, int ox, int oy) {
    Difference d;
    for (int y=0; y<cpu.height(); ++y) for (int x=0; x<cpu.width(); ++x) for (int c=0;c<3;++c) {
        float a=cpu(x,y,c), b=gpu(x,y,c);
        if (std::isfinite(a) && std::isfinite(b)) d.quality.squared += double(a-b) * double(a-b);
        d.cpu_nonfinite+=!std::isfinite(a); d.gpu_nonfinite+=!std::isfinite(b);
        size_t n=different_bytes(&a,&b,sizeof(float));
        d.float_bytes+=n; d.float_values+=n!=0;
        if (!std::isfinite(a) || !std::isfinite(b)) ++d.nonfinite;
        else if (std::abs(a-b)>d.maximum) {
            d.maximum=std::abs(a-b); d.reference_at_maximum=a; d.vulkan_at_maximum=b;
            d.worst_x=x; d.worst_y=y; d.worst_channel=c;
        }
    }
    d.quality.rmse=std::sqrt(d.quality.squared / double(cpu.width()*cpu.height()*3));
    cpu.set_host_dirty(); gpu.set_host_dirty();
    for (int bits : {8,16}) {
        int words=bits==8?1:2;
        Buffer<uint32_t> a(cpu.width()*words,cpu.height()), b(cpu.width()*words,cpu.height());
        auto cf=bits==8?cpu_display_rgba8:cpu_display_rgba16;
        auto gf=bits==8?vk_display_rgba8:vk_display_rgba16;
        int status=cf(cpu,ox,oy,cpu.width()+ox,0,seed,a);
        if (!status) status=gf(gpu,ox,oy,gpu.width()+ox,0,seed,b);
        if (!status) status=b.copy_to_host();
        if (status) { d.encoding_status=status; continue; }
        size_t bytes=different_bytes(a.data(),b.data(),a.number_of_elements()*4);
        if (bits==8) d.rgba8_bytes=bytes; else d.rgba16_bytes=bytes;
        if (bits==8) d.quality.rgba8_maximum=d.quality.display_error<uint8_t>(a.data(),b.data(),a.number_of_elements()*4,true);
        else d.quality.rgba16_maximum=d.quality.display_error<uint16_t>(a.data(),b.data(),a.number_of_elements()*4,false);
    }
    return d;
}
inline void report(const char *test, const Difference &d, int cpu_status, int gpu_status) {
    printf("{\"case\":\"%s\",\"cpu_status\":%d,\"gpu_status\":%d,"
        "\"encoding_status\":%d,\"float_values_different\":%zu,\"float_bytes_different\":%zu,"
        "\"rgba8_bytes_different\":%zu,\"rgba16_bytes_different\":%zu,"
        "\"nonfinite\":%zu,\"cpu_nonfinite\":%zu,\"gpu_nonfinite\":%zu,\"maximum_float_error\":%.9g,"
        "\"worst_pixel\":[%d,%d,%d],\"reference_value\":%.9g,\"vulkan_value\":%.9g,\"exact\":%s,"
        "\"linear_rmse\":%.9g,\"rgba8_maximum_error\":%u,\"rgba16_maximum_error\":%u,\"quality_pass\":%s}\n",
        test,cpu_status,gpu_status,d.encoding_status,d.float_values,d.float_bytes,
        d.rgba8_bytes,d.rgba16_bytes,d.nonfinite,d.cpu_nonfinite,d.gpu_nonfinite,d.maximum,
        d.worst_x,d.worst_y,d.worst_channel,d.reference_at_maximum,d.vulkan_at_maximum,
        !cpu_status && !gpu_status && d.exact()?"true":"false",d.quality.rmse,
        d.quality.rgba8_maximum,d.quality.rgba16_maximum,
        !cpu_status && !gpu_status && d.acceptable()?"true":"false");
}
