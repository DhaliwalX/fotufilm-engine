import Foundation

/// A scan read without a film, as Normal reads a negative: each channel's density above the clear
/// base, balanced on the frame's densest end, taken back to scene light along a straight-line
/// negative. The result is a scene-linear positive, developed like any photograph without film.
/// The kernels read it (`NegativeScanPreparation`); this is their reference.
public struct PlainNegativeScan: Equatable, Sendable {
    /// The straight-line negative's contrast: density per decade of exposure, a colour
    /// negative's typical average gradient.
    public static let gamma: Float = 0.6
    /// Where the frame's densest end lands: diffuse white, two and a half stops over mid-grey.
    public static let highlight: Float = 0.18 * 5.656854
    /// The densest end's density when a frame is too small or flat to read one.
    public static let defaultReference: Float = 1

    /// Clear film as linear scan RGB.
    public let border: SIMD3<Float>
    /// Record density per unit of scanner-channel density above the border, green held.
    public let gains: SIMD3<Float>
    /// The densest end's balanced density, which prints as `highlight`.
    public let reference: Float

    public init(border: SIMD3<Float>, denseEnd: SIMD3<Float>?) {
        self.border = border
        var gains = SIMD3<Float>.one
        var reference = Self.defaultReference
        if let dense = denseEnd, (0..<3).allSatisfy({ dense[$0].isFinite }), dense.y > 0.05 {
            reference = dense.y
            for channel in [0, 2] where dense[channel] > 0.05 {
                gains[channel] = min(max(dense.y / dense[channel],
                                         ApproximateNegativeScan.gainRange.lowerBound),
                                     ApproximateNegativeScan.gainRange.upperBound)
            }
        }
        self.gains = gains
        self.reference = reference
    }

    /// One linear scan sample's scene light; black where the sample passes no light.
    @inlinable
    public func light(of sample: SIMD3<Float>) -> SIMD3<Float> {
        var light = SIMD3<Float>.zero
        for channel in 0..<3 {
            let value = sample[channel]
            guard value.isFinite, value > 0 else { return .zero }
            let density = -gains[channel] * log10(value / border[channel])
            light[channel] = Self.highlight * pow(10, (density - reference) / Self.gamma)
        }
        return light
    }
}
