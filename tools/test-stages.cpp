#define FOTUFILM_HALIDE_ENABLED 1
#include "FotufilmHalideShared.h"
#include "FotufilmHalideFrameParams.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <string>
#include <vector>

using namespace fotufilm;
using Halide::Buffer;
using Halide::Expr;
using Halide::Func;
using Halide::ImageParam;
using Halide::Var;

namespace {

constexpr int kSamples = 4096;
int failures = 0;

void check(bool condition, const std::string &what) {
    if (!condition) {
        ++failures;
        std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    }
}

Buffer<float> configuration() {
    Buffer<float> values(FOTUFILM_FRAME_CONFIGURATION_COUNT);
    values.fill(0.0f);
    for (int record = 0; record < 3; ++record) {
        float *curve = &values(FOTUFILM_CONFIG_CURVES + record * 6);
        curve[0] = 0.10f;
        curve[1] = 0.60f;
        curve[2] = -2.0f;
        curve[3] = 0.30f;
        curve[4] = 1.0f;
        curve[5] = 0.40f;
        values(FOTUFILM_CONFIG_COUPLER + record * 3 + record) = 0.2f;
        values(FOTUFILM_CONFIG_COUPLER_RELEASE_GAMMA + record) = 1.0f;
        values(FOTUFILM_CONFIG_GRAIN + record) = 0.05f;
        values(FOTUFILM_CONFIG_MOTTLE + record) = 0.02f;
        values(FOTUFILM_CONFIG_GRAIN_ANCHOR + record) = 1.0f;
        values(FOTUFILM_CONFIG_GRAIN_FOG + record) = 0.05f;
    }
    values(FOTUFILM_CONFIG_COUPLER_SCALE) = 1.0f;
    values(FOTUFILM_CONFIG_DONOR_RELEASE_GAMMA) = 1.0f;
    values(FOTUFILM_CONFIG_GRAIN_DENSITY_PROFILE) = 1.0f;
    values(FOTUFILM_CONFIG_GRAIN_DENSITY_PROFILE + 1) = 0.2f;
    values(FOTUFILM_CONFIG_GRAIN_DENSITY_PROFILE + 2) = 0.5f;
    for (int record = 0; record < 3; ++record) {
        const int row = FOTUFILM_CONFIG_GRAIN_DENSITY_RECORDS + record * 6;
        values(row) = 1.0f;
        values(row + 1) = 0.2f;
        values(row + 2) = 0.5f;
        values(row + 3) = 0.0f;
        values(row + 4) = 1.0f;
        values(row + 5) = 0.3f;
    }
    values(FOTUFILM_CONFIG_FLARE) = 0.25f;
    values(FOTUFILM_CONFIG_PRINT_SHARPEN) = 0.5f;
    return values;
}

void frame_parameters() {
    auto values = configuration();
    values(FOTUFILM_CONFIG_MTF_SIGMA) = -1;
    values(FOTUFILM_CONFIG_MTF_RADIUS) = -4;
    values(FOTUFILM_CONFIG_MTF_LUMA_RADIUS) = 2;
    values(FOTUFILM_CONFIG_MTF_SECONDARY_RADIUS + 1) = 17;
    values(FOTUFILM_CONFIG_HALATION_RADIUS) = 1000;
    values(FOTUFILM_CONFIG_DIFFUSION_RADIUS) = 1000;
    values(FOTUFILM_CONFIG_ADJACENCY_SECONDARY_SIGMA) = 8;
    values(FOTUFILM_CONFIG_ADJACENCY_SECONDARY_RADIUS) = 24;
    ResolvedFrameParams frame(values.data(), 4096, 2160, 0xfedcba98u, 1, 103, 257);
    check(frame.mtf_sigma_0 == 0.151f && frame.mtf_radius_0 == 0,
          "frame: invalid spatial controls clamp to safe limits");
    check(frame.mtf_luma_radius == 17, "frame: secondary MTF sets shared blur reach");
    check(frame.halation_stride_0 == 8 && frame.diffusion_stride_0 == 64,
          "frame: halation and diffusion keep different decimation ceilings");
    FrameParams bound("test_frame_", "");
    bound.set_frame(frame);
    check(bound.width_.get() == 4096 && bound.height_.get() == 2160
          && bound.origin_x_.get() == 103 && bound.origin_y_.get() == 257
          && bound.seed_.get() == 0xfedcba98u && bound.reversal_.get() == 1,
          "frame: binding preserves whole-frame coordinates and unsigned seed");
    check(bound.mtf_luma_radius_.get() == 17
          && bound.diffusion_stride_0_.get() == 64
          && bound.adjacency_secondary_sigma_.get() == 8
          && bound.adjacency_secondary_radius_.get() == 24,
          "frame: JIT binding preserves AOT spatial support");
}

struct Stage {
    ImageParam config{Halide::Float(32), 1, "config"};
    Var x{"x"}, c{"c"};
    Halide::Target target;
    Buffer<float> values = configuration();

