#ifndef FOTUFILM_HALIDE_STAGES_EXPOSURE_H
#define FOTUFILM_HALIDE_STAGES_EXPOSURE_H

#include "FotufilmHalide.h"
#include "Math.h"
#include "Sampling.h"
#include "Transfer.h"

#include <Halide.h>
#include <cmath>

namespace fotufilm {

/// Stage 1: scene-linear RGB to normalized per-layer film exposure, where 1 is metered mid-grey.
///
/// Buffers arrive in linear Rec.2020, the engine's one scene basis, and every ingest boundary
/// converts into it at decode. Wide sources (ACEScg, DaVinci Wide Gamut, S-Gamut3.Cine, camera
/// matrices) land inside it whole. Its primaries sit on the spectral locus, but the locus bulges
/// outward between them, so narrow-band light — a laser, an LED, a gas discharge — can leave the
/// cube while still being real; nothing on the scene path clamps it. The exposure table is
/// indexed in a wider basis that encloses the whole locus (`kRec2020ToExposureDomain`), and the
/// only boundary sits at that basis's edge, where physical light actually ends.
///
/// The BT.2020 luminance weights, the Y row of its RGB-to-XYZ matrix: exact CIE luminance of
/// the 2020-basis components, negatives included.
constexpr float kLumaR = 0.2627002f;
constexpr float kLumaG = 0.6779981f;
constexpr float kLumaB = 0.0593017f;

/// Linear Display P3 to linear Rec.2020, D65 to D65, rows summing to exactly 1 so P3 white is
/// working white. The ingest conversion for the encoded-byte frame path, whose buffers arrive
/// as transfer-encoded Display P3: after the transfer decode they step into the working space
/// here. Must match ColorScience.linearDisplayP3ToRec2020 digit for digit — the Swift
/// reference path converts the same buffers with it.
constexpr float kP3ToRec2020[9] = {
     0.753833034f, 0.198597369f, 0.047569597f,
     0.045743849f, 0.941777220f, 0.012478931f,
    -0.001210340f, 0.017601717f, 0.983608623f,
};

/// Linear Rec.2020 to linear Display P3, D65 to D65 — `kP3ToRec2020` the other way. The film
/// path never needs it: the paper integrates its dyes straight to Display P3, so the step out of
/// the working space is something the emulsion does. With no film in the gate there is no paper
/// to do it, and the same re-expression has to happen as a matrix. Must match
/// ColorScience.linearRec2020ToDisplayP3 digit for digit — the Swift reference path is
/// `PlainDevelop`, which applies exactly this.
constexpr float kRec2020ToP3[9] = {
     1.343578253f, -0.282179671f, -0.061398582f,
    -0.065297453f,  1.075787916f, -0.010490463f,
     0.002821787f, -0.019598495f,  1.016776707f,
};

/// Linear Rec.2020 to the exposure table's own basis: the ACES AP0 primaries about the D65
/// working white, whose chromaticity triangle encloses the whole spectral locus. Rows sum to
/// exactly 1, so the neutral axis is the same line in both bases and a walk toward it means the
/// same thing on either side. Must match ColorScience.linearRec2020ToExposureDomain digit for
/// digit — the Swift reference path and the handwritten Metal shaders apply the same seam.
constexpr float kRec2020ToExposureDomain[9] = {
     0.670231843f, 0.152168745f, 0.177599412f,
     0.044501114f, 0.854482372f, 0.101016514f,
     0.0f,         0.025777047f, 0.974222953f,
};

/// The local key the tone masks read: the pixel's regional brightness in stops from metered
/// mid-grey, from the guided-filter model base = a * stops + b with (a, b) bilinearly sampled from
/// the coarse whole-frame grid packed at FOTUFILM_CONFIG_TONE_GRID_A/_B (solved by
/// FilmEngineInvocation's tone-base measurement) and `stops` the pixel's own metered luminance.
inline Halide::Expr tone_base(Halide::ImageParam &configuration,
                              Halide::Expr stops, Halide::Expr frame_x,
                              Halide::Expr frame_y) {
    using Halide::Expr;
    Expr grid_w = Halide::cast<int32_t>(
        configuration(FOTUFILM_CONFIG_TONE_GRID_WIDTH));
    Expr grid_h = Halide::cast<int32_t>(
        configuration(FOTUFILM_CONFIG_TONE_GRID_HEIGHT));
    Expr frame_w = Halide::max(configuration(FOTUFILM_CONFIG_FRAME_WIDTH), 1.0f);
    Expr frame_h = Halide::max(configuration(FOTUFILM_CONFIG_FRAME_HEIGHT), 1.0f);
    Expr gx = Halide::clamp(
        (Halide::cast<float>(frame_x) + 0.5f) * Halide::cast<float>(grid_w)
            / frame_w - 0.5f,
        0.0f, Halide::cast<float>(grid_w - 1));
    Expr gy = Halide::clamp(
        (Halide::cast<float>(frame_y) + 0.5f) * Halide::cast<float>(grid_h)
            / frame_h - 0.5f,
        0.0f, Halide::cast<float>(grid_h - 1));
    Expr x0 = Halide::clamp(Halide::cast<int32_t>(gx), 0,
                            Halide::max(grid_w - 2, 0));
    Expr y0 = Halide::clamp(Halide::cast<int32_t>(gy), 0,
                            Halide::max(grid_h - 2, 0));
    Expr x1 = Halide::min(x0 + 1, grid_w - 1);
    Expr y1 = Halide::min(y0 + 1, grid_h - 1);
    Expr fx = Halide::clamp(gx - Halide::cast<float>(x0), 0.0f, 1.0f);
    Expr fy = Halide::clamp(gy - Halide::cast<float>(y0), 0.0f, 1.0f);
    auto bilinear = [&](int plane) {
        Expr c00 = configuration(plane + y0 * grid_w + x0);
        Expr c10 = configuration(plane + y0 * grid_w + x1);
        Expr c01 = configuration(plane + y1 * grid_w + x0);
        Expr c11 = configuration(plane + y1 * grid_w + x1);
        return (1.0f - fy) * ((1.0f - fx) * c00 + fx * c10)
            + fy * ((1.0f - fx) * c01 + fx * c11);
    };
    return bilinear(FOTUFILM_CONFIG_TONE_GRID_A) * stops
        + bilinear(FOTUFILM_CONFIG_TONE_GRID_B);
}

/// Scene RGB after the creative controls, before any spectral recovery.
struct CreativeScene {
    Halide::Expr r, g, b;
};

/// The creative half of the exposure stage: the white-balance gains, then the exposure-keyed tone
/// masks, then saturation and vibrance — everything a user moves, applied to scene RGB exactly as
/// `scene_exposure` always has. Domain-independent: it neither knows nor cares how the light will
/// be turned into layer exposure.
///
/// The gains go on first so that everything after them reads the adapted scene: the metering the
/// tone masks key to, the luminance the chroma is taken about, and the colourfulness vibrance
/// weighs. A grey card lit by the declared illuminant is then grey to all three, and desaturating
/// it leaves it grey rather than the colour of the adaptation. Gains of exactly 1 change no bit.
inline CreativeScene creative_exposure(Halide::ImageParam &configuration,
                                       Halide::Expr red, Halide::Expr green,
                                       Halide::Expr blue, Halide::Expr frame_x,
                                       Halide::Expr frame_y,
                                       bool approximate = false) {
    using Halide::Expr;
    // No clamp: the only clamp on the scene path is the exposure domain's physical-light
    // boundary. Everything here — tone gain, the luma lerp, the white-balance gains — is linear,
    // so rare out-of-Rec.2020 components pass through intact to be judged there.
    Expr r0 = red * configuration(FOTUFILM_CONFIG_WHITE_BALANCE);
    Expr g0 = green * configuration(FOTUFILM_CONFIG_WHITE_BALANCE + 1);
    Expr b0 = blue * configuration(FOTUFILM_CONFIG_WHITE_BALANCE + 2);

    constexpr float kToneEV = 3.0f;
    constexpr float kToneWindowStops = 6.0f;
    Expr metered = (kLumaR * r0 + kLumaG * g0 + kLumaB * b0)
        * configuration(FOTUFILM_CONFIG_EXPOSURE_GAIN) * (1.0f / 0.18f);
    Expr stops = fs_log(Halide::max(metered, 1.0e-6f), approximate)
        * (1.0f / 0.6931472f);
    Expr keyed = tone_base(configuration, stops, frame_x, frame_y);
    Expr high = Halide::clamp(keyed * (1.0f / kToneWindowStops), 0.0f, 1.0f);
    Expr low = Halide::clamp(-keyed * (1.0f / kToneWindowStops), 0.0f, 1.0f);
    Expr highlight_mask = high * high * (3.0f - 2.0f * high);
    Expr shadow_mask = low * low * (3.0f - 2.0f * low);
    Expr tone_ev = kToneEV * (configuration(FOTUFILM_CONFIG_HIGHLIGHTS) * highlight_mask
                              + configuration(FOTUFILM_CONFIG_SHADOWS) * shadow_mask);
    Expr tone_gain = approximate ? Halide::fast_exp(tone_ev * 0.6931472f)
                                 : Halide::pow(2.0f, tone_ev);
    Expr r1 = r0 * tone_gain;
    Expr g1 = g0 * tone_gain;
    Expr b1 = b0 * tone_gain;

    Expr luma1 = kLumaR * r1 + kLumaG * g1 + kLumaB * b1;
    Expr peak = Halide::max(r1, Halide::max(g1, b1));
    Expr colourfulness = (peak - Halide::min(r1, Halide::min(g1, b1)))
        / Halide::max(peak, 1.0e-6f);
    Expr chroma = configuration(FOTUFILM_CONFIG_SATURATION)
        * (1.0f + configuration(FOTUFILM_CONFIG_VIBRANCE) * (1.0f - colourfulness));
    Expr r2 = luma1 + chroma * (r1 - luma1);
    Expr g2 = luma1 + chroma * (g1 - luma1);
    Expr b2 = luma1 + chroma * (b1 - luma1);

    return {r2, g2, b2};
}

/// The film-free print: creative scene RGB, re-expressed in the print's delivery basis and
/// graded. What `FOTUFILM_FRAME_NO_FILM` puts where the emulsion, the couplers and the paper were.
///
/// Out-of-gamut components are left alone. The grade is a bijection over the whole line and the
/// delivery encoder owns the clip, exactly as the film path clamps only at the exposure domain's
/// physical-light boundary — so a colour too saturated for P3 arrives at the encoder to be judged
/// there rather than being flattened here.
///
/// Mirrors `PlainDevelop.printed` expression for expression, and shares `creative_exposure` with
/// the film path so the controls mean the same thing with and without a stock loaded.
inline Halide::Expr plain_print(Halide::ImageParam &configuration,
                                const CreativeScene &scene,
                                Halide::Expr channel) {
    // The exposure gain goes on here, and only here. `creative_exposure` deliberately leaves it
    // out — on the film path it is the emulsion that is exposed, and the gain reaches the light
    // through `recover_exposure` — so with no emulsion in the way there is nothing else left to
    // apply it. It is the same multiplication `PlainDevelop.printed` makes, in the same place:
    // after the tone and chroma controls, before the step into the delivery basis.
    Halide::Expr gain = configuration(FOTUFILM_CONFIG_EXPOSURE_GAIN);
    Halide::Expr r = scene.r * gain, g = scene.g * gain, b = scene.b * gain;
    auto row = [&](int index) {
        return kRec2020ToP3[3 * index] * r
            + kRec2020ToP3[3 * index + 1] * g
            + kRec2020ToP3[3 * index + 2] * b;
    };
    return color_grade(configuration, channel,
                       Halide::mux(channel, {row(0), row(1), row(2)}));
}

/// The recovery half: creative scene RGB to normalized per-layer film exposure through the
/// spectral LUT, the chromaticity evaluated at the radiance anchor and the radiance scaled back
/// out. Domain-dependent — this is the seam a direct film-layer-exposure input replaces.
///
/// The LUT's domain is a cube whose chromaticity triangle encloses the spectral locus — the AP0
/// primaries about the working white, `kRec2020ToExposureDomain` — so every real light has cells
/// of its own, monochromatic sources included; beyond Rec.2020 the table holds the cube-edge
/// reflectance mixed with light at the hue's dominant wavelength. The boundary below is the only
/// one on the scene path and it sits at that triangle's edge: what it gives up is colour outside
/// the locus, which no light can carry, rather than anything a display or a working space cannot
/// hold — and it gives it up as purity, never as a channel, so the hue and the luminance a wide
/// source stated are the hue and luminance the emulsion is shown.
inline Halide::Expr recover_exposure(Halide::ImageParam &configuration,
                                     Halide::ImageParam &exposure_lut,
                                     Halide::Expr r, Halide::Expr g,
                                     Halide::Expr b, Halide::Expr channel,
                                     bool half_lut_math = false) {
    using Halide::Expr;
    // Luminance is basis-invariant, so it is read once on the Rec.2020 components; the seam's
    // rows sum to 1, so y on the neutral axis is the same point in the table's basis.
    Expr y = kLumaR * r + kLumaG * g + kLumaB * b;
    Expr dr = kRec2020ToExposureDomain[0] * r + kRec2020ToExposureDomain[1] * g
        + kRec2020ToExposureDomain[2] * b;
    Expr dg = kRec2020ToExposureDomain[3] * r + kRec2020ToExposureDomain[4] * g
        + kRec2020ToExposureDomain[5] * b;
    Expr db = kRec2020ToExposureDomain[7] * g + kRec2020ToExposureDomain[8] * b;
    // A component the seam leaves negative names a chromaticity outside the locus-enclosing
    // triangle — colour no physical light can carry. Zeroing that channel alone would *add*
    // light the scene never had and shift the ratio between the survivors, which appears as a
    // hue flip on saturated sources. Instead the colour is walked toward its own luminance axis
    // until the binding channel reaches zero: the most saturated real light of the same CIE
    // luminance and hue. A colour whose luminance is not even positive is no light at all
    // and develops as darkness. In-cube colours take the untouched expressions bit for bit.
    Expr tr = Halide::select(dr < 0.0f, y / (y - dr), 1.0f);
    Expr tg = Halide::select(dg < 0.0f, y / (y - dg), 1.0f);
    Expr tb = Halide::select(db < 0.0f, y / (y - db), 1.0f);
    Expr s = Halide::min(Halide::min(tr, tg), tb);
    Expr outside = dr < 0.0f || dg < 0.0f || db < 0.0f;
    Expr pr = Halide::select(y <= 0.0f, 0.0f,
                             Halide::select(outside, y + s * (dr - y), dr));
    Expr pg = Halide::select(y <= 0.0f, 0.0f,
                             Halide::select(outside, y + s * (dg - y), dg));
    Expr pb = Halide::select(y <= 0.0f, 0.0f,
                             Halide::select(outside, y + s * (db - y), db));
    Expr wr = Halide::max(pr, 0.0f);
    Expr wg = Halide::max(pg, 0.0f);
    Expr wb = Halide::max(pb, 0.0f);
    Expr radiance_scale = Halide::max(Halide::max(wr, Halide::max(wg, wb)), 1.0e-6f);
    return Halide::max(
        lut_sample(exposure_lut, wr / radiance_scale, wg / radiance_scale,
                   wb / radiance_scale, channel, half_lut_math)
            * (radiance_scale * configuration(FOTUFILM_CONFIG_EXPOSURE_GAIN) / 0.18f),
        0.0f);
}

inline Halide::Expr scene_exposure(Halide::ImageParam &configuration,
                                   Halide::ImageParam &exposure_lut,
                                   Halide::Expr red, Halide::Expr green,
                                   Halide::Expr blue, Halide::Expr channel,
                                   Halide::Expr frame_x, Halide::Expr frame_y,
                                   bool approximate = false,
                                   bool half_lut_math = false) {
    CreativeScene scene = creative_exposure(configuration, red, green, blue,
                                            frame_x, frame_y, approximate);
    return Halide::select(configuration(FOTUFILM_CONFIG_RECORD_INPUT) != 0.0f,
        Halide::mux(Halide::min(channel, 2), {red, green, blue}),
        recover_exposure(configuration, exposure_lut, scene.r, scene.g,
                         scene.b, channel, half_lut_math));
}

/// Luminance of a three-plane Func at one pixel, in the renderer's working primaries.
inline Halide::Expr luminance(Halide::Func planes, Halide::Expr x, Halide::Expr y) {
    return kLumaR * planes(x, y, 0) + kLumaG * planes(x, y, 1)
        + kLumaB * planes(x, y, 2);
}

/// Projection onto the neutral axis of film-record exposure. These planes are emulsion records,
/// not RGB primaries, so display-space luminance coefficients do not apply.
inline Halide::Expr record_neutral(Halide::Func planes, Halide::Expr x, Halide::Expr y) {
    return (planes(x, y, 0) + planes(x, y, 1) + planes(x, y, 2)) / 3.0f;
}

/// Luminance/chrominance recombination for the emulsion MTF. `per_layer` is each record blurred at
/// its own diffusion sigma — the opponent detail — and `luma_blurred` is the film-record neutral
/// axis blurred at the shared sigma.
inline Halide::Expr mtf_luma_mix(Halide::ImageParam &configuration,
                                 Halide::Expr per_layer,
                                 Halide::Expr per_layer_luma,
                                 Halide::Expr luma_blurred) {
    return per_layer + configuration(FOTUFILM_CONFIG_MTF_LUMA_SHARE)
        * (luma_blurred - per_layer_luma);
}

}

#endif
