import Foundation

/// Shadow and Highlight Detail: printing a film's ends with more or less light, the way a
/// printer dodges the shadows and burns in the highlights.
///
/// A print's deepest tones sit on the paper's shoulder and its brightest on its toe, where a stop
/// of the negative moves the density hardly at all, so they crush into black or clip to white
/// and lose their colour. Lifting or pulling them on the finished picture only greys the black or
/// the white. Instead the printing light moves: the same log exposure on every record, so each
/// pixel prints as that area would have printed lighter or darker, back on the paper's steeper
/// part with the paper's own separation and colour.
///
/// Shadows: the hold is a bump between a knee below the film's mid-grey and whichever end of the
/// film prints black — a negative's clear base, a slide's densest — so mid-tones keep their place
/// and black stays black while the shadow detail between opens.
/// Highlights: past the exposure at which the paper prints a stop above its aim, the exposure is
/// drawn in toward the paper's white along `W x / (x + W)`, so the negative's long highlight range
/// rolls toward the white, still separated, instead of clipping. The shadows are placed by what
/// the film's mid-grey and black would print and the highlights by the paper's own curve, so
/// the controls mean the same on a print, a scan and Digital Reference. A slide viewed directly
/// has no paper: there the same curve runs on its displayed density, a stop above an 18% grey
/// up to its clear film, and the hold is applied as light, the same factor on every channel.
public enum PrintDetail {
    /// Where the shadow knee sits, as a share of the way from the negative's mid-grey to its base.
    public static let shadowKneeShare: Float = 0.2
    /// The shadow hold at its peak, at full strength, as a share of the knee-to-base span. Above
    /// about 0.41 the print would reverse on the bump's rising side.
    public static let reach: Float = 0.3
    /// The bump `u^1.5 (1 - u)` at its maximum, u = 0.6, so it peaks at one.
    static let peak: Float = 0.18592
    /// The highlight knee: how many display stops above its aim the paper prints there.
    public static let highlightKneeStops: Float = 1
    /// The paper's white, as the density above its D-min the highlights roll toward.
    public static let whiteDensity: Float = 0.03
    /// Each record's share of the exposure the controls are keyed on, near the print's luminance.
    public static let weights = SIMD3<Float>(0.25, 0.65, 0.10)

    /// FOTUFILM_CONFIG_PRINT_DETAIL: the shadow and highlight strengths, each held to 0...1, then
    /// the luminance-weighted paper exposures of the highlight knee and of the white, for a paper
    /// whose records are `curves` with aims at `midpoints`.
    public static func packed(shadows: Float, highlights: Float,
                              curves: [CharacteristicCurve], midpoints: [Float]) -> [Float] {
        func held(_ value: Float) -> Float { min(max(value.isFinite ? value : 0, 0), 1) }
        guard curves.count == 3, midpoints.count == 3 else { return [held(shadows), 0, 0, 0] }
        var knee: Float = 0, white: Float = 0
        for record in 0..<3 {
            let curve = curves[record]
            let lightest = curve.dMin + whiteDensity
            let aim = curve.density(logExposure: midpoints[record])
            let bright = max(aim - highlightKneeStops * log10(2), lightest + 0.01)
            knee += weights[record] * curve.logExposure(density: bright)
            white += weights[record] * curve.logExposure(density: lightest)
        }
        guard knee.isFinite, white.isFinite else { return [held(shadows), 0, 0, 0] }
        return [held(shadows), held(highlights), knee, white]
    }

    /// A directly viewed transparency's mid-grey, as the optical density of an 18% display grey.
    public static let viewGrey: Float = -log10(0.18)

    /// The luminance-weighted paper exposure a print is keyed on.
    public static func paperKey(_ exposure: SIMD3<Float>) -> Float {
        weights.x * exposure.x + weights.y * exposure.y + weights.z * exposure.z
    }

    /// A directly viewed transparency's key: the optical density of its displayed Display P3
    /// luminance.
    public static func viewKey(_ display: SIMD3<Float>) -> Float {
        let luminance = 0.2289746 * display.x + 0.6917385 * display.y + 0.0792869 * display.z
        return -log10(max(luminance, 1e-6))
    }

    /// The hold of a transparency viewed directly, `shown` between its `darkest` (densest) and
    /// `lightest` (clear) film: mid-grey at `viewGrey`, the highlight knee a stop above it, and
    /// the white a hair short of the clear film's.
    public static func viewHold(shown: SIMD3<Float>, darkest: SIMD3<Float>,
                                lightest: SIMD3<Float>, packed: [Float]) -> Float {
        hold(at: viewKey(shown), mid: viewGrey, black: viewKey(darkest),
             knee: viewGrey - highlightKneeStops * log10(2),
             white: viewKey(lightest) + whiteDensity, packed: packed)
    }

    /// How far a pixel's log exposure moves, positive where the shadows are held back and
    /// negative where the highlights burn in, for `packed` (FOTUFILM_CONFIG_PRINT_DETAIL). Every
    /// argument sits on one axis on which more prints darker: the pixel `at`, the film's mid-grey
    /// `mid`, the film extreme that prints darkest `black`, and the highlight `knee` and `white`.
    /// Through a paper these are luminance-weighted paper exposures (`weights`); a directly
    /// viewed transparency uses the optical density of its displayed luminance. Mirrors
    /// `print_detail_hold` in FotufilmHalide/Stages/Print.h.
    public static func hold(at: Float, mid: Float, black: Float, knee: Float, white: Float,
                            packed: [Float]) -> Float {
        guard packed.count == 4 else { return 0 }
        var hold: Float = 0
        let shadowKnee = mid + shadowKneeShare * (black - mid)
        let span = black - shadowKnee
        if packed[0] > 0, span > 0.05 {
            let u = min(max((at - shadowKnee) / max(span, 1e-3), 0), 1)
            let bump = u * u.squareRoot() * (1 - u) / peak
            hold = packed[0] * reach * span * bump
        }
        let room = knee - white
        if packed[1] > 0, room > 0.05 {
            let past = max(knee - at, 0)
            hold -= packed[1] * past * past / (past + room)
        }
        return hold
    }
}