    explicit Stage(const Halide::Target &target) : target(target) {
        config.set(values);
    }

    Expr ramp(float low, float high) const {
        return low + (high - low) * Halide::cast<float>(x) / float(kSamples - 1);
    }

    Buffer<float> realize(Func f) {
        Buffer<float> out(kSamples, 3);
        f.realize(out, target);
        out.copy_to_host();
        return out;
    }
};

float max_abs_difference(const Buffer<float> &a, const Buffer<float> &b) {
    float worst = 0.0f;
    for (int c = 0; c < 3; ++c) {
        for (int i = 0; i < kSamples; ++i) {
            worst = std::max(worst, std::fabs(a(i, c) - b(i, c)));
        }
    }
    return worst;
}

std::vector<std::pair<std::string, std::function<Func(Stage &)>>> stages() {
    return {
        {"inhibited_log_exposure_identity", [](Stage &s) {
            Func f("inhibited");
            f(s.x, s.c) = inhibited_log_exposure(s.config, s.c, s.ramp(-3.0f, 2.0f), 0.0f);
            return f;
        }},
        {"film_activation_endpoints", [](Stage &s) {
            Func f("activation");
            f(s.x, s.c) = film_activation(
                s.config, s.c, s.config(FOTUFILM_CONFIG_CURVES + s.c * 6)
                    + s.ramp(0.0f, 1.0f) * film_curve_range(s.config, s.c));
            return f;
        }},
        {"developed_density_negative", [](Stage &s) {
            Func f("developed");
            f(s.x, s.c) = developed_density(s.config, s.c, s.ramp(0.1f, 1.9f));
            return f;
        }},
        {"transmittance_round_trip", [](Stage &s) {
            Func f("round_trip");
            f(s.x, s.c) = density_of(transmittance_of(s.ramp(0.0f, 4.0f)));
            return f;
        }},
        {"print_mtf_read", [](Stage &s) {
            Func f("read");
            f(s.x, s.c) = print_mtf_read(s.config, s.ramp(1.0f, 1.0f), 0.5f);
            return f;
        }},
        {"texture_carry_identity", [](Stage &s) {
            Func f("carry");
            Expr density = s.ramp(0.2f, 2.5f);
            f(s.x, s.c) = texture_carry(s.ramp(0.0f, 8.0f), density, density, s.c);
            return f;
        }},
        {"veiling_glare_mix", [](Stage &s) {
            Func f("glare");
            f(s.x, s.c) = veiling_glare(s.config, s.ramp(0.0f, 2.0f), 1.0f);
            return f;
        }},
        {"clump_grain_scaling", [](Stage &s) {
            Func f("clump");
            f(s.x, s.c) = clump_grain(s.config, s.c, 1.0f, s.ramp(-1.0f, 1.0f), 1.0f);
            return f;
        }},
        {"grain_density_modulation", [](Stage &s) {
            Func f("modulation");
            f(s.x, s.c) = grain_density_modulation(s.config, s.c, s.ramp(0.0f, 2.0f));
            return f;
        }},
        {"coupler_chain", [](Stage &s) {
            Func f("chain");
            Expr log_exposure = s.ramp(-3.0f, 2.0f);
            Expr formed = film_density(s.config, s.c, log_exposure);
            Expr activation = film_activation(s.config, s.c, formed);
            Expr released = coupler_release(s.config, s.c, activation);
            Expr inhibition = coupler_inhibition(s.config, s.c, released, released, released);
            Expr inhibited = inhibited_log_exposure(s.config, s.c, log_exposure, inhibition);
            f(s.x, s.c) = developed_density(s.config, s.c,
                                            film_density(s.config, s.c, inhibited));
            return f;
        }},
    };
}

void verify(const std::string &name, Stage &s, const Buffer<float> &out) {
    auto at = [&](int i, int c) { return out(i, c); };
    auto near = [](float a, float b, float tolerance) { return std::fabs(a - b) <= tolerance; };
    const float *curve = &s.values(FOTUFILM_CONFIG_CURVES);
    const float range = curve[1] * (curve[4] - curve[2]);
    if (name == "inhibited_log_exposure_identity") {
        for (int i = 0; i < kSamples; ++i) {
            const float expected = -3.0f + 5.0f * float(i) / float(kSamples - 1);
            check(near(at(i, 1), expected, 1e-6f), name + ": no inhibition must change nothing");
        }
    } else if (name == "film_activation_endpoints") {
        check(near(at(0, 0), 0.0f, 1e-6f), name + ": dMin is activation 0");
        check(near(at(kSamples - 1, 2), 1.0f, 1e-5f), name + ": dMax is activation 1");
    } else if (name == "developed_density_negative") {
        for (int i = 0; i < kSamples; i += 97) {
            const float formed = 0.1f + 1.8f * float(i) / float(kSamples - 1);
            check(near(at(i, 0), formed, 1e-6f), name + ": a negative delivers what it formed");
        }
    } else if (name == "transmittance_round_trip") {
        for (int i = 0; i < kSamples; i += 61) {
            const float density = 4.0f * float(i) / float(kSamples - 1);
            check(near(at(i, 0), density, 2e-5f * (1.0f + density)),
                  name + ": density survives the transmittance round trip");
        }
    } else if (name == "print_mtf_read") {
        check(near(at(7, 0), 0.75f, 1e-6f), name + ": keep 0.5 returns half the detail");
    } else if (name == "texture_carry_identity") {
        for (int i = 0; i < kSamples; i += 53) {
            const float source = 8.0f * float(i) / float(kSamples - 1);
            check(at(i, 0) == source && at(i, 1) == source,
                  name + ": equal developments leave the source alone, negative or reversal");
        }
    } else if (name == "veiling_glare_mix") {
        check(near(at(0, 0), 0.25f, 1e-6f), name + ": black picks up the glare");
        check(near(at(kSamples - 1, 0), 1.75f, 1e-6f), name + ": the mix is linear");
    } else if (name == "clump_grain_scaling") {
        check(near(at(0, 0), -0.05f + 0.02f, 1e-6f), name + ": amplitude scales the field");
        check(near(at(kSamples - 1, 0), 0.05f + 0.02f, 1e-6f), name + ": mottle adds its share");
    } else if (name == "grain_density_modulation") {
        const int anchor = (kSamples - 1) / 2;
        check(near(at(anchor, 0), 1.0f, 1e-3f), name + ": unity at the anchor density");
        float peak = 0.0f;
        for (int i = 0; i < kSamples; ++i) peak = std::max(peak, at(i, 0));
        check(at(0, 0) < peak && at(kSamples - 1, 0) < peak,
              name + ": the curve peaks above D-min and falls");
        for (int i = 0; i < kSamples; ++i) {
            check(std::isfinite(at(i, 0)) && at(i, 0) >= 0.0f, name + ": finite and positive");
        }
    } else if (name == "coupler_chain") {
        for (int i = 0; i < kSamples; i += 31) {
            const float d = at(i, 0);
            check(d >= curve[0] - 1e-5f && d <= curve[0] + range + 1e-5f,
                  name + ": density stays between dMin and dMax");
        }
        check(at(kSamples / 2, 0) == at(kSamples / 2, 1)
                  && at(kSamples / 2, 1) == at(kSamples / 2, 2),
              name + ": three identical records develop identically");
    }
}

}  // namespace

