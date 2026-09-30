#include "fotufilm_codecs.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {
int assertions = 0;
void require(bool value, const std::string &message) {
    ++assertions;
    if (!value) { std::fprintf(stderr, "%s\n", message.c_str()); std::exit(1); }
}
struct Image {
    ffc_image value{};
    uint32_t sourceWidth = 0, sourceHeight = 0;
    ~Image() { ffc_image_free(&value); }
};
ffc_raw_limits limits{512ull << 20, 120000000, 1ull << 30};
std::string root;
void decode(const std::string &name, Image &out, uint32_t edge = 0, uint32_t options = 0) {
    char error[512];
    const auto path = root + "/" + name;
    int status = ffc_decode_raw(path.c_str(), options, edge, &limits, &out.value,
                                &out.sourceWidth, &out.sourceHeight, error, sizeof error);
    require(status == FFC_RAW_OK, name + ": " + error);
    require(out.value.rgba && out.value.is_raw, name + ": missing pixels/RAW identity");
    for (size_t i = 0; i < size_t(out.value.width) * out.value.height * 4; ++i)
        require(std::isfinite(out.value.rgba[i]), name + ": nonfinite sample");
}
void close(float got, float want, float tolerance, const std::string &label) {
    if (std::abs(got - want) > tolerance)
        std::fprintf(stderr, "%s: %.9g wanted %.9g\n", label.c_str(), got, want);
    require(std::abs(got - want) <= tolerance, label);
}
}

