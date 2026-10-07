import Foundation

/// A scanned negative's light controls, acting on its print: the developed film is already there,
/// so what the editor's light controls do to a photograph's scene they do to the picture the
/// print makes. Gains first, then highlights and shadows move the bright and the dark ends of the
/// print's luminance on their own, then saturation and vibrance, all on display-linear Display P3
/// before the grade. Tone scales the three channels together, so it never shifts a hue, and its
/// curve always rises, so no tone passes another.
///
/// Packed at FOTUFILM_CONFIG_PRINT_FINISH and read only by a print span with density input; the
/// Halide stage (`print_finish` in Graph/Frame.h) mirrors `apply` expression for expression.
public struct PrintFinish: Equatable, Sendable {
    /// Linear gains on the printed light.
    public var gains: SIMD3<Float>
    /// −1...1 each.
    public var highlights: Float
    public var shadows: Float
    /// Chroma multiplier about each pixel's luminance; 1 is untouched.
    public var saturation: Float
    /// Signed chroma boost weighted toward the least colourful pixels, −1...1.
    public var vibrance: Float

    public init(gains: SIMD3<Float> = .one, highlights: Float = 0, shadows: Float = 0,
                saturation: Float = 1, vibrance: Float = 0) {
        self.gains = gains
        self.highlights = highlights
        self.shadows = shadows
        self.saturation = saturation
        self.vibrance = vibrance
    }

    public static let neutral = PrintFinish()

    public var isNeutral: Bool { self == .neutral }

    /// FOTUFILM_CONFIG_PRINT_FINISH: every value as its offset from neutral, so a configuration
    /// that never wrote the slots leaves the print as it is.
    public var packed: [Float] {
        [gains.x - 1, gains.y - 1, gains.z - 1, highlights, shadows, saturation - 1, vibrance]
    }

    /// Mid-grey, about which the ends are measured.
    public static let pivot: Float = 0.18
    /// Highlights and shadows at full move their end by this many stops, easing in over the reach.
    public static let endStops: Float = 0.75
    /// Stops above mid-grey over which highlights ease in: diffuse white sits 2.3 stops up.
    public static let highlightReach: Float = 3
    /// Stops below mid-grey over which shadows ease in.
    public static let shadowReach: Float = 4
    /// Display P3 luminance.
    public static let luminance = SIMD3<Float>(0.2289746, 0.6917385, 0.0792869)

    /// 0 at and below 0, rising smoothly to 1 at 1.
    static func ease(_ t: Float) -> Float {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// One display-linear Display P3 value finished.
    public func apply(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        var light = rgb * gains
        let y = (light * Self.luminance).sum()
        if y > 1e-6 {
            let stops = log2(y / Self.pivot)
            let moved = highlights * Self.endStops * Self.ease(stops / Self.highlightReach)
                + shadows * Self.endStops * Self.ease(-stops / Self.shadowReach)
            light *= pow(2, moved)
        }
        let luma = (light * Self.luminance).sum()
        let peak = light.max()
        let colourfulness = (peak - light.min()) / max(peak, 1e-6)
        let chroma = saturation * (1 + vibrance * (1 - colourfulness))
        return luma + chroma * (light - luma)
    }
}
