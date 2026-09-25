import Foundation

/// Grain laid on the film itself, for `GrainModel.film`: the crystals a record coats sit at fixed
/// places on the emulsion, the exposure at each decides which of them develop, each developed
/// crystal grows a dye cloud — or a silver grain — of its own physical size, and an output pixel
/// is what light passing through that patch of film averages to.
///
/// **The film, not the pixels.** Every crystal's position, size mark and development draw come
/// from a hash of its cell in film millimetres, so a render at any resolution samples the same
/// film: zooming in resolves the grains a coarser render averaged, as a loupe does on a negative.
/// A crystal's draws do not depend on the light, so the same frame exposed differently develops
/// a different share of the same crystals.
///
/// **The population** is `CrystalGrainModel`'s: the speed classes fitted to the record's curve,
/// the four sublayers along speed, the crystal counts and the dye per crystal that the sheet's
/// RMS granularity fixes. Nothing here is fitted per stock.
///
/// **A dye cloud spreads as Jarvis measured it.** Couplers are dispersed evenly through a
/// sublayer (Hunt, *The Reproduction of Colour* §18.7: oil globules a tenth of the grain's
/// diameter), so the most dye any point of the sublayer can form is its coupler capacity — the
/// sublayer's pool, which is also what a fully developed sublayer reaches. The oxidised developer
/// a developed crystal releases spreads as the dye cloud Jarvis measured on C-41 coatings,
/// `exp(-r / k)` with decay length `dyeCloudDecayMM` (J. Photogr. Sci. 40:105, 1992), and forms
/// dye up to that capacity, `C (1 - exp(-demand / C))`, summed with every other cloud of the
/// sublayer before it saturates: clouds merge where they meet, and a crystal whose demand passes
/// the capacity grows a flat top wider than the decay length. The sheet fixes how much dye a
/// crystal forms; the coupler, not the dye, fixes how far it spreads, so the dye per crystal sets
/// the cloud's peak demand at the measured width.
///
/// **A silver grain follows from its dye.** Silver is the same construction with an opaque grain,
/// `silverGrainDensity`, in place of the coupler capacity and a flat-topped Gaussian in place of
/// the cloud, its width solved so that its density-area is the sheet's — which makes the grain's
/// projected area Nutting's `D = 0.434 n a` read backwards from the sheet. No grain is narrower
/// than its crystal, whose width follows the population's size ladder down from
/// `fastestCrystalMM`; one that would be keeps the crystal's width and forms its silver fainter.
///
/// **Pixels average light.** Density adds through the depth of the film at one point; across an
/// area it is the transmittance that averages. Each output pixel is sampled on a sub-grid at
/// most `finestSampleMM` apart (up to `maxSupersample` per side), and its density is
/// `-log10` of the mean transmittance, so a pixel half covered by a dense cloud reads as the
/// light through it does rather than as the mean of two densities.
///
/// **The tone stays the curve's.** The model's own mean at each developed density is measured on
/// a flat patch at the render's pitch and subtracted, so the grain is the physical fluctuation
/// about the pipeline's developed density.
///
/// The dye per crystal is then taken again from the sheet on this model's own render
/// (`anchorToSheet`), since saturating clouds read through the 48 µm aperture differently from
/// the additive field the population was anchored on.
///
/// The model runs on the CPU at the density seam (`developNegative` then `printPositive`) and is
/// a reference: its cost grows with the film area over the square of the sample spacing.
public struct FilmGrain: Sendable {
    /// Decay length `k` of a dye cloud's point spread `exp(-r / k) / (2π k²)`, mm, whose transfer
    /// function is `[1 + (2π k f)²]^(-3/2)` (Jarvis, J. Photogr. Sci. 40:105, 1992, Eqs. 2 and 4).
    /// Jarvis measured k = 0.76, 1.07, 1.37 and 1.45 µm on C-41 coatings of 0.8, 0.5, 0.2 and
    /// 0.1 g/m² cyan coupler: the less coupler, the further oxidised developer travels before it
    /// couples. 1.45 µm is the value Jarvis (J. Photogr. Sci. 43:136, 1995) calls typical of a
    /// coupler-starved commercial colour-negative layer; noise spectra of C-41 coatings give
    /// clouds 4–6 µm across (Graves & Saunders, J. Photogr. Sci. 33:145, 1985), about 3k.
    public static let dyeCloudDecayMM: Float = 0.00145
    /// Jarvis's cloud `exp(-ρ)`, ρ = r / k, as four Gaussians `weight · exp(-ρ² / 2σ²)`, so a
    /// sublayer's clouds lay as four separable blurs of its crystals: fitted to the transfer
    /// function to 9 % wherever it is above 10⁻³ and to the profile to 0.03 of its peak, with
    /// `Σ weight σ² = 1` so each cloud carries its dye exactly.
    static let dyeCloudTerms: [(sigma: Float, weight: Float)] = [
        (0.1162, 0.1096), (0.3089, 0.2167), (0.7469, 0.4030), (1.732, 0.2510),
    ]
    /// Peak demand of a developed silver grain over its local density: how far past saturation
    /// its centre is, which sets how flat its top is and how hard its rim. Not measured; a stance.
    public static let silverGrainEdge: Float = 12
    /// Local density of a developed silver grain: transmits one percent. Not measured; a stance.
    public static let silverGrainDensity: Float = 2
    /// Width of a record's fastest crystals, mm; slower classes follow the size ladder. Not
    /// measured; a stance near the 1–2 µm tabular crystals of fast negative emulsions.
    public static let fastestCrystalMM: Float = 0.0012
    /// Finest sub-pixel sample spacing, mm.
    public static let finestSampleMM: Float = 0.00035
    /// Most sub-samples per pixel side.
    public static let maxSupersample = 8
    /// Shape of the gamma distribution each crystal's dye is drawn from: mean 1, second moment
    /// `1 + 1/shape`, the `CrystalGrainModel.Development.markSecondMoment` the sheet anchor uses.
    static var markShape: Int {
        Int((1 / (CrystalGrainModel.Development.markDispersion
                  * CrystalGrainModel.Development.markDispersion)).rounded())
    }
    /// Samples of the developed-fraction table against gross density.
    static let tableSamples = 129
    /// Developed-density levels the mean is measured at.
    static let biasSamples = 17
    /// Side of the flat patch the mean is measured on, mm: wide enough that its own grain moves
    /// the mean by a few thousandths.
    static let biasPatchMM: Float = 0.16

