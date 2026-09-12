// Synthetic coverage regression captured from the unrolled cell walk at 50d8513.
// Run with bash tools/test-grain-coverage.sh on a Mac with Halide installed.
#include "FotufilmHalideShared.h"
#include <chrono>
#include <iomanip>
#include <iostream>
using namespace Halide;
int main(int argc, char **argv) {
    if (argc != 2 || (std::string(argv[1]) != "cpu" && std::string(argv[1]) != "metal")) {
        std::cerr << "usage: test-grain-coverage <cpu|metal>\n";
        return 2;
    }
    bool metal = std::string(argv[1]) == "metal";
    Var x("x"), y("y"), c("c"), xi("xi"), yi("yi");
    Param<float> coverage("coverage"), radius("radius");
    Param<uint32_t> seed("seed");
    Param<int> origin_x("origin_x"), origin_y("origin_y");
    Func output("grain_coverage");
    output(x, y, c) = fotufilm::boolean_coverage(x + origin_x, y + origin_y,
                                               coverage, radius, seed, c);
    Target target = get_host_target();
    // Fix arithmetic in this golden fixture across CPU and GPU drivers. The normal
    // renderer's relaxed Metal arithmetic is covered by the Swift CPU/Metal tests.
    target.set_feature(Target::StrictFloat);
    if (metal) {
        target.set_feature(Target::Metal);
        output.bound(c, 0, 4).gpu_tile(x, y, xi, yi, 8, 8);
    } else {
        output.bound(c, 0, 4).parallel(y).vectorize(x, 4);
    }
    auto start = std::chrono::steady_clock::now();
    output.compile_jit(target);
    std::cerr << "compile_seconds=" << std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count() << "\n";
    // Hash integer hit counts so harmless final float rounding cannot change the fixture.
    // Each byte is the number (0...9) of stratified sample points covered by the disc union.
    uint64_t digest = 14695981039346656037ULL;
    Buffer<float> result(32, 24, 4);
    int cases = 0;
    start = std::chrono::steady_clock::now();
    for (float cov : {0.00001f, 0.02f, 0.18f, 0.65f, 0.98f, 1.0f}) {
        coverage.set(cov);
        for (float r : {1.0f, 1.25f, 2.7f, 9.0f}) {
            radius.set(r);
            for (uint32_t value : {0u, 0x5EEDu, 0xFFFFFFFFu}) {
                seed.set(value);
                origin_x.set(cases % 2 ? -17 : 31);
                origin_y.set(cases % 2 ? 23 : -13);
                output.realize(result, target);
                result.copy_to_host();
                for (int layer = 0; layer < 4; ++layer) {
                    for (int y = 0; y < result.height(); ++y) {
                        for (int x = 0; x < result.width(); ++x) {
                            const float covered = std::min(std::max(cov, 1.0e-4f), 0.99f);
                            const int hits = int(std::lround((result(x, y, layer) + covered) * 9));
                            if (hits < 0 || hits > 9) return 1;
                            digest = (digest ^ uint64_t(hits)) * 1099511628211ULL;
                        }
                    }
                }
                ++cases;
            }
        }
    }
    std::cerr << "cases=" << cases << " render_seconds=" << std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count() << "\n";
    const uint64_t expected = 0x03b2784df34ad7f5ULL;
    std::cout << "coverage_digest=" << std::hex << digest << "\n";
    if (digest != expected) {
        std::cerr << "Resolved grain coverage differs from the original seeded cell walk.\n";
        return 1;
    }
    return 0;
}
