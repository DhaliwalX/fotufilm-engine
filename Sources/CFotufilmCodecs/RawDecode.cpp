// Camera RAW through LibRaw, with the choices the Mac's `RawDecode` makes: the sensor's linear
// light at its as-shot white, no tone, contrast, sharpening or noise reduction, highlights clipped
// where the sensor clipped, and a DNG's baseline exposure for a scene (none for a scan).
//
// Gaps against Core Image's decoder: LibRaw's demosaic (AHD) differs a little from Apple's; a
// DNG develops through its own two calibrations, but other files through LibRaw's single (Adobe,
// D65) matrix rather than Apple's profiles; Apple's per-camera exposure offsets, crops and lens
// corrections for non-DNG files are not applied; temperatures are McCamy's.
// Apple platforms decode and encode through ImageIO; this target builds empty there.
#if !defined(__APPLE__)
#include "Codecs.hpp"

#if __has_include(<libraw/libraw.h>)
#include <libraw/libraw.h>
#else
#include <libraw.h>
#endif

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>

namespace ffc {
namespace {

void check(int status, const char *what) {
    if (status != LIBRAW_SUCCESS)
        throw Failure(std::string(what) + ": " + libraw_strerror(status));
}

bool isTIFFStructure(const std::vector<uint8_t> &file) {
    return file.size() > 8 && ((file[0] == 'I' && file[1] == 'I' && file[2] == 42 && file[3] == 0)
                               || (file[0] == 'M' && file[1] == 'M' && file[2] == 0 && file[3] == 42));
}

/// The as-shot white as xy and its correlated colour temperature (McCamy), from the camera's
/// neutral and its XYZ-to-camera matrix.
void asShotWhite(const libraw_colordata_t &color, ffc_image &out) {
    double neutral[3];
    for (int c = 0; c < 3; ++c) {
        if (!(color.cam_mul[c] > 0)) return;
        neutral[c] = 1.0 / color.cam_mul[c];
    }
    const auto &m = color.cam_xyz;
    double a = m[0][0], b = m[0][1], c = m[0][2], d = m[1][0], e = m[1][1], f = m[1][2],
           g = m[2][0], h = m[2][1], i = m[2][2];
    double det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (std::fabs(det) < 1e-12) return;
    double inv[9] = {(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
                     (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
                     (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det};
    double X = inv[0] * neutral[0] + inv[1] * neutral[1] + inv[2] * neutral[2];
    double Y = inv[3] * neutral[0] + inv[4] * neutral[1] + inv[5] * neutral[2];
    double Z = inv[6] * neutral[0] + inv[7] * neutral[1] + inv[8] * neutral[2];
    double sum = X + Y + Z;
    if (!(sum > 0)) return;
    double x = X / sum, y = Y / sum;
    if (!(x > 0 && y > 0 && x + y < 1)) return;
    out.as_shot_x = float(x);
    out.as_shot_y = float(y);
    double n = (x - 0.3320) / (0.1858 - y);
    double kelvin = 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33;
    if (kelvin > 1000 && kelvin < 50000) out.as_shot_kelvin = float(kelvin);
}

/// The correlated colour temperature of a DNG calibration illuminant (EXIF LightSource), 0 when
/// it names none.
double illuminantKelvin(int code) {
    switch (code) {
    case 1: case 4: case 9: return 5500;
    case 2: case 14: return 4150;
    case 3: return 2850;
    case 10: return 6500;
    case 11: return 7500;
    case 12: return 6430;
    case 13: return 5000;
    case 15: return 3450;
    case 16: return 2940;
    case 17: return 2856;
    case 18: return 4874;
    case 19: return 6774;
    case 20: return 5503;
    case 21: return 6504;
    case 22: return 7504;
    case 23: return 5003;
    case 24: return 3200;
    default: return 0;
    }
}

double mcCamy(double x, double y) {
    double n = (x - 0.3320) / (0.1858 - y);
    return 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33;
}

/// A DNG's colour as the DNG specification (and Core Image) develops it: the two calibrations
/// blended by the as-shot white's temperature, found iteratively, then white balanced camera RGB
/// to linear Rec. 2020 with the white on D65. False when the file lacks two usable calibrations.
bool dngColour(const libraw_colordata_t &color, Matrix &toWide, ffc_image &out) {
    const auto &one = color.dng_color[0], &two = color.dng_color[1];
    double k1 = illuminantKelvin(one.illuminant), k2 = illuminantKelvin(two.illuminant);
    auto matrix = [](const float m[4][3]) {
        return Matrix{m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[2][0], m[2][1], m[2][2]};
    };
    auto calibration = [](const float m[4][4]) {
        Matrix c{m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[2][0], m[2][1], m[2][2]};
        return c[0] > 0 && c[4] > 0 && c[8] > 0 ? c : Matrix{1, 0, 0, 0, 1, 0, 0, 0, 1};
    };
    Matrix cm1 = matrix(one.colormatrix), cm2 = matrix(two.colormatrix);
    auto usable = [](const Matrix &m) { return std::fabs(m[0]) + std::fabs(m[4]) + std::fabs(m[8]) > 0; };
    if (!usable(cm1) && !usable(cm2)) return false;
    if (!usable(cm2) || k2 <= 0) { cm2 = cm1; k2 = k1; }
    if (!usable(cm1) || k1 <= 0) { cm1 = cm2; k1 = k2; }
    Matrix cc1 = calibration(one.calibration), cc2 = calibration(two.calibration);
    const auto &levels = color.dng_levels;
    Matrix ab{1, 0, 0, 0, 1, 0, 0, 0, 1};
    for (int c = 0; c < 3; ++c)
        if (levels.analogbalance[c] > 0) ab[c * 4] = levels.analogbalance[c];
    double neutral[3];
    for (int c = 0; c < 3; ++c) {
        if (!(color.cam_mul[c] > 0)) return false;
        neutral[c] = color.cam_mul[1] / color.cam_mul[c];
    }
    if (k1 > k2) { std::swap(cm1, cm2); std::swap(cc1, cc2); std::swap(k1, k2); }
    auto blend = [&](const Matrix &a, const Matrix &b, double kelvin) {
        double w = k1 == k2 || kelvin <= k1 ? 1 : kelvin >= k2 ? 0
            : (1 / kelvin - 1 / k2) / (1 / k1 - 1 / k2);
        Matrix m;
        for (int i = 0; i < 9; ++i) m[i] = w * a[i] + (1 - w) * b[i];
        return m;
    };
    // XYZ to camera at a temperature; the white is where it sends the as-shot neutral.
    double kelvin = 5000, x = 0.3457, y = 0.3585;
    Matrix cameraFromXYZ{};
    for (int pass = 0; pass < 20; ++pass) {
        cameraFromXYZ = multiply(ab, multiply(blend(cc1, cc2, kelvin), blend(cm1, cm2, kelvin)));
        Matrix inv = inverse(cameraFromXYZ);
        double X = inv[0] * neutral[0] + inv[1] * neutral[1] + inv[2] * neutral[2];
        double Y = inv[3] * neutral[0] + inv[4] * neutral[1] + inv[5] * neutral[2];
        double Z = inv[6] * neutral[0] + inv[7] * neutral[1] + inv[8] * neutral[2];
        if (!(X + Y + Z > 0)) return false;
        x = X / (X + Y + Z);
        y = Y / (X + Y + Z);
        double next = std::min(50000.0, std::max(1500.0, mcCamy(x, y)));
        if (std::fabs(next - kelvin) < 0.5) { kelvin = next; break; }
        kelvin = next;
    }
    out.as_shot_x = float(x);
    out.as_shot_y = float(y);
    out.as_shot_kelvin = float(kelvin);
    // White-balanced camera RGB is the raw signal divided by the neutral: undo that, take it to
    // XYZ, and carry the as-shot white onto D65.
    Matrix unbalance{neutral[0], 0, 0, 0, neutral[1], 0, 0, 0, neutral[2]};
    Matrix toXYZ = multiply(bradford(x, y, 0.3127, 0.3290), inverse(cameraFromXYZ));
    toWide = multiply(xyzToRec2020(), multiply(toXYZ, unbalance));
    // Neutral to Y = 1, as LibRaw's own matrix normalises white.
    double white = toWide[3] + toWide[4] + toWide[5];
    if (!(white > 0)) return false;
    for (auto &v : toWide) v /= white;
    return true;
}

} // namespace

void decodeRaw(const std::string &path, uint32_t options, uint32_t longEdge, ffc_image &out) {
    std::vector<uint8_t> file = readFile(path);
    auto raw = std::make_unique<LibRaw>(0);
    check(raw->open_buffer(file.data(), file.size()), "Could not read raw file");

    auto &data = raw->imgdata;
    // The camera's own record, as ImageIO reads it, for TIFF-based RAW (DNG, CR2, NEF, ARW, ...).
    bool isDNG = data.idata.dng_version != 0;
    std::array<double, 4> crop{};
    if (isTIFFStructure(file)) {
        try {
            const ExifFields fields = parseExif(file.data(), file.size(), out.capture);
            isDNG = fields.isDNG || isDNG;
            crop = fields.crop;
            keepExif(file.data(), file.size(), out.capture);
        } catch (const Failure &) {
        }
    }
    if (!out.capture.make[0]) copyString(out.capture.make, sizeof out.capture.make, data.idata.make);
    if (!out.capture.model[0]) copyString(out.capture.model, sizeof out.capture.model, data.idata.model);
    if (!out.capture.lens_model[0])
        copyString(out.capture.lens_model, sizeof out.capture.lens_model, data.lens.Lens);
    if (!out.capture.lens_make[0])
        copyString(out.capture.lens_make, sizeof out.capture.lens_make, data.lens.LensMake);
    if (out.capture.focal_length <= 0) out.capture.focal_length = data.other.focal_len;
    if (out.capture.f_number <= 0) out.capture.f_number = data.other.aperture;
    if (out.capture.focal_length_35mm <= 0) out.capture.focal_length_35mm = data.lens.FocalLengthIn35mmFormat;
    // The visible area before any half-size develop, which crops are stated in.
    const uint32_t visibleWidth = data.sizes.width, visibleHeight = data.sizes.height;
    const libraw_raw_inset_crop_t inset = data.sizes.raw_inset_crops[0];
    out.capture.stored_width = visibleWidth;
    out.capture.stored_height = visibleHeight;
    if (data.idata.colors != 3) throw Failure("This raw file's colour filter is not supported.");

    auto &params = data.params;
    params.output_color = 0;   // camera RGB; the matrix below is applied in float, unclipped
    params.output_bps = 16;
    params.gamm[0] = 1;
    params.gamm[1] = 1;
    params.no_auto_bright = 1;
    params.use_camera_wb = 1;
    params.use_auto_wb = 0;
    params.use_camera_matrix = 1;
    params.highlight = 0;
    params.user_flip = -1;
    const uint32_t nativeLong = std::max(visibleWidth, visibleHeight);
    // Half size where the Mac's scale factor (`RawDecode.scaleFactor`) is at most one half.
    params.half_size = longEdge > 0 && 4ull * longEdge <= nativeLong ? 1 : 0;

    check(raw->unpack(), "Could not unpack raw file");
    check(raw->dcraw_process(), "Could not develop raw file");
    int status = 0;
    std::unique_ptr<libraw_processed_image_t, void (*)(libraw_processed_image_t *)> image(
        raw->dcraw_make_mem_image(&status), LibRaw::dcraw_clear_mem);
    if (!image || status != LIBRAW_SUCCESS || image->type != LIBRAW_IMAGE_BITMAP || image->colors != 3
        || image->bits != 16)
        throw Failure("Could not develop raw file");

    float matrix[9];
    Matrix dng{};
    if (isDNG && dngColour(data.color, dng, out)) {
        for (int k = 0; k < 9; ++k) matrix[k] = float(dng[k]);
    } else {
        // Camera RGB (white balanced) to linear sRGB by LibRaw's matrix, then to Rec. 2020.
        asShotWhite(data.color, out);
        const std::array<float, 9> toWide = toRec2020({0.64f, 0.33f, 0.30f, 0.60f, 0.15f, 0.06f,
                                                       0.3127f, 0.3290f});
        for (int r = 0; r < 3; ++r)
            for (int c = 0; c < 3; ++c)
                matrix[r * 3 + c] = toWide[r * 3] * data.color.rgb_cam[0][c]
                    + toWide[r * 3 + 1] * data.color.rgb_cam[1][c]
                    + toWide[r * 3 + 2] * data.color.rgb_cam[2][c];
    }
    float exposure = 1;
    if (!(options & FFC_DECODE_SCAN) && isDNG) {
        float baseline = data.color.dng_levels.baseline_exposure;
        if (std::isfinite(baseline) && baseline > -10 && baseline < 10) exposure = std::exp2(baseline);
    }
    const float scale = exposure / 65535.0f;
    for (int k = 0; k < 9; ++k) matrix[k] *= scale;

    // The frame Core Image delivers: a DNG's default crop, else the maker's inset crop, within
    // the sensor's visible area; in the pre-turn frame, then carried through LibRaw's turn.
    const auto &sizes = data.sizes;
    if (!(crop[2] > 0 && crop[3] > 0 && crop[0] + crop[2] <= visibleWidth
          && crop[1] + crop[3] <= visibleHeight)) {
        crop = {0, 0, double(visibleWidth), double(visibleHeight)};
        if (inset.cwidth > 0 && inset.cheight > 0 && inset.cwidth != 0xFFFF
            && inset.cleft + inset.cwidth <= visibleWidth && inset.ctop + inset.cheight <= visibleHeight)
            crop = {double(inset.cleft), double(inset.ctop), double(inset.cwidth), double(inset.cheight)};
    }
    const int iw = sizes.iwidth, ih = sizes.iheight, flip = sizes.flip;
    const double shrink = double(iw) / std::max<uint32_t>(1, visibleWidth);
    const int x0 = int(std::lround(crop[0] * shrink)), y0 = int(std::lround(crop[1] * shrink));
    const int x1 = std::min(iw, x0 + int(std::lround(crop[2] * shrink)));
    const int y1 = std::min(ih, y0 + int(std::lround(crop[3] * shrink)));
    auto turned = [&](int column, int row) {
        if (flip & 1) column = iw - 1 - column;
        if (flip & 2) row = ih - 1 - row;
        return flip & 4 ? std::array<int, 2>{row, column} : std::array<int, 2>{column, row};
    };
    const auto a = turned(x0, y0), b = turned(x1 - 1, y1 - 1);
    const int left = std::min(a[0], b[0]), top = std::min(a[1], b[1]);
    const uint32_t width = uint32_t(std::abs(b[0] - a[0]) + 1), height = uint32_t(std::abs(b[1] - a[1]) + 1);
    if (left < 0 || top < 0 || left + width > image->width || top + height > image->height)
        throw Failure("Could not develop raw file");
    const uint32_t stride = image->width;
    out.width = width;
    out.height = height;
    out.is_raw = 1;
    out.content_headroom = 1;
    out.rgba = static_cast<float *>(std::malloc(size_t(width) * height * 4 * sizeof(float)));
    if (!out.rgba) throw Failure("Out of memory.");
    const auto *pixels = reinterpret_cast<const uint16_t *>(image->data);
    float *rgba = out.rgba;
    parallelRows(height, [&](uint32_t begin, uint32_t end) {
        for (uint32_t y = begin; y < end; ++y) {
            const uint16_t *row = pixels + ((size_t(top) + y) * stride + size_t(left)) * 3;
            float *o = rgba + size_t(y) * width * 4;
            for (uint32_t x = 0; x < width; ++x, row += 3, o += 4) {
                float r = row[0], g = row[1], b = row[2];
                o[0] = matrix[0] * r + matrix[1] * g + matrix[2] * b;
                o[1] = matrix[3] * r + matrix[4] * g + matrix[5] * b;
                o[2] = matrix[6] * r + matrix[7] * g + matrix[8] * b;
                o[3] = 1;
            }
        }
    });
}

} // namespace ffc

#endif