    /// How a developed crystal's demand spreads over the film.
    public enum Profile: UInt32, Sendable {
        /// A silver grain: a Gaussian of sigma `sigmaMM`, flat-topped by its edge.
        case silverGrain = 0
        /// A dye cloud: Jarvis's `exp(-r / k)` with `k` = `sigmaMM`, laid as `dyeCloudTerms`.
        case dyeCloud = 1

        /// The profile at radius `ρ` in units of its length, 1 at the centre.
        func value(_ rho: Double) -> Double {
            switch self {
            case .silverGrain:
                return exp(-rho * rho / 2)
            case .dyeCloud:
                return FilmGrain.dyeCloudTerms.reduce(0) {
                    let s = Double($1.sigma)
                    return $0 + Double($1.weight) * exp(-rho * rho / (2 * s * s))
                }
            }
        }

        /// Radius past which a profile of centre `peak` lays less than 10⁻⁷, in its length.
        func reach(peak: Double) -> Double {
            let widest = self == .silverGrain ? 1.0 : Double(FilmGrain.dyeCloudTerms.last!.sigma)
            return widest * (2 * log(max(peak * 8, 1) / 1e-7)).squareRoot()
        }
    }

    /// One coated sublayer of a record, as this model lays it.
    public struct Sublayer: Sendable {
        /// Crystals coated per mm².
        public var coatedPerMM2: Float
        /// Length of the demand one developed crystal releases, mm: a silver grain's Gaussian
        /// sigma, a dye cloud's decay length.
        public var sigmaMM: Float
        /// Peak demand of a mark-1 crystal, density.
        public var peakDemand: Float
        /// Most density a point of the sublayer can form.
        public var capacity: Float
        /// Peak demand over capacity of a silver grain free to take its own width; a dye cloud,
        /// held at its measured width, takes whatever peak its dye needs.
        public var edge: Float
        /// Narrowest length a crystal's demand of this sublayer may take, mm.
        public var smallestSigmaMM: Float
        /// Dye one mark-1 crystal forms as a densitometer reads it, density × mm².
        public var dyePerCloudMM2: Float
        /// Side of the film cell its crystals are hashed in, mm.
        public var cellMM: Float
        /// Dye-forming fraction against gross density, `tableSamples` from `dMin` to `dMax`.
        public var forming: [Float]
        /// `E_mark ∫ (1 - exp(-demand / C))` over the plane for one developed crystal, mm²: with
        /// `λ` developed crystals per mm², `exp(-λ J)` is the expected `exp(-demand / C)` of the
        /// Poisson field (Campbell), so the sublayer's mean dye is `C (1 - exp(-λ J))` exactly.
        public var voidIntegralMM2: Float
        /// How its crystals' demand spreads.
        public var profile: Profile

        init(profile: Profile, coatedPerMM2: Float, capacity: Float, edge: Float,
             smallestSigmaMM: Float, dyePerCloudMM2: Float, cellMM: Float, forming: [Float]) {
            self.profile = profile
            self.coatedPerMM2 = coatedPerMM2
            self.capacity = capacity
            self.edge = edge
            self.peakDemand = edge * capacity
            self.smallestSigmaMM = smallestSigmaMM
            self.dyePerCloudMM2 = dyePerCloudMM2
            self.cellMM = cellMM
            self.forming = forming
            sigmaMM = 0
            voidIntegralMM2 = 0
            shape()
        }

        /// Restores an already solved population without re-running its numerical fit.
        init(profile: Profile, coatedPerMM2: Float, sigmaMM: Float, peakDemand: Float,
             capacity: Float, edge: Float, smallestSigmaMM: Float, dyePerCloudMM2: Float,
             cellMM: Float, forming: [Float], voidIntegralMM2: Float) {
            self.profile = profile
            self.coatedPerMM2 = coatedPerMM2
            self.sigmaMM = sigmaMM
            self.peakDemand = peakDemand
            self.capacity = capacity
            self.edge = edge
            self.smallestSigmaMM = smallestSigmaMM
            self.dyePerCloudMM2 = dyePerCloudMM2
            self.cellMM = cellMM
            self.forming = forming
            self.voidIntegralMM2 = voidIntegralMM2
        }

        /// Sets the demand from its dye. A silver grain is as wide as its edge makes it, or held
        /// at its crystal's width with its peak lowered until it forms that density-area; a dye
        /// cloud keeps its measured decay length and takes the peak its dye needs.
        mutating func shape() {
            var peak = edge
            let free = profile == .silverGrain
                ? (dyePerCloudMM2 / FilmGrain.unitCloudDye(capacity: capacity, edge: edge,
                                                           profile: profile)).squareRoot()
                : 0
            if free >= smallestSigmaMM {
                sigmaMM = free
            } else {
                sigmaMM = smallestSigmaMM
                let wanted = dyePerCloudMM2 / (smallestSigmaMM * smallestSigmaMM)
                var low = profile == .silverGrain ? log(edge * 1e-5) : log(Float(1e-6))
                var high = profile == .silverGrain ? log(edge) : log(Float(1e4))
                for _ in 0..<40 {
                    let mid = (low + high) / 2
                    if FilmGrain.unitCloudDye(capacity: capacity, edge: exp(mid), profile: profile) < wanted {
                        low = mid
                    } else {
                        high = mid
                    }
                }
                peak = exp((low + high) / 2)
            }
            peakDemand = peak * capacity
            voidIntegralMM2 = sigmaMM * sigmaMM * FilmGrain.unitVoidIntegral(edge: peak, profile: profile)
        }

