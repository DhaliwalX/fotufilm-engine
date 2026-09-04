import Foundation

/// One additional emulsion population contributing density to a characteristic curve.
///
/// Colour records are commonly coated from more than one speed group. A single toe-to-shoulder
/// component cannot reproduce the corresponding changes in slope, so a measured record may carry
/// one secondary population. Its contribution is additive and non-negative; omitting it is the
/// original six-parameter curve exactly.
public struct CharacteristicCurveComponent: Sendable {
    public var gamma: Float
    public var toe: Float
    public var toeWidth: Float
    public var shoulder: Float
    public var shoulderWidth: Float

    public init(gamma: Float, toe: Float, toeWidth: Float,
                shoulder: Float, shoulderWidth: Float) {
        precondition(shoulder > toe,
                     "secondary shoulder must sit above the toe on the log-exposure axis")
        self.gamma = gamma
        self.toe = toe
        self.toeWidth = toeWidth
        self.shoulder = shoulder
        self.shoulderWidth = shoulderWidth
    }

    var densityRange: Float { gamma * (shoulder - toe) }

    func density(logExposure x: Float) -> Float {
        let t = toeWidth * softplus((x - toe) / toeWidth)
        let s = shoulderWidth * softplus((x - shoulder) / shoulderWidth)
        return gamma * min(max(t - s, 0), shoulder - toe)
    }
}

/// Analytic Hurter–Driffield (H&D) characteristic curve: dye density as a
/// function of log10 exposure.
public struct CharacteristicCurve: Sendable {
    /// Minimum density: film base + fog (+ mask for color negative layers).
    public var dMin: Float
    /// Straight-line slope, ~0.55-0.65 for color negative film. A print's toe
    /// and shoulder overlap, so there is no straight line and this is an
    /// asymptote it never reaches: the RA-4 paper carries 5.851 and turns over
    /// at 3.16 D per decade, 2383 carries 6.409 and turns over at 4.09.
    public var gamma: Float
    /// Log-exposure position of the toe (relative to mid-gray at 0).
    public var toe: Float
    /// Softness of the toe transition in log-exposure units.
    public var toeWidth: Float
    /// Log-exposure position of the shoulder.
    public var shoulder: Float
    /// Softness of the shoulder transition.
    public var shoulderWidth: Float
    /// A second coated speed group where the publication resolves one. `nil` is the original
    /// single-population curve and remains bit-identical.
    public var secondary: CharacteristicCurveComponent?

    public init(dMin: Float, gamma: Float, toe: Float, toeWidth: Float,
                shoulder: Float, shoulderWidth: Float,
                secondary: CharacteristicCurveComponent? = nil) {
        precondition(shoulder > toe, "shoulder must sit above the toe on the log-exposure axis")
        self.dMin = dMin
        self.gamma = gamma
        self.toe = toe
        self.toeWidth = toeWidth
        self.shoulder = shoulder
        self.shoulderWidth = shoulderWidth
        self.secondary = secondary
    }

    /// Maximum achievable density.
    public var dMax: Float {
        dMin + gamma * (shoulder - toe) + (secondary?.densityRange ?? 0)
    }

    public func density(logExposure x: Float) -> Float {
        let t = toeWidth * softplus((x - toe) / toeWidth)
        let s = shoulderWidth * softplus((x - shoulder) / shoulderWidth)
        return dMin + gamma * min(max(t - s, 0), shoulder - toe)
            + (secondary?.density(logExposure: x) ?? 0)
    }

    /// Inverse of `density(logExposure:)` via bisection.
    public func logExposure(density target: Float) -> Float {
        var lo: Float = toe - 6
        var hi: Float = shoulder + 6
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if density(logExposure: mid) < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}
