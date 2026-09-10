#pragma once
#include <algorithm>
#include <cmath>
#include <vector>

// Positive area reduction, dense convolution and pixel-centred bicubic B-spline reconstruction.
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
        if (stride == 1) {
            for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
                dst[size_t(y) * w + x] = at(x, y);
            }
        } else {
            for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
                float px = (x + .5f) / stride - .5f, py = (y + .5f) / stride - .5f;
                int x0 = int(std::floor(px)), y0 = int(std::floor(py));
                float fx = px - x0, fy = py - y0;
                float omfx = 1.0f - fx, fx2 = fx * fx, fx3 = fx2 * fx;
                float wx[4] = {
                    (1.0f / 6.0f) * (omfx * omfx * omfx),
                    (1.0f / 6.0f) * (3.0f * fx3 - 6.0f * fx2 + 4.0f),
                    (1.0f / 6.0f) * (-3.0f * fx3 + 3.0f * fx2 + 3.0f * fx + 1.0f),
                    (1.0f / 6.0f) * fx3
                };
                float omfy = 1.0f - fy, fy2 = fy * fy, fy3 = fy2 * fy;
                float wy[4] = {
                    (1.0f / 6.0f) * (omfy * omfy * omfy),
                    (1.0f / 6.0f) * (3.0f * fy3 - 6.0f * fy2 + 4.0f),
                    (1.0f / 6.0f) * (-3.0f * fy3 + 3.0f * fy2 + 3.0f * fy + 1.0f),
                    (1.0f / 6.0f) * fy3
                };
                float val = 0.0f;
                for (int dy = -1; dy <= 2; ++dy) {
                    float row = 0.0f;
                    for (int dx = -1; dx <= 2; ++dx) {
                        row += wx[dx + 1] * at(x0 + dx, y0 + dy);
                    }
                    val += wy[dy + 1] * row;
                }
                dst[size_t(y) * w + x] = val;
            }
        }
    }
    return 0;
}