        /// Radius at which a mark-1 crystal has formed half its capacity, mm.
        public var halfCapacityRadiusMM: Float {
            let formed = Double(M_LN2) // demand = C ln 2 gives C/2
            let ratio = Double(peakDemand / max(capacity, 1e-6))
            guard ratio > formed else { return 0 }
            var low = 0.0, high = profile.reach(peak: ratio)
            for _ in 0..<50 {
                let mid = (low + high) / 2
                if ratio * profile.value(mid) > formed { low = mid } else { high = mid }
            }
            return sigmaMM * Float((low + high) / 2)
        }
    }

    public struct Record: Sendable {
        public var sublayers: [Sublayer]
        public var dMin: Float
        public var dMax: Float
    }

    public var records: [Record]
    public var monochrome: Bool
    /// Identity of this population: the stock and grain scale it was built for.
    let key: String
    /// A decoded bank belongs to the population, independently of shared cache eviction.
    let assetTiles: Tiles?

    init(records: [Record], monochrome: Bool, identity: Data, tiles: Tiles) {
        self.records = records
        self.monochrome = monochrome
        key = Self.populationKey(identity: identity, grainScale: 1)
        assetTiles = tiles
    }

    /// The population of `stock` as developed; `reference` is the same roll at the pack's
    /// reference process, as `CrystalGrainModel` takes it.
    public init(stock: FilmStock, reference: FilmStock? = nil, grainScale: Float = 1) {
        self.init(stock: stock, reference: reference, grainScale: grainScale, useCachedAnchor: true, checkCancellation: {})
    }

    init(stock: FilmStock, reference: FilmStock? = nil, grainScale: Float = 1,
         useCachedAnchor: Bool, checkCancellation: () throws -> Void) rethrows {
        try checkCancellation()
        var timing = StageTiming()
        monochrome = stock.isMonochrome
        key = Self.populationKey(identity: FilmGrainAsset.identity(stock: stock, reference: reference),
                                 grainScale: grainScale)
        assetTiles = nil
        let silver = stock.grainDensityLaw == .silver
        var anchors: [(gross: Float, sigma: Float)] = []
        records = (0..<3).map { layer in
            let model = CrystalGrainModel(stock: stock, reference: reference, layer: layer,
                                          grainScale: grainScale)
            anchors.append((stock.curves[layer].density(
                                logExposure: model.logExposure(netDensity: model.readNetDensity)),
                            model.readSigma))
            let curve = stock.curves[layer]
            let lo = curve.dMin, hi = max(curve.dMax, curve.dMin + 1e-3)
            let densities = (0..<Self.tableSamples).map {
                lo + (hi - lo) * Float($0) / Float(Self.tableSamples - 1)
            }
            let fractions = densities.map { density -> [Float] in
                model.binFractions(logExposure: curve.logExposure(density: density))
            }
            var sublayers: [Sublayer] = []
            let fastest = model.bins.first { $0.cloudRadiusMM > 0 }?.cloudRadiusMM ?? 1
            for (b, bin) in model.bins.enumerated()
            where bin.crystalsPerMM2 > 0 && bin.dyePerCloud > 0 {
                // A silver grain is no narrower than its crystal on the ladder, taken as the
                // width at half capacity of its Gaussian: 2σ √(2 ln(edge / ln 2)). A dye cloud
                // spreads over its measured decay length.
                let edge: Float = silver ? Self.silverGrainEdge : 1
                let smallestSigma = silver
                    ? Self.fastestCrystalMM * bin.cloudRadiusMM / fastest
                        / (2 * (2 * log(edge / Float(M_LN2))).squareRoot())
                    : Self.dyeCloudDecayMM
                // About eight coated crystals per cell keeps the Poisson draw short.
                let cell = min(max((8 / bin.crystalsPerMM2).squareRoot(), 0.00025), 0.004)
                sublayers.append(Sublayer(profile: silver ? .silverGrain : .dyeCloud,
                                          coatedPerMM2: bin.crystalsPerMM2,
                                          capacity: silver ? Self.silverGrainDensity : max(bin.pool, 0.05),
                                          edge: edge, smallestSigmaMM: smallestSigma,
                                          dyePerCloudMM2: bin.dyePerCloud, cellMM: cell,
                                          forming: fractions.map { $0[b] }))
            }
            return Record(sublayers: sublayers, dMin: lo, dMax: hi)
        }
        timing.mark("records")
        try anchorToSheet(anchors, key: key, useCache: useCachedAnchor, checkCancellation: checkCancellation)
        timing.mark("anchor")
        timing.report("Film population")
    }

    // MARK: - The sheet's anchor

    /// Solved records, per stock and grain scale. Reapplying a product of calibration factors
    /// changes rounding relative to the successive cold-calibration steps.
    private static let anchorCache = AnchorCache()

