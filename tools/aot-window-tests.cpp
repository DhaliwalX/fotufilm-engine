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
        || std::memcmp(header, "FSWP", 4) || (header[1] != 1 && header[1] != 2)
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
        int coupler_radius = 2;
        float fringe_sigma = 0;
        bool screened = false;
        // 0: linear P3, 1: linear Rec.709, 2: Rec.709 Gamma 2.4, 3: sRGB.
        int delivery = 0;
        bool monochrome = false;
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
        {"stride-one-limit", 65, 769, 0, 1, 1, 12},
        {"stride-one-fallback", 65, 769, 0, 1, 1, 13},
        {"chromatic-fringe-small-fallback", 65, 769, 0, 1, 1, 2, 2.0f},
        {"chromatic-fringe-fallback", 65, 769, 0, 1, 1, 2, 50.0f},
        {"screened-adjacency-fallback", 65, 769, 0, 1, 1, 2, 0, true},
        {"portrait-rec709", 1080, 1920, 0, 1, 1, 2, 0, false, 2},
        {"partial-window-srgb", 65, 513, 0, 1, 1, 2, 0, false, 3},
        {"odd-frame-linear709", 1919, 1081, 0, 1, 1, 2, 0, false, 1},
        {"portrait-monochrome-rec709", 1080, 1920, 0, 1, 1, 2, 0, false, 2, true},
        {"partial-monochrome-srgb", 65, 769, 0, 1, 1, 2, 0, false, 3, true},
        {"linear709-one-window", 32, 512, 0, 1, 1, 2, 0, false, 1},
    };
    for (const Case &test : cases) {
        auto c = configuration;
        c[FOTUFILM_CONFIG_FRAME_WIDTH] = float(test.width);
        c[FOTUFILM_CONFIG_FRAME_HEIGHT] = float(test.height);
        // Exercise changing tone over every row, including each window boundary.
        c[FOTUFILM_CONFIG_TONE_GRID_WIDTH] = FOTUFILM_TONE_GRID_EDGE;
        c[FOTUFILM_CONFIG_TONE_GRID_HEIGHT] = FOTUFILM_TONE_GRID_EDGE;
        for (int gy = 0; gy < FOTUFILM_TONE_GRID_EDGE; ++gy) {
            for (int gx = 0; gx < FOTUFILM_TONE_GRID_EDGE; ++gx) {
                const int i = gy * FOTUFILM_TONE_GRID_EDGE + gx;
                c[FOTUFILM_CONFIG_TONE_GRID_A + i] = 0.8f + 0.4f * gy / 63;
                c[FOTUFILM_CONFIG_TONE_GRID_B + i] = 0.05f * gx / 63;
            }
        }
        for (int i = 0; i < 3; ++i) c[FOTUFILM_CONFIG_MTF_RADIUS + i] = 1;
        c[FOTUFILM_CONFIG_COUPLER_SIGMA] = 0.81f;
        c[FOTUFILM_CONFIG_COUPLER_RADIUS] = float(test.coupler_radius);
        c[FOTUFILM_CONFIG_ADJACENCY_SIGMA] = 2.7f;
        c[FOTUFILM_CONFIG_ADJACENCY_RADIUS] = 8;
        c[FOTUFILM_CONFIG_ADJACENCY_MODEL] = test.screened ? 1 : 0;
        c[FOTUFILM_CONFIG_ADJACENCY_SECONDARY_SIGMA] = test.screened ? 5.0f : 0.151f;
        c[FOTUFILM_CONFIG_ADJACENCY_SECONDARY_RADIUS] = test.screened ? 15 : 0;
        c[FOTUFILM_CONFIG_CHROMATIC_FRINGE_AMOUNT] = test.fringe_sigma > 0 ? 0.2f : 0;
        c[FOTUFILM_CONFIG_CHROMATIC_FRINGE_SIGMA] = test.fringe_sigma;
        c[FOTUFILM_CONFIG_CHROMATIC_FRINGE_RADIUS] = 3 * test.fringe_sigma;
        const float halo[] = {13, 23, 39};
        std::memcpy(c.data() + FOTUFILM_CONFIG_HALATION_RADIUS, halo, sizeof(halo));
        c[FOTUFILM_CONFIG_PRINT_MTF_RADIUS] = float(test.print_radius);
        c[FOTUFILM_CONFIG_GRAIN_RADIUS] = float(test.grain_radius);
        for (int i = 0; i < 9; ++i) c[FOTUFILM_CONFIG_OUTPUT_MATRIX + i] = i % 4 == 0 ? 1 : 0;
        c[FOTUFILM_CONFIG_OUTPUT_TRANSFER] = 0;
        c[FOTUFILM_CONFIG_OUTPUT_PREMULTIPLIED] = 0;
        c[FOTUFILM_CONFIG_OUTPUT_GAMUT] = 0;
        c[FOTUFILM_CONFIG_OUTPUT_SHOULDER] = -1;
        if (test.delivery) {
            // A real display conversion reads all three channels from folded film rows.
            // Exercise both fitting branches, including saturated negative/out-of-range RGB.
            const float p3_to_709[] = {
                1.2249402f, -0.2249402f, 0,
                -0.0420570f, 1.0420570f, 0,
                -0.0196376f, -0.0786360f, 1.0982736f,
            };
            std::memcpy(c.data() + FOTUFILM_CONFIG_OUTPUT_MATRIX, p3_to_709, sizeof(p3_to_709));
            c[FOTUFILM_CONFIG_OUTPUT_GAMUT] = 1;
            c[FOTUFILM_CONFIG_OUTPUT_GAMUT + 1] = 0.2126f;
            c[FOTUFILM_CONFIG_OUTPUT_GAMUT + 2] = 0.7152f;
            c[FOTUFILM_CONFIG_OUTPUT_GAMUT + 3] = 0.0722f;
        }
        if (test.delivery >= 2) {
            c[FOTUFILM_CONFIG_OUTPUT_TRANSFER] = 1;
            const float gamma24[] = {1, 1, 1.0f / 2.4f, 0, 0, 0};
            const float srgb[] = {12.92f, 1.055f, 1.0f / 2.4f, -0.055f, 0.0031308f, 0};
            std::memcpy(c.data() + FOTUFILM_CONFIG_OUTPUT_COEFFICIENTS,
                        test.delivery == 3 ? srgb : gamma24, sizeof(gamma24));
        }
        const int mask = FOTUFILM_AOT_BASIC_STAGES
            | FOTUFILM_FRAME_ENCODE_OUT
            | (test.delivery >= 2 ? FOTUFILM_FRAME_OUTPUT_POWER : FOTUFILM_FRAME_OUTPUT_LINEAR)
            | (test.monochrome ? FOTUFILM_FRAME_MONOCHROME : 0)
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
