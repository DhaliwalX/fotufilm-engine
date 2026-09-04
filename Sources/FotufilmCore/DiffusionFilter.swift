import Foundation

/// Optical model for a diffusion filter containing suspended particles. `interactedFraction`
/// controls the light removed from the sharp component, and `albedo` divides that light between
/// scattering and absorption. The forward-scattering width scales as `λ / r`, so larger particles
/// produce a tighter halo and red light spreads about 38% wider than blue across the visible range.
public struct DiffusionFilter: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// The fraction of the beam that meets a particle at all. This is the filter's *grade*: the
    /// 1/8, 1/4, 1/2 and 1 of a product line are increasing particle loadings of one formulation.
    public var interactedFraction: Float
    /// Single scattering albedo of the particles, 0…1. 1 is a transparent particle that scatters
    /// everything it intercepts — a white mist; low values are the absorbing carbon-loaded
    /// particles of a black mist. What is neither transmitted nor scattered is absorbed, so a
    /// black mist genuinely takes light out of the picture rather than moving it around.
    public var albedo: Float
    /// Median particle radius in micrometres, and the width of the log-normal spread about it.
    /// The radius sets how tight the glow is; the spread smooths the diffraction rings of a
    /// single size into the featureless halo a real filter makes.
    public var particleRadiusUM: Float
    public var sizeSpread: Float
    public var substrate: OpticalMaterial
    public var coating: FilterCoating

    public init(id: String, name: String,
                interactedFraction: Float, albedo: Float,
                particleRadiusUM: Float, sizeSpread: Float = 0.45,
                substrate: OpticalMaterial = .opticalGlassDefault,
                coating: FilterCoating = .multiCoated) {
        self.id = id
        self.name = name
        self.interactedFraction = clamp(interactedFraction, 0, 1)
        self.albedo = clamp(albedo, 0, 1)
        self.particleRadiusUM = max(particleRadiusUM, 0.1)
        self.sizeSpread = max(sizeSpread, 0.01)
        self.substrate = substrate
        self.coating = coating
    }

    /// The share of the beam that reaches the film without having met a particle. Perfectly
    /// sharp, and the reason the picture keeps its detail.
    public var directShare: Float { 1 - interactedFraction }

    /// The share that comes back as halo. The rest of what interacted was absorbed.
    public var scatteredShare: Float { interactedFraction * albedo }

    /// The share the particles swallow. Zero for a white mist, most of the interaction for a
    /// black one.
    public var absorbedShare: Float { interactedFraction * (1 - albedo) }

    /// The clear glass a diffusion filter is also made of: its two surfaces cost light and add
    /// veiling glare exactly as any other filter's do, so a mist filter carries a `LensFilter`
    /// with no dye in it and the diffusion rides on top.
    public var glass: LensFilter {
        LensFilter(id: id + "-glass", name: name,
                   internalTransmittance: [Float](repeating:
                       LensFilter.clearInternalTransmittance, count: SpectralGrid.count),
                   substrate: substrate, coating: coating)
    }
}

// MARK: - The halo

/// Runtime diffusion halo represented by three Gaussian scales and per-capture-record weights. The direct
/// share remains sharp; the Gaussian mixture approximates the heavy-tailed diffraction profile.
public struct DiffusionHalo: Equatable, Sendable {
    /// Gaussian sigmas in pixels, ascending. Shared by the three records.
    public var sigmasPixels: [Float]
    /// `weights[record][scale]`, each record's row summing to 1. The first three rows are the
    /// dye-forming records and an optional fourth is the donor capture layer. Records differ here rather
    /// than in the sigmas because the three scales are what the engine blurs at, and a red halo
    /// that is wider than a blue one is a red row weighted further out.
    public var weights: [[Float]]
    /// What survived without scattering, and what came back as halo.
    public var directShare: Float
    public var scatteredShare: Float
    /// Scattered-light share assigned inside the supported radius instead of the true power-law
    /// tail. This diagnostic is checked by tests; mixture weights stay normalized to conserve
    /// energy.
    public var truncatedShare: Float

    public var isIdentity: Bool {
        scatteredShare <= 0 || sigmasPixels.allSatisfy { $0 <= 0 }
    }
}

extension DiffusionFilter {

    /// Per-capture-record sensitivity centroid under daylight. Scattering width scales with wavelength.
    static func recordWavelengths(stock: FilmStock) -> [Float] {
        let sensitivities = stock.spectralProfile.layerSensitivity
            + stock.donorLayers.map(\.sensitivity)
        return sensitivities.map { sensitivity in
            var weighted: Float = 0, total: Float = 0
            for i in 0..<SpectralGrid.count {
                let w = sensitivity[i] * SpectralGrid.d65[i]
                weighted += w * SpectralGrid.wavelengths[i]
                total += w
            }
            return total > 0 ? weighted / total : 550
        }
    }