int run(int argc, char **argv);

int main(int argc, char **argv) {
    try {
        return run(argc, argv);
    } catch (const Halide::Error &error) {
        std::fprintf(stderr, "Halide error: %s\n", error.what());
        return 1;
    }
}

int run(int argc, char **argv) {
    const std::string mode = argc > 1 ? argv[1] : "cpu";
    Halide::Target host = Halide::get_host_target().with_feature(Halide::Target::StrictFloat);
    Halide::Target gpu = host;
    if (mode == "metal") gpu = Halide::get_host_target().with_feature(Halide::Target::Metal);
    else if (mode != "cpu") { std::fprintf(stderr, "usage: test-stages cpu|metal\n"); return 2; }

    frame_parameters();
    int compared = 0;
    for (auto &[name, build] : stages()) {
        const int before = failures;
        Stage reference(host);
        Func on_host = build(reference);
        Buffer<float> expected = reference.realize(on_host);
        verify(name, reference, expected);
        if (mode == "metal") {
            Stage device(gpu);
            Func on_device = build(device);
            Var block("block"), thread("thread");
            on_device.compute_root().bound(device.c, 0, 3).reorder(device.c, device.x)
                .unroll(device.c)
                .gpu_tile(device.x, block, thread, 64, Halide::TailStrategy::GuardWithIf);
            Buffer<float> actual = device.realize(on_device);
            const float worst = max_abs_difference(expected, actual);
            check(worst <= 2e-5f, name + ": CPU and Metal disagree by " + std::to_string(worst));
            ++compared;
        }
        std::printf("%-34s %s\n", name.c_str(), failures == before ? "ok" : "FAILED");
    }
    std::printf("stages=%zu compared_on_gpu=%d failures=%d\n", stages().size(), compared,
                failures);
    return failures ? 1 : 0;
}