    private final class AnchorCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(key: String, records: [Record])] = []
        func get(_ key: String) -> [Record]? {
            lock.lock(); defer { lock.unlock() }
            return entries.first { $0.key == key }?.records
        }
        func set(_ key: String, _ records: [Record]) {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll { $0.key == key }
            entries.append((key, records))
            if entries.count > 4 { entries.removeFirst() }
        }
    }

    static func anchorKey(stock: FilmStock, grainScale: Float) -> String {
        populationKey(identity: FilmGrainAsset.identity(stock: stock, reference: nil),
                      grainScale: grainScale)
    }

    static func populationKey(identity: Data, grainScale: Float) -> String {
        identity.base64EncodedString() + "|\(grainScale.bitPattern)"
    }

    /// The crystal population's dye per crystal was set so that an additive density field
    /// reads the sheet's RMS granularity. Clouds that saturate and light that averages read
    /// differently, so the anchor is taken again on this model's own render: a flat patch at
    /// the sheet's read density, read through the 48 µm aperture, and each crystal's dye
    /// scaled until it reads the sheet — its count by the inverse, so the mean holds and the
    /// cloud's area follows its dye. How far the reading moves with the dye depends on how full
    /// the clouds are, so each step takes the slope the last one measured.
    mutating func anchorToSheet(_ anchors: [(gross: Float, sigma: Float)], key: String,
                               useCache: Bool = true, checkCancellation: () throws -> Void) rethrows {
        try checkCancellation()
        if useCache, let cached = Self.anchorCache.get(key) {
            records = cached
            return
        }
        var solved = [Float](repeating: 1, count: 3)
        let active = monochrome ? [1] : [0, 1, 2]
        for r in active where !records[r].sublayers.isEmpty && anchors[r].sigma > 0 {
            var slope: Float = 0.5
            var last: (factor: Float, sigma: Float)?
            for _ in 0..<Self.anchorPasses {
                try checkCancellation()
                let measured = sigma48(record: r, gross: anchors[r].gross)
                try checkCancellation()
                guard measured > 0 else { break }
                let miss = log(anchors[r].sigma / measured)
                if abs(miss) < Self.anchorTolerance { break }
                if let last, abs(log(solved[r] / last.factor)) > 1e-3 {
                    slope = min(max(log(measured / last.sigma) / log(solved[r] / last.factor),
                                    0.25), 1.5)
                }
                last = (solved[r], measured)
                let step = exp(miss / slope)
                scale(record: r, by: step)
                solved[r] *= step
            }
        }
        if monochrome {
            solved[0] = solved[1]; solved[2] = solved[1]
            for r in [0, 2] { scale(record: r, by: solved[r]) }
        }
        try checkCancellation()
        if useCache { Self.anchorCache.set(key, records) }
    }

    /// Steps the anchor takes at most, and how near the sheet it stops, as a log ratio.
    static let anchorPasses = 8
    static let anchorTolerance: Float = 0.02

    /// Each crystal forms `factor` times the dye, `1 / factor` as many are coated. The cells the
    /// crystals are drawn in stay as they were, so a scaled population is the same crystals.
    mutating func scale(record r: Int, by factor: Float) {
        guard factor > 0, factor != 1 else { return }
        for i in records[r].sublayers.indices {
            records[r].sublayers[i].coatedPerMM2 /= factor
            records[r].sublayers[i].dyePerCloudMM2 *= factor
            records[r].sublayers[i].shape()
        }
    }

    /// RMS granularity of record `r` through the 48 µm aperture on a flat patch at `gross`, read
    /// as a microdensitometer reads it: on the periodic tile the fast road samples, rendered at
    /// the texel pitch where the reference has converged.
    func sigma48(record r: Int, gross: Float) -> Float {
        var timing = StageTiming()
        let light = tileLight(record: r, gross: gross, seed: Self.tileSeed)
        timing.mark("render")
        let sigma = Self.tileSigma48(light)
        timing.mark("covariance")
        timing.report("Film anchor record=\(r)")
        return sigma
    }

    /// Dye one crystal of unit demand length forms as a densitometer reads it — the small-signal
    /// density-area `0.434 ∫ (1 - 10^-dye)` — averaged over the crystals' gamma marks.
    static func unitCloudDye(capacity: Float, edge: Float, profile: Profile) -> Float {
        let shape = Double(markShape)
        // Marks at the gamma's quantile midpoints: deterministic and smooth enough.
        let quantiles = 24
        let marks = (0..<quantiles).map {
            gammaQuantile((Double($0) + 0.5) / Double(quantiles), shape: shape) / shape
        }
        let steps = 800
        let top = profile.reach(peak: Double(edge) * (marks.last ?? 1))
        let dr = top / Double(steps)
        let radii = (0..<steps).map { (Double($0) + 0.5) * dr }
        let values = radii.map { profile.value($0) }
        var total = 0.0
        for mark in marks {
            let peak = Double(edge) * mark
            var area = 0.0
            for i in 0..<steps {
                let dye = Double(capacity) * (1 - exp(-peak * values[i]))
                area += (1 - pow(10, -dye)) * radii[i] * dr
            }
            total += 0.4342944819 * 2 * Double.pi * area
        }
        return Float(total / Double(quantiles))
    }

    /// `E_mark ∫ (1 - exp(-edge · mark · profile(ρ))) d²ρ` for a unit demand length.
    static func unitVoidIntegral(edge: Float, profile: Profile) -> Float {
        let shape = Double(markShape)
        let quantiles = 24
        var total = 0.0
        for q in 0..<quantiles {
            let mark = gammaQuantile((Double(q) + 0.5) / Double(quantiles), shape: shape) / shape
            total += Double(occupiedArea(peak: edge * Float(mark), profile: profile))
        }
        return Float(total / Double(quantiles))
    }

    /// `∫ (1 - exp(-peak · profile(ρ))) d²ρ`: the share of the capacity a crystal of unit demand
    /// length fills, as an area. For the Gaussian it is `2π Ein(peak)` in closed form.
    static func occupiedArea(peak: Float, profile: Profile) -> Float {
        let p = Double(max(peak, 0))
        guard profile == .silverGrain else {
            let steps = 800
            let dr = profile.reach(peak: p) / Double(steps)
            var area = 0.0
            for i in 0..<steps {
                let rho = (Double(i) + 0.5) * dr
                area += (1 - exp(-p * profile.value(rho))) * rho * dr
            }
            return Float(2 * Double.pi * area)
        }
        var ein: Double
        if p < 6 {
            // Ein(p) = Σ (-1)^{k+1} p^k / (k · k!)
            var term = p, sum = 0.0
            for k in 1...60 {
                sum += term / Double(k)
                term *= -p / Double(k + 1)
                if abs(term) < 1e-14 { break }
            }
            ein = sum
        } else {
            // E1 by its asymptotic series is accurate to ~1e-4 here.
            let e1 = exp(-p) / p * (1 - 1 / p + 2 / (p * p) - 6 / (p * p * p))
            ein = e1 + log(p) + 0.5772156649
        }
        return Float(2 * Double.pi * ein)
    }

    /// The record's exact mean density at a point where the grain-free gross density is
    /// `gross`: every sublayer's Campbell mean, summed.
    func pointMean(record r: Int, gross: Float) -> Float {
        let record = records[r]
        let t = min(max((gross - record.dMin) / max(record.dMax - record.dMin, 1e-6), 0), 1)
            * Float(Self.tableSamples - 1)
        let i = min(Int(t), Self.tableSamples - 2), f = t - Float(i)
        var total: Float = 0
        for layer in record.sublayers {
            let fraction = layer.forming[i] * (1 - f) + layer.forming[i + 1] * f
            let developed = layer.coatedPerMM2 * fraction
            total += layer.capacity * (1 - exp(-developed * layer.voidIntegralMM2))
        }
        return total
    }

    /// Quantile of a gamma distribution with integer `shape` and unit scale, by bisection on its
    /// Erlang CDF.
    static func gammaQuantile(_ p: Double, shape: Double) -> Double {
        let k = Int(shape)
        func cdf(_ x: Double) -> Double {
            var term = 1.0, sum = 1.0
            if k > 1 { for n in 1..<k { term *= x / Double(n); sum += term } }
            return 1 - exp(-x) * sum
        }
        var lo = 0.0, hi = shape * 20
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            if cdf(mid) < p { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    // MARK: - Rendering

    /// Sub-samples per pixel side at `pxPerMM`.
    public static func supersample(pxPerMM: Float) -> Int {
        let pitch = 1 / max(pxPerMM, 1e-6)
        return min(max(Int((pitch / finestSampleMM).rounded(.up)), 1), maxSupersample)
    }

    /// How a frame lays the film's grain beyond its amount. None of it rebuilds the tiles: every
    /// setting is the kernel's pitch, footprint, amounts or mix.
    public struct Look: Sendable, Equatable {
        /// Each record's share of the grain amount: red, green then blue sensitive.
        public var layers: SIMD3<Float> = SIMD3(repeating: 1)
        /// 1 keeps the records' grain independent, as the layers lay it; 0 gives all three one
        /// shared grain. The three records' total variance is kept either way.
        public var colour: Float = 1
        /// The film's texture magnified this many times, its fluctuation divided by as much so
        /// that the 48 µm aperture still reads the sheet's granularity: coarser, softer grain of
        /// the same measured RMS above 1, finer below.
        public var size: Float = 1
        /// The side of film each pixel reads, in pixels: 1 for a scan as sharp as its pitch,
        /// wider for a softer scan, which averages the grain down with it.
        public var softness: Float = 1

        public init(layers: SIMD3<Float> = SIMD3(repeating: 1), colour: Float = 1,
                    size: Float = 1, softness: Float = 1) {
            self.layers = layers
            self.colour = colour
            self.size = size
            self.softness = softness
        }

        public static let sizeRange: ClosedRange<Float> = 0.5...4
        public static let softnessRange: ClosedRange<Float> = 0.5...4

        /// The pixel pitch and footprint in tile texels at `pxPerMM`.
        func geometry(pxPerMM: Float) -> (pitch: Float, footprint: Float) {
            let pitch = (1 / pxPerMM) / FilmGrain.tileTexelMM
                / min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
            let softness = min(max(softness, Self.softnessRange.lowerBound), Self.softnessRange.upperBound)
            return (pitch, pitch * softness)
        }

        /// Each record's grain amount at `amount`, the size's compensation included.
        func recordAmounts(_ amount: Float) -> [Float] {
            let size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
            return (0..<3).map { amount * max(layers[$0], 0) / size }
        }

        /// The weights of a record's own grain and of the records' mean in its colour mix.
        static func mix(colour: Float) -> (own: Float, shared: Float) {
            let own = min(max(colour, 0), 1)
            return (own, (3 - 2 * own * own).squareRoot() - own)
        }
    }

    /// Lays the grain on `negative`, the grain-free developed gross density per record, for a
    /// frame of `pxPerMM` pixels per millimetre whose pixel (0, 0) sits at the film's origin,
    /// from the film tiles — the arithmetic of the Halide kernel, which renders frames in grain
    /// mode 1 — scaled by `amount` and laid as `look` lays it.
    public func apply(to negative: ImageBuffer, pxPerMM: Float, seed: UInt32,
                      amount: Float = 1, look: Look = Look()) -> ImageBuffer {
        applyTiled(to: negative, pxPerMM: pxPerMM, seed: seed, amount: amount, look: look)
    }

    /// The reference render: every crystal under the frame, laid and averaged as light. Its
    /// cost is the film's area over the square of the sample spacing; the tiles stand in for it.
    public func applyReference(to negative: ImageBuffer, pxPerMM: Float, seed: UInt64) -> ImageBuffer {
        let width = negative.width, height = negative.height
        let supersample = Self.supersample(pxPerMM: pxPerMM)
        let active = monochrome ? [1] : [0, 1, 2]
        var fluctuations = [[Float]](repeating: [], count: 3)
        for r in active {
            let record = records[r]
            guard !record.sublayers.isEmpty else {
                fluctuations[r] = [Float](repeating: 0, count: width * height)
                continue
            }
            let mean = meanTable(record: r, pxPerMM: pxPerMM, supersample: supersample, seed: seed)
            let plane = negative.planes[r]
            var unused = [Float]()
            let field = render(record: r, width: width, height: height, pxPerMM: pxPerMM,
                               supersample: supersample, seed: seed,
                               grossAt: { x, y in Self.bilinear(plane, width, height, x, y) },
                               pointMeans: &unused, wantPointMeans: false)
            var out = [Float](repeating: 0, count: width * height)
            for i in 0..<(width * height) {
                out[i] = field[i] - Self.lookup(mean, plane[i], record.dMin, record.dMax)
            }
            fluctuations[r] = out
        }
        var planes = negative.planes
        for r in 0..<3 {
            let source = monochrome ? fluctuations[1] : fluctuations[r]
            guard !source.isEmpty else { continue }
            for i in 0..<(width * height) { planes[r][i] += source[i] }
        }
        return ImageBuffer(width: width, height: height, planes: planes)
    }

    /// The model's own mean effective density against gross density at this pitch, so the grain
    /// can be laid about the pipeline's tone. The point mean is exact; what averaging light
    /// rather than density over a pixel takes off it is measured on a flat patch, and that
    /// difference is small and smooth, so the patch's own grain barely moves it.
    func meanTable(record r: Int, pxPerMM: Float, supersample: Int, seed: UInt64) -> [Float] {
        let record = records[r]
        let pitch = 1 / pxPerMM
        let side = min(max(Int((Self.biasPatchMM / pitch).rounded()), 24), 1024)
        return (0..<Self.biasSamples).map { i -> Float in
            let gross = record.dMin + (record.dMax - record.dMin) * Float(i) / Float(Self.biasSamples - 1)
            var point = [Float]()
            let field = render(record: r, width: side, height: side, pxPerMM: pxPerMM,
                               supersample: supersample, seed: seed ^ 0xB1A5_CA11_B1A5_CA11,
                               grossAt: { _, _ in gross }, pointMeans: &point)
            var correction: Float = 0
            for k in field.indices { correction += field[k] - point[k] }
            return pointMean(record: r, gross: gross) + correction / Float(field.count)
        }
    }

    static func lookup(_ table: [Float], _ gross: Float, _ lo: Float, _ hi: Float) -> Float {
        let t = min(max((gross - lo) / max(hi - lo, 1e-6), 0), 1) * Float(table.count - 1)
        let i = min(Int(t), table.count - 2)
        let f = t - Float(i)
        return table[i] * (1 - f) + table[i + 1] * f
    }

    static func bilinear(_ plane: [Float], _ width: Int, _ height: Int, _ x: Float, _ y: Float) -> Float {
        let fx = min(max(x, 0), Float(width - 1)), fy = min(max(y, 0), Float(height - 1))
        let x0 = min(Int(fx), max(width - 2, 0)), y0 = min(Int(fy), max(height - 2, 0))
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let ax = fx - Float(x0), ay = fy - Float(y0)
        let top = plane[y0 * width + x0] * (1 - ax) + plane[y0 * width + x1] * ax
        let bottom = plane[y1 * width + x0] * (1 - ax) + plane[y1 * width + x1] * ax
        return top * (1 - ay) + bottom * ay
    }

    /// Effective density above base per pixel of record `r`, tile by tile. `grossAt` gives the
    /// grain-free gross density at a point in pixel coordinates (pixel centres at integers).
    /// `pointMeans` receives each pixel's mean density over its samples — density averaged
    /// rather than light — when `wantPointMeans`.
    func render(record r: Int, width: Int, height: Int, pxPerMM: Float, supersample: Int,
                seed: UInt64, grossAt: @escaping @Sendable (Float, Float) -> Float,
                pointMeans: inout [Float], wantPointMeans: Bool = true,
                periodMM: Float? = nil) -> [Float] {
        let tile = 48
        let tilesX = (width + tile - 1) / tile, tilesY = (height + tile - 1) / tile
        let output = UnsafeMutableBufferPointer<Float>.allocate(capacity: width * height)
        output.initialize(repeating: 0)
        defer { output.deallocate() }
        let means = UnsafeMutableBufferPointer<Float>.allocate(capacity: wantPointMeans ? width * height : 1)
        means.initialize(repeating: 0)
        defer { means.deallocate() }
        let record = records[r]
        let box = Sendable_Box(output)
        let meanBox = wantPointMeans ? Sendable_Box(means) : nil
        DispatchQueue.concurrentPerform(iterations: tilesX * tilesY) { index in
            let tx = index % tilesX, ty = index / tilesX
            let x0 = tx * tile, y0 = ty * tile
            let tw = min(tile, width - x0), th = min(tile, height - y0)
            Self.renderTile(record: record, recordIndex: r, x0: x0, y0: y0, tw: tw, th: th,
                            pxPerMM: pxPerMM, supersample: supersample, seed: seed,
                            grossAt: grossAt, into: box.pointer, means: meanBox?.pointer, width: width,
                            periodMM: periodMM)
        }
        if wantPointMeans { pointMeans = Array(means) }
        return Array(output)
    }

    private final class Sendable_Box: @unchecked Sendable {
        let pointer: UnsafeMutableBufferPointer<Float>
        init(_ pointer: UnsafeMutableBufferPointer<Float>) { self.pointer = pointer }
    }

    static func renderTile(record: Record, recordIndex: Int, x0: Int, y0: Int, tw: Int, th: Int,
                           pxPerMM: Float, supersample s: Int, seed: UInt64,
                           grossAt: (Float, Float) -> Float,
                           into output: UnsafeMutableBufferPointer<Float>,
                           means: UnsafeMutableBufferPointer<Float>?, width: Int,
                           periodMM: Float? = nil) {
        let pitch = 1 / pxPerMM
        let h = pitch / Float(s)
        let sw = tw * s, sh = th * s
        // Film rectangle of the tile's samples, mm; sample (i, j) centred at
        // (fx0 + (i + 0.5) h, fy0 + (j + 0.5) h).
        let fx0 = Float(x0) * pitch, fy0 = Float(y0) * pitch
        let ln10: Float = 2.302585093
        // Per sample, over the sublayers: log of the light it passes, and its density (for the
        // mean, which averages density rather than light).
        var logTransmit = [Float](repeating: 0, count: sw * sh)
        var density = [Float](repeating: 0, count: sw * sh)
        // Per sublayer: the resolved clouds' summed demand over capacity at each sample, and the
        // log of the share of each sample cell the sub-sample grains leave uncovered.
        var demand = [Float](repeating: 0, count: sw * sh)
        var logUncovered = [Float](repeating: 0, count: sw * sh)
        let tableScale = Float(tableSamples - 1) / max(record.dMax - record.dMin, 1e-6)
        let shape = markShape

        for (b, layer) in record.sublayers.enumerated() {
            for i in demand.indices { demand[i] = 0; logUncovered[i] = 0 }
            let sigma = layer.sigmaMM
            let edge = layer.peakDemand / layer.capacity
            // A cloud two samples wide is point-sampled — each sample is a point of the
            // continuous field. One under half a sample would fall between samples, so it lays
            // the area it fills instead, as a square of that area over the cells it overlaps.
            // Between the two it lays both, weighted, so that a cloud growing through the
            // sample size changes the film smoothly: the anchor scales clouds through it.
            let resolvedShare = min(max((sigma / h - 0.5) / 1.5, 0), 1)
            // A dye cloud's demand adds before it saturates, so a sublayer's clouds are one
            // field: each developed crystal leaves its peak demand at its place, on a grid
            // `margin` samples wider than the tile, which the profile's terms then blur.
            let dye = layer.profile == .dyeCloud
            let margin = dye
                ? Int((3.5 * Self.dyeCloudTerms.last!.sigma * sigma / h).rounded(.up)) + 1 : 0
            let gw = sw + 2 * margin, gh = sh + 2 * margin
            var deposits = [Float](repeating: 0, count: dye ? gw * gh : 0)
            let reach = dye ? Float(margin) * h
                : resolvedShare > 0 ? 4.2 * sigma : 3 * sigma + h
            // A periodic film repeats its crystals every `periodMM`, so its cells must divide it.
            let periodCells = periodMM.map { max(Int(($0 / layer.cellMM).rounded()), 1) }
            let cell = periodMM.map { $0 / Float(periodCells!) } ?? layer.cellMM
            let meanPerCell = layer.coatedPerMM2 * cell * cell
            let cx0 = Int(((fx0 - reach) / cell).rounded(.down))
            let cx1 = Int(((fx0 + Float(sw) * h + reach) / cell).rounded(.down))
            let cy0 = Int(((fy0 - reach) / cell).rounded(.down))
            let cy1 = Int(((fy0 + Float(sh) * h + reach) / cell).rounded(.down))
            let inverseTwoSigma2 = 1 / (2 * sigma * sigma)
            for cy in cy0...cy1 {
                for cx in cx0...cx1 {
                    let hx = periodCells.map { ((cx % $0) + $0) % $0 } ?? cx
                    let hy = periodCells.map { ((cy % $0) + $0) % $0 } ?? cy
                    // The count takes a stream of its own, so the crystals' draws do not move
                    // with it.
                    var counter = FilmRandom(seed: seed ^ 0xC0DE_C0DE_C0DE_C0DE, record: recordIndex,
                                             sublayer: b, x: hx, y: hy)
                    let count = counter.poisson(meanPerCell)
                    var rng = FilmRandom(seed: seed, record: recordIndex, sublayer: b, x: hx, y: hy)
                    for _ in 0..<count {
                        // Every crystal draws the same numbers whether or not it develops, so the
                        // coating is one film under any exposure.
                        let px = (Float(cx) + rng.uniform()) * cell
                        let py = (Float(cy) + rng.uniform()) * cell
                        let develop = rng.uniform()
                        var mark: Float = 0
                        for _ in 0..<shape { mark -= log(max(rng.uniform(), 1e-7)) }
                        mark /= Float(shape)
                        // Local development: the developed fraction where the crystal sits.
                        let gross = grossAt(px * pxPerMM - 0.5, py * pxPerMM - 0.5)
                        let t = min(max((gross - record.dMin) * tableScale, 0), Float(tableSamples - 1))
                        let ti = min(Int(t), tableSamples - 2)
                        let tf = t - Float(ti)
                        let fraction = layer.forming[ti] * (1 - tf) + layer.forming[ti + 1] * tf
                        guard develop < fraction else { continue }
                        let lx = (px - fx0) / h, ly = (py - fy0) / h   // in sample units, edges at integers
                        if dye {
                            // Shared between the four grid samples around it, by distance.
                            let u = lx - 0.5 + Float(margin), v = ly - 0.5 + Float(margin)
                            let i0 = Int(u.rounded(.down)), j0 = Int(v.rounded(.down))
                            let au = u - Float(i0), av = v - Float(j0)
                            let amount = edge * mark
                            for (dj, wy) in [(0, 1 - av), (1, av)] {
                                let j = j0 + dj
                                guard j >= 0, j < gh else { continue }
                                for (di, wx) in [(0, 1 - au), (1, au)] {
                                    let i = i0 + di
                                    guard i >= 0, i < gw else { continue }
                                    deposits[j * gw + i] += amount * wx * wy
                                }
                            }
                            continue
                        }
                        if resolvedShare > 0 {
                            let span = reach / h
                            let ix0 = max(Int((lx - span).rounded(.down)), 0)
                            let ix1 = min(Int((lx + span).rounded(.up)), sw - 1)
                            let iy0 = max(Int((ly - span).rounded(.down)), 0)
                            let iy1 = min(Int((ly + span).rounded(.up)), sh - 1)
                            if ix0 <= ix1, iy0 <= iy1 {
                            let peak = edge * mark * resolvedShare
                            for j in iy0...iy1 {
                                let dy = (Float(j) + 0.5 - ly) * h
                                let rowFactor = peak * exp(-dy * dy * inverseTwoSigma2)
                                if rowFactor < 1e-5 { continue }
                                let base = j * sw
                                for i in ix0...ix1 {
                                    let dx = (Float(i) + 0.5 - lx) * h
                                    demand[base + i] += rowFactor * exp(-dx * dx * inverseTwoSigma2)
                                }
                            }
                            }
                        }
                        if resolvedShare < 1 {
                            let covering = 1 - resolvedShare
                            let side = sigma * Self.occupiedArea(peak: edge * mark, profile: layer.profile).squareRoot() / h
                            let left = lx - side / 2, right = lx + side / 2
                            let top = ly - side / 2, bottom = ly + side / 2
                            let ix0 = max(Int(left.rounded(.down)), 0), ix1 = min(Int(right.rounded(.down)), sw - 1)
                            let iy0 = max(Int(top.rounded(.down)), 0), iy1 = min(Int(bottom.rounded(.down)), sh - 1)
                            guard ix0 <= ix1, iy0 <= iy1 else { continue }
                            for j in iy0...iy1 {
                                let oy = min(bottom, Float(j + 1)) - max(top, Float(j))
                                if oy <= 0 { continue }
                                let base = j * sw
                                for i in ix0...ix1 {
                                    let ox = min(right, Float(i + 1)) - max(left, Float(i))
                                    if ox <= 0 { continue }
                                    logUncovered[base + i] += log(max(1 - covering * ox * oy, 1e-6))
                                }
                            }
                        }
                    }
                }
            }
            if dye {
                // Each term is a normalised Gaussian of `term.sigma` decay lengths; its weight
                // times 2π s² turns the crystal's peak into the mass that blur spreads.
                var across = [Float](repeating: 0, count: gh * sw)
                for term in Self.dyeCloudTerms {
                    let s = term.sigma * sigma / h
                    let radius = max(Int((3.5 * s).rounded(.up)), 1)
                    var kernel = (-radius...radius).map { exp(-Float($0 * $0) / (2 * s * s)) }
                    let total = kernel.reduce(0, +)
                    kernel = kernel.map { $0 / total }
                    let scale = term.weight * 2 * Float.pi * s * s
                    for j in 0..<gh {
                        let row = j * gw + margin - radius
                        for i in 0..<sw {
                            var sum: Float = 0
                            for t in 0..<kernel.count { sum += kernel[t] * deposits[row + i + t] }
                            across[j * sw + i] = sum
                        }
                    }
                    for j in 0..<sh {
                        let top = j + margin - radius
                        for i in 0..<sw {
                            var sum: Float = 0
                            for t in 0..<kernel.count { sum += kernel[t] * across[(top + t) * sw + i] }
                            demand[j * sw + i] += scale * sum
                        }
                    }
                }
            }
            // The sublayer at each sample: resolved dye saturates point by point against the
            // capacity; where sub-sample grains cover the cell, it is at capacity.
            let capacity = layer.capacity
            let full = exp(-ln10 * capacity)
            for i in density.indices {
                let resolvedDye = demand[i] > 0 ? capacity * (1 - exp(-demand[i])) : 0
                let uncovered = logUncovered[i] < 0 ? exp(logUncovered[i]) : 1
                if resolvedDye == 0 && uncovered == 1 { continue }
                density[i] += resolvedDye * uncovered + capacity * (1 - uncovered)
                let passed = uncovered * exp(-ln10 * resolvedDye) + (1 - uncovered) * full
                logTransmit[i] += log(max(passed, 1e-12))
            }
        }
        // Light averaged over each pixel's samples; density averaged too, for the mean.
        let norm = 1 / Float(s * s)
        for py in 0..<th {
            for px in 0..<tw {
                var transmitted: Float = 0, averaged: Float = 0
                for j in 0..<s {
                    let base = (py * s + j) * sw + px * s
                    for i in 0..<s {
                        transmitted += exp(logTransmit[base + i])
                        averaged += density[base + i]
                    }
                }
                output[(y0 + py) * width + x0 + px] = -log10(max(transmitted * norm, 1e-6))
                means?[(y0 + py) * width + x0 + px] = averaged * norm
            }
        }
    }
}

/// Counter-based draws for one film cell of one sublayer: the same cell always draws the same.
struct FilmRandom {
    var state: UInt64

    init(seed: UInt64, record: Int, sublayer: Int, x: Int, y: Int) {
        var h = seed ^ 0x9E37_79B9_7F4A_7C15
        h = Self.mix(h ^ UInt64(bitPattern: Int64(record &* 0x1F1F + sublayer &* 0x2B)))
        h = Self.mix(h ^ UInt64(bitPattern: Int64(x)))
        h = Self.mix(h ^ (UInt64(bitPattern: Int64(y)) &* 0xD6E8_FEB8_6659_FD93))
        state = h
    }

    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        return Self.mix(state)
    }

    /// Uniform in (0, 1).
    mutating func uniform() -> Float {
        (Float(next() >> 40) + 0.5) * (1 / 16_777_216)
    }

    /// Poisson count of mean `mean` from one uniform, by the inverse of its distribution: the
    /// same draw gives a count that only grows with the mean, so a cell whose mean moves keeps
    /// its crystals and gains or loses the last few.
    mutating func poisson(_ mean: Float) -> Int {
        guard mean > 0 else { return 0 }
        let u = Double(uniform())
        let m = Double(min(mean, 600))
        var term = exp(-m), total = term, count = 0
        while u > total && count < 4096 {
            count += 1
            term *= m / Double(count)
            total += term
        }
        return count
    }
}
