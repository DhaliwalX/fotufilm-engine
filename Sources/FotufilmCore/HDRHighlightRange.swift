import Foundation

/// How much of a source's recorded range above diffuse white reaches the film.
///
/// An HDR source declares headroom H, a linear multiple of diffuse white. Keeping a fraction
/// `range` of its stops keeps headroom H^range, and the light above a knee just under white is
/// compressed in log2 to fit: s' = s / (1 + c·s) stops above the knee, with c chosen so the
/// declared peak lands on the kept headroom. The curve leaves everything below the knee alone,
/// leaves the slope unchanged at the knee, and is the identity when the whole range is kept
/// (c = 0), so a full-range or SDR source changes no bit. Range 0 fits the peak to diffuse white,
/// as a standard-range rendition would. The compression scales a pixel's three channels by its
/// peak channel's gain, which keeps highlight hue (the knee BT.2446 rolls off through, in the
/// same 75% place `SceneLinearInput.toneMapToSDR` uses).
///
/// The develop stage (`creative_exposure` in Stages/Exposure.h) applies the gain from the packed
/// knee and curvature; `PlainDevelop` mirrors it.
public enum HDRHighlightRange {
    /// Where compression starts, in units of diffuse white.
    public static let knee: Float = 0.75

    /// The headroom left when `range` (0...1) of the stops above white in `headroom` is kept.
    public static func keptHeadroom(_ headroom: Float, range: Float) -> Float {
        guard headroom > 1 else { return 1 }
        return exp2(min(max(range, 0), 1) * log2(headroom))
    }

    /// The curvature c that lands the declared peak on the kept headroom; 0 changes nothing.
    public static func curvature(headroom: Float, range: Float) -> Float {
        guard headroom > 1 else { return 0 }
        let full = log2(headroom / knee)
        let kept = log2(keptHeadroom(headroom, range: range) / knee)
        guard full > kept, kept > 0 else { return 0 }
        return (full - kept) / (full * kept)
    }

    /// The gain a pixel whose brightest channel is `peak` takes.
    public static func gain(peak: Float, curvature: Float) -> Float {
        guard curvature > 0, peak > knee else { return 1 }
        let stops = log2(peak / knee)
        return exp2(stops / (1 + curvature * stops) - stops)
    }
}