    /// The scattered light's radial profile on the film, as the fraction of scattered energy
    /// landing inside a radius.
    ///
    /// Built from the physics rather than from a shape: the forward lobe of a large particle is
    /// the Airy pattern of its silhouette, `[2 J₁(u) / u]²` with `u = 2π r θ / λ`; the particle
    /// sizes are log-normally spread, which smooths the rings away; and a ray deviated by θ
    /// ahead of the lens lands `f · θ` off its unscattered position on the film. Everything after
    /// that is unit conversion.
    static func scatteredEnergyWithin(radiusPixels: Float, wavelengthNM: Float,
                                      medianRadiusUM: Float, spread: Float,
                                      focalLengthMM: Float, pixelPitchMM: Float) -> Float {
        guard radiusPixels > 0 else { return 0 }
        let theta = radiusPixels * pixelPitchMM / max(focalLengthMM, 1e-3)
        var total: Float = 0, weight: Float = 0
        // Seven quadrature points across the log-normal, which is enough to fill in the rings.
        for step in -3...3 {
            let z = Float(step) * spread
            let radiusUM = medianRadiusUM * exp(z)
            let w = exp(-0.5 * (z / spread) * (z / spread))
            weight += w
            total += w * airyEnergyWithin(
                u: 2 * .pi * radiusUM * 1000 * theta / wavelengthNM)
        }
        return weight > 0 ? clamp(total / weight, 0, 1) : 0
    }

    /// Fraction of an Airy pattern's energy inside the dimensionless radius `u = 2π r θ / λ`.
    /// The closed form is `1 − J₀(u)² − J₁(u)²`, which is exact and needs only the two Bessel
    /// functions — no integration of the pattern itself.
    static func airyEnergyWithin(u: Float) -> Float {
        guard u > 0 else { return 0 }
        let j0 = besselJ0(u), j1 = besselJ1(u)
        return clamp(1 - j0 * j0 - j1 * j1, 0, 1)
    }

    /// The halo this filter makes on a given emulsion, imaged by a given lens onto a frame of a
    /// given size in pixels.
    ///
    /// The three sigmas are read off the profile itself — the radii holding a tenth and
    /// ninety-six hundredths of the scattered energy, with the middle scale their geometric mean
    /// — so a tight filter gets tight scales and a broad one broad ones. Those two quantiles were
    /// chosen by sweeping the pair and taking the mixture that follows the true cumulative energy
    /// most closely; they hold it to about three parts in a hundred of the scattered light, where
    /// an evenly spaced ladder is off by seven and leaves the middle scale carrying nothing. The
    /// profile is self-similar in `r / λ`, so one rule serves every particle size.
    public func halo(stock: FilmStock, focalLengthMM: Float,
                     pixelPitchMM: Float, maximumSigmaPixels: Float = 512) -> DiffusionHalo {
        let wavelengths = Self.recordWavelengths(stock: stock)
        guard scatteredShare > 0, pixelPitchMM > 0, focalLengthMM > 0,
              maximumSigmaPixels > 0 else {
            return DiffusionHalo(sigmasPixels: [0, 0, 0],
                                 weights: [[0, 0, 0], [0, 0, 0], [0, 0, 0]],
                                 directShare: directShare, scatteredShare: 0,
                                 truncatedShare: 0)
        }

        func energy(_ radius: Float, _ wavelength: Float) -> Float {
            Self.scatteredEnergyWithin(radiusPixels: radius, wavelengthNM: wavelength,
                                       medianRadiusUM: particleRadiusUM, spread: sizeSpread,
                                       focalLengthMM: focalLengthMM, pixelPitchMM: pixelPitchMM)
        }

        /// The radius holding `fraction` of the scattered energy, by bisection on a profile that
        /// is monotonic by construction.
        func quantile(_ fraction: Float, _ wavelength: Float) -> Float {
            var low: Float = 0, high: Float = 1
            while energy(high, wavelength) < fraction && high < 1e6 { high *= 2 }
            for _ in 0..<40 {
                let mid = 0.5 * (low + high)
                if energy(mid, wavelength) < fraction { low = mid } else { high = mid }
            }
            return 0.5 * (low + high)
        }

        // A 2D Gaussian holds 1 − exp(−r²/2σ²) inside r, so the radius holding a fraction p
        // corresponds to σ = r / sqrt(−2 ln(1 − p)).
        func sigma(forQuantile p: Float, _ wavelength: Float) -> Float {
            quantile(p, wavelength) / (-2 * log(1 - p)).squareRoot()
        }
        func meanSigma(_ p: Float) -> Float {
            wavelengths.map { sigma(forQuantile: p, $0) }.reduce(0, +) / 3
        }

        let tightest = clamp(meanSigma(Self.coreQuantile), 0.5, maximumSigmaPixels)
        let widest = clamp(meanSigma(Self.tailQuantile), tightest, maximumSigmaPixels)
        let sigmas = [tightest, (tightest * widest).squareRoot(), widest]
        // Where the halo stops and the wash begins: three sigmas of the widest scale is where a
        // Gaussian has spent all but a fraction of a percent of itself.
        let reach = sigmas[2] * 3

        var weights: [[Float]] = []
        var truncated: Float = 0
        for wavelength in wavelengths {
            let fitted = Self.solveWeights(sigmas: sigmas, reachPixels: reach) {
                energy($0, wavelength)
            }
            let total = fitted.reduce(0, +)
            truncated += max(0, 1 - total)
            // Renormalised, so every photon the particles scattered is still in the picture.
            // What the fit could not reach is carried by the scales that exist, which places it
            // nearer the source than the lobe does — `truncatedShare` is the size of that lie.
            weights.append(total > 0 ? fitted.map { $0 / total } : [1, 0, 0])
        }
        return DiffusionHalo(sigmasPixels: sigmas, weights: weights,
                             directShare: directShare,
                             scatteredShare: scatteredShare,
                             truncatedShare: truncated / Float(wavelengths.count))
    }

