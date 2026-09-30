#include "../Sources/CFotufilmCodecs/Codecs.hpp"
#include <tiffio.h>
#include <lcms2.h>
#include <fstream>
#include <limits>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <set>

namespace {
size_t checks = 0;
void require(bool pass, const std::string &message) { ++checks; if (!pass) throw std::runtime_error(message); }
struct Image { ffc_image value{}; ~Image() { ffc_image_free(&value); } };
// A project-authored CMYK test profile: all inks affect only neutral lightness.
std::vector<uint8_t> cmykProfile() {
    cmsHPROFILE p = cmsCreateProfilePlaceholder(nullptr);
    cmsSetProfileVersion(p, 2.1); cmsSetDeviceClass(p, cmsSigInputClass);
    cmsSetColorSpace(p, cmsSigCmykData); cmsSetPCS(p, cmsSigLabData);
    cmsWriteTag(p, cmsSigMediaWhitePointTag, cmsD50_XYZ());
    auto *lut = cmsPipelineAlloc(nullptr, 4, 3);
    auto *clut = cmsStageAllocCLut16bit(nullptr, 2, 4, 3, nullptr);
    cmsStageSampleCLut16bit(clut, [](const cmsUInt16Number *in, cmsUInt16Number *out, void *) -> int {
        cmsCIELab lab{100 - (in[0] + in[1] + in[2] + in[3]) * (100.0 / (4 * 65535)), 0, 0};
        cmsFloat2LabEncodedV2(out, &lab); return 1;
    }, nullptr, 0);
    cmsPipelineInsertStage(lut, cmsAT_END, clut);
    require(cmsWriteTag(p, cmsSigAToB0Tag, lut), "write CMYK transform"); cmsPipelineFree(lut);
    cmsUInt32Number size = 0; require(cmsSaveProfileToMem(p, nullptr, &size), "measure CMYK profile");
    std::vector<uint8_t> result(size); require(cmsSaveProfileToMem(p, result.data(), &size), "write CMYK profile");
    cmsCloseProfile(p); return result;
}
struct Spec {
    std::string name;
    uint32_t width = 73, height = 41;
    uint16_t bits = 16, format = SAMPLEFORMAT_UINT, photo = PHOTOMETRIC_RGB;
    uint16_t planar = PLANARCONFIG_CONTIG, orientation = 1, compression = COMPRESSION_ADOBE_DEFLATE;
    int alpha = 0;
    bool tiled = false, big = false, little = true, profile = true, junk = false;
};
std::array<float, 4> source(uint32_t x, uint32_t y, const Spec &s) {
    if (s.name == "nonfinite") return {NAN, 0, 0, 1};
    if (s.name == "invalid-alpha") return {0, 0, 0, 2};
    if (s.name == "precision") { float v = float(y * s.width + x) / 65535; return {v, v, v, 1}; }
    const bool grey = s.photo == PHOTOMETRIC_MINISBLACK || s.photo == PHOTOMETRIC_MINISWHITE;
    float r = float((x * 13 + y * 7) % 97) / 96, g = grey ? r : float((x * 3 + y * 17) % 89) / 88,
        b = grey ? r : float((x * 19 + y) % 83) / 82;
    if (s.format == SAMPLEFORMAT_IEEEFP) { r = r * 5 - 0.2f; g = g * 2; b = b * 3; }
    if (s.name.find("palette-reference-") == 0) {
        const int depth = std::stoi(s.name.substr(18)); const uint32_t count = 1u << depth;
        const uint32_t index = uint32_t(std::round(r * (count - 1)));
        auto channel = [&](int c) { return float((index * (c * 17 + 1) % count) * 65535 / (count - 1)) / 65535; };
        return {channel(0), channel(1), channel(2), 1};
    }
    float a = s.alpha ? float((x + y) % 5) / 4 : 1;
    return {r, g, b, a};
}
void write(const std::filesystem::path &path, const Spec &s) {
    std::string mode = std::string("w") + (s.big ? "8" : "") + (s.little ? "l" : "b");
    TIFF *t = TIFFOpen(path.c_str(), mode.c_str()); require(t != nullptr, "fixture open");
    const int colours = s.photo == PHOTOMETRIC_MINISBLACK || s.photo == PHOTOMETRIC_MINISWHITE || s.photo == PHOTOMETRIC_PALETTE ? 1 : s.photo == PHOTOMETRIC_SEPARATED ? 4 : 3;
    const int channels = colours + (s.alpha ? 1 : 0) + (s.junk ? 1 : 0);
    TIFFSetField(t, TIFFTAG_IMAGEWIDTH, s.width); TIFFSetField(t, TIFFTAG_IMAGELENGTH, s.height);
    TIFFSetField(t, TIFFTAG_BITSPERSAMPLE, s.bits); TIFFSetField(t, TIFFTAG_SAMPLEFORMAT, s.format);
    TIFFSetField(t, TIFFTAG_SAMPLESPERPIXEL, channels); TIFFSetField(t, TIFFTAG_PHOTOMETRIC, s.photo);
    TIFFSetField(t, TIFFTAG_PLANARCONFIG, s.planar); TIFFSetField(t, TIFFTAG_ORIENTATION, s.orientation);
    TIFFSetField(t, TIFFTAG_COMPRESSION, s.compression);
    TIFFSetField(t, TIFFTAG_MAKE, "Synthetic"); TIFFSetField(t, TIFFTAG_MODEL, "TIFF test");
    std::vector<uint16_t> extras;
    if (s.junk) extras.push_back(EXTRASAMPLE_UNSPECIFIED);
    if (s.alpha) extras.push_back(s.alpha == 1 ? EXTRASAMPLE_UNASSALPHA : EXTRASAMPLE_ASSOCALPHA);
    if (!extras.empty()) TIFFSetField(t, TIFFTAG_EXTRASAMPLES, uint16_t(extras.size()), extras.data());
    std::vector<uint16_t> map[3];
    if (s.photo == PHOTOMETRIC_PALETTE) {
        const size_t count = size_t(1) << s.bits;
        for (int c = 0; c < 3; ++c) { map[c].resize(count); for (size_t i = 0; i < count; ++i) map[c][i] = uint16_t((i * (c * 17 + 1) % count) * 65535 / (count - 1)); }
        TIFFSetField(t, TIFFTAG_COLORMAP, map[0].data(), map[1].data(), map[2].data());
    }
    if (s.photo == PHOTOMETRIC_SEPARATED) TIFFSetField(t, TIFFTAG_INKSET, INKSET_CMYK);
    if (s.profile) {
        const auto p = s.photo == PHOTOMETRIC_SEPARATED ? cmykProfile() : ffc::displayP3Profile();
        TIFFSetField(t, TIFFTAG_ICCPROFILE, uint32_t(p.size()), p.data());
    }
    if (s.compression == COMPRESSION_JPEG) { TIFFSetField(t, TIFFTAG_JPEGQUALITY, 100); TIFFSetField(t, TIFFTAG_JPEGCOLORMODE, JPEGCOLORMODE_RGB); }
    else if (s.compression == COMPRESSION_ADOBE_DEFLATE || s.compression == COMPRESSION_LZW)
        TIFFSetField(t, TIFFTAG_PREDICTOR, s.format == SAMPLEFORMAT_IEEEFP ? PREDICTOR_FLOATINGPOINT : s.bits >= 8 ? PREDICTOR_HORIZONTAL : PREDICTOR_NONE);
    uint32_t bw = s.tiled ? 32 : s.width, bh = 16;
    if (s.tiled) { TIFFSetField(t, TIFFTAG_TILEWIDTH, bw); TIFFSetField(t, TIFFTAG_TILELENGTH, bh); }
    else TIFFSetField(t, TIFFTAG_ROWSPERSTRIP, bh);
    const int planes = s.planar == PLANARCONFIG_SEPARATE ? channels : 1;
    for (int plane = 0; plane < planes; ++plane) for (uint32_t top = 0; top < s.height; top += bh)
        for (uint32_t left = 0; left < s.width; left += bw) {
            size_t rowBytes = s.tiled ? TIFFTileRowSize(t) : TIFFScanlineSize(t);
            uint32_t rows = s.tiled ? bh : std::min(bh, s.height - top);
            std::vector<uint8_t> block(rowBytes * rows);
            for (uint32_t y = 0; y < rows; ++y) for (uint32_t x = 0; x < bw && x + left < s.width; ++x) {
                auto pixel = source(x + left, y + top, s);
                for (int c = 0; c < (planes == 1 ? channels : 1); ++c) {
                    int channel = planes == 1 ? c : plane;
                    float v = channel < colours ? (channel == 3 ? float((x + left + y + top) % 11) / 10 : pixel[channel]) : s.junk && channel == colours ? 0.371f : pixel[3];
                    if (channel < colours && s.photo == PHOTOMETRIC_MINISWHITE) v = 1 - v;
                    if (channel < colours && s.alpha == 2) v *= pixel[3];
                    const size_t sample = size_t(x) * (planes == 1 ? channels : 1) + c;
                    auto *at = block.data() + y * rowBytes;
                    if (s.bits < 8) {
                        uint32_t code = uint32_t(std::round(v * ((1 << s.bits) - 1)));
                        size_t bit = sample * s.bits;
                        at[bit / 8] |= uint8_t(code << (8 - s.bits - bit % 8));
                    } else if (s.format == SAMPLEFORMAT_UINT) {
                        if (s.bits == 8) at[sample] = uint8_t(std::round(v * 255));
                        else if (s.bits == 16) { uint16_t code = uint16_t(std::round(v * 65535)); std::memcpy(at + sample * 2, &code, 2); }
                        else { uint32_t code = uint32_t(std::round(double(v) * UINT32_MAX)); std::memcpy(at + sample * 4, &code, 4); }
                    } else if (s.bits == 16) { _Float16 half = _Float16(v); std::memcpy(at + sample * 2, &half, 2); }
                    else if (s.bits == 32) std::memcpy(at + sample * 4, &v, 4);
                    else { double d = v; std::memcpy(at + sample * 8, &d, 8); }
                }
            }
            auto index = s.tiled ? TIFFComputeTile(t, left, top, 0, plane) : TIFFComputeStrip(t, top, plane);
            require((s.tiled ? TIFFWriteEncodedTile(t, index, block.data(), block.size())
                            : TIFFWriteEncodedStrip(t, index, block.data(), block.size())) >= 0, "write fixture");
        }
    TIFFClose(t);
}
ffc_tiff_limits limits{512ull << 20, 120000000, 256ull << 20};
void decode(const std::filesystem::path &path, Image &out, uint32_t edge = 0, const ffc_tiff_limits &budget = limits) {
    char error[512]{}; uint32_t w = 0, h = 0;
    int result = ffc_decode_tiff(path.c_str(), 0, edge, &budget, &out.value, &w, &h, error, sizeof error);
    require(result == FFC_TIFF_OK, path.filename().string() + ": " + error);
    require(!out.value.is_raw && out.value.rgba && w > 0 && h > 0, "non-RAW result");
    require(std::string(out.value.capture.make) == "Synthetic", "capture make");
}
void comparePreview(const Image &full, const Image &preview) {
    const auto &a = full.value, &b = preview.value;
    for (uint32_t y = 0; y < b.height; ++y) for (uint32_t x = 0; x < b.width; ++x) {
        double px = std::max(0.0, (x + 0.5) * a.width / b.width - 0.5), py = std::max(0.0, (y + 0.5) * a.height / b.height - 0.5);
        uint32_t x0 = uint32_t(px), y0 = uint32_t(py), x1 = std::min(x0 + 1, a.width - 1), y1 = std::min(y0 + 1, a.height - 1);
        for (int c = 0; c < 4; ++c) {
            auto at = [&](uint32_t xx, uint32_t yy) { return a.rgba[(size_t(yy) * a.width + xx) * 4 + c]; };
            double expected = ((1 - (px - x0)) * at(x0, y0) + (px - x0) * at(x1, y0)) * (1 - (py - y0))
                + ((1 - (px - x0)) * at(x0, y1) + (px - x0) * at(x1, y1)) * (py - y0);
            require(std::abs(b.rgba[(size_t(y) * b.width + x) * 4 + c] - expected) < 2e-6, "linear-light preview sampling");
        }
    }
}
void reject(const std::filesystem::path &path, ffc_tiff_limits budget, int expected = FFC_TIFF_ERROR) {
    Image out; uint32_t w = 999, h = 999; char error[512]{};
    int result = ffc_decode_tiff(path.c_str(), 0, 0, &budget, &out.value, &w, &h, error, sizeof error);
    require(result == expected && !out.value.rgba && !out.value.width && !out.value.height && !w && !h && error[0], "rejected request is empty");
}
void modify(const std::filesystem::path &file, const std::function<void(TIFF *)> &edit) {
    TIFF *t = TIFFOpen(file.c_str(), "r+"); require(t != nullptr, "modify fixture");
    edit(t); require(TIFFRewriteDirectory(t), "rewrite directory"); TIFFClose(t);
}
void malformed(const std::filesystem::path &root) {
    const auto original = root / "rgb16-1.tif";
    auto copy = [&](const char *name) { auto p = root / (std::string(name) + ".tif"); std::filesystem::copy_file(original, p, std::filesystem::copy_options::overwrite_existing); return p; };
    auto bad = copy("invalid-profile"); modify(bad, [](TIFF *t) { const char p[] = "invalid"; TIFFSetField(t, TIFFTAG_ICCPROFILE, sizeof p, p); }); reject(bad, limits);
    bad = copy("mismatched-profile"); modify(bad, [](TIFF *t) { auto p = cmykProfile(); TIFFSetField(t, TIFFTAG_ICCPROFILE, uint32_t(p.size()), p.data()); }); reject(bad, limits);
    bad = copy("truncated"); std::filesystem::resize_file(bad, 20); reject(bad, limits);
    bad = copy("missing-block"); modify(bad, [](TIFF *t) { uint64_t *offsets = nullptr; TIFFGetField(t, TIFFTAG_TILEOFFSETS, &offsets); offsets[0] = UINT64_C(0xFFFFFFFF); }); reject(bad, limits);
    bad = copy("dng"); modify(bad, [](TIFF *t) { uint8_t v[]{1, 4, 0, 0}; TIFFSetField(t, TIFFTAG_DNGVERSION, v); }); reject(bad, limits, FFC_TIFF_UNSUPPORTED);
    bad = copy("cfa"); modify(bad, [](TIFF *t) { uint16_t dim[]{2,2}; TIFFSetField(t, TIFFTAG_CFAREPEATPATTERNDIM, dim); }); reject(bad, limits, FFC_TIFF_UNSUPPORTED);
    bad = copy("raw-subifd");
    // Append a second directory from a DNG fixture, then point the normal first image's SubIFD at it.
    { TIFF *t = TIFFOpen(bad.c_str(), "r+"); require(t != nullptr, "subifd open");
      TIFFCreateDirectory(t); TIFFSetField(t, TIFFTAG_IMAGEWIDTH, 1); TIFFSetField(t, TIFFTAG_IMAGELENGTH, 1);
      TIFFSetField(t, TIFFTAG_BITSPERSAMPLE, 8); TIFFSetField(t, TIFFTAG_SAMPLESPERPIXEL, 1);
      TIFFSetField(t, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_CFA); TIFFSetField(t, TIFFTAG_ROWSPERSTRIP, 1);
      uint8_t pixel = 0; require(TIFFWriteEncodedStrip(t, 0, &pixel, 1) == 1, "raw subifd pixel");
      require(TIFFWriteDirectory(t), "raw directory"); require(TIFFSetDirectory(t, 1), "find raw directory");
      uint64_t offset = TIFFCurrentDirOffset(t); require(TIFFSetDirectory(t, 0), "find normal directory");
      TIFFSetField(t, TIFFTAG_SUBIFD, 1, &offset); require(TIFFRewriteDirectory(t), "link raw subifd"); TIFFClose(t); }
    reject(bad, limits, FFC_TIFF_UNSUPPORTED);
    for (const auto *name : {"nonfinite", "invalid-alpha"}) {
        Spec s{name}; s.bits = 32; s.format = SAMPLEFORMAT_IEEEFP; s.alpha = 1; s.profile = false;
        bad = root / (s.name + ".tif"); write(bad, s); reject(bad, limits);
    }
    Spec cmyk{"unprofiled-cmyk"}; cmyk.photo = PHOTOMETRIC_SEPARATED; cmyk.profile = false;
    bad = root / "unprofiled-cmyk.tif"; write(bad, cmyk); reject(bad, limits);
    { std::ofstream f(root / "not-tiff"); f << "not a TIFF"; } reject(root / "not-tiff", limits, FFC_TIFF_UNSUPPORTED);
    reject(root / "does-not-exist", limits);
    Image out; char error[1] = {'x'}; uint32_t w = 9, h = 9;
    require(ffc_decode_tiff(nullptr, 0, 0, &limits, &out.value, &w, &h, error, 1) == FFC_TIFF_ERROR && !w && !h && !error[0], "null path and short error");
    require(ffc_decode_tiff(original.c_str(), UINT32_MAX, 0, &limits, &out.value, &w, &h, nullptr, 0) == FFC_TIFF_ERROR, "unknown options");
    require(ffc_decode_tiff(original.c_str(), 0, 0, &limits, nullptr, &w, &h, nullptr, 0) == FFC_TIFF_ERROR, "null output");
    bool caught = false; try { ffc::parallelRows(256, [](uint32_t, uint32_t) { throw ffc::Failure("worker failure"); }); } catch (const ffc::Failure &) { caught = true; }
    require(caught, "worker exceptions reach caller");
}
void metadata(const std::filesystem::path &root) {
    auto path = root / "metadata.tif"; write(path, Spec{"metadata"});
    TIFF *t = TIFFOpen(path.c_str(), "r+"); require(t != nullptr, "EXIF open");
    TIFFCreateEXIFDirectory(t); TIFFSetField(t, EXIFTAG_LENSMAKE, "Synthetic lens"); TIFFSetField(t, EXIFTAG_LENSMODEL, "50mm f/2");
    TIFFSetField(t, EXIFTAG_FOCALLENGTH, 50.0); TIFFSetField(t, EXIFTAG_FNUMBER, 2.0); TIFFSetField(t, EXIFTAG_FOCALLENGTHIN35MMFILM, 75);
    uint64_t offset = 0; require(TIFFWriteCustomDirectory(t, &offset), "EXIF directory");
    require(TIFFSetDirectory(t, 0), "main image directory"); TIFFSetField(t, TIFFTAG_EXIFIFD, offset);
    require(TIFFRewriteDirectory(t), "EXIF link"); TIFFClose(t);
    Image image; decode(path, image); const auto &c = image.value.capture;
    require(std::string(c.lens_make) == "Synthetic lens" && std::string(c.lens_model) == "50mm f/2"
        && c.focal_length == 50 && c.f_number == 2 && c.focal_length_35mm == 75, "capture EXIF");
    require(!c.exif && !c.exif_length, "no full file copy in EXIF");
}

}
int main(int argc, char **argv) {
    try {
        require(argc == 2, "pass fixture directory"); std::filesystem::path root(argv[1]); std::filesystem::create_directories(root);
        std::vector<Spec> cases;
        for (uint16_t orientation = 1; orientation <= 8; ++orientation) {
            Spec s{"rgb16-" + std::to_string(orientation)}; s.orientation = orientation;
            s.tiled = orientation % 2; s.planar = orientation % 3 ? PLANARCONFIG_CONTIG : PLANARCONFIG_SEPARATE;
            s.little = orientation % 2; s.big = orientation > 4; cases.push_back(s);
        }
        for (int alpha : {1, 2}) { Spec s{"alpha-" + std::to_string(alpha)}; s.alpha = alpha; s.junk = true; s.planar = PLANARCONFIG_SEPARATE; cases.push_back(s); }
        for (uint16_t bits : {1, 2, 4, 8, 16}) { Spec s{"grey-" + std::to_string(bits)}; s.bits = bits; s.photo = PHOTOMETRIC_MINISWHITE; s.profile = false; cases.push_back(s); }
        for (uint16_t bits : {16, 32, 64}) { Spec s{"float-" + std::to_string(bits)}; s.bits = bits; s.format = SAMPLEFORMAT_IEEEFP; s.profile = false; s.tiled = true; cases.push_back(s); }
        { Spec s{"jpeg"}; s.bits = 8; s.photo = PHOTOMETRIC_YCBCR; s.compression = COMPRESSION_JPEG; cases.push_back(s); }
        { Spec s{"precision"}; s.width = 32768; s.height = 2; cases.push_back(s); }
        for (uint16_t orientation = 1; orientation <= 8; ++orientation) { Spec s{"classic-" + std::to_string(orientation)}; s.orientation = orientation; cases.push_back(s); }
        for (int alpha : {1, 2}) { Spec s{"simple-alpha-" + std::to_string(alpha)}; s.alpha = alpha; cases.push_back(s); }
        for (uint16_t bits : {1, 2, 4, 8, 16}) { Spec s{"palette-" + std::to_string(bits)}; s.photo = PHOTOMETRIC_PALETTE; s.bits = bits; s.tiled = bits % 3 == 1; cases.push_back(s); }
        { Spec s{"cmyk"}; s.photo = PHOTOMETRIC_SEPARATED; s.planar = PLANARCONFIG_SEPARATE; s.alpha = 2; s.junk = true; s.tiled = true; cases.push_back(s); }
        { Spec s{"uint32"}; s.bits = 32; s.little = false; cases.push_back(s); }
        for (uint16_t compression : {COMPRESSION_LZW, COMPRESSION_PACKBITS, COMPRESSION_NONE}) { Spec s{"compression-" + std::to_string(compression)}; s.compression = compression; cases.push_back(s); }
        for (int alpha : {1, 2}) { Spec s{"grey-alpha-" + std::to_string(alpha)}; s.photo = PHOTOMETRIC_MINISWHITE; s.alpha = alpha; s.profile = false; cases.push_back(s); }
        Image baseline; write(root / "baseline.tif", Spec{"baseline"}); decode(root / "baseline.tif", baseline);
        for (const auto &s : cases) {
            auto path = root / (s.name + ".tif"); write(path, s);
            Image full, preview; decode(path, full); decode(path, preview, 31);
            require(full.value.width == (s.orientation >= 5 ? s.height : s.width), "upright width");
            require(full.value.height == (s.orientation >= 5 ? s.width : s.height), "upright height");
            comparePreview(full, preview);
            if (s.name.find("rgb16-") == 0 || s.name.find("classic-") == 0 || s.name.find("compression-") == 0) {
                auto expected = std::vector<float>(baseline.value.rgba, baseline.value.rgba + size_t(s.width) * s.height * 4);
                auto w = s.width, h = s.height; ffc::orient(expected, w, h, s.orientation);
                require(std::equal(expected.begin(), expected.end(), full.value.rgba), "layout/orientation independent equivalence");
            }
            if (s.photo == PHOTOMETRIC_PALETTE) {
                Spec ref{"palette-reference-" + std::to_string(s.bits)}; auto path = root / (ref.name + ".tif"); write(path, ref);
                Image equivalent; decode(path, equivalent);
                require(std::equal(full.value.rgba, full.value.rgba + size_t(s.width) * s.height * 4, equivalent.value.rgba), "palette matches explicit RGB16");
            }
            if (s.photo == PHOTOMETRIC_MINISWHITE && !s.alpha) {
                const uint32_t maximum = (1u << s.bits) - 1;
                for (uint32_t y = 0; y < s.height; ++y) for (uint32_t x = 0; x < s.width; ++x) {
                    const double encoded = 1 - std::round((1 - source(x, y, s)[0]) * maximum) / maximum;
                    const double expected = encoded <= .04045 ? encoded / 12.92 : std::pow((encoded + .055) / 1.055, 2.4);
                    require(std::abs(full.value.rgba[(size_t(y) * s.width + x) * 4] - expected) < 2e-6, "white-is-zero grayscale transfer");
                }
            }
            if (s.photo == PHOTOMETRIC_SEPARATED) {
                for (uint32_t y = 0; y < s.height; ++y) for (uint32_t x = 0; x < s.width; ++x) {
                    auto input = source(x, y, s); const double alpha = std::round(input[3] * 65535) / 65535;
                    double inks = 0;
                    for (int c = 0; c < 4; ++c) { double v = c == 3 ? float((x + y) % 11) / 10 : input[c]; inks += alpha ? std::round(v * input[3] * 65535) / 65535 / alpha : 0; }
                    const double labL = 100 - inks * 25, f = (labL + 16) / 116;
                    const double expected = (labL > 8 ? f * f * f : labL / 903.296296) * alpha;
                    for (int c = 0; c < 3; ++c) require(std::abs(full.value.rgba[(size_t(y) * s.width + x) * 4 + c] - expected) < .0002, "CMYK profile uses all four inks before alpha");
                }
            }
            if (s.name.find("simple-alpha-") == 0 || s.name.find("grey-alpha-") == 0 || s.name.find("classic-") == 0) {
                ffc_capture capture{}; auto raster = ffc::decodeTIFF(path, capture); std::free(capture.exif);
                auto legacy = ffc::sceneLinear(raster, false); ffc::orient(legacy, raster.width, raster.height, raster.orientation);
                for (size_t i = 0; i < legacy.size(); ++i) require(std::abs(legacy[i] - full.value.rgba[i]) < 2e-6, "shared colour path agrees for full raster");
            }
            if (s.name == "precision") { std::set<float> levels; for (size_t i = 0; i < 65536; ++i) levels.insert(full.value.rgba[i * 4]); require(levels.size() == 65536, "retain all 16-bit levels"); }
            if (s.format == SAMPLEFORMAT_IEEEFP) { float lo = 0, hi = 0; for (size_t i = 0; i < size_t(full.value.width) * full.value.height * 4; ++i) { lo = std::min(lo, full.value.rgba[i]); hi = std::max(hi, full.value.rgba[i]); } require(lo < 0 && hi > 1, "unclipped float source"); }
            { std::ofstream dimensions(root / (s.name + ".size")); dimensions << full.value.width << " " << full.value.height; }
            FILE *pixels = std::fopen((root / (s.name + ".rgba")).c_str(), "wb");
            require(pixels != nullptr, "open reference pixels");
            const size_t count = size_t(full.value.width) * full.value.height * 4;
            require(std::fwrite(full.value.rgba, sizeof(float), count, pixels) == count, "write reference pixels"); std::fclose(pixels);
        }
        const auto file = root / "rgb16-1.tif";
        auto budget = limits; budget.max_file_bytes = 12; reject(file, budget);
        budget = limits; budget.max_pixels = 100; reject(file, budget);
        budget = limits; budget.max_working_bytes = 32; reject(file, budget);
        { Spec large{"large"}; large.width = 4000; large.height = 3000; large.profile = false; large.compression = COMPRESSION_NONE;
          write(root / "large.tif", large); budget = limits; budget.max_working_bytes = 64ull << 20;
          Image preview; decode(root / "large.tif", preview, 200, budget); reject(root / "large.tif", budget); }
        malformed(root); metadata(root);
        std::cout << "TIFF: " << cases.size() << " full/preview fixtures; " << checks << " pixel/contract checks passed\n";
    } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}
