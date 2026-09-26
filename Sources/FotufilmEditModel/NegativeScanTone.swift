import Foundation

/// The tone a converted scan is finished with, on linear light: contrast pivots about mid-grey,
/// then highlights and shadows move the bright and the dark ends on their own. Each works on the
/// luminance in stops and scales the three channels together, so it never shifts a hue, and the
/// curve always rises, so no tone passes another.
public struct NegativeScanTone: Equatable, Sendable {
    /// −1...1 each.
    public var contrast: Float
    public var highlights: Float
    public var shadows: Float

    public init(contrast: Float = 0, highlights: Float = 0, shadows: Float = 0) {
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
    }

    public var isNeutral: Bool { contrast == 0 && highlights == 0 && shadows == 0 }

    /// Mid-grey, which contrast leaves where it is.
    static let pivot: Float = 0.18
    /// Contrast of 1 steepens the curve by this many stops per stop.
    static let contrastStops: Float = 0.6
    /// Highlights and shadows at full move their end by this many stops, easing in over `reach`.
    static let endStops: Float = 0.75
    static let highlightReach: Float = 3
    static let shadowReach: Float = 4

    /// The slope contrast sets, in stops out per stop in.
    var slope: Float { pow(2, contrast * Self.contrastStops) }

    /// Stops from mid-grey in, stops from mid-grey out.
    func curve(_ stops: Float) -> Float {
        var out = stops * slope
        out += highlights * Self.endStops * Self.ease(stops / Self.highlightReach)
        out += shadows * Self.endStops * Self.ease(-stops / Self.shadowReach)
        return out
    }

    /// 0 at and below 0, rising smoothly to 1 at 1.
    private static func ease(_ t: Float) -> Float {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// Applies the tone to one linear RGB value.
    public func apply(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        guard !isNeutral else { return rgb }
        let luminance = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
        guard luminance > 1e-6, luminance.isFinite else { return rgb }
        let stops = log2(luminance / Self.pivot)
        return rgb * pow(2, curve(stops) - stops)
    }

    /// Applies the tone to interleaved RGBA, in place.
    public func apply(rgba: inout [Float]) {
        guard !isNeutral else { return }
        for i in stride(from: 0, to: rgba.count - 3, by: 4) {
            let toned = apply(SIMD3(rgba[i], rgba[i + 1], rgba[i + 2]))
            rgba[i] = toned.x
            rgba[i + 1] = toned.y
            rgba[i + 2] = toned.z
        }
    }
}
