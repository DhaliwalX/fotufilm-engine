// The measuring half of a trichromatic scan (FotufilmTrichromatic.h): which light each exposure
// was made under, how exposures group into frames, how the layers line up, and the merged file's
// header. Pixels are only read here, on reduced copies and on patches; the per-pixel layer and
// merge are Halide (Pipeline/Trichromatic.h).
//
// Each binary includes this once, from the file that defines its Halide entry points
// (FotufilmNegativeScan.cpp, FotufilmHalideIOS.cpp, FotufilmHalideLinux.cpp, the browser's
// negative_wasm.cpp), which then defines fotufilm_trichromatic_layer and _merge with
// `trichromatic::merge_header`.
#ifndef FOTUFILM_TRICHROMATIC_MEASURE_H
#define FOTUFILM_TRICHROMATIC_MEASURE_H
#include "FotufilmTrichromatic.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <complex>
#include <cstring>
#include <vector>

namespace fotufilm::trichromatic {

// One light when one channel holds at least this share of the colour. White light through a colour
// negative's orange mask can pass too (red); grouping then finds too many red exposures.
constexpr float kNarrowShare = 0.5f;
// A blank exposure's spread of log transmittance (measure).
constexpr float kBlankSpread = 0.13f;

inline bool valid_size(int32_t width, int32_t height) {
    return width > 0 && height > 0 && width <= 40000 && height <= 40000
        && int64_t(width) * height <= 150000000;
}

// Row-major samples.
struct Plane {
    int width = 0, height = 0;
    std::vector<float> samples;
    float &at(int x, int y) { return samples[size_t(y) * width + x]; }
    float at(int x, int y) const { return samples[size_t(y) * width + x]; }
};

// The value below which `fraction` of a plane's finite, positive samples lie, from at most about
// a million of them.
inline float level(const float *samples, int64_t count, double fraction) {
    const int64_t step = std::max<int64_t>(1, count / 1000000);
    std::vector<float> values;
    values.reserve(size_t(count / step + 1));
    for (int64_t i = 0; i < count; i += step)
        if (std::isfinite(samples[i]) && samples[i] > 0) values.push_back(samples[i]);
    if (values.empty()) return 0;
    auto at = values.begin() + std::min<ptrdiff_t>(ptrdiff_t(values.size()) - 1,
                                                   ptrdiff_t(fraction * double(values.size())));
    std::nth_element(values.begin(), at, values.end());
    return *at;
}

// ---- Phase correlation ----

constexpr double kPi = 3.14159265358979323846;

using Complex = std::complex<double>;

inline void fft(Complex *a, int n, bool inverse) {
    for (int i = 1, j = 0; i < n; ++i) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(a[i], a[j]);
    }
    for (int length = 2; length <= n; length <<= 1) {
        const double angle = (inverse ? 2 : -2) * kPi / length;
        for (int i = 0; i < n; i += length)
            for (int k = 0; k < length / 2; ++k) {
                const Complex w = std::polar(1.0, angle * k);
                const Complex u = a[i + k], v = a[i + k + length / 2] * w;
                a[i + k] = u + v;
                a[i + k + length / 2] = u - v;
            }
    }
}

inline void fft2(std::vector<Complex> &a, int width, int height, bool inverse) {
    for (int y = 0; y < height; ++y) fft(&a[size_t(y) * width], width, inverse);
    std::vector<Complex> column(height);
    for (int x = 0; x < width; ++x) {
        for (int y = 0; y < height; ++y) column[y] = a[size_t(y) * width + x];
        fft(column.data(), height, inverse);
        for (int y = 0; y < height; ++y) a[size_t(y) * width + x] = column[y];
    }
}

inline int power_of_two_below(int n) {
    int p = 1;
    while (p * 2 <= n) p *= 2;
    return p;
}

struct Shift { double dy = 0, dx = 0, peak = 0; };

