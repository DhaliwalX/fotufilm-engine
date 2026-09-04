import Foundation

/// Which model develops grain.
public enum GrainModel: Sendable {
    /// A unit-variance field blurred to the clump's correlation length: Poisson counts for dye
    /// clouds and a continuous normal field for silver, whose clump size is a correlation length
    /// rather than one countable particle. Granularity is calibrated and cost is flat, but the
    /// texture is tied to the output lattice.
    case clumpField
    /// Lattice-free Boolean discs with overlap saturation, laid at the clump radius and scaled
    /// onto the published granularity (`FilmEngineInvocation.discAmplitudes`): a texture at the
    /// emulsion's correlation length, not a model of its crystals. Available only in the
    /// reference schedule; realtime schedules use `clumpField`.
    case discs
}

/// Boolean grain model using equal-radius discs from a Poisson process.
/// Coverage `a` fixes point intensity at `-ln(1 - a) / (πr²)`. `FilmStock.grainSizeMM` is a
/// clump radius, not a crystal radius; `radius(forGranularity:)` gives the crystal-scale radius
/// whose unscaled fluctuation would match a published figure.
public enum BooleanGrain {

    /// Area shared by two discs of equal radius whose centres are `separation` apart.
    static func discIntersectionArea(separation h: Double, radius r: Double) -> Double {
        guard h < 2 * r else { return 0 }
        let half = h / 2
        return 2 * r * r * Foundation.acos(min(half / r, 1))
            - half * (max(4 * r * r - h * h, 0)).squareRoot()
    }

    /// Covariance of the coverage indicator at two points `separation` apart.
    ///
    /// Both points are uncovered only if no grain centre falls in either disc, which is a Poisson
    /// void probability over the union of the two, giving
    /// `(1 - a)^2 (exp(lambda K(h)) - 1)`. At h = 0 it is `a (1 - a)`, the variance of a coin.
    static func coverageCovariance(separation h: Double, radius r: Double,
                                   coverage a: Double) -> Double {
        let coverage = min(max(a, 1e-6), 1 - 1e-6)
        let lambda = -Foundation.log(1 - coverage) / (Double.pi * r * r)
        return (1 - coverage) * (1 - coverage)
            * Foundation.expm1(lambda * discIntersectionArea(separation: h, radius: r))
    }

    /// Set covariance of a disc aperture: the area it still shares with itself shifted by `h`.
    private static func apertureOverlap(separation h: Double, radius R: Double) -> Double {
        discIntersectionArea(separation: h, radius: R)
    }

    /// Standard deviation of the covered fraction read through a circular aperture of
    /// `apertureRadiusMM`, as a fraction of the film's density scale.
    ///
    /// The variance of an average over a window is its covariance integrated against the window's
    /// own set covariance. Both are radial, so it is one integral in the separation, and the
    /// covariance vanishes past 2r because discs that far apart can share no centre.
    public static func granularity(radiusMM r: Float, coverage a: Float,
                                   apertureRadiusMM R: Float,
                                   steps: Int = 512) -> Float {
        guard r > 0, R > 0 else { return 0 }
        let radius = Double(r), aperture = Double(R)
        let area = Double.pi * aperture * aperture
        let top = min(2 * radius, 2 * aperture)
        let step = top / Double(steps)
        var total = 0.0
        for i in 0..<steps {
            let h = top * (Double(i) + 0.5) / Double(steps)
            total += coverageCovariance(separation: h, radius: radius,
                                        coverage: Double(a))
                * apertureOverlap(separation: h, radius: aperture)
                * 2 * Double.pi * h * step
        }
        return Float(max(total, 0).squareRoot() / area)
    }

    /// The grain radius a published granularity implies, by bisection on `granularity`.
    ///
    /// `granularity` rises monotonically with the radius — coarser grain means fewer, larger
    /// fluctuations under the same aperture — so the inverse is well defined.
    public static func radius(forGranularity target: Float, coverage a: Float,
                              apertureRadiusMM R: Float) -> Float {
        guard target > 0, R > 0 else { return 0 }
        var low = 1e-6, high = Double(R) * 2
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if granularity(radiusMM: Float(mid), coverage: a,
                           apertureRadiusMM: R) < target {
                low = mid
            } else {
                high = mid
            }
        }
        return Float((low + high) / 2)
    }
}
