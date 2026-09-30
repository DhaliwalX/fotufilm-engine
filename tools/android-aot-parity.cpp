#include "vulkan-parity/fixture.h"
#include <cmath>
#include <cstdio>
#include <limits>

// Run unchanged against the Android adapter and the CPU reference in separate processes.
// The fixture is public example-stock data; deliberately nonzero stage settings make a
// missing compiled stage fail even at this small image size.
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    Fixture f(argv[1]);
    const int w = f.width, h = f.height, n = w * h;
    auto input = scene(w, h);
    std::vector<float> rgb(n * 3), out(n * 3);
    for (int c = 0; c < 3; ++c)
        for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x)
            rgb[c*n+y*w+x] = input(x,y,c);
    auto &p = f.config;
    p[FOTUFILM_CONFIG_GRAIN_MODE] = 0;
    p[FOTUFILM_CONFIG_DIFFUSION_DIRECT] = .6f;
    for (int c = 0; c < 3; ++c) {
        p[FOTUFILM_CONFIG_DIFFUSION_KERNEL+c*3] = .2f;
        p[FOTUFILM_CONFIG_DIFFUSION_KERNEL+c*3+1] = .1f;
        p[FOTUFILM_CONFIG_DIFFUSION_KERNEL+c*3+2] = .1f;
        p[FOTUFILM_CONFIG_MOTTLE+c] = .08f;
        p[FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER+c] = 1.5f;
    }
    p[FOTUFILM_CONFIG_DIFFUSION_RADIUS] = 3;
    p[FOTUFILM_CONFIG_DIFFUSION_RADIUS+1] = 7;
    p[FOTUFILM_CONFIG_DIFFUSION_RADIUS+2] = 12;
    p[FOTUFILM_CONFIG_MOTTLE_RADIUS] = 5;
    p[FOTUFILM_CONFIG_MOTTLE_LAMBDA] = 8;
    p[FOTUFILM_CONFIG_PRINT_MTF_SIGMA] = 1.5f;
    p[FOTUFILM_CONFIG_PRINT_MTF_RADIUS] = 5;
    p[FOTUFILM_CONFIG_PRINT_SHARPEN] = 0;
    const int stages[] = {0, FOTUFILM_FRAME_DIFFUSION, FOTUFILM_FRAME_GRAIN_MOTTLE,
        FOTUFILM_FRAME_PRINT_MTF,
        FOTUFILM_FRAME_DIFFUSION | FOTUFILM_FRAME_GRAIN_MOTTLE | FOTUFILM_FRAME_PRINT_MTF};
    const int base = (f.mask | FOTUFILM_FRAME_GRAIN) & ~stages[4] &
        ~(FOTUFILM_FRAME_REVERSAL | FOTUFILM_FRAME_MONOCHROME);
    auto write = [&] {
        for (float v : out) if (!std::isfinite(v)) throw std::runtime_error("Nonfinite output");
        if (std::fwrite(out.data(), sizeof(float), out.size(), stdout) != out.size())
            throw std::runtime_error("Output write failed");
    };
    for (int variant = 0; variant < 4; ++variant) {
        int mask = base | ((variant & 1) ? FOTUFILM_FRAME_REVERSAL : 0) |
            ((variant & 2) ? FOTUFILM_FRAME_MONOCHROME : 0);
        for (int stage : stages) {
            int status = fotufilm_halide_process(rgb.data(), rgb.data()+n, rgb.data()+2*n,
                out.data(), out.data()+n, out.data()+2*n, w, h, p.data(), f.exposure.data(),
                f.film.data(), f.paper.data(), 33, mask | stage, f.seed);
            if (status) return 3;
            write();
        }
        // Standalone development must stop before the enlarger even when its bit is set.
        std::vector<float> negative;
        for (int stage : {0, int(FOTUFILM_FRAME_PRINT_MTF)}) {
            int status = fotufilm_halide_develop(rgb.data(), rgb.data()+n, rgb.data()+2*n,
                out.data(), out.data()+n, out.data()+2*n, w, h, p.data(), f.exposure.data(),
                33, mask | stage, f.seed);
            if (status) return 4;
            if (negative.empty()) negative = out;
            else if (out != negative) return 5;
            write();
        }
        // Nonzero global origins and a cropped interior exercise extended bindings in tile calls.
        std::fill(out.begin(), out.end(), -123.f);
        int tw = w-8, th = h-8;
        int status = fotufilm_halide_process_tile(rgb.data(), rgb.data()+n, rgb.data()+2*n,
            out.data(), out.data()+n, out.data()+2*n, tw, th, w, h, 3, 5,
            2, 2, tw-4, th-4, p.data(), f.exposure.data(), f.film.data(), f.paper.data(),
            33, mask | stages[4], f.seed);
        if (status) return 6;
        for (int c=0;c<3;++c) for (int y=0;y<h;++y) for (int x=0;x<w;++x)
            if ((x<5 || x>=tw+1 || y<7 || y>=th+3) && out[c*n+y*w+x] != -123.f) return 7;
        write();

        // Generic record exposure: RGB and donor are independent, behind the gate.
        for (int i=0;i<6;++i) p[FOTUFILM_CONFIG_DONOR_CURVE+i] = p[FOTUFILM_CONFIG_CURVES+i];
        for (int c=0;c<3;++c) p[FOTUFILM_CONFIG_DONOR_RELEASE+c] = .8f;
        p[FOTUFILM_CONFIG_DONOR_RELEASE_GAMMA] = 1;
        const int extraMask = mask | stages[4] | FOTUFILM_FRAME_DONOR_LAYER;
        std::vector<float> zero(n*4), extra(n*4);
        auto renderExtra = [&](const float *records, bool tile, int flags) {
            return fotufilm_halide_process_tile_with_exposure(
                rgb.data(), rgb.data()+n, rgb.data()+2*n,
                out.data(), out.data()+n, out.data()+2*n, tile ? tw : w, tile ? th : h,
                w, h, tile ? 3 : 0, tile ? 5 : 0, tile ? 2 : 0, tile ? 2 : 0,
                tile ? tw-4 : w, tile ? th-4 : h, p.data(), f.exposure.data(),
                f.film.data(), f.paper.data(), 33, flags, f.seed, records);
        };
        if (renderExtra(nullptr, false, extraMask)) return 8;
        write();
        if (renderExtra(zero.data(), false, extraMask)) return 9;
        write();
        for (int mode=0;mode<3;++mode) {
            for (int i=0;i<n;++i) {
                extra[i*4] = mode == 1 ? 0 : .025f * (i%11);
                extra[i*4+1] = mode == 1 ? 0 : .02f * ((i/w)%7);
                extra[i*4+2] = mode == 1 ? 0 : .04f;
                extra[i*4+3] = mode == 0 ? 0 : .3f * (i%5+1);
            }
            if (renderExtra(extra.data(), false, extraMask)) return 10;
            write();
        }
        float savedGate[5];
        for (int i=0;i<5;++i) { savedGate[i]=p[FOTUFILM_CONFIG_GATE+i]; p[FOTUFILM_CONFIG_GATE+i]=10000; }
        p[FOTUFILM_CONFIG_GATE+4]=0;
        if (renderExtra(zero.data(), false, extraMask)) return 11;
        write();
        if (renderExtra(extra.data(), false, extraMask)) return 12;
        write();
        for (int i=0;i<5;++i) p[FOTUFILM_CONFIG_GATE+i]=savedGate[i];
        std::fill(out.begin(), out.end(), -123.f);
        if (renderExtra(extra.data(), true, extraMask)) return 13;
        write();
        const auto unchanged = out;
        for (float bad : {-1.f, std::numeric_limits<float>::infinity(), std::numeric_limits<float>::quiet_NaN()}) {
            extra[0] = bad;
            if (!renderExtra(extra.data(), false, extraMask) || out != unchanged) return 14;
        }
        extra[0] = 0;
        for (int unsupported : {FOTUFILM_FRAME_NO_FILM, FOTUFILM_FRAME_DENSITY_IN,
                                FOTUFILM_FRAME_RECORD_EXPOSURE_IN, FOTUFILM_FRAME_TEXTURE})
            if (!renderExtra(extra.data(), false, extraMask | unsupported) || out != unchanged) return 15;
    }
}