// The shift that moves patch b onto patch a (a(p) = b(p - shift)), both `width` x `height`, powers
// of two, in log transmittance. Phase correlation weighted to the band between Gaussian scales
// `fine` and `coarse` (pixels): grain finer than one, density ramps broader than the other, count
// for nothing. `peak` is 1 for a perfect match.
inline Shift phase_shift(const std::vector<float> &a, const std::vector<float> &b, int width,
                         int height, double fine, double coarse) {
    const size_t count = size_t(width) * height;
    double mean_a = 0, mean_b = 0;
    for (size_t i = 0; i < count; ++i) { mean_a += a[i]; mean_b += b[i]; }
    mean_a /= double(count);
    mean_b /= double(count);
    std::vector<double> hann_x(width), hann_y(height);
    for (int i = 0; i < width; ++i) hann_x[i] = 0.5 - 0.5 * std::cos(2 * kPi * i / (width - 1));
    for (int i = 0; i < height; ++i) hann_y[i] = 0.5 - 0.5 * std::cos(2 * kPi * i / (height - 1));
    std::vector<Complex> fa(count), fb(count);
    for (int y = 0; y < height; ++y)
        for (int x = 0; x < width; ++x) {
            const size_t i = size_t(y) * width + x;
            const double window = hann_x[x] * hann_y[y];
            fa[i] = (a[i] - mean_a) * window;
            fb[i] = (b[i] - mean_b) * window;
        }
    fft2(fa, width, height, false);
    fft2(fb, width, height, false);
    double weights = 0;
    for (int y = 0; y < height; ++y) {
        const double fy = double(y < height / 2 ? y : y - height) / height;
        for (int x = 0; x < width; ++x) {
            const double fx = double(x < width / 2 ? x : x - width) / width;
            const double f2 = 2 * kPi * kPi * (fx * fx + fy * fy);
            const double weight = std::exp(-fine * fine * f2) - std::exp(-coarse * coarse * f2);
            const size_t i = size_t(y) * width + x;
            const Complex cross = fa[i] * std::conj(fb[i]);
            fa[i] = cross / (std::abs(cross) + 1e-20) * weight;
            weights += weight;
        }
    }
    fft2(fa, width, height, true);
    // The inverse is unnormalised; a perfect match peaks at the weights' sum.
    const double norm = weights > 0 ? 1 / weights : 0;
    size_t best = 0;
    for (size_t i = 1; i < count; ++i)
        if (fa[i].real() > fa[best].real()) best = i;
    const int iy = int(best / width), ix = int(best % width);
    auto value = [&](int x, int y) {
        return fa[size_t((y + height) % height) * width + size_t((x + width) % width)].real();
    };
    auto vertex = [](double minus, double centre, double plus) {
        const double d = minus - 2 * centre + plus;
        return std::abs(d) < 1e-20 ? 0.0 : 0.5 * (minus - plus) / d;
    };
    Shift shift;
    shift.peak = value(ix, iy) * norm;
    shift.dy = iy + vertex(value(ix, iy - 1), value(ix, iy), value(ix, iy + 1));
    shift.dx = ix + vertex(value(ix - 1, iy), value(ix, iy), value(ix + 1, iy));
    if (shift.dy > height / 2.0) shift.dy -= height;
    if (shift.dx > width / 2.0) shift.dx -= width;
    return shift;
}

// ---- Registration ----

// Row/column affine: moving (row, col) = A (row, col) + t, as the merge's sampling is stated in
// x/y order at the end.
struct Affine {
    double a[2][2] = {{1, 0}, {0, 1}};
    double t[2] = {0, 0};
    void apply(double row, double col, double &out_row, double &out_col) const {
        out_row = a[0][0] * row + a[0][1] * col + t[0];
        out_col = a[1][0] * row + a[1][1] * col + t[1];
    }
};

// A layer read as log transmittance: through a floor, so clear-of-signal samples stay finite.
struct LogLayer {
    const float *samples;
    int width, height;
    float floor;
    float at(int x, int y) const {
        x = std::clamp(x, 0, width - 1);
        y = std::clamp(y, 0, height - 1);
        const float v = samples[size_t(y) * width + x];
        return std::log(std::isfinite(v) ? std::max(v, floor) : floor);
    }
    float sample(double row, double col) const {
        const double fr = std::floor(row), fc = std::floor(col);
        const int r = int(fr), c = int(fc);
        const float ty = float(row - fr), tx = float(col - fc);
        return (1 - ty) * ((1 - tx) * at(c, r) + tx * at(c + 1, r))
            + ty * ((1 - tx) * at(c, r + 1) + tx * at(c + 1, r + 1));
    }
};

struct Patches {
    std::vector<std::array<double, 2>> centres, shifts;
    std::vector<double> peaks;
};

