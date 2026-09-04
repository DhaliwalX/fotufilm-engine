#include "ParityFrame.h"

#include <cstdio>

namespace parity {

void fillFrame(float *pixels) {
    for (int y = 0; y < kHeight; ++y) {
        const float down = 0.25f + 0.75f * (float)y / (float)(kHeight - 1);
        for (int x = 0; x < kWidth; ++x) {
            const float across = (float)x / (float)(kWidth - 1);
            float *pixel = pixels + ((size_t)y * kWidth + x) * 4;
            pixel[0] = (0.02f + across * 1.60f) * down;
            pixel[1] = (0.02f + across * 1.40f) * down;
            pixel[2] = (0.02f + across * 1.10f) * down;
            pixel[3] = 1.0f;
        }
    }
}

bool writeDump(const char *path, const float *pixels, int width, int height) {
    FILE *file = std::fopen(path, "wb");
    if (!file) return false;
    const int32_t header[2] = {width, height};
    bool wrote = std::fwrite(header, sizeof(header), 1, file) == 1;
    const size_t count = (size_t)width * height * 4;
    wrote = wrote && std::fwrite(pixels, sizeof(float), count, file) == count;
    std::fclose(file);
    return wrote;
}

}  // namespace parity
