#include "WorkingSpace.h"

#include <algorithm>
#include <cmath>
#include <string>

namespace fotufilm {
namespace {

/// CIE xy of the three primaries and the white they are balanced to.
struct Chromaticities {
    double red[2], green[2], blue[2], white[2];
};

constexpr double kD65[2] = {0.3127, 0.3290};
/// ACES' white, which is near but not at D60 — the value the specification prints, not the one a
/// D60 blackbody gives.
constexpr double kACESWhite[2] = {0.32168, 0.33767};

constexpr Chromaticities kRec709 = {
    {0.640, 0.330}, {0.300, 0.600}, {0.150, 0.060}, {kD65[0], kD65[1]}};
constexpr Chromaticities kDisplayP3 = {
    {0.680, 0.320}, {0.265, 0.690}, {0.150, 0.060}, {kD65[0], kD65[1]}};
/// BT.2020 — the engine's scene working space.
constexpr Chromaticities kRec2020 = {
    {0.708, 0.292}, {0.170, 0.797}, {0.131, 0.046}, {kD65[0], kD65[1]}};
/// Blackmagic's DaVinci Wide Gamut.
constexpr Chromaticities kDaVinciWideGamut = {
    {0.8000, 0.3130}, {0.1682, 0.9877}, {0.0790, -0.1155}, {kD65[0], kD65[1]}};
/// AP1, shared by ACEScct and ACEScg.
constexpr Chromaticities kAP1 = {
    {0.713, 0.293}, {0.165, 0.830}, {0.128, 0.044},
    {kACESWhite[0], kACESWhite[1]}};

void multiply(const double *a, const double *b, double *out) {
    for (int row = 0; row < 3; ++row) {
        for (int column = 0; column < 3; ++column) {
            double sum = 0;
            for (int k = 0; k < 3; ++k) sum += a[row * 3 + k] * b[k * 3 + column];
            out[row * 3 + column] = sum;
        }
    }
}

void apply(const double *m, const double *v, double *out) {
    for (int row = 0; row < 3; ++row) {
        out[row] = m[row * 3] * v[0] + m[row * 3 + 1] * v[1] + m[row * 3 + 2] * v[2];
    }
}

bool invert(const double *m, double *out) {
    const double a = m[0], b = m[1], c = m[2];
    const double d = m[3], e = m[4], f = m[5];
    const double g = m[6], h = m[7], i = m[8];
    const double determinant =
        a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (determinant == 0) return false;
    const double scale = 1.0 / determinant;
    out[0] = (e * i - f * h) * scale;
    out[1] = (c * h - b * i) * scale;
    out[2] = (b * f - c * e) * scale;
    out[3] = (f * g - d * i) * scale;
    out[4] = (a * i - c * g) * scale;
    out[5] = (c * d - a * f) * scale;
    out[6] = (d * h - e * g) * scale;
    out[7] = (b * g - a * h) * scale;
    out[8] = (a * e - b * d) * scale;
    return true;
}

/// XYZ of a chromaticity at unit luminance.
void toXYZ(const double *xy, double *out) {
    out[0] = xy[0] / xy[1];
    out[1] = 1.0;
    out[2] = (1.0 - xy[0] - xy[1]) / xy[1];
}

/// The RGB-to-XYZ matrix a set of chromaticities implies: the primaries as columns, each scaled so
/// that RGB (1, 1, 1) lands exactly on the white.
void primariesToXYZ(const Chromaticities &c, double *out) {
    double red[3], green[3], blue[3], white[3];
    toXYZ(c.red, red);
    toXYZ(c.green, green);
    toXYZ(c.blue, blue);
    toXYZ(c.white, white);

    const double columns[9] = {
        red[0], green[0], blue[0],
        red[1], green[1], blue[1],
        red[2], green[2], blue[2],
    };
    double inverse[9], scale[3];
    if (!invert(columns, inverse)) {
        for (int i = 0; i < 9; ++i) out[i] = i % 4 == 0 ? 1.0 : 0.0;
        return;
    }
    apply(inverse, white, scale);
    for (int row = 0; row < 3; ++row) {
        for (int column = 0; column < 3; ++column) {
            out[row * 3 + column] = columns[row * 3 + column] * scale[column];
        }
    }
}

/// Bradford chromatic adaptation from one white to another.
void adaptation(const double *sourceWhite, const double *destinationWhite,
                double *out) {
    static const double kBradford[9] = {
        0.8951, 0.2664, -0.1614,
        -0.7502, 1.7135, 0.0367,
        0.0389, -0.0685, 1.0296,
    };
    double inverseBradford[9];
    invert(kBradford, inverseBradford);

    double source[3], destination[3], sourceCone[3], destinationCone[3];
    toXYZ(sourceWhite, source);
    toXYZ(destinationWhite, destination);
    apply(kBradford, source, sourceCone);
    apply(kBradford, destination, destinationCone);

    const double gains[9] = {
        destinationCone[0] / sourceCone[0], 0, 0,
        0, destinationCone[1] / sourceCone[1], 0,
        0, 0, destinationCone[2] / sourceCone[2],
    };
    double scaled[9];
    multiply(gains, kBradford, scaled);
    multiply(inverseBradford, scaled, out);
}

const Chromaticities &primariesOf(Encoding encoding) {
    switch (encoding) {
    case Encoding::DaVinciIntermediate: return kDaVinciWideGamut;
    case Encoding::ACEScct:
    case Encoding::ACEScg: return kAP1;
    case Encoding::LinearDisplayP3: return kDisplayP3;
    case Encoding::LinearRec2020: return kRec2020;
    case Encoding::Rec709Gamma24:
    case Encoding::SRGB:
    case Encoding::LinearRec709:
    case Encoding::Count:
    default: return kRec709;
    }
}

/// Applies `f` to the magnitude and puts the sign back.
template <typename Function>
inline float signPreserving(float value, Function f) {
    return value < 0 ? -f(-value) : f(value);
}

constexpr double kDaVinciA = 0.0075, kDaVinciB = 7.0;
constexpr double kDaVinciC = 0.07329248, kDaVinciM = 10.44426855;
constexpr double kDaVinciLinearCut = 0.00262409;
constexpr double kDaVinciLogCut = 0.02740668;

constexpr double kACESctA = 10.5402377416545, kACESctB = 0.0729055341958355;
constexpr double kACESctBreak = 0.0078125;
constexpr double kACESctLogBreak = 0.155251141552511;

}

const char *encodingLabel(Encoding encoding) {
    switch (encoding) {
    case Encoding::Rec709Gamma24: return "Rec.709 / Gamma 2.4";
    case Encoding::SRGB: return "sRGB";
    case Encoding::DaVinciIntermediate: return "DaVinci Wide Gamut / Intermediate";
    case Encoding::ACEScct: return "ACEScct (AP1)";
    case Encoding::ACEScg: return "ACEScg (AP1)";
    case Encoding::LinearRec709: return "Linear Rec.709";
    case Encoding::LinearDisplayP3: return "Linear Display P3";
    case Encoding::LinearRec2020: return "Linear Rec.2020";
    case Encoding::Count: break;
    }
    return "Rec.709 / Gamma 2.4";
}

Encoding encodingForColourspace(const char *name) {
    if (name == nullptr) return Encoding::Count;

    // Case- and punctuation-blind, so one table covers the OFX core names and a host's
    // own display spellings of the same spaces.
    std::string key;
    for (const char *c = name; *c; ++c) {
        if ((*c >= 'a' && *c <= 'z') || (*c >= '0' && *c <= '9')) key.push_back(*c);
        else if (*c >= 'A' && *c <= 'Z') key.push_back(static_cast<char>(*c - 'A' + 'a'));
    }

    /// The OFX 1.5 core colourspace names (ofx-native-v1.5_aces-v1.3_ocio-v2.3), plus common
    /// display spellings. A name that is not here — a camera log, `ofx_scene_linear` with its
    /// unstated primaries, a pure gamma 2.2 — is left unknown rather than guessed at.
    struct Alias { const char *key; Encoding encoding; };
    static const Alias kAliases[] = {
        {"rec709gamma24", Encoding::Rec709Gamma24},
        {"gamma24rec709", Encoding::Rec709Gamma24},
        {"g24rec709tx", Encoding::Rec709Gamma24},
        {"srgb", Encoding::SRGB},
        {"srgbtx", Encoding::SRGB},
        {"davinciintermediate", Encoding::DaVinciIntermediate},
        {"davinciintermediatewidegamut", Encoding::DaVinciIntermediate},
        {"davinciwidegamutintermediate", Encoding::DaVinciIntermediate},
        {"davinciwgintermediate", Encoding::DaVinciIntermediate},
        {"acescct", Encoding::ACEScct},
        {"acescctap1", Encoding::ACEScct},
        {"acescg", Encoding::ACEScg},
        {"linap1", Encoding::ACEScg},
        {"linearrec709", Encoding::LinearRec709},
        {"linrec709", Encoding::LinearRec709},
        {"linrec709srgb", Encoding::LinearRec709},
        {"lineardisplayp3", Encoding::LinearDisplayP3},
        {"lindisplayp3", Encoding::LinearDisplayP3},
        {"linp3d65", Encoding::LinearDisplayP3},
        {"linearp3d65", Encoding::LinearDisplayP3},
        {"linrec2020", Encoding::LinearRec2020},
        {"linearrec2020", Encoding::LinearRec2020},
        {"linrec2020srgb", Encoding::LinearRec2020},
    };
    for (const Alias &alias : kAliases) {
        if (key == alias.key) return alias.encoding;
    }
    return Encoding::Count;
}

Transform transformFor(Encoding encoding) {
    const Chromaticities &source = primariesOf(encoding);

    double sourceToXYZ[9], sceneToXYZ[9], sceneFromXYZ[9];
    double printToXYZ[9], printFromXYZ[9];
    primariesToXYZ(source, sourceToXYZ);
    // Two bases, two paths: the scene goes in as linear Rec.2020, and the developed
    // print comes back in the engine's Display P3 delivery basis.
    primariesToXYZ(kRec2020, sceneToXYZ);
    invert(sceneToXYZ, sceneFromXYZ);
    primariesToXYZ(kDisplayP3, printToXYZ);
    invert(printToXYZ, printFromXYZ);

    double adapted[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    if (source.white[0] != kD65[0] || source.white[1] != kD65[1]) {
        adaptation(source.white, kD65, adapted);
    }

    double toWhite[9], toWorking[9];
    multiply(adapted, sourceToXYZ, toWhite);
    multiply(sceneFromXYZ, toWhite, toWorking);

    // The way out is the inverse of the *source to P3* path, not of `toWorking`: it will be
    // applied to print pixels that are already P3.
    double sourceToP3[9], fromWorking[9];
    multiply(printFromXYZ, toWhite, sourceToP3);
    invert(sourceToP3, fromWorking);

    // The way back out of the scene basis, which — unlike `fromWorking` — really is the inverse
    // of the way in, because the light taking it never left that basis.
    double fromScene[9];
    invert(toWorking, fromScene);

    Transform result{};
    for (int i = 0; i < 9; ++i) {
        result.toWorking[i] = static_cast<float>(toWorking[i]);
        result.fromWorking[i] = static_cast<float>(fromWorking[i]);
        result.fromScene[i] = static_cast<float>(fromScene[i]);
    }
    // Row two of the host's own RGB-to-XYZ is its CIE Y, which is the quantity the gamut fit
    // holds. Taken before the chromatic adaptation above, because it weighs the host's channels
    // as the host's own primaries define them.
    for (int i = 0; i < 3; ++i) {
        result.luminance[i] = static_cast<float>(sourceToXYZ[3 + i]);
    }
    return result;
}

bool deliveryLeavesGamut(Encoding encoding) {
    // Only the Rec.709 primaries are narrower than the Display P3 the print arrives in. Every
    // other encoding here is either P3 itself or a space that encloses it, and a colour inside
    // P3 cannot leave those.
    switch (encoding) {
    case Encoding::Rec709Gamma24:
    case Encoding::SRGB:
    case Encoding::LinearRec709:
        return true;
    case Encoding::DaVinciIntermediate:
    case Encoding::ACEScct:
    case Encoding::ACEScg:
    case Encoding::LinearDisplayP3:
    case Encoding::LinearRec2020:
    case Encoding::Count:
        break;
    }
    return false;
}

void fitToGamut(const float *luminance, float *pixel) {
    // Most of a frame is inside the container and wants nothing done to it, so the cheap test
    // comes first: four comparisons to leave those pixels alone, ahead of the luminance the rest
    // of this needs. It also states the property the fit is built on — in gamut is the identity —
    // in a form the compiler can see.
    const float lo = std::min(std::min(pixel[0], pixel[1]), pixel[2]);
    const float hi = std::max(std::max(pixel[0], pixel[1]), pixel[2]);
    if (lo >= 0.0f && hi <= 1.0f) return;

    const float y = luminance[0] * pixel[0] + luminance[1] * pixel[1]
                  + luminance[2] * pixel[2];
    if (!(y > 0.0f)) {
        // At or below black there is no chroma to hold and no axis to move along; a negative
        // luminance is only reachable from a colour already far outside, and black is the only
        // in-gamut answer for it.
        for (int c = 0; c < 3; ++c) pixel[c] = std::max(pixel[c], 0.0f);
        return;
    }
    if (!(y < 1.0f)) {
        // At and above white there is no in-gamut colour to move to: the cube pinches to white
        // at Y = 1 and stops, so any chroma up there is outside whatever this function does to
        // it. A transparency highlight that goes above white means it, and what the container
        // makes of a level it cannot hold is the host's business — this function's is the
        // gamut, not the level. A negative channel is still never right.
        for (int c = 0; c < 3; ++c) pixel[c] = std::max(pixel[c], 0.0f);
        return;
    }
    // The least move toward the neutral axis that brings every channel inside [0, 1], which
    // holds Y because the axis it moves along is the one Y is constant on. As Y approaches white
    // the fit approaches neutral, and that is the cube's own shape rather than a choice: at
    // Y = 1 the only in-gamut colour left is white itself.
    float scale = 1.0f;
    for (int c = 0; c < 3; ++c) {
        const float v = pixel[c];
        // Both denominators are strictly positive: v > 1 > y in the first, and y > 0 > v in
        // the second.
        if (v > 1.0f) scale = std::min(scale, (1.0f - y) / (v - y));
        else if (v < 0.0f) scale = std::min(scale, y / (y - v));
    }
    if (scale >= 1.0f) return;   // in gamut, and returned bit-identical
    scale = std::max(scale, 0.0f);
    for (int c = 0; c < 3; ++c) pixel[c] = y + (pixel[c] - y) * scale;
}

namespace {

/// The transfer functions, with the encoding known at compile time so that a row's worth of
/// pixels resolves it once rather than re-deciding it for every channel of every pixel. The
/// arithmetic is the runtime `toLinear`/`fromLinear` verbatim — same expressions, same order,
/// same rounding — and those two are now written in terms of these, so the two cannot drift.
template <Encoding E>
inline float toLinearFixed(float value) {
    if constexpr (E == Encoding::Rec709Gamma24) {
        return signPreserving(value, [](float v) { return std::pow(v, 2.4f); });
    } else if constexpr (E == Encoding::SRGB) {
        return signPreserving(value, [](float v) {
            return v <= 0.04045f ? v / 12.92f
                                 : std::pow((v + 0.055f) / 1.055f, 2.4f);
        });
    } else if constexpr (E == Encoding::DaVinciIntermediate) {
        // Blackmagic's published branch is on the signed encoded value. Negative DI values stay
        // on the linear toe; reflecting them through the positive log branch is not the curve.
        if (value <= static_cast<float>(kDaVinciLogCut)) {
            return value / static_cast<float>(kDaVinciM);
        }
        return static_cast<float>(
            std::pow(2.0, value / kDaVinciC - kDaVinciB) - kDaVinciA);
    } else if constexpr (E == Encoding::ACEScct) {
        if (value <= static_cast<float>(kACESctLogBreak)) {
            return static_cast<float>((value - kACESctB) / kACESctA);
        }
        return static_cast<float>(std::pow(2.0, value * 17.52 - 9.72));
    } else {
        return value;
    }
}

template <Encoding E>
inline float fromLinearFixed(float value) {
    if constexpr (E == Encoding::Rec709Gamma24) {
        return signPreserving(value, [](float v) { return std::pow(v, 1 / 2.4f); });
    } else if constexpr (E == Encoding::SRGB) {
        return signPreserving(value, [](float v) {
            return v <= 0.0031308f ? v * 12.92f
                                   : 1.055f * std::pow(v, 1 / 2.4f) - 0.055f;
        });
    } else if constexpr (E == Encoding::DaVinciIntermediate) {
        if (value <= static_cast<float>(kDaVinciLinearCut)) {
            return value * static_cast<float>(kDaVinciM);
        }
        return static_cast<float>(
            kDaVinciC * (std::log2(value + kDaVinciA) + kDaVinciB));
    } else if constexpr (E == Encoding::ACEScct) {
        if (value <= static_cast<float>(kACESctBreak)) {
            return static_cast<float>(kACESctA * value + kACESctB);
        }
        return static_cast<float>((std::log2(value) + 9.72) / 17.52);
    } else {
        return value;
    }
}

/// Whether the encoding's transfer is the identity. Where it is, the decode can skip both the
/// call and the finiteness re-check that follows it: a value that was finite going in is still
/// the same finite value coming out.
template <Encoding E>
constexpr bool kIsLinear = E != Encoding::Rec709Gamma24 && E != Encoding::SRGB &&
                           E != Encoding::DaVinciIntermediate && E != Encoding::ACEScct;

/// Calls `op.operator()<E>()` with the runtime encoding lifted into a template argument — the
/// one place the encoding is branched on, so a row resolves it once instead of per channel.
/// `Count` is not an encoding; it takes the same identity path the runtime functions give it.
template <typename Operation>
inline auto withEncoding(Encoding encoding, const Operation &op) {
    switch (encoding) {
    case Encoding::Rec709Gamma24: return op.template operator()<Encoding::Rec709Gamma24>();
    case Encoding::SRGB: return op.template operator()<Encoding::SRGB>();
    case Encoding::DaVinciIntermediate:
        return op.template operator()<Encoding::DaVinciIntermediate>();
    case Encoding::ACEScct: return op.template operator()<Encoding::ACEScct>();
    case Encoding::ACEScg: return op.template operator()<Encoding::ACEScg>();
    case Encoding::LinearRec709: return op.template operator()<Encoding::LinearRec709>();
    case Encoding::LinearDisplayP3: return op.template operator()<Encoding::LinearDisplayP3>();
    case Encoding::LinearRec2020:
    case Encoding::Count:
        break;
    }
    return op.template operator()<Encoding::LinearRec2020>();
}

/// Repair, then optionally undo the host's premultiplication, from `in` into `out`.
inline void prepare(const float *in, float *out, bool premultiplied, bool &clean) {
    float r = in[0], g = in[1], b = in[2], a = in[3];
    if (!std::isfinite(r)) { r = 0; clean = false; }
    if (!std::isfinite(g)) { g = 0; clean = false; }
    if (!std::isfinite(b)) { b = 0; clean = false; }
    if (!std::isfinite(a)) { a = 1; clean = false; }

    if (premultiplied && a > 0 && a != 1) {
        const float scale = 1.0f / a;
        r *= scale;
        g *= scale;
        b *= scale;
        // Only the division can have reintroduced infinity, so this is the row-at-a-time
        // version's second sweep, kept where it was. Alpha cannot have changed, so its half of
        // that sweep is provably a no-op and is not repeated.
        if (!std::isfinite(r)) { r = 0; clean = false; }
        if (!std::isfinite(g)) { g = 0; clean = false; }
        if (!std::isfinite(b)) { b = 0; clean = false; }
    }
    out[0] = r;
    out[1] = g;
    out[2] = b;
    out[3] = a;
}

/// The transfer decode and the step into the working space, in place. Alpha is not touched.
template <Encoding E>
inline void transferIn(const float *m, float *pixel, bool &clean) {
    float r = pixel[0], g = pixel[1], b = pixel[2];
    // A linear encoding's transfer is the identity, so both the call and the finiteness check
    // after it drop out entirely: `prepare` already left these three finite, and the identity
    // returns them unchanged.
    if constexpr (!kIsLinear<E>) {
        r = toLinearFixed<E>(r);
        g = toLinearFixed<E>(g);
        b = toLinearFixed<E>(b);
        if (!std::isfinite(r)) { r = 0; clean = false; }
        if (!std::isfinite(g)) { g = 0; clean = false; }
        if (!std::isfinite(b)) { b = 0; clean = false; }
    }
    float x = m[0] * r + m[1] * g + m[2] * b;
    float y = m[3] * r + m[4] * g + m[5] * b;
    float z = m[6] * r + m[7] * g + m[8] * b;
    if (!std::isfinite(x)) { x = 0; clean = false; }
    if (!std::isfinite(y)) { y = 0; clean = false; }
    if (!std::isfinite(z)) { z = 0; clean = false; }
    pixel[0] = x;
    pixel[1] = y;
    pixel[2] = z;
}

/// The largest finite RGB component in `count` pixels.
///
/// Three running maxima rather than one, so the scan is not a single chain of compares each
/// waiting on the last. That reordering is exact: `max` over finite values does not round and
/// does not care about order, and a maximum starting at +0 is never displaced by -0, so the three
/// combined at the end are the float a channel-by-channel walk arrives at.
inline float peakOf(const float *in, int count) {
    float red = 0, green = 0, blue = 0;
    for (int i = 0; i < count; ++i) {
        const float *pixel = in + static_cast<size_t>(i) * 4;
        if (std::isfinite(pixel[0])) red = std::max(red, pixel[0]);
        if (std::isfinite(pixel[1])) green = std::max(green, pixel[1]);
        if (std::isfinite(pixel[2])) blue = std::max(blue, pixel[2]);
    }
    return std::max(red, std::max(green, blue));
}

/// One pixel, start to finish, held in registers the whole way. The row is therefore read once
/// and written once, where the row-at-a-time form sweeps it for finiteness, copies it, divides it
/// and transforms it in four separate passes.
template <Encoding E>
inline void decodePixel(const float *m, const float *in, float *out, bool premultiplied,
                        bool &clean) {
    float pixel[4];
    prepare(in, pixel, premultiplied, clean);
    transferIn<E>(m, pixel, clean);
    std::memcpy(out, pixel, sizeof(pixel));
}

template <Encoding E>
DecodeReport decodeSpan(const Transform &transform, const float *in, float *out, int count,
                        bool premultiplied, bool watchRange) {
    const float *m = transform.toWorking;
    bool clean = true;
    float peak = 0;
    // The over-range warning quotes the host's own numbers, so the peak is read off `in` before
    // anything is repaired or decoded. It keeps the pass of its own it has always had: where the
    // transfer is a libm call, a running maximum threaded through the decode has to be spilled
    // around every one of them, and that costs more than the extra read of a row already in L1.
    if (watchRange) peak = peakOf(in, count);
    for (int i = 0; i < count; ++i) {
        decodePixel<E>(m, in + static_cast<size_t>(i) * 4, out + static_cast<size_t>(i) * 4,
                       premultiplied, clean);
    }
    return {clean, peak};
}

/// The step out of the print's delivery basis, the transfer encode, and the re-premultiplication.
inline void matrixOut(const float *m, const float *in, float *out) {
    const float r = in[0], g = in[1], b = in[2], a = in[3];
    out[0] = m[0] * r + m[1] * g + m[2] * b;
    out[1] = m[3] * r + m[4] * g + m[5] * b;
    out[2] = m[6] * r + m[7] * g + m[8] * b;
    out[3] = a;
}

inline void repremultiply(float *pixel) {
    const float a = pixel[3];
    if (a == 1) return;
    pixel[0] *= a;
    pixel[1] *= a;
    pixel[2] *= a;
}

/// Split on the same reasoning as `decodeSpan`.
template <Encoding E>
void encodeSpan(const Transform &transform, const float *in, float *out, int count,
                bool premultiplied, bool fitGamut) {
    const float *m = transform.fromWorking;
    for (int i = 0; i < count; ++i) {
        float *pixel = out + static_cast<size_t>(i) * 4;
        matrixOut(m, in + static_cast<size_t>(i) * 4, pixel);
        // Between the matrix and the transfer: the fit is defined on linear light in the host's
        // own primaries, which is exactly what the matrix has just produced.
        if (fitGamut) fitToGamut(transform.luminance, pixel);
        if constexpr (kIsLinear<E>) {
            if (premultiplied) repremultiply(pixel);
        }
    }
    if constexpr (!kIsLinear<E>) {
        for (int i = 0; i < count; ++i) {
            float *pixel = out + static_cast<size_t>(i) * 4;
            for (int c = 0; c < 3; ++c) pixel[c] = fromLinearFixed<E>(pixel[c]);
            if (premultiplied) repremultiply(pixel);
        }
    }
}

/// The four things `withEncoding` is asked to do. Plain functors rather than generic lambdas:
/// a lambda with an explicit template parameter list is C++20, and this builds as C++17.
struct ToLinearOp {
    float value;
    template <Encoding E> float operator()() const { return toLinearFixed<E>(value); }
};

struct FromLinearOp {
    float value;
    template <Encoding E> float operator()() const { return fromLinearFixed<E>(value); }
};

struct DecodeOp {
    const Transform &transform;
    const float *in;
    float *out;
    int count;
    bool premultiplied, watchRange;
    template <Encoding E> DecodeReport operator()() const {
        return decodeSpan<E>(transform, in, out, count, premultiplied, watchRange);
    }
};

struct EncodeOp {
    const Transform &transform;
    const float *in;
    float *out;
    int count;
    bool premultiplied, fitGamut;
    template <Encoding E> int operator()() const {
        encodeSpan<E>(transform, in, out, count, premultiplied, fitGamut);
        return 0;
    }
};

}

float toLinear(Encoding encoding, float value) {
    return withEncoding(encoding, ToLinearOp{value});
}

float fromLinear(Encoding encoding, float value) {
    return withEncoding(encoding, FromLinearOp{value});
}

bool decodeRow(Encoding encoding, const Transform &transform,
               float *pixels, int count) {
    return decodePixels(encoding, transform, pixels, pixels, count, false, false).clean;
}

void encodeRow(Encoding encoding, const Transform &transform,
               float *pixels, int count, bool fitGamut) {
    encodePixels(encoding, transform, pixels, pixels, count, false, fitGamut);
}

DecodeReport decodePixels(Encoding encoding, const Transform &transform,
                          const float *in, float *out, int count,
                          bool premultiplied, bool watchRange) {
    return withEncoding(encoding,
                        DecodeOp{transform, in, out, count, premultiplied, watchRange});
}

void encodePixels(Encoding encoding, const Transform &transform,
                  const float *in, float *out, int count, bool premultiplied,
                  bool fitGamut) {
    withEncoding(encoding, EncodeOp{transform, in, out, count, premultiplied, fitGamut});
}

OutputTransform outputTransformFor(Encoding encoding) {
    // 1 / ln 2, the change of base that lets the kernel reach a base-two curve with a natural log.
    constexpr double kLog2E = 1.4426950408889634;
    switch (encoding) {
    case Encoding::Rec709Gamma24:
        // No linear segment: the cut sits at zero, where both arms agree on zero anyway.
        return {1, {0.0f, 1.0f, 1.0f / 2.4f, 0.0f, 0.0f, 0.0f}};
    case Encoding::SRGB:
        return {1, {12.92f, 1.055f, 1.0f / 2.4f, -0.055f, 0.0031308f, 0.0f}};
    case Encoding::DaVinciIntermediate:
        // C * (log2(v + A) + B) regrouped as (C / ln 2) * ln(v + A) + C * B.
        return {2, {static_cast<float>(kDaVinciM),
                    static_cast<float>(kDaVinciC * kLog2E),
                    static_cast<float>(kDaVinciC * kDaVinciB), 0.0f,
                    static_cast<float>(kDaVinciLinearCut), static_cast<float>(kDaVinciA)}};
    case Encoding::ACEScct:
        // (log2(v) + 9.72) / 17.52 regrouped as ln(v) / (17.52 ln 2) + 9.72 / 17.52.
        return {2, {static_cast<float>(kACESctA),
                    static_cast<float>(kLog2E / 17.52),
                    static_cast<float>(9.72 / 17.52),
                    static_cast<float>(kACESctB),
                    static_cast<float>(kACESctBreak), 0.0f}};
    case Encoding::ACEScg:
    case Encoding::LinearRec709:
    case Encoding::LinearDisplayP3:
    case Encoding::LinearRec2020:
    case Encoding::Count:
        break;
    }
    return {0, {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}};
}

InputTransform inputTransformFor(Encoding encoding) {
    // ln 2, the change of base that lets the kernel reach a base-two curve with a natural
    // exponential.
    constexpr double kLn2 = 0.6931471805599453;
    switch (encoding) {
    case Encoding::Rec709Gamma24:
        // No linear segment: the cut sits at zero, where both arms agree on zero anyway.
        return {1, {0.0f, 1.0f, 2.4f, 0.0f, 0.0f, 0.0f}};
    case Encoding::SRGB:
        // ((|v| + 0.055) / 1.055)^2.4 regrouped as (|v| / 1.055 + 0.055 / 1.055)^2.4.
        return {1, {1.0f / 12.92f, 1.0f / 1.055f, 2.4f, 0.055f / 1.055f, 0.04045f, 0.0f}};
    case Encoding::DaVinciIntermediate:
        // 2^(v / C - B) - A regrouped as exp(v (ln 2 / C) - B ln 2) - A. The branch is on the
        // signed value: a negative DI code stays on the linear toe rather than being reflected
        // through the log arm, which is the curve Blackmagic publishes.
        return {2, {static_cast<float>(1.0 / kDaVinciM),
                    static_cast<float>(kLn2 / kDaVinciC),
                    static_cast<float>(kDaVinciB * kLn2), 0.0f,
                    static_cast<float>(kDaVinciLogCut), static_cast<float>(kDaVinciA)}};
    case Encoding::ACEScct:
        // 2^(17.52 v - 9.72) regrouped as exp(17.52 ln 2 v - 9.72 ln 2).
        return {2, {static_cast<float>(1.0 / kACESctA),
                    static_cast<float>(17.52 * kLn2),
                    static_cast<float>(9.72 * kLn2),
                    static_cast<float>(kACESctB),
                    static_cast<float>(kACESctLogBreak), 0.0f}};
    case Encoding::ACEScg:
    case Encoding::LinearRec709:
    case Encoding::LinearDisplayP3:
    case Encoding::LinearRec2020:
    case Encoding::Count:
        break;
    }
    return {0, {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}};
}

bool resampleRow(const float *in, int inCount, float *out, int outCount) {
    bool clean = true;
    for (int x = 0; x < outCount; ++x) {
        const float position =
            (static_cast<float>(x) + 0.5f) * inCount / outCount - 0.5f;
        const int left =
            std::max(0, std::min(inCount - 1, static_cast<int>(std::floor(position))));
        const int right = std::min(left + 1, inCount - 1);
        const float mix = std::max(0.0f, std::min(1.0f, position - left));
        const float *a = in + static_cast<size_t>(left) * 4;
        const float *b = in + static_cast<size_t>(right) * 4;
        float *pixel = out + static_cast<size_t>(x) * 4;
        for (int channel = 0; channel < 4; ++channel) {
            pixel[channel] = a[channel] + (b[channel] - a[channel]) * mix;
            if (!std::isfinite(pixel[channel])) {
                pixel[channel] = channel == 3 ? 1.0f : 0.0f;
                clean = false;
            }
        }
    }
    return clean;
}

}