// Shifts that move the warped moving layer onto the reference, on a grid of `size` patches across
// the middle of the frame (the holder and the film's edges stay out), kept where the match is
// clear and the shift within `limit`.
inline Patches patch_shifts(const LogLayer &reference, const LogLayer &moving, const Affine &warp,
                            int size, double limit, int across_short, int across_long,
                            double fine, double coarse) {
    const int height = reference.height, width = reference.width;
    const bool wide = width >= height;
    const int rows = wide ? across_short : across_long, cols = wide ? across_long : across_short;
    Patches found;
    std::vector<float> a(size_t(size) * size), b(a.size());
    for (int j = 0; j < rows; ++j)
        for (int i = 0; i < cols; ++i) {
            const double cy = height * (0.18 + 0.64 * (rows > 1 ? double(j) / (rows - 1) : 0.5));
            const double cx = width * (0.15 + 0.70 * (cols > 1 ? double(i) / (cols - 1) : 0.5));
            const int top = int(cy - size / 2.0), left = int(cx - size / 2.0);
            for (int y = 0; y < size; ++y)
                for (int x = 0; x < size; ++x) {
                    double row, col;
                    warp.apply(top + y, left + x, row, col);
                    a[size_t(y) * size + x] = reference.at(left + x, top + y);
                    b[size_t(y) * size + x] = moving.sample(row, col);
                }
            const Shift shift = phase_shift(a, b, size, size, fine, coarse);
            if (shift.peak > 0.03 && std::abs(shift.dy) < limit && std::abs(shift.dx) < limit) {
                found.centres.push_back({top + (size - 1) / 2.0, left + (size - 1) / 2.0});
                found.shifts.push_back({shift.dy, shift.dx});
                found.peaks.push_back(shift.peak);
            }
        }
    return found;
}

// Solves the 3x3 system m x = v in place; false when singular.
inline bool solve3(double m[3][3], double v[3]) {
    for (int c = 0; c < 3; ++c) {
        int pivot = c;
        for (int r = c + 1; r < 3; ++r) if (std::abs(m[r][c]) > std::abs(m[pivot][c])) pivot = r;
        if (std::abs(m[pivot][c]) < 1e-12) return false;
        std::swap(m[c], m[pivot]);
        std::swap(v[c], v[pivot]);
        for (int r = 0; r < 3; ++r) {
            if (r == c) continue;
            const double f = m[r][c] / m[c][c];
            for (int k = c; k < 3; ++k) m[r][k] -= f * m[c][k];
            v[r] -= f * v[c];
        }
    }
    for (int c = 0; c < 3; ++c) v[c] /= m[c][c];
    return true;
}

// The affine taking `from` to `to`, weighted least squares that drops the patches it cannot
// explain (a speck of dust, a scratch on one layer only) and fits again.
inline bool fit_affine(const std::vector<std::array<double, 2>> &from,
                       const std::vector<std::array<double, 2>> &to,
                       const std::vector<double> &weights, Affine &fitted,
                       std::vector<double> &residuals, std::vector<char> &kept) {
    const size_t n = from.size();
    kept.assign(n, 1);
    residuals.assign(n, 0);
    for (int round = 0; round < 3; ++round) {
        double coefficients[2][3];
        for (int axis = 0; axis < 2; ++axis) {
            double m[3][3] = {}, v[3] = {};
            for (size_t i = 0; i < n; ++i) {
                if (!kept[i]) continue;
                const double x[3] = {from[i][0], from[i][1], 1};
                for (int r = 0; r < 3; ++r) {
                    for (int c = 0; c < 3; ++c) m[r][c] += weights[i] * x[r] * x[c];
                    v[r] += weights[i] * x[r] * to[i][axis];
                }
            }
            if (!solve3(m, v)) return false;
            std::copy(v, v + 3, coefficients[axis]);
        }
        for (int axis = 0; axis < 2; ++axis) {
            fitted.a[axis][0] = coefficients[axis][0];
            fitted.a[axis][1] = coefficients[axis][1];
            fitted.t[axis] = coefficients[axis][2];
        }
        std::vector<double> inliers;
        for (size_t i = 0; i < n; ++i) {
            double row, col;
            fitted.apply(from[i][0], from[i][1], row, col);
            residuals[i] = std::hypot(row - to[i][0], col - to[i][1]);
            if (kept[i]) inliers.push_back(residuals[i]);
        }
        std::nth_element(inliers.begin(), inliers.begin() + inliers.size() / 2, inliers.end());
        const double bound = std::max(3 * inliers[inliers.size() / 2], 0.3);
        std::vector<char> next(n);
        size_t count = 0;
        for (size_t i = 0; i < n; ++i) count += (next[i] = residuals[i] < bound);
        if (count < 6 || next == kept) break;
        kept = next;
    }
    return true;
}