    /// The two quantiles the scale ladder is pinned to. Swept rather than assumed: over the pair
    /// (0.10…0.50) × (0.88…0.98) these minimise the mixture's worst error against the true
    /// cumulative energy.
    static let coreQuantile: Float = 0.10
    static let tailQuantile: Float = 0.96

    /// The mixture of the three Gaussians that best follows the true profile: non-negative
    /// weights, least squares against the cumulative energy on a log-spaced radius grid running
    /// out to `reachPixels`.
    ///
    /// Log spacing rather than linear because the profile's whole character is in its tail, and a
    /// linear grid would spend all its samples on the core and fit the part that was never in
    /// doubt. The weights are *not* forced to sum to one: what they fall short by is the light
    /// that scattered past the widest scale, which the caller hands to veiling glare. Solved by
    /// projected coordinate descent — three unknowns on a simplex, where a general solver would
    /// be more machinery than the problem.
    static func solveWeights(sigmas: [Float], reachPixels: Float,
                             profile: (Float) -> Float) -> [Float] {
        let samples = 48
        let smallest = max(sigmas[0], 1e-3) * 0.15
        let largest = max(reachPixels, smallest * 2)
        let radii = (0..<samples).map { i -> Float in
            smallest * pow(largest / smallest, Float(i) / Float(samples - 1))
        }
        let target = radii.map(profile)
        let basis = sigmas.map { sigma -> [Float] in
            radii.map { r in
                sigma > 0 ? 1 - exp(-(r * r) / (2 * sigma * sigma)) : 0
            }
        }
        var weights: [Float] = [1.0 / 3, 1.0 / 3, 1.0 / 3]
        func residualCost(_ w: [Float]) -> Float {
            var total: Float = 0
            for i in 0..<samples {
                let modelled = w[0] * basis[0][i] + w[1] * basis[1][i] + w[2] * basis[2][i]
                let d = modelled - target[i]
                total += d * d
            }
            return total
        }
        var step: Float = 0.25
        var best = residualCost(weights)
        for _ in 0..<400 {
            var improved = false
            for k in 0..<3 {
                for direction in [step, -step] {
                    var trial = weights
                    trial[k] = max(trial[k] + direction, 0)
                    // A mixture cannot return more light than scattered.
                    let sum = trial.reduce(0, +)
                    if sum > 1 { for j in 0..<3 { trial[j] /= sum } }
                    let cost = residualCost(trial)
                    if cost < best {
                        best = cost
                        weights = trial
                        improved = true
                    }
                }
            }
            if !improved {
                step *= 0.5
                if step < 1e-5 { break }
            }
        }
        return weights
    }
}

// MARK: - Bessel functions

/// `J₀` and `J₁` by the standard Abramowitz & Stegun rational approximations: a polynomial in
/// `(x/3)²` below 3, and the asymptotic amplitude-and-phase form above it. Accurate to about one
/// part in 10⁸, which is far past what a scattering profile sampled on 48 radii can notice.
///
/// Here rather than in `Math.swift` because the Airy energy is the only thing in the engine that
/// wants them, and a Bessel function with one caller reads better beside that caller.
func besselJ0(_ x: Float) -> Float {
    let ax = abs(x)
    if ax < 3 {
        let y = (x / 3) * (x / 3)
        return 1 - y * (2.2499997 - y * (1.2656208 - y * (0.3163866
                - y * (0.0444479 - y * (0.0039444 - y * 0.00021)))))
    }
    let z = 3 / ax
    let amplitude = 0.79788456 - z * (0.00000077 + z * (0.00552740
        + z * (0.00009512 - z * (0.00137237 - z * (0.00072805 - z * 0.00014476)))))
    let phase = ax - 0.78539816 - z * (0.04166397 + z * (0.00003954
        - z * (0.00262573 - z * (0.00054125 + z * (0.00029333 - z * 0.00013558)))))
    return amplitude * cos(phase) / ax.squareRoot()
}

