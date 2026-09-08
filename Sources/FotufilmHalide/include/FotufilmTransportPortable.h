#pragma once
#include <algorithm>
#include <cmath>
#include <vector>

// Positive area reduction, dense convolution and pixel-centred bilinear reconstruction.
// Matches the Halide reference and native Metal transport implementation, including edges.
inline int fotufilm_transport_filter(const float *input, float *output, int w, int h,
                                     const float *kernel, int radius, int stride) {
    if (!input || !output || !kernel || w <= 0 || h <= 0 || radius < 1 || radius > 128
        || stride < 1 || stride > 4096 || (stride & (stride - 1))) return -1;
    double mass = 0;
    const int side = radius * 2 + 1;
    for (int k = 0; k < side * side; ++k) {
        if (!std::isfinite(kernel[k]) || kernel[k] < 0) return -1;
        mass += kernel[k];
    }
    if (std::abs(mass - 1) > 1e-5) return -1;
    const int gw = (w + stride - 1) / stride, gh = (h + stride - 1) / stride;
    std::vector<float> reduced(size_t(gw) * gh), blurred(size_t(gw) * gh);
    for (int c = 0; c < 3; ++c) {
        const float *src = input + size_t(c) * w * h;
        float *dst = output + size_t(c) * w * h;
        for (int y = 0; y < gh; ++y) for (int x = 0; x < gw; ++x) {
            float sum = 0;
            for (int dy = 0; dy < stride; ++dy) for (int dx = 0; dx < stride; ++dx)
                sum += src[size_t(std::min(y * stride + dy, h - 1)) * w + std::min(x * stride + dx, w - 1)];
            reduced[size_t(y) * gw + x] = sum / float(stride * stride);
        }
        for (int y = 0; y < gh; ++y) for (int x = 0; x < gw; ++x) {
            float sum = 0;
            for (int dy = -radius; dy <= radius; ++dy) for (int dx = -radius; dx <= radius; ++dx)
                sum += kernel[(dy + radius) * side + dx + radius]
                    * reduced[size_t(std::clamp(y + dy, 0, gh - 1)) * gw + std::clamp(x + dx, 0, gw - 1)];
            blurred[size_t(y) * gw + x] = sum;
        }
        auto at = [&](int x, int y) { return blurred[size_t(std::clamp(y, 0, gh - 1)) * gw + std::clamp(x, 0, gw - 1)]; };
        for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
            float px = (x + .5f) / stride - .5f, py = (y + .5f) / stride - .5f;
            int ix = int(std::floor(px)), iy = int(std::floor(py));
            float fx = px - ix, fy = py - iy;
            float a = at(ix, iy) * (1 - fx) + at(ix + 1, iy) * fx;
            float b = at(ix, iy + 1) * (1 - fx) + at(ix + 1, iy + 1) * fx;
            dst[size_t(y) * w + x] = a * (1 - fy) + b * fy;
        }
    }
    return 0;
}