struct Pass { int size; double limit; int across_short, across_long; };

// Refines `warp` pass by pass: patch shifts measured through the current warp say where each
// patch's reference point lands in the moving layer.
inline bool refine(const LogLayer &reference, const LogLayer &moving, Affine &warp,
                   const std::vector<Pass> &passes, double fine, double coarse,
                   std::vector<char> &kept) {
    const int shortest = std::min(reference.width, reference.height);
    for (const Pass &pass : passes) {
        const int size = std::max(32, std::min(pass.size, power_of_two_below(shortest / 3)));
        Patches found = patch_shifts(reference, moving, warp, size, pass.limit, pass.across_short,
                                     pass.across_long, fine, coarse);
        if (found.centres.size() < 6) return false;
        // reference(p) = warped(p - d) = moving(warp(p - d)).
        std::vector<std::array<double, 2>> to(found.centres.size());
        for (size_t i = 0; i < to.size(); ++i)
            warp.apply(found.centres[i][0] - found.shifts[i][0],
                       found.centres[i][1] - found.shifts[i][1], to[i][0], to[i][1]);
        std::vector<double> residuals;
        if (!fit_affine(found.centres, to, found.peaks, warp, residuals, kept)) return false;
    }
    return true;
}

// A layer reduced `factor` times by area.
inline Plane reduce(const float *samples, int width, int height, int factor) {
    Plane reduced;
    reduced.width = width / factor;
    reduced.height = height / factor;
    reduced.samples.assign(size_t(reduced.width) * reduced.height, 0);
    const float scale = 1.0f / float(factor * factor);
    for (int y = 0; y < reduced.height; ++y)
        for (int x = 0; x < reduced.width; ++x) {
            float sum = 0;
            for (int j = 0; j < factor; ++j)
                for (int i = 0; i < factor; ++i) {
                    const float v = samples[size_t(y * factor + j) * width + x * factor + i];
                    sum += std::isfinite(v) ? v : 0;
                }
            reduced.at(x, y) = sum * scale;
        }
    return reduced;
}

inline int32_t register_layers(const float *reference_samples, const float *moving_samples,
                               int width, int height, float affine[6], float report[3]) {
    const int64_t count = int64_t(width) * height;
    const float reference_floor = std::max(level(reference_samples, count, 0.999) * 1e-4f, 1e-20f);
    const float moving_floor = std::max(level(moving_samples, count, 0.999) * 1e-4f, 1e-20f);
    const LogLayer reference{reference_samples, width, height, reference_floor};
    const LogLayer moving{moving_samples, width, height, moving_floor};

    // A reduced pair, about 900 pixels long, first: where the layers are, then how they turn.
    const int factor = std::max(1, int(std::lround(std::max(width, height) / 900.0)));
    const Plane small_reference = reduce(reference_samples, width, height, factor);
    const Plane small_moving = reduce(moving_samples, width, height, factor);
    const LogLayer small_a{small_reference.samples.data(), small_reference.width,
                           small_reference.height, reference_floor};
    const LogLayer small_b{small_moving.samples.data(), small_moving.width, small_moving.height,
                           moving_floor};
    const int region_w = power_of_two_below(int(small_a.width * 0.76));
    const int region_h = power_of_two_below(int(small_a.height * 0.76));
    if (region_w < 64 || region_h < 64) return -4;
    const int left = (small_a.width - region_w) / 2, top = (small_a.height - region_h) / 2;
    std::vector<float> a(size_t(region_w) * region_h), b(a.size());
    for (int y = 0; y < region_h; ++y)
        for (int x = 0; x < region_w; ++x) {
            a[size_t(y) * region_w + x] = small_a.at(left + x, top + y);
            b[size_t(y) * region_w + x] = small_b.at(left + x, top + y);
        }
    const Shift global = phase_shift(a, b, region_w, region_h, 0.7, 6);
    Affine warp;
    warp.t[0] = -global.dy;
    warp.t[1] = -global.dx;
    std::vector<char> kept;
    if (!refine(small_a, small_b, warp, {{128, 24, 4, 6}, {128, 6, 5, 7}}, 0.7, 6, kept))
        return -4;
    // To the full layers: a reduced sample's centre is factor x + (factor - 1) / 2.
    const double centre = (factor - 1) / 2.0;
    for (int r = 0; r < 2; ++r)
        warp.t[r] = factor * warp.t[r] + centre * (1 - warp.a[r][0] - warp.a[r][1]);
    if (!refine(reference, moving, warp, {{256, 10, 6, 8}, {256, 3, 7, 10}, {256, 2, 7, 10}},
                1, 12, kept))
        return -4;

    // How far the patches still disagree once lined up.
    const int size = std::max(32, std::min(256, power_of_two_below(std::min(width, height) / 3)));
    Patches left_over = patch_shifts(reference, moving, warp, size, 2, 7, 10, 1, 12);
    std::vector<double> distances;
    for (const auto &shift : left_over.shifts) distances.push_back(std::hypot(shift[0], shift[1]));
    std::sort(distances.begin(), distances.end());
    report[0] = float(std::count(kept.begin(), kept.end(), 1));
    report[1] = distances.empty() ? NAN : float(distances[distances.size() / 2]);
    report[2] = distances.empty() ? NAN : float(distances[distances.size() * 9 / 10]);

    // (row, col) to x/y: x' = a11 x + a10 y + t1, y' = a01 x + a00 y + t0.
    affine[0] = float(warp.a[1][1]);
    affine[1] = float(warp.a[1][0]);
    affine[2] = float(warp.t[1]);
    affine[3] = float(warp.a[0][1]);
    affine[4] = float(warp.a[0][0]);
    affine[5] = float(warp.t[0]);
    for (int i = 0; i < 6; ++i) if (!std::isfinite(affine[i])) return -4;
    return 0;
}

