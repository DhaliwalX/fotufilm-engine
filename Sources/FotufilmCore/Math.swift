import Foundation

@inlinable
public func clamp<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T {
    min(max(x, lo), hi)
}

@inlinable
public func softplus(_ x: Float) -> Float {
    if x > 20 { return x }
    if x < -20 { return exp(x) }
    return log1p(exp(x))
}

@inlinable
public func pcgHash(_ v: UInt32) -> UInt32 {
    let state = v &* 747796405 &+ 2891336453
    let word = ((state >> ((state >> 28) &+ 4)) ^ state) &* 277803737
    return (word >> 22) ^ word
}

/// Triangular-PDF dither spanning ±1 quantizer step.
@inlinable
public func triangularDither(index: UInt32, channel: UInt32, seed: UInt32) -> Float {
    let h1 = pcgHash(index ^ pcgHash(channel &+ (seed &* 0x9E3779B9)))
    let h2 = pcgHash(h1)
    let u1 = Float(h1 >> 8) * (1.0 / 16777216.0)
    let u2 = Float(h2 >> 8) * (1.0 / 16777216.0)
    return u1 + u2 - 1
}

/// Modified Bessel function I0, scaled by exp(-x). Abramowitz & Stegun 9.8.1 and 9.8.2.
///
/// The scaling is not a convenience: the grain aperture response needs I0 at arguments in the
/// tens, where I0 itself overflows well before the answer stops being useful, and only the ratio
/// exp(-x) I0(x) is wanted.
func scaledBesselI0(_ x: Float) -> Float {
    let ax = Double(abs(x))
    if ax < 3.75 {
        let t = (ax / 3.75) * (ax / 3.75)
        let series = 1.0 + t * (3.5156229 + t * (3.0899424 + t * (1.2067492
            + t * (0.2659732 + t * (0.0360768 + t * 0.0045813)))))
        return Float(series * Foundation.exp(-ax))
    }
    let t = 3.75 / ax
    let series = 0.39894228 + t * (0.01328592 + t * (0.00225319
        + t * (-0.00157565 + t * (0.00916281 + t * (-0.02057706
        + t * (0.02635537 + t * (-0.01647633 + t * 0.00392377)))))))
    return Float(series / ax.squareRoot())
}

/// Modified Bessel function I1, scaled by exp(-x). Abramowitz & Stegun 9.8.3 and 9.8.4.
func scaledBesselI1(_ x: Float) -> Float {
    let ax = Double(abs(x))
    if ax < 3.75 {
        let t = (ax / 3.75) * (ax / 3.75)
        let series = ax * (0.5 + t * (0.87890594 + t * (0.51498869
            + t * (0.15084934 + t * (0.02658733 + t * (0.00301532
            + t * 0.00032411))))))
        return Float(series * Foundation.exp(-ax))
    }
    let t = 3.75 / ax
    let tail = 0.02282967 + t * (-0.02895312 + t * (0.01787654 - t * 0.00420059))
    let series = 0.39894228 + t * (-0.03988024 + t * (-0.00362018
        + t * (0.00163801 + t * (-0.01031555 + t * tail))))
    return Float(series / ax.squareRoot())
}

/// Deterministic xorshift128+ generator so grain is reproducible for a given seed.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Samples of the *centered, unit-variance* Poisson grain field: (N - lambda) / sqrt(lambda) with N
/// ~ Poisson(lambda).
public struct PoissonFieldGenerator {
    private var rng: SplitMix64
    private var gaussian: GaussianGenerator
    public let lambda: Float
    private let expNegLambda: Double
    private let invSqrtLambda: Float

    /// Above this, skewness (1/sqrt(lambda)) is negligible and the Gaussian limit is used.
    public static let gaussianLimit: Float = 32

    public init(seed: UInt64, lambda: Float) {
        self.rng = SplitMix64(seed: seed)
        self.gaussian = GaussianGenerator(seed: seed ^ 0xA5A5_5A5A_1234_8765)
        self.lambda = max(lambda, 1e-4)
        self.expNegLambda = Foundation.exp(-Double(self.lambda))
        self.invSqrtLambda = 1 / sqrt(self.lambda)
    }

    public mutating func next() -> Float {
        if lambda >= Self.gaussianLimit {
            return gaussian.next()
        }
        var k = -1
        var p = 1.0
        repeat {
            k += 1
            p *= Double(rng.next() >> 11) * 0x1p-53
        } while p > expNegLambda
        return (Float(k) - lambda) * invSqrtLambda
    }
}

/// Box–Muller transform producing standard-normal samples.
public struct GaussianGenerator {
    private var rng: SplitMix64
    private var cached: Float?

    public init(seed: UInt64) {
        rng = SplitMix64(seed: seed)
    }

    public mutating func next() -> Float {
        if let value = cached {
            cached = nil
            return value
        }
        let u1 = Float(rng.next() >> 40) * (1.0 / 16777216.0) + .leastNormalMagnitude
        let u2 = Float(rng.next() >> 40) * (1.0 / 16777216.0)
        let r = sqrt(-2 * log(u1))
        let theta = 2 * Float.pi * u2
        cached = r * sin(theta)
        return r * cos(theta)
    }
}
