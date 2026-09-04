#ifndef FOTUFILM_WORKING_SPACE_H
#define FOTUFILM_WORKING_SPACE_H

#include <cstdint>

namespace fotufilm {

/// Supported Resolve timeline encodings. Linear Rec.2020 is the engine working space; other
/// encodings use a transfer function and matrix. Do not clamp out-of-gamut components before
/// spectral recovery, which clamps at the working-cube boundary.
///
/// Enum order is append-only: `FotufilmPlugin` persists the colour-space choice by menu index,
/// so a new space goes before `Count` here and after the frozen Auto slot in the menu.
enum class Encoding : int32_t {
    Rec709Gamma24 = 0,
    SRGB,
    DaVinciIntermediate,
    ACEScct,
    ACEScg,
    LinearRec709,
    LinearDisplayP3,
    LinearRec2020,
    Count,
};

/// The menu label for an encoding, in `Encoding` order.
const char *encodingLabel(Encoding encoding);

/// Resolves an OFX colour-space tag, or returns `Count` when no unambiguous match exists.
/// Matching ignores case and punctuation.
Encoding encodingForColourspace(const char *name);

/// Colour-space matrices for scene input, print output, and scene output.
/// `fromWorking` converts the engine's Display P3 print basis to the host encoding.
/// `fromScene` is the inverse of `toWorking` and is used by texture output, which remains in the
/// linear Rec.2020 scene basis.
struct Transform {
    float toWorking[9];
    float fromWorking[9];
    float fromScene[9];
};
Transform transformFor(Encoding encoding);

/// Decodes one channel to scene-linear, and encodes it back.
float toLinear(Encoding encoding, float value);
float fromLinear(Encoding encoding, float value);

/// Converts a whole interleaved RGBA row in place, leaving alpha untouched.
/// `count` is pixels, not floats. Non-finite RGB is replaced with black and
/// non-finite alpha with one; false reports that at least one repair was made.
bool decodeRow(Encoding encoding, const Transform &transform,
               float *pixels, int count);
void encodeRow(Encoding encoding, const Transform &transform,
               float *pixels, int count);

/// What one decode pass noticed on the way past.
struct DecodeReport {
    /// Every pixel arrived finite and stayed finite; false means at least one repair was made.
    bool clean;
    /// The largest finite RGB component in the *host's* pixels, read before any repair,
    /// un-premultiplication or decoding — the number the over-range warning quotes. Zero unless
    /// `watchRange` asked for it.
    float peak;
};

/// Decodes `count` interleaved RGBA pixels in one pass: repair, optional un-premultiplication,
/// transfer, and scene-space matrix. Alpha is repaired and copied. Input and output may be equal
/// but must not otherwise overlap.
DecodeReport decodePixels(Encoding encoding, const Transform &transform,
                          const float *in, float *out, int count,
                          bool premultiplied, bool watchRange);

/// The way back, likewise in one pass: the matrix out of the print's delivery basis, the transfer
/// encode, and optional re-premultiplication. Alpha is copied through untouched. `in` and `out`
/// may be the same pointer; they may not otherwise overlap.
void encodePixels(Encoding encoding, const Transform &transform,
                  const float *in, float *out, int count, bool premultiplied);

/// Coefficient form of `encodePixels` for the engine kernel, avoiding one GPU branch per colour space.
///
/// `shape` is 0 for an identity transfer, 1 for a sign-preserving power law
/// (|v| <= c4 ? |v| * c0 : c1 * pow(|v|, c2) + c3, carried back across zero by the sign) and 2 for
/// a signed logarithm (v <= c4 ? v * c0 + c3 : c1 * log(v + c5) + c2). The logarithmic gain has
/// the change of base folded in, so the kernel wants a natural log where the published curve is
/// written in base two.
///
/// `TranscodeParity` checks this float/GPU form against the double/libm host implementation.
struct OutputTransform {
    int32_t shape;
    float coefficients[6];
};
OutputTransform outputTransformFor(Encoding encoding);

/// Coefficient form of `decodePixels` for the engine kernel.
///
/// `shape` is 0 for an identity transfer, 1 for a sign-preserving power law
/// (|v| <= c4 ? |v| * c0 : pow(c1 * |v| + c3, c2), carried back across zero by the sign) and 2 for
/// a signed exponential (v <= c4 ? (v - c3) * c0 : exp(v * c1 - c2) - c5). The exponential's gain
/// has the change of base folded in, so the kernel wants a natural exponential where the published
/// curve is written in base two.
///
/// Not the algebraic inverse of `outputTransformFor`'s coefficients: the published curves state
/// each direction separately, the cut sits at a different place on each side, and DaVinci
/// Intermediate branches on the signed value going in where it is sign-preserving coming out.
struct InputTransform {
    int32_t shape;
    float coefficients[6];
};
InputTransform inputTransformFor(Encoding encoding);

/// Resamples `inCount` already-decoded RGBA pixels onto `outCount` of them, linearly, sampling at
/// pixel centres. Returns false if a sample came out non-finite, having replaced it with black
/// (or opaque, for alpha). Decoding before this — rather than resampling the host's encoded
/// values — is deliberate: transfer-encoded values must never be averaged.
bool resampleRow(const float *in, int inCount, float *out, int outCount);

}

#endif