// ---- Measuring an exposure ----

// `pixels` interleaved, `channels` to a pixel, the first three red, green and blue, linear.
template<typename Sample>
inline int32_t measure(const Sample *pixels, int channels, int width, int height,
                       float measured[4], int32_t &light) {
    // Cells about 512 to the long edge, averaged.
    const int factor = std::max(1, (std::max(width, height) + 511) / 512);
    const int cols = std::max(1, width / factor), rows = std::max(1, height / factor);
    std::vector<std::array<float, 3>> cells(size_t(cols) * rows);
    for (int y = 0; y < rows; ++y)
        for (int x = 0; x < cols; ++x) {
            double sum[3] = {};
            int n = 0;
            for (int j = 0; j < factor && y * factor + j < height; ++j)
                for (int i = 0; i < factor && x * factor + i < width; ++i) {
                    const Sample *p = pixels + channels * (size_t(y * factor + j) * width + x * factor + i);
                    const float v[3] = {float(p[0]), float(p[1]), float(p[2])};
                    if (!std::isfinite(v[0]) || !std::isfinite(v[1]) || !std::isfinite(v[2])) continue;
                    for (int c = 0; c < 3; ++c) sum[c] += v[c];
                    ++n;
                }
            for (int c = 0; c < 3; ++c) cells[size_t(y) * cols + x][c] = n ? float(sum[c] / n) : 0;
        }
    // The middle of the frame: the holder and whatever lies beyond the film stay out.
    const int x0 = cols * 15 / 100, x1 = std::max(x0 + 1, cols * 85 / 100);
    const int y0 = rows * 15 / 100, y1 = std::max(y0 + 1, rows * 85 / 100);
    double colour[3] = {};
    for (int y = y0; y < y1; ++y)
        for (int x = x0; x < x1; ++x)
            for (int c = 0; c < 3; ++c) colour[c] += cells[size_t(y) * cols + x][c];
    const double area = double(x1 - x0) * (y1 - y0);
    for (int c = 0; c < 3; ++c) measured[c] = float(colour[c] / area);
    measured[3] = 0;
    const float positive[3] = {std::max(measured[0], 0.0f), std::max(measured[1], 0.0f),
                               std::max(measured[2], 0.0f)};
    const float total = positive[0] + positive[1] + positive[2];
    const int strongest = int(std::max_element(positive, positive + 3) - positive);
    const float length2 = measured[0] * measured[0] + measured[1] * measured[1]
        + measured[2] * measured[2];
    if (!(total > 0) || !(length2 > 0) || positive[strongest] < kNarrowShare * total) {
        light = FOTUFILM_TRICHROMATIC_OTHER;
        return 0;
    }
    // How far the layer's log transmittance spreads over the middle of the frame. A blank's spread
    // is its light's falloff and the leader's fog; on a test roll blanks spread 0.05 to
    // 0.12, pictures 0.21 and more.
    double sum = 0, sum2 = 0;
    int counted = 0;
    float most = 0;
    for (const auto &cell : cells)
        most = std::max(most, (cell[0] * measured[0] + cell[1] * measured[1]
                               + cell[2] * measured[2]) / length2);
    const float floor = std::max(most * 1e-3f, 1e-20f);
    for (int y = y0; y < y1; ++y)
        for (int x = x0; x < x1; ++x) {
            const auto &cell = cells[size_t(y) * cols + x];
            const double v = std::log(std::max(
                (cell[0] * measured[0] + cell[1] * measured[1] + cell[2] * measured[2]) / length2,
                floor));
            sum += v;
            sum2 += v * v;
            ++counted;
        }
    const double mean = sum / counted;
    measured[3] = float(std::sqrt(std::max(0.0, sum2 / counted - mean * mean)));
    light = measured[3] < kBlankSpread ? FOTUFILM_TRICHROMATIC_BLANK : strongest;
    return 0;
}

