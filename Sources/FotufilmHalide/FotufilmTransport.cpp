#include "FotufilmTransport.h"
#if defined(FOTUFILM_HALIDE_ENABLED)
#include "FotufilmHalideShared.h"
#include <memory>
#include <mutex>
#include <cmath>
#include <cstdio>
#if defined(__APPLE__)
#include <Accelerate/Accelerate.h>
#endif

namespace {
using namespace Halide;

class AccumulatePipeline {
    ImageParam accum_in{Float(32), 3}, band_in{Float(32), 3};
    Param<float> weight;
    Pipeline pipeline;
public:
    explicit AccumulatePipeline(bool metal) {
        Var x, y, c, xo, yo, xi, yi;
        Func output;
        output(x, y, c) = accum_in(x, y, c) + weight * band_in(x, y, c);
        output.bound(c, 0, 3).reorder(c, x, y).unroll(c);
        if (metal) { output.gpu_tile(x, y, xo, yo, xi, yi, 16, 8, TailStrategy::GuardWithIf); }
        else { output.vectorize(x, 8, TailStrategy::GuardWithIf).parallel(y); }
        pipeline = Pipeline(output);
    }
    void run(Buffer<float> &accum, Buffer<float> &band, float w, Target target, Buffer<float> &out) {
        accum_in.set(accum);
        band_in.set(band);
        weight.set(w);
        pipeline.realize(out, target);
    }
};

class TransportConvolution {
    ImageParam red{Float(32), 2}, green{Float(32), 2}, blue{Float(32), 2}, kernel{Float(32), 2};
    Param<int32_t> width, height, radius, stride;
    Pipeline pipeline;
    Target target;
    bool is_metal;
    AccumulatePipeline accum_pipe;
    std::mutex mutex;
    Buffer<float> cached_accum[2];
    Buffer<float> cached_band_result;
    int cached_w = 0, cached_h = 0;

