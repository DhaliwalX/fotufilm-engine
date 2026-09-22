// Benchmark the frame pack emitted by tools/benchmark-webgpu.mjs.
// Source, dimensions, configuration, LUTs and seed match the browser benchmark.
#include "FotufilmHalide.h"
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <vector>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: benchmark-native-metal FRAME.pack\n");
        return 2;
    }
    std::ifstream file(argv[1], std::ios::binary);
    std::vector<char> bytes((std::istreambuf_iterator<char>(file)), {});
    if (bytes.size() < 40 || memcmp(bytes.data(), "FSWP", 4)) return 2;
    int32_t header[9];
    memcpy(header, bytes.data() + 4, sizeof(header));
    const int width = header[1], height = header[2], mask = header[3];
    const uint32_t seed = static_cast<uint32_t>(header[4]);
    const int count = header[5], lut_count = header[7];
    if (header[0] != 1 || width <= 0 || height <= 0 || width > 8192 || height > 8192 ||
        count != FOTUFILM_FRAME_CONFIGURATION_COUNT || lut_count != 33 * 33 * 33 * 4 ||
        bytes.size() != 40 + (count + 3 * lut_count) * sizeof(float)) return 2;
    std::vector<float> tables(count + 3 * lut_count);
    memcpy(tables.data(), bytes.data() + 40, tables.size() * sizeof(float));
    const float *configuration = tables.data(), *exposure = configuration + count;
    const float *film = exposure + lut_count, *paper = film + lut_count;
    std::vector<float> input(width * height * 4), output(input.size());
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const int i = (y * width + x) * 4;
            input[i] = 0.01 + 1.2 * x / width;
            input[i + 1] = 0.01 + 0.8 * y / height;
            input[i + 2] = 0.1 + 0.5 * (1.0 - double(x) / width);
            input[i + 3] = 1;
        }
    }
    for (bool exact : {false, true}) {
        const int features = mask | (exact ? FOTUFILM_FRAME_EXACT_MATH : 0);
        for (int run = 0; run < 7; ++run) {
            const auto start = std::chrono::steady_clock::now();
            const int status = fotufilm_halide_metal_process_linear_float(
                input.data(), output.data(), width, height, 0, 0, configuration,
                exposure, film, paper, 33, 1, features, seed);
            const double milliseconds = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - start).count();
            printf("Metal %dx%d exact=%d run=%d status=%d ms=%.3f center=%g\n",
                   width, height, exact, run, status, milliseconds,
                   output[((height / 2) * width + width / 2) * 4]);
            fflush(stdout);
            if (status) return 1;
        }
    }
}