// The layer stage's parameters: the light's colour over its squared length. False when there is
// no colour.
inline bool layer_weights(const float colour[3], float weights[3]) {
    if (!colour) return false;
    const float length2 = colour[0] * colour[0] + colour[1] * colour[1] + colour[2] * colour[2];
    if (!std::isfinite(length2) || !(length2 > 0)) return false;
    for (int c = 0; c < 3; ++c) weights[c] = colour[c] / length2;
    return true;
}

// ---- Grouping ----

inline int32_t group(const int32_t *lights, int32_t count, int32_t *frames) {
    struct Run { int32_t light; std::vector<int32_t> members; };
    std::vector<Run> runs;
    for (int32_t i = 0; i < count; ++i) {
        const int32_t light = lights[i];
        if (light < FOTUFILM_TRICHROMATIC_RED || light > FOTUFILM_TRICHROMATIC_BLUE) continue;
        if (runs.empty() || runs.back().light != light) runs.push_back({light, {}});
        runs.back().members.push_back(i);
    }
    int32_t made = 0;
    for (size_t k = 0; k < runs.size(); k += 3) {
        const bool fits = k + 2 < runs.size()
            && runs[k].light != runs[k + 1].light && runs[k].light != runs[k + 2].light
            && runs[k + 1].light != runs[k + 2].light
            && runs[k].members.size() == runs[k + 1].members.size()
            && runs[k].members.size() == runs[k + 2].members.size();
        if (!fits) return -(1 + runs[k].members.front());
        for (size_t j = 0; j < runs[k].members.size(); ++j, ++made)
            for (size_t r = k; r < k + 3; ++r)
                frames[3 * made + runs[r].light] = runs[r].members[j];
    }
    return made;
}

// ---- The merged file ----

constexpr int kStripRows = 64;

inline int64_t strips(int32_t height) { return (height + kStripRows - 1) / kStripRows; }

// Where the pixels start: after the header, the directory and its arrays, on 16 bytes.
inline int64_t pixel_offset(int32_t height) {
    const int64_t directory = 8 + 2 + 12 * 12 + 4;
    return (directory + 6 + 6 + 8 * strips(height) + 15) / 16 * 16;
}

inline int64_t file_size(int32_t width, int32_t height) {
    return pixel_offset(height) + int64_t(width) * height * 6;
}

