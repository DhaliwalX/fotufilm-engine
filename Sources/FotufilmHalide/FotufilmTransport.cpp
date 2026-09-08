#include "FotufilmTransport.h"
#if defined(FOTUFILM_HALIDE_ENABLED)
#include "FotufilmHalideShared.h"
#include <memory>
#include <mutex>
#include <cmath>
#include <cstdio>

namespace {
using namespace Halide;
class TransportConvolution {
    ImageParam red{Float(32), 2}, green{Float(32), 2}, blue{Float(32), 2}, kernel{Float(32), 2};
    Param<int32_t> width, height, radius, stride;
    Pipeline pipeline;
    Target target;
    std::mutex mutex;
public:
    explicit TransportConvolution(bool metal) : target(get_jit_target_from_environment()) {
        if (metal) { target.set_feature(Target::Metal); }
        Var x, y, c, xo, yo, xi, yi;
        Expr gw = (width + stride - 1) / stride, gh = (height + stride - 1) / stride;
        Func input, reduced, blurred, output;
        Expr sx = clamp(x, 0, width - 1), sy = clamp(y, 0, height - 1);
        input(x, y, c) = mux(c, {red(sx, sy), green(sx, sy), blue(sx, sy)});
        RDom down(0, stride, 0, stride);
        reduced(x, y, c) = sum(input(x * stride + down.x, y * stride + down.y, c))
            / cast<float>(stride * stride);
        RDom tap(-radius, 2 * radius + 1, -radius, 2 * radius + 1);
        blurred(x, y, c) = sum(kernel(tap.x + radius, tap.y + radius)
            * reduced(clamp(x + tap.x, 0, gw - 1), clamp(y + tap.y, 0, gh - 1), c));
        Expr px = (cast<float>(x) + 0.5f) / cast<float>(stride) - 0.5f;
        Expr py = (cast<float>(y) + 0.5f) / cast<float>(stride) - 0.5f;
        output(x, y, c) = fotufilm::bilinear_sample([&](Expr xx, Expr yy) {
            return blurred(clamp(xx, 0, gw - 1), clamp(yy, 0, gh - 1), c);
        }, px, py);
        for (Func f : {reduced, blurred}) {
            f.compute_root().bound(c, 0, 3).reorder(c, x, y).unroll(c);
            if (metal) { f.gpu_tile(x, y, xo, yo, xi, yi, 16, 8, TailStrategy::GuardWithIf); }
            else { f.vectorize(x, 8, TailStrategy::GuardWithIf).parallel(y); }
        }
        output.compute_root().bound(c, 0, 3).reorder(c, x, y).unroll(c);
        if (metal) { output.gpu_tile(x, y, xo, yo, xi, yi, 16, 8, TailStrategy::GuardWithIf); }
        else { output.vectorize(x, 8, TailStrategy::GuardWithIf).parallel(y); }
        pipeline = Pipeline(output);
    }
    void run(const float *r, const float *g, const float *b,
             float *out_r, float *out_g, float *out_b,
             int w, int h, const float *weights, int rad, int scale) {
        std::lock_guard<std::mutex> lock(mutex);
        Buffer<float> rb(const_cast<float *>(r), w, h), gb(const_cast<float *>(g), w, h),
            bb(const_cast<float *>(b), w, h), kb(const_cast<float *>(weights), rad * 2 + 1, rad * 2 + 1);
        rb.set_host_dirty(); gb.set_host_dirty(); bb.set_host_dirty(); kb.set_host_dirty();
        red.set(rb); green.set(gb); blue.set(bb); kernel.set(kb);
        width.set(w); height.set(h); radius.set(rad); stride.set(scale);
        Buffer<float> result(w, h, 3);
        pipeline.realize(result, target);
        result.copy_to_host();
        const int64_t n = int64_t(w) * h;
        std::copy_n(result.data(), n, out_r);
        std::copy_n(result.data() + n, n, out_g);
        std::copy_n(result.data() + 2 * n, n, out_b);
    }
};
}
extern "C" int32_t fotufilm_transport_available(int32_t backend) {
    if (backend == 0) return 1;
#if defined(__APPLE__)
    if (backend == 1) {
        Halide::Target target = Halide::get_jit_target_from_environment();
        target.set_feature(Halide::Target::Metal);
        return Halide::host_supports_target_device(target) ? 1 : 0;
    }
#endif
    return 0;
}
extern "C" int32_t fotufilm_transport_convolve(
    const float *r, const float *g, const float *b, float *out_r, float *out_g, float *out_b,
    int32_t width, int32_t height, const float *kernel, int32_t radius, int32_t stride, int32_t backend) {
    if (!r || !g || !b || !out_r || !out_g || !out_b || !kernel || width <= 0 || height <= 0
        || radius < 1 || radius > 128 || stride < 1 || stride > 4096 || (stride & (stride - 1))) return -1;
    if (!fotufilm_transport_available(backend)) return -3;
    double sum = 0;
    for (int i = 0; i < (radius * 2 + 1) * (radius * 2 + 1); ++i) {
        if (!std::isfinite(kernel[i]) || kernel[i] < 0) return -1;
        sum += kernel[i];
    }
    if (std::abs(sum - 1) > 1e-5) return -1;
    try {
        static std::unique_ptr<TransportConvolution> engines[2];
        static std::mutex preparation;
        TransportConvolution *engine;
        {
            std::lock_guard<std::mutex> lock(preparation);
            if (!engines[backend]) engines[backend] = std::make_unique<TransportConvolution>(backend == 1);
            engine = engines[backend].get();
        }
        engine->run(r, g, b, out_r, out_g, out_b, width, height, kernel, radius, stride);
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Layered transport: %s\n", error.what());
        return -2;
    }
}
#else
extern "C" int32_t fotufilm_transport_available(int32_t) { return 0; }
extern "C" int32_t fotufilm_transport_convolve(const float *, const float *, const float *,
    float *, float *, float *, int32_t, int32_t, const float *, int32_t, int32_t, int32_t) { return -3; }
#endif