    void ensure_buffers(int w, int h) {
        if (w == cached_w && h == cached_h) return;
        cached_w = w; cached_h = h;
        cached_band_result = Buffer<float>(w, h, 3);
        if (is_metal) {
            cached_accum[0] = Buffer<float>(w, h, 3);
            cached_accum[1] = Buffer<float>(w, h, 3);
        }
    }
public:
    explicit TransportConvolution(bool metal)
        : target(get_jit_target_from_environment()), is_metal(metal), accum_pipe(metal) {
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
        auto sample_at = [&](Expr xx, Expr yy) {
            return blurred(clamp(xx, 0, gw - 1), clamp(yy, 0, gh - 1), c);
        };
        Expr px = (cast<float>(x) + 0.5f) / cast<float>(stride) - 0.5f;
        Expr py = (cast<float>(y) + 0.5f) / cast<float>(stride) - 0.5f;
        output(x, y, c) = select(stride == 1,
            sample_at(x, y),
            fotufilm::bicubic_sample(sample_at, px, py));
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
        ensure_buffers(w, h);
        pipeline.realize(cached_band_result, target);
        cached_band_result.copy_to_host();
        const int64_t n = int64_t(w) * h;
        std::copy_n(cached_band_result.data(), n, out_r);
        std::copy_n(cached_band_result.data() + n, n, out_g);
        std::copy_n(cached_band_result.data() + 2 * n, n, out_b);
    }
    void accumulate_bands(const float *r, const float *g, const float *b,
                          float *accum_r, float *accum_g, float *accum_b,
                          int w, int h, const FotufilmTransportBand *bands, int band_count) {
        if (band_count <= 0) return;
        std::lock_guard<std::mutex> lock(mutex);
        const int64_t n = int64_t(w) * h;

        // 1. Host -> Device upload of input planes: EXACTLY ONCE
        Buffer<float> rb(const_cast<float *>(r), w, h), gb(const_cast<float *>(g), w, h),
            bb(const_cast<float *>(b), w, h);
        rb.set_host_dirty(); gb.set_host_dirty(); bb.set_host_dirty();
        red.set(rb); green.set(gb); blue.set(bb);
        width.set(w); height.set(h);

        ensure_buffers(w, h);

        if (is_metal) {
            cached_accum[0].fill(0.0f);
            cached_accum[0].set_host_dirty();
            int cur = 0;

            for (int i = 0; i < band_count; ++i) {
                if (bands[i].weight <= 0.0f) continue;
                Buffer<float> kb(const_cast<float *>(bands[i].kernel),
                                 bands[i].radius * 2 + 1, bands[i].radius * 2 + 1);
                kb.set_host_dirty();
                kernel.set(kb);
                radius.set(bands[i].radius);
                stride.set(bands[i].stride);

                // Run convolution on GPU
                pipeline.realize(cached_band_result, target);

                // Run GPU accumulation without downloading to host
                accum_pipe.run(cached_accum[cur], cached_band_result, bands[i].weight, target, cached_accum[1 - cur]);
                cur = 1 - cur;
            }

            // Download accumulated result to host EXACTLY ONCE at the end
            cached_accum[cur].copy_to_host();
            const float *res = cached_accum[cur].data();

            #if defined(__APPLE__)
            vDSP_vadd(res, 1, accum_r, 1, accum_r, 1, n);
            vDSP_vadd(res + n, 1, accum_g, 1, accum_g, 1, n);
            vDSP_vadd(res + 2 * n, 1, accum_b, 1, accum_b, 1, n);
            #else
            for (int64_t i = 0; i < n; ++i) {
                accum_r[i] += res[i];
                accum_g[i] += res[i + n];
                accum_b[i] += res[i + 2 * n];
            }
            #endif
        } else {
            // CPU backend: reuse cached_band_result and accumulate directly into accum_r, accum_g, accum_b
            for (int i = 0; i < band_count; ++i) {
                if (bands[i].weight <= 0.0f) continue;
                Buffer<float> kb(const_cast<float *>(bands[i].kernel),
                                 bands[i].radius * 2 + 1, bands[i].radius * 2 + 1);
                kb.set_host_dirty();
                kernel.set(kb);
                radius.set(bands[i].radius);
                stride.set(bands[i].stride);

                pipeline.realize(cached_band_result, target);
                const float *res = cached_band_result.data();
                const float weight = bands[i].weight;

                #if defined(__APPLE__)
                vDSP_vsma(res, 1, &weight, accum_r, 1, accum_r, 1, n);
                vDSP_vsma(res + n, 1, &weight, accum_g, 1, accum_g, 1, n);
                vDSP_vsma(res + 2 * n, 1, &weight, accum_b, 1, accum_b, 1, n);
                #else
                for (int64_t j = 0; j < n; ++j) {
                    accum_r[j] += weight * res[j];
                    accum_g[j] += weight * res[j + n];
                    accum_b[j] += weight * res[j + 2 * n];
                }
                #endif
            }
        }
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
extern "C" int32_t fotufilm_transport_accumulate(
    const float *r, const float *g, const float *b,
    float *accum_r, float *accum_g, float *accum_b,
    int32_t width, int32_t height,
    const FotufilmTransportBand *bands, int32_t band_count,
    int32_t backend) {
    if (!r || !g || !b || !accum_r || !accum_g || !accum_b || !bands || width <= 0 || height <= 0 || band_count < 0) return -1;
    if (band_count == 0) return 0;
    if (!fotufilm_transport_available(backend)) return -3;
    for (int b = 0; b < band_count; ++b) {
        int rad = bands[b].radius, scale = bands[b].stride;
        if (!bands[b].kernel || rad < 1 || rad > 128 || scale < 1 || scale > 4096 || (scale & (scale - 1))) return -1;
        if (!std::isfinite(bands[b].weight) || bands[b].weight < 0) return -1;
        double sum = 0;
        for (int i = 0; i < (rad * 2 + 1) * (rad * 2 + 1); ++i) {
            if (!std::isfinite(bands[b].kernel[i]) || bands[b].kernel[i] < 0) return -1;
            sum += bands[b].kernel[i];
        }
        if (std::abs(sum - 1) > 1e-5) return -1;
    }
    try {
        static std::unique_ptr<TransportConvolution> engines[2];
        static std::mutex preparation;
        TransportConvolution *engine;
        {
            std::lock_guard<std::mutex> lock(preparation);
            if (!engines[backend]) engines[backend] = std::make_unique<TransportConvolution>(backend == 1);
            engine = engines[backend].get();
        }
        engine->accumulate_bands(r, g, b, accum_r, accum_g, accum_b, width, height, bands, band_count);
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Layered transport accumulate: %s\n", error.what());
        return -2;
    }
}
#else
extern "C" int32_t fotufilm_transport_available(int32_t) { return 0; }
extern "C" int32_t fotufilm_transport_convolve(const float *, const float *, const float *,
    float *, float *, float *, int32_t, int32_t, const float *, int32_t, int32_t, int32_t) { return -3; }
extern "C" int32_t fotufilm_transport_accumulate(const float *, const float *, const float *,
    float *, float *, float *, int32_t, int32_t, const FotufilmTransportBand *, int32_t, int32_t) { return -3; }
#endif