// Writes the header of an uncompressed, untagged 16-bit RGB TIFF, little-endian, in strips of
// kStripRows rows, and the merge's parameters; the pixels go at pixel_offset. False for bad input.
inline bool merge_header(const float *red, const float *green, const float *blue, int32_t width,
                         int32_t height, const float green_affine[6], const float blue_affine[6],
                         uint8_t *file, int64_t size, float parameters[15]) {
    if (!red || !green || !blue || !green_affine || !blue_affine || !file
        || !valid_size(width, height) || size < file_size(width, height))
        return false;
    for (int i = 0; i < 6; ++i)
        if (!std::isfinite(green_affine[i]) || !std::isfinite(blue_affine[i])) return false;
    const uint16_t probe = 1;
    if (*reinterpret_cast<const uint8_t *>(&probe) != 1) return false;
    const int64_t count = int64_t(width) * height;
    const float *layers[3] = {red, green, blue};
    std::copy(green_affine, green_affine + 6, parameters);
    std::copy(blue_affine, blue_affine + 6, parameters + 6);
    for (int c = 0; c < 3; ++c) {
        // The clear end of the layer (the film's base, or bare light) near the top of the range.
        const float clear = level(layers[c], count, 0.999);
        if (!(clear > 0)) return false;
        parameters[12 + c] = 60000.0f / clear;
    }

    std::memset(file, 0, size_t(pixel_offset(height)));
    uint8_t *p = file;
    auto put16 = [&](uint16_t v) { std::memcpy(p, &v, 2); p += 2; };
    auto put32 = [&](uint32_t v) { std::memcpy(p, &v, 4); p += 4; };
    const uint32_t n = uint32_t(strips(height));
    const uint32_t directory = 8, extra = directory + 2 + 12 * 12 + 4;
    const uint32_t bits_at = extra, format_at = extra + 6, offsets_at = extra + 12,
                   counts_at = offsets_at + 4 * n;
    put16(0x4949); put16(42); put32(directory);
    put16(12);
    auto entry = [&](uint16_t tag, uint16_t type, uint32_t values, uint32_t value) {
        put16(tag); put16(type); put32(values);
        if (type == 3 && values == 1) { put16(uint16_t(value)); put16(0); } else put32(value);
    };
    const uint16_t SHORT = 3, LONG = 4;
    entry(256, LONG, 1, uint32_t(width));
    entry(257, LONG, 1, uint32_t(height));
    entry(258, SHORT, 3, bits_at);
    entry(259, SHORT, 1, 1);                       // no compression
    entry(262, SHORT, 1, 2);                       // RGB
    entry(273, LONG, n, n == 1 ? uint32_t(pixel_offset(height)) : offsets_at);
    entry(274, SHORT, 1, 1);                       // upright
    entry(277, SHORT, 1, 3);
    entry(278, LONG, 1, kStripRows);
    const uint32_t full_strip = uint32_t(width) * kStripRows * 6;
    const uint32_t last_strip = uint32_t(width) * uint32_t(height - (int32_t(n) - 1) * kStripRows) * 6;
    entry(279, LONG, n, n == 1 ? last_strip : counts_at);
    entry(284, SHORT, 1, 1);                       // chunky
    entry(339, SHORT, 3, format_at);               // unsigned integers
    put32(0);
    for (int i = 0; i < 3; ++i) put16(16);
    for (int i = 0; i < 3; ++i) put16(1);
    if (n > 1) {
        for (uint32_t s = 0; s < n; ++s) put32(uint32_t(pixel_offset(height)) + s * full_strip);
        for (uint32_t s = 0; s < n; ++s) put32(s + 1 < n ? full_strip : last_strip);
    }
    return true;
}

}  // namespace fotufilm::trichromatic

extern "C" int32_t fotufilm_trichromatic_measure(const float *rgba, int32_t width, int32_t height,
                                                 float measured[4], int32_t *light) {
    if (!rgba || !measured || !light || !fotufilm::trichromatic::valid_size(width, height)) return -1;
    return fotufilm::trichromatic::measure(rgba, 4, width, height, measured, *light);
}

extern "C" int32_t fotufilm_trichromatic_group(const int32_t *lights, int32_t count,
                                               int32_t *frames) {
    if (count < 0 || (count && (!lights || !frames))) return -1;
    return fotufilm::trichromatic::group(lights, count, frames);
}

extern "C" int32_t fotufilm_trichromatic_register(const float *reference, const float *moving,
                                                  int32_t width, int32_t height, float affine[6],
                                                  float report[3]) {
    if (!reference || !moving || !affine || !report
        || !fotufilm::trichromatic::valid_size(width, height))
        return -1;
    return fotufilm::trichromatic::register_layers(reference, moving, width, height, affine, report);
}

extern "C" int64_t fotufilm_trichromatic_file_size(int32_t width, int32_t height) {
    return fotufilm::trichromatic::valid_size(width, height)
        ? fotufilm::trichromatic::file_size(width, height) : -1;
}
#endif