func besselJ1(_ x: Float) -> Float {
    let ax = abs(x)
    if ax < 3 {
        let y = (x / 3) * (x / 3)
        let value = x * (0.5 - y * (0.56249985 - y * (0.21093573 - y * (0.03954289
            - y * (0.00443319 - y * (0.00031761 - y * 0.00001109))))))
        return value
    }
    let z = 3 / ax
    let amplitude = 0.79788456 + z * (0.00000156 + z * (0.01659667
        + z * (0.00017105 - z * (0.00249511 - z * (0.00113653 - z * 0.00020033)))))
    let phase = ax - 2.35619449 + z * (0.12499612 + z * (0.00005650
        - z * (0.00637879 - z * (0.00074348 + z * (0.00079824 - z * 0.00029166)))))
    let value = amplitude * cos(phase) / ax.squareRoot()
    return x < 0 ? -value : value
}

// MARK: - The families on the shelf

extension DiffusionFilter {
    /// The grades a diffusion filter is sold in, and what they mean here: one formulation at
    /// increasing particle loadings, so the grade moves how much light takes part and never how
    /// far it goes.
    ///
    /// The ladder roughly doubles and then flattens, because loading cannot keep doubling — past
    /// a point the particles start shadowing one another and the filter stops getting stronger as
    /// fast as it gets denser. The numbers are the model's own calibration of the grade names,
    /// not a measurement of anyone's product.
    public enum Grade: String, Sendable, CaseIterable {
        case eighth = "1/8"
        case quarter = "1/4"
        case half = "1/2"
        case one = "1"
        case two = "2"

        public var interactedFraction: Float {
            switch self {
            case .eighth: return 0.05
            case .quarter: return 0.10
            case .half: return 0.19
            case .one: return 0.32
            case .two: return 0.50
            }
        }
    }

    /// The families, which differ in the two things that are not the grade: how big the particles
    /// are, and whether they are transparent or black.
    ///
    /// Particle radius is stated in micrometres because that is the quantity the physics uses,
    /// but it is chosen to reproduce each family's halo character rather than transcribed from a
    /// datasheet — no manufacturer publishes what is in the laminate. What *is* a measurement is
    /// what those radii then do: the halo width follows from diffraction, not from a dial.
    public enum Family: String, Sendable, CaseIterable {
        /// A broad, soft bloom around highlights. The workhorse.
        case proMist = "promist"
        /// The same halo with absorbing particles: the blacks still lift and the highlights
        /// bloom much less, which is why it is the one that survives a colourist's eye.
        case blackProMist = "blackpromist"
        /// Tighter, brighter — a sparkle close in to the highlight rather than a wash.
        case glimmerglass = "glimmerglass"
        case blackGlimmerglass = "blackglimmerglass"
        /// The widest halo here: small particles diffract through large angles, so the glow
        /// spreads across the frame instead of ringing the highlight.
        case fog = "fog"
        case blackFog = "blackfog"

        var particleRadiusUM: Float {
            switch self {
            case .proMist, .blackProMist: return 12
            case .glimmerglass, .blackGlimmerglass: return 35
            case .fog, .blackFog: return 5
            }
        }

        var albedo: Float {
            switch self {
            case .proMist: return 0.95
            case .blackProMist: return 0.30
            case .glimmerglass: return 0.92
            case .blackGlimmerglass: return 0.35
            case .fog: return 0.97
            case .blackFog: return 0.35
            }
        }

        public var label: String {
            switch self {
            case .proMist: return "Pro-Mist"
            case .blackProMist: return "Black Pro-Mist"
            case .glimmerglass: return "Glimmerglass"
            case .blackGlimmerglass: return "Black Glimmerglass"
            case .fog: return "Fog"
            case .blackFog: return "Black Fog"
            }
        }
    }

    public static func preset(_ family: Family, grade: Grade,
                              coating: FilterCoating = .multiCoated) -> DiffusionFilter {
        DiffusionFilter(id: "\(family.rawValue)-\(grade.rawValue)",
                        name: "\(family.label) \(grade.rawValue)",
                        interactedFraction: grade.interactedFraction,
                        albedo: family.albedo,
                        particleRadiusUM: family.particleRadiusUM,
                        coating: coating)
    }
}