int main(int argc, char **argv) {
    require(argc == 2 || argc == 3, "Pass the synthetic fixture directory and optionally the camera fixture directory.");
    root = argv[1];
    for (bool mosaic : {false, true}) for (uint32_t edge : {0u, 101u}) {
        const auto prefix = std::string("byte-order-") + (mosaic ? "true-" : "false-");
        Image little, big;
        decode(prefix + "true", little, edge); decode(prefix + "false", big, edge);
        require(little.value.width == big.value.width && little.value.height == big.value.height, "byte-order geometry");
        const size_t count = size_t(little.value.width) * little.value.height * 4;
        require(std::equal(little.value.rgba, little.value.rgba + count, big.value.rgba), "big/little endian source radiance");
    }
    Image original;
    decode("orientation-1", original);
    require(original.value.width == 320 && original.value.height == 192, "native size");
    require(std::string(original.value.capture.make) == "Fotufilm", "camera metadata");
    require(original.value.as_shot_kelvin > 6000 && original.value.as_shot_kelvin < 7000, "as-shot white");
    for (int orientation = 1; orientation <= 8; ++orientation) for (bool cropped : {false, true}) {
        Image image;
        decode(std::string(cropped ? "crop-" : "orientation-") + std::to_string(orientation), image);
        const uint32_t w = cropped ? 282 : 320, h = cropped ? 166 : 192;
        require(image.sourceWidth == (orientation >= 5 ? h : w) &&
                image.sourceHeight == (orientation >= 5 ? w : h), "upright source dimensions");
        require(image.value.width == image.sourceWidth && image.value.height == image.sourceHeight, "native crop dimensions");
        for (uint32_t y = 0; y < h; y += 17) for (uint32_t x = 0; x < w; x += 19) {
            uint32_t tx = x, ty = y;
            switch (orientation) {
            case 2: tx = w - 1 - x; break;
            case 3: tx = w - 1 - x; ty = h - 1 - y; break;
            case 4: ty = h - 1 - y; break;
            case 5: tx = y; ty = x; break;
            case 6: tx = h - 1 - y; ty = x; break;
            case 7: tx = h - 1 - y; ty = w - 1 - x; break;
            case 8: tx = y; ty = w - 1 - x; break;
            }
            for (int c = 0; c < 4; ++c) close(image.value.rgba[(ty * image.value.width + tx) * 4 + c],
                original.value.rgba[((y + (cropped ? 7 : 0)) * 320 + x + (cropped ? 11 : 0)) * 4 + c],
                1e-6f, "orientation/default crop");
        }
    }
    for (bool mosaic : {false, true}) for (int exposure : {-2, 0, 2}) for (bool scan : {false, true}) {
        Image image;
        decode(std::string("neutral-") + (mosaic ? "true-" : "false-") + std::to_string(exposure), image, 0,
               scan ? FFC_DECODE_SCAN : FFC_DECODE_SCENE);
        for (int band = 0; band < 3; ++band) {
            const float want = (band == 0 ? 0.02f : band == 1 ? 0.18f : 0.8f) * std::exp2(scan ? 0 : exposure);
            const size_t at = (96 * 320 + (2 * band + 1) * 320 / 6) * 4;
            for (int c = 0; c < 3; ++c) close(image.value.rgba[at + c], want, 0.002f, "recorded radiance");
        }
    }
    Image odd, small, half;
    decode("odd", odd);
    decode("odd", small, 101);
    require(small.sourceWidth == 321 && small.sourceHeight == 193, "preview retains native size");
    require(small.value.width == 101 && small.value.height == 61, "preview long edge");
    decode("half", half, 128);
    require(half.sourceWidth == 640 && half.sourceHeight == 384, "half demosaic retains native size");
    require(half.value.width == 128 && half.value.height == 77, "half demosaic bounded output");
    int distinct = 1;
    for (uint32_t x = 1; x < odd.value.width; ++x)
        if (std::abs(odd.value.rgba[x * 4] - odd.value.rgba[(x - 1) * 4]) > 1e-5f) ++distinct;
    require(distinct > 256, "source precision must exceed 8-bit");
    // None of these camera channels clipped: after undoing the as-shot white, some RGB light
    // is nevertheless above 1. A display-range intermediate loses it even without baseline gain.
    Image headroom;
    decode("headroom", headroom, 0, FFC_DECODE_SCAN);
    const float wide[3] = {1.388549f, 0.878000f, 2.604304f}; // linear sRGB [1.6,.8,2.8] -> BT.2020
    for (int c = 0; c < 3; ++c)
        close(headroom.value.rgba[(96 * 320 + 160) * 4 + c], wide[c], 0.002f, "unclipped sensor headroom");
    Image sceneHeadroom;
    decode("headroom", sceneHeadroom);
    const auto *bright = sceneHeadroom.value.rgba + (96 * 320 + 160) * 4;
    require(*std::max_element(bright, bright + 3) > 1.5f, "scene highlight blending retains floating-point range");

    // The preview samples the same linear camera values before matrix conversion. Verify its
    // pixel centres independently against the full raster, including the last row and column.
    for (uint32_t y = 0; y < small.value.height; y += 5) for (uint32_t x = 0; x < small.value.width; x += 5) {
        const double sx = (x + 0.5) * odd.value.width / small.value.width - 0.5;
        const double sy = (y + 0.5) * odd.value.height / small.value.height - 0.5;
        const uint32_t x0 = uint32_t(sx), y0 = uint32_t(sy);
        const double fx = sx - x0, fy = sy - y0;
        for (int c = 0; c < 3; ++c) {
            const auto sample = [&](uint32_t xx, uint32_t yy) { return odd.value.rgba[(yy * odd.value.width + xx) * 4 + c]; };
            const double expected = sample(x0, y0) * (1 - fx) * (1 - fy) + sample(x0 + 1, y0) * fx * (1 - fy)
                + sample(x0, y0 + 1) * (1 - fx) * fy + sample(x0 + 1, y0 + 1) * fx * fy;
            close(small.value.rgba[(y * small.value.width + x) * 4 + c], float(expected), 1e-6f, "linear preview reduction");
        }
    }

    for (int kind = 0; kind < 10; ++kind) {
        Image image;
        auto budget = limits;
        std::string path = root + "/orientation-1";
        if (kind == 0) budget.max_file_bytes = 10;
        if (kind == 1) budget.max_sensor_pixels = 10;
        if (kind == 2) budget.max_working_bytes = 1000000;
        if (kind == 3) budget.max_file_bytes = 0;
        if (kind == 4) path = root + "/missing";
        if (kind == 5) path = root + "/truncated";
        if (kind == 6) path = root + "/ordinary";
        if (kind == 7) path = root + "/bad-crop";
        if (kind == 9) budget.max_working_bytes = 37ull << 20; // linear DNG cannot demosaic at half size
        char error[128];
        int status = ffc_decode_raw(path.c_str(), kind == 8 ? 8 : 0, kind == 9 ? 64 : 0, &budget, &image.value,
                                    &image.sourceWidth, &image.sourceHeight, error, sizeof error);
        require(status == (kind == 6 ? FFC_RAW_UNSUPPORTED : FFC_RAW_ERROR), "rejected request " + std::to_string(kind));
        require(error[0] && !image.value.rgba && !image.value.capture.exif && !image.value.width &&
                !image.sourceWidth && !image.sourceHeight, "failure releases and clears result");
        ffc_image_free(&image.value); // releasing an empty failure is safe
    }
    require(ffc_decode_raw(nullptr, 0, 0, nullptr, nullptr, nullptr, nullptr, nullptr, 0) == FFC_RAW_ERROR, "null request");
    if (argc == 3) {
        root = argv[2];
        limits.max_working_bytes = 2ull << 30;
        struct Camera { const char *file; const char *model; unsigned width, height; };
        const Camera cameras[] = {{"1964", "S3Pro", 3008, 2013}, {"2249", "NIKON D700", 4284, 2844},
                                  {"2421", "X-T1", 4896, 3262}, {"4671", "EOS RP", 3910, 2612}};
        for (const auto &camera : cameras) for (unsigned edge : {1024u, 0u}) {
            Image image;
            decode(camera.file, image, edge);
            require(std::string(image.value.capture.model) == camera.model, "camera identity");
            require(image.sourceWidth == camera.width && image.sourceHeight == camera.height, "camera native frame");
            require(std::max(image.value.width, image.value.height) == (edge ? edge : camera.width), "camera preview bound");
            require(std::abs(double(image.value.width) / image.value.height - double(camera.width) / camera.height) < 0.002,
                    "preview and native aspect ratio");
            std::printf("%s %ux%u -> %ux%u passed.\n", camera.model, camera.width, camera.height,
                        image.value.width, image.value.height);
        }
    }
    std::printf("Portable RAW checks passed (%d assertions).\n", assertions);
}
