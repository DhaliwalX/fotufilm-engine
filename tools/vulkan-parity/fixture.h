#pragma once
#include "FotufilmHalide.h"
#include "HalideBuffer.h"
#include <fstream>
#include <vector>
#include <cstring>
#include <stdexcept>

using Halide::Runtime::Buffer;
struct Fixture {
    int width, height, mask;
    uint32_t seed;
    std::vector<float> config, exposure, film, paper;
    explicit Fixture(const char *path) {
        std::ifstream file(path, std::ios::binary);
        int32_t h[10];
        if (!file.read(reinterpret_cast<char *>(h), sizeof(h)) || memcmp(h, "FSWP", 4)
            || (h[1] != 1 && h[1] != 2) || h[6] != FOTUFILM_FRAME_CONFIGURATION_COUNT
            || h[7] != 33 || h[8] != 33*33*33*4) throw std::runtime_error("Invalid fixture");
        width=h[2]; height=h[3]; mask=h[4]; seed=uint32_t(h[5]);
        for (auto *v : {&config, &exposure, &film, &paper}) {
            int n = v == &config ? h[6] : h[8];
            v->resize(n);
            if (!file.read(reinterpret_cast<char *>(v->data()), n*sizeof(float)))
                throw std::runtime_error("Truncated fixture");
            if (v != &config) v->resize(147456, 0); // Vulkan LUT binding bound.
        }
    }
};

inline Buffer<float> scene(int w, int h) {
    auto b = Buffer<float>::make_interleaved(w, h, 4);
    for (int y=0; y<h; ++y) for (int x=0; x<w; ++x) {
        float u=float(x)/std::max(1,w-1), v=float(y)/std::max(1,h-1);
        b(x,y,0)=.05f+3*u*u; b(x,y,1)=.05f+2*v; b(x,y,2)=.05f+1.5f*(1-u)*v;
        if (x>w/2 && y>h/3 && y<2*h/3) {
            b(x,y,0)=8; b(x,y,1)=7.2f; b(x,y,2)=6.4f;
        }
        b(x,y,3)=1;
    }
    return b;
}
