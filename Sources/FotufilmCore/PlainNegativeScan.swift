import Foundation

/// A scan read without a film, as Normal reads a negative: each channel's density above the clear
/// base, weighted across the channels against the dyes' crosstalk (`NegativeScanCrosstalk`),
/// balanced on the frame's densest end, taken back to scene light along a negative's curve: a
/// straight line, or one with a toe, where the clear film is no exposure at all. The result is
/// a scene-linear positive, developed like any photograph without film. The kernels read it
/// (`NegativeScanPreparation`); this is their reference.
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
    /// What each channel reads from the three channels' densities over the border
    /// (`NegativeScanCrosstalk.plainWeights`), keeping the frame's densest end.
    public let weights: [SIMD3<Float>]
    /// The densest end's balanced density, which prints as `highlight`.
    public let reference: Float
    /// Stray light the scan carries, linear scan RGB like `border`, taken off a sample and the
    /// clear film before their densities (`ApproximateNegativeScan.flare`).
    public var flare: SIMD3<Float> = .zero
    /// How much of a toe the negative's curve has, 0 to 1. A negative's density grows as
    /// `gamma` times the logarithm of one plus its exposure over the toe's, so the exposure
    /// that made a density is ten to that density over `gamma`, less one: at 1 the clear film
    /// is black and the shadows deepen as a real negative's do; at 0 the curve is a straight
    /// line, which leaves the clear film a dim grey and the shadows flat.
    public var toe: Float = 0
    /// The frame's balance as light: what each channel's light is multiplied by, which is the
    /// exposure a printer's filtration adds. One leaves a channel as it reads.
    public var balance: SIMD3<Float> = .one

    /// The toe a reading through the scan's light and camera takes.
    public static let modelToe: Float = 1
    /// How far a balance moves a channel's light.
    public static let balanceRange: ClosedRange<Float> = (1 / 32)...32

    /// What the clear film's light reads on the straight line: taken off every channel's, by
    /// `toe`.
    @inlinable public var toeLight: Float { toe * pow(10, -reference / Self.gamma) }

    /// Reads against `border` balanced on `denseEnd`, the frame's densest end over it, with
    /// `correction` of the dyes' crosstalk.
    public init(border: SIMD3<Float>, denseEnd: SIMD3<Float>?,
                correction: NegativeScanCrosstalk.Correction = .none) {
        self.border = border
        weights = NegativeScanCrosstalk.plainWeights(correction: correction, neutral: denseEnd)
        var gains = SIMD3<Float>.one
        var reference = Self.defaultReference
        if let raw = denseEnd, (0..<3).allSatisfy({ raw[$0].isFinite }),
           case let dense = NegativeScanCrosstalk.apply(weights, raw), dense.y > 0.05 {
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

    /// One linear scan sample's scene light; black where the sample passes no light over the
    /// scan's stray light.
    @inlinable
    public func light(of sample: SIMD3<Float>) -> SIMD3<Float> {
        var scanner = SIMD3<Float>.zero
        for channel in 0..<3 {
            let value = sample[channel] - flare[channel]
            guard value.isFinite, value > 0 else { return .zero }
            scanner[channel] = -log10(value / (border[channel] - flare[channel]))
        }
        let scales = lightScales
        var light = SIMD3<Float>.zero
        for channel in 0..<3 {
            let weight = weights[channel]
            let density = gains[channel]
                * (weight.x * scanner.x + weight.y * scanner.y + weight.z * scanner.z)
            light[channel] = max(0, Self.highlight
                * (pow(10, (density - reference) / Self.gamma) - toeLight) * scales[channel])
        }
        return light
    }

    /// What each channel's light over the toe is multiplied by: its balance, and what brings
    /// the densest end back to `highlight` once the toe is taken off.
    @inlinable public var lightScales: SIMD3<Float> { balance / (1 - toeLight) }
}
