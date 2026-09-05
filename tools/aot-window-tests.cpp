// Render the same synthetic frames with FOTUFILM_AOT_WINDOWED=0 and =1.
// Compare their dumps to exercise window seams, changing frame data, and the
// spatial-support fallback through the shipped AOT shim. No GPU API is used here.
#include "FotufilmHalide.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <vector>

int main(int argc, char **argv) {
    if (argc != 3) {
        std::fprintf(stderr, "usage: aot-window-tests fixture.fswp output-directory\n");
        return 2;
    }
    FILE *pack = std::fopen(argv[1], "rb");
    if (!pack) return 2;
    uint32_t header[10];
    if (std::fread(header, sizeof(header), 1, pack) != 1
        || std::memcmp(header, "FSWP", 4) || header[1] != 1
        || header[6] != FOTUFILM_FRAME_CONFIGURATION_COUNT
        || header[7] != 33 || header[8] != 33 * 33 * 33 * 4) {
        std::fclose(pack);
        return 2;
    }
    std::vector<float> configuration(header[6]), exposure(header[8]);
    std::vector<float> film(header[8]), paper(header[8]);
    for (auto *values : {&configuration, &exposure, &film, &paper}) {
        if (std::fread(values->data(), sizeof(float), values->size(), pack) != values->size()) {
            std::fclose(pack);
            return 2;
        }
    }
    std::fclose(pack);
    if (!fotufilm_halide_metal_available()) return 1;
    std::filesystem::create_directories(argv[2]);

    struct Case {
        const char *name;
        int width, height, origin;
        int print_radius, grain_radius;
    };
    const Case cases[] = {
        {"first-window", 32, 512, 0, 1, 1},
        {"partial-window", 65, 513, 0, 1, 1},
        {"odd-frame", 1919, 1081, 0, 1, 1},
        {"4k", 3840, 2160, 0, 1, 1},
        {"image-reach-limit", 65, 769, 0, 2, 1},
        {"image-reach-fallback", 65, 769, 0, 3, 1},
        {"grain-reach-limit", 65, 769, 0, 1, 126},
        {"grain-reach-fallback", 65, 769, 0, 1, 127},
        {"offset-fallback", 65, 769, 7, 1, 1},
    };
    for (const Case &test : cases) {
        auto c = configuration;
        c[FOTUFILM_CONFIG_FRAME_WIDTH] = float(test.width);
        for (int i = 0; i < 3; ++i) c[FOTUFILM_CONFIG_MTF_RADIUS + i] = 1;
        c[FOTUFILM_CONFIG_COUPLER_SIGMA] = 0.81f;
        c[FOTUFILM_CONFIG_COUPLER_RADIUS] = 2;
        c[FOTUFILM_CONFIG_ADJACENCY_SIGMA] = 2.7f;
        c[FOTUFILM_CONFIG_ADJACENCY_RADIUS] = 8;
        const float halo[] = {13, 23, 39};
        std::memcpy(c.data() + FOTUFILM_CONFIG_HALATION_RADIUS, halo, sizeof(halo));
        c[FOTUFILM_CONFIG_PRINT_MTF_RADIUS] = float(test.print_radius);
        c[FOTUFILM_CONFIG_GRAIN_RADIUS] = float(test.grain_radius);
        for (int i = 0; i < 9; ++i) c[FOTUFILM_CONFIG_OUTPUT_MATRIX + i] = i % 4 == 0 ? 1 : 0;
        c[FOTUFILM_CONFIG_OUTPUT_TRANSFER] = 0;
        c[FOTUFILM_CONFIG_OUTPUT_PREMULTIPLIED] = 0;
        c[FOTUFILM_CONFIG_OUTPUT_GAMUT] = 0;
        c[FOTUFILM_CONFIG_OUTPUT_SHOULDER] = -1;
        const int mask = (FOTUFILM_AOT_ALL_STAGES
            & ~(FOTUFILM_FRAME_MTF_LUMA | FOTUFILM_FRAME_DIFFUSION))
            | FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_REALTIME
            | FOTUFILM_FRAME_ENCODE_OUT | FOTUFILM_FRAME_OUTPUT_LINEAR
            | (header[4] & (FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_REVERSAL));
        std::vector<float> input(size_t(test.width) * test.height * 4), output(input.size());
        for (int frame = 0; frame < 2; ++frame) {
            for (int y = 0; y < test.height; ++y) for (int x = 0; x < test.width; ++x) {
                const size_t i = (size_t(y) * test.width + x) * 4;
                const float u = float(x) / (test.width - 1), v = float(y) / (test.height - 1);
                const bool bright = x > test.width / 2 && (y + frame * 17) % 257 < 31;
                input[i] = bright ? 8 : 0.05f + 3 * u * u;
                input[i + 1] = bright ? 7.2f : 0.05f + 2 * v;
                input[i + 2] = 0.05f + (frame ? 1.2f : 1.5f) * (1 - u) * v;
                input[i + 3] = float((x + y) % 32) / 31;
            }
            std::printf("%s frame %d\n", test.name, frame);
            std::fflush(stdout);
            const int status = fotufilm_halide_metal_process_linear_float(
                input.data(), output.data(), test.width, test.height, test.origin, test.origin,
                c.data(), exposure.data(), film.data(), paper.data(), 33, 1, mask, 42 + frame);
            if (status) return 1;
            for (size_t i = 0; i < output.size(); ++i) {
                if (!std::isfinite(output[i]) || (i % 4 == 3 && output[i] != input[i])) return 1;
            }
            const auto path = std::filesystem::path(argv[2])
                / (std::string(test.name) + "-" + std::to_string(frame) + ".f32");
            FILE *dump = std::fopen(path.c_str(), "wb");
            if (!dump) return 2;
            const bool written = std::fwrite(output.data(), sizeof(float), output.size(), dump)
                == output.size();
            std::fclose(dump);
            if (!written) return 2;
        }
    }
    return 0;
}
