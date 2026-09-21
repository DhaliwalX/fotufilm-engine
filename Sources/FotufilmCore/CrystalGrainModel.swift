import Foundation
import FotufilmHalide

/// Stock-authoring parameters for the organic crystal model. These are effective model
/// populations, not a measurement of silver mass or a unique reconstruction of the emulsion.
public struct CrystalGrainPopulation: Codable, Equatable, Sendable {
    /// Maximum radius ratio on the class ladder; 1 gives equal radii.
    public let radiusSpan: Float
    /// Target fractions of fitted density weight, fastest to slowest. Whole speed classes
    /// are assigned at cumulative boundaries, then weights are refitted to the tone curve;
    /// these are not guaranteed final crystal-count or silver-mass fractions.
    public let sublayerShares: [Float]
    /// Effective crystal count relative to the RMS-anchored population. Each crystal forms
    /// inversely as much dye, preserving mean demand and pool capacity. The model's RMS
    /// becomes the sheet anchor / sqrt(scale). Keep 1 when matching a measured RMS anchor.
    public let coatingDensityScale: Float

    public init(radiusSpan: Float, sublayerShares: [Float], coatingDensityScale: Float) {
        precondition(Self.valid(radiusSpan, sublayerShares, coatingDensityScale),
                     "invalid crystal grain population")
        self.radiusSpan = radiusSpan
        self.sublayerShares = sublayerShares
        self.coatingDensityScale = coatingDensityScale
    }

    private static func valid(_ span: Float, _ shares: [Float], _ scale: Float) -> Bool {
        span.isFinite && (1...20).contains(span)
            && shares.count == CrystalGrainModel.binCount
            && shares.allSatisfy { $0.isFinite && $0 > 0 && $0 < 1 }
            && abs(shares.reduce(0, +) - 1) <= 1e-5
            && scale.isFinite && (0.25...4).contains(scale)
    }

    private enum CodingKeys: String, CodingKey {
        case radiusSpan, sublayerShares, coatingDensityScale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let span = try c.decode(Float.self, forKey: .radiusSpan)
        let shares = try c.decode([Float].self, forKey: .sublayerShares)
        let scale = try c.decode(Float.self, forKey: .coatingDensityScale)
        guard Self.valid(span, shares, scale) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "crystalGrainPopulation requires radiusSpan in 1...20, four positive sublayerShares summing to 1, and coatingDensityScale in 0.25...4"))
        }
        self.init(radiusSpan: span, sublayerShares: shares, coatingDensityScale: scale)
    }
}

/// Grain formed by the crystals that form the image, for `GrainModel.crystals`, in the three
/// stages a real emulsion's grain passes through.
///
/// **Exposure** decides which crystals will develop. One record of an emulsion is a population
/// of silver halide crystals; each has a speed — the exposure at which it absorbs one photon on
/// average — and holds a developable latent image once a Poisson number of absorbed photons
/// reaches the threshold of three. The record's characteristic curve is what that population
/// forms, so the population is read off the curve: non-negative weights on a ladder of speed
/// classes whose threshold-hit responses add up to the curve above base. Speed goes with volume
/// (Mees & James), so the same ladder places each class on a size ladder, `r ∝ 10^(-E0 / 3)`,
/// clipped to the stock-authored span. Nothing here depends on the
/// developer; `Exposure` is the coating and the light.
///
/// **Development** turns latent crystals into what is seen. A developed crystal forms dye, or
/// silver, in proportion to its projected area, `d ∝ r²`, and not the same amount every time:
/// each forms `1 ± 0.5` of its sublayer's mean, the two-point stand-in for the developed-grain
/// mass distribution. The developer's diffusion spreads each crystal's dye to a cloud — the
/// fastest sublayer's cloud is `FilmStock.grainSizeMM`, the coarsest structure a scan resolves,
/// and the rest follow the size ladder down from it. The classes are coated as sublayers from
/// the fastest down, using the stock's target density-weight shares, each
/// with its own finite coupler pool: with `demand` the dye its developed crystals
/// ask for, the dye that forms is `C (1 - exp(-demand / C))`, sized so that once the whole
/// sublayer has developed a further crystal forms a tenth of what an unstarved one would. That
/// starvation is what makes granularity fall past its peak; silver has no pool. Reversal dye
/// forms in the crystals the first developer left, fog develops a share of every class, and a
/// pushed or pulled process is the same population developed differently: the sub-threshold
/// centres it reaches and the mass each crystal grows to are refitted to the condition's
/// measured curve with the coating held. `Development` is everything the tank decides.
///
/// **Print** is what the paper sees and what it adds. The negative's developed field reaches
/// the paper through the enlarger's spread and the paper's curve, which the pipeline already
/// lays; the paper — or the release print's film — is an emulsion of its own, and its
/// developed crystals are a Poisson field at the paper's own activation. `Print` derives that
/// population from the silver chloride cubes a colour paper coats.
///
/// Two measurements anchor the scale: the sheet's RMS granularity at its read density fixes the
/// dye one crystal of the reference size forms at the reference process, and with it how many
/// crystals the record coats per square millimetre; `grainSizeMM` fixes the cloud. Each stock
/// authors its population width and allocation; an explicit coating-density scale also
/// changes RMS and must not be mistaken for a measured stock calibration.
public struct CrystalGrainModel: Sendable {
    /// Size bins per record, matching FOTUFILM_CRYSTAL_GRAIN_BINS.
    public static let binCount = Int(FOTUFILM_CRYSTAL_GRAIN_BINS)
    /// Samples of the per-bin count table, matching FOTUFILM_CRYSTAL_GRAIN_SAMPLES.
    public static let samples = Int(FOTUFILM_CRYSTAL_GRAIN_SAMPLES)
    /// Log-exposure grid the fits and the density inversion run on.
    static let fitLogExposures: [Float] = stride(from: -4.0, through: 4.0, by: 0.05)
        .map { Float($0) }

    // MARK: - Stage 1: exposure

    /// The coating and the light: the crystal population and which of its crystals a given
    /// exposure leaves developable.
    public struct Exposure: Sendable {
        /// Speed classes: log10 exposure at which a crystal of the class absorbs one photon on
        /// average, relative to mid-grey, in the pack curves' own units.
        public static let classLogExposures: [Float] = stride(from: -3.0, through: 4.0, by: 0.2)
            .map { Float($0) }
        /// Absorbed photons a crystal needs before it develops in the reference process.
        public static let hitThreshold = 3
        /// Speed goes with volume: log10 radius per decade of speed.
        public static let sizeExponent: Float = 1.0 / 3.0

        /// Coating weight per speed class: the density the class forms at full, unstarved
        /// development in the reference process. Zero for classes the record does not coat.
        public var weights: [Float]
        /// log10 crystal radius per class relative to the ladder, clipped to the span.
        public var logRadius: [Float]

        /// Probability a crystal of the class has absorbed exactly `hits` photons at
        /// `logExposure`.
        public static func hitProbability(exactly hits: Int, logExposure: Float,
                                          classLogExposure: Float) -> Float {
            let mean = Double(pow(10, logExposure - classLogExposure))
            var term = exp(-mean)
            if hits > 0 { for n in 1...hits { term *= mean / Double(n) } }
            return Float(min(max(term, 0), 1))
        }

        /// Fraction of a class developable at `logExposure` in the reference process: a
        /// Poisson hit count of mean `10^(logExposure - classLogExposure)` reaching
        /// `hitThreshold`.
        public static func hitFraction(logExposure: Float, classLogExposure: Float) -> Float {
            let mean = Double(pow(10, logExposure - classLogExposure))
            var term = 1.0, below = 1.0
            for hits in 1..<hitThreshold {
                term *= mean / Double(hits)
                below += term
            }
            return Float(min(max(1 - exp(-mean) * below, 0), 1))
        }

        /// Fraction of a class the process develops at `logExposure`. `developability` is the
        /// process's reach into the latent image: 1 develops exactly the threshold centres,
        /// below 1 that share of them — a pulled, shorter development that leaves some
        /// threshold centres undeveloped — and above 1 all of them plus that excess of the
        /// sub-threshold centres one hit short, which a pushed, longer development reaches.
        public static func latentFraction(logExposure: Float, classLogExposure: Float,
                                          developability: Float) -> Float {
            let threshold = hitFraction(logExposure: logExposure, classLogExposure: classLogExposure)
            if developability <= 1 { return threshold * max(developability, 0) }
            let short = hitProbability(exactly: hitThreshold - 1, logExposure: logExposure,
                                       classLogExposure: classLogExposure)
            return min(threshold + (developability - 1) * short, 1)
        }

        /// The developable fraction of every class at `logExposure`.
        public func latentFractions(logExposure: Float, developability: Float) -> [Float] {
            Self.classLogExposures.map { e0 in
                Self.latentFraction(logExposure: logExposure, classLogExposure: e0,
                                    developability: developability)
            }
        }
    }

    // MARK: - Stage 2: development

    /// Everything the tank decides: what each latent crystal grows to, how far its dye spreads,
    /// what its sublayer's coupler allows, and how far the process reaches into the latent image.
    public struct Development: Sendable {
        /// Fraction of an unstarved crystal's dye a further crystal forms once its sublayer has
        /// fully developed.
        public static let poolGain: Float = 0.1
        /// What a developed crystal forms goes with its projected area.
        public static let dyeExponent: Float = 2
        /// Each developed crystal forms `1 ± markDispersion` of its sublayer's mean: the
        /// two-point stand-in for the developed-grain mass distribution, whose second moment
        /// `1 + d²` Dainty and Shaw put at 1.2–1.5 for coated emulsions. Matches the kernel's
        /// `kCrystalMarkDispersion`.
        public static let markDispersion: Float = 0.5
        /// Second moment of the marks: what the dispersion multiplies a Poisson variance by.
        public static var markSecondMoment: Float { 1 + markDispersion * markDispersion }
        /// The developability grid a condition's refit searches, reference process at 1.
        static let developabilities: [Float] = stride(from: 0.3, through: 1.8, by: 0.05)
            .map { Float($0) }

        /// One coated sublayer: the crystals of one size bin as this process develops them.
        public struct Bin: Sendable, Equatable {
            /// Radius of the dye cloud — or developed silver grain — one crystal forms, mm.
            public var cloudRadiusMM: Float
            /// Density × mm² one cloud carries on average.
            public var dyePerCloud: Float
            /// Crystals coated per mm² — the coating's, unchanged by the process.
            public var crystalsPerMM2: Float
            /// The sublayer's coupler pool in density; 0 for silver, which has none.
            public var pool: Float
            /// Dye the sublayer asks for when every crystal has developed, in density.
            public var demandAtFull: Float
            /// How much more each crystal forms in this process than in the reference one.
            public var gain: Float
            /// The speed classes in the bin and their shares of its weight.
            public var classes: [Int]
            public var shares: [Float]
        }

        public var bins: [Bin]
        public var isReversal: Bool
        public var isSilver: Bool
        /// Fraction of every class fog develops regardless of exposure.
        public var fogFraction: Float
        /// The process's reach into the latent image (`Exposure.latentFraction`): 1 at the
        /// reference process.
        public var developability: Float
        /// Largest departure of the developed sublayers' mean from the record's curve over the
        /// fit grid.
        public var fitError: Float

        /// Dye one unit of weight forms when `forming` of its crystals form dye through a pool
        /// whose gain at full development is `gain`: `(1 - gain^forming) / (1 - gain)`.
        static func saturated(_ forming: Float, gain: Float) -> Float {
            gain >= 1 ? forming : (1 - pow(gain, forming)) / (1 - gain)
        }

        /// Dye a sublayer forms from `demand` against `pool`; silver's pool of 0 forms what it
        /// asks.
        static func dye(demand: Float, pool: Float) -> Float {
            pool > 0 ? pool * (1 - exp(-demand / pool)) : demand
        }

        /// Dye-forming fraction of every class at `logExposure`, fog included.
        public func formingFractions(exposure: Exposure, logExposure: Float) -> [Float] {
            exposure.latentFractions(logExposure: logExposure, developability: developability)
                .map { latent in
                    let developed = 1 - (1 - latent) * (1 - fogFraction)
                    return isReversal ? 1 - developed : developed
                }
        }

        /// Each bin's mean dye-forming fraction at `logExposure`.
        public func binFractions(exposure: Exposure, logExposure: Float) -> [Float] {
            let fractions = formingFractions(exposure: exposure, logExposure: logExposure)
            return bins.map { bin in
                zip(bin.classes, bin.shares).reduce(Float(0)) { $0 + fractions[$1.0] * $1.1 }
            }
        }

        /// Density above base the sublayers form at `logExposure` — what the kernel's mean is.
        public func meanDensity(exposure: Exposure, logExposure: Float) -> Float {
            let fractions = binFractions(exposure: exposure, logExposure: logExposure)
            var total: Float = 0
            for (bin, fraction) in zip(bins, fractions) {
                total += Self.dye(demand: bin.demandAtFull * fraction, pool: bin.pool)
            }
            return total
        }

        /// Density fluctuation variance through the 48 µm aperture at `logExposure`, in
        /// density².
        ///
        /// Each bin's developed crystals are a Poisson count with marks, so the variance of the
        /// dye they ask for is the count times the mean dye per crystal squared times the marks'
        /// second moment; the pool's gain at the bin's mean demand squares onto it, and the
        /// aperture keeps of a cloud's variance what its response to a Gaussian of the cloud's
        /// radius says.
        public func apertureVariance(exposure: Exposure, logExposure: Float) -> Float {
            let fractions = binFractions(exposure: exposure, logExposure: logExposure)
            let apertureArea = Float.pi * FilmStock.granularityApertureRadiusMM
                * FilmStock.granularityApertureRadiusMM
            var total: Float = 0
            for (bin, fraction) in zip(bins, fractions)
            where bin.cloudRadiusMM > 0 && bin.dyePerCloud > 0 {
                let demand = bin.demandAtFull * fraction
                let poolGain = bin.pool > 0 ? exp(-demand / bin.pool) : 1
                // N f d² (1 + δ²), with N d the demand at full.
                let developed = bin.crystalsPerMM2 * fraction
                let asked = developed * bin.dyePerCloud * bin.dyePerCloud * Self.markSecondMoment
                let response = FilmStock.granularityApertureResponse(clumpSigmaMM: bin.cloudRadiusMM / 2)
                total += poolGain * poolGain * asked * response * response / apertureArea
            }
            return total
        }
    }

    // MARK: - Stage 3: print

    /// The print material's own crystals: the emulsion the negative's light exposes.
    ///
    /// A colour paper coats cubic silver chloride crystals — 0.2 to 0.5 µm on edge in Kodak's
    /// and Fuji's patents, chosen for the rapid, complete development a minilab's process asks
    /// for — at a few tenths of a gram of silver per square metre per record, with coupler in
    /// excess. Every crystal that develops forms its share of the record's range, so the
    /// paper's grain is a plain Poisson field: no pool, and no sheet to anchor it to, because
    /// no manufacturer publishes a paper's granularity. The count per coated area follows from
    /// the edge and the coating weight alone.
    public enum Print {
        /// Edge of the paper's cubic crystals, mm.
        public static let crystalEdgeMM: Float = 0.25e-3
        /// Silver coated per record, g/m².
        public static let silverGramsPerM2: Float = 0.2
        /// Density of silver chloride, g/cm³.
        public static let silverChlorideDensity: Float = 5.56
        /// Coating weights are expressed as silver, not AgCl. CIAAW atomic weights give
        /// Ag / (Ag + Cl); omitting chlorine's mass undercounts the coated crystals.
        public static let silverMassFraction: Float = 107.8682 / (107.8682 + 35.45)
        /// The sheet a negative is printed on when nothing says otherwise: 8 × 10 in, its short
        /// edge filled by the frame's. A release print is a contact print, magnified by one.
        public static let sheetShortEdgeMM: Float = 203.2

        /// Crystals the paper coats per mm²: the silver per area over the silver per crystal.
        public static var crystalsPerMM2: Float {
            let gramsPerMM2 = silverGramsPerM2 * 1e-6
            let gramsPerMM3 = silverChlorideDensity * 1e-3
            let silverPerCrystal = gramsPerMM3 * crystalEdgeMM * crystalEdgeMM * crystalEdgeMM
                * silverMassFraction
            return gramsPerMM2 / silverPerCrystal
        }

        /// Whether the medium exposes an emulsion of its own. A viewed transparency, a scan,
        /// the screen's fixed receiver and the negative itself expose none.
        public static func exposesCrystals(stock: FilmStock, paper: PrintPaper) -> Bool {
            !paper.viewsFilmDirectly(for: stock) && !stock.isReflectionPrint
                && paper != .screen && !paper.isScan && !paper.isNegative
        }

        /// The size of one output pixel on the print, mm: the frame's short edge fills the
        /// sheet's. A crop retains the corresponding fraction of the original sheet instead
        /// of enlarging the crop to fill a new sheet. A contact print's pixel is the negative's.
        public static func pixelMM(paper: PrintPaper, shortEdgePixels: Int, pxPerMM: Float,
                                   frameCoverage: Float = 1) -> Float {
            if paper.isProjected { return pxPerMM > 0 ? 1 / pxPerMM : 0 }
            let coverage = min(max(frameCoverage, 0.05), 1)
            return shortEdgePixels > 0 ? sheetShortEdgeMM * coverage / Float(shortEdgePixels) : 0
        }

        /// Crystals of the print material one output pixel holds at full development.
        public static func crystalsPerPixel(paper: PrintPaper, shortEdgePixels: Int,
                                            pxPerMM: Float, frameCoverage: Float = 1) -> Float {
            let pixel = pixelMM(paper: paper, shortEdgePixels: shortEdgePixels, pxPerMM: pxPerMM,
                                frameCoverage: frameCoverage)
            return crystalsPerMM2 * pixel * pixel
        }

        /// The paper's own RMS granularity through the 48 µm aperture where a record of `range`
        /// has formed `netDensity` above base: a Poisson field of `N f` crystals per area each
        /// forming `range / N`, with the marks' second moment.
        public static func sigma(netDensity: Float, range: Float) -> Float {
            let apertureArea = Float.pi * FilmStock.granularityApertureRadiusMM
                * FilmStock.granularityApertureRadiusMM
            let perCrystal = range / crystalsPerMM2
            let developed = max(netDensity, 0) / max(perCrystal, 1e-9)
            return (developed * perCrystal * perCrystal * Development.markSecondMoment
                    / apertureArea).squareRoot()
        }
    }

    // MARK: - The record

    public var exposure: Exposure
    public var development: Development
    /// The record's density above base at the sheet's read point, and the model's sigma there —
    /// the published figure it was scaled to.
    public var readNetDensity: Float
    public var readSigma: Float
    var dMin: Float
    var range: Float
    var curve: CharacteristicCurve

    public var bins: [Development.Bin] { development.bins }
    public var weights: [Float] { exposure.weights }
    public var fitError: Float { development.fitError }
    public var fogFraction: Float { development.fogFraction }
    public var isReversal: Bool { development.isReversal }
    public var isSilver: Bool { development.isSilver }
    public static var classLogExposures: [Float] { Exposure.classLogExposures }
    public static func hitFraction(logExposure: Float, classLogExposure: Float) -> Float {
        Exposure.hitFraction(logExposure: logExposure, classLogExposure: classLogExposure)
    }

    /// Builds the model for record `layer` of `stock` as developed. `reference` is the same
    /// roll at the pack's reference process — the coating the population is read from and the
    /// sheet's granularity anchors; when it is nil or identical, `stock` is at the reference
    /// process. `grainScale` is the user's grain multiplier: a stock that is `s` times grainier
    /// at the same speed and density coats crystals `s` times wider that each form `s²` the
    /// dye, `1/s²` as many of them.
    public init(stock: FilmStock, reference: FilmStock? = nil, layer: Int, grainScale: Float = 1) {
        let referenceStock = reference ?? stock
        let population = referenceStock.crystalGrainPopulation
        let referenceCurve = referenceStock.curves[layer]
        let developedCurve = stock.curves[layer]
        curve = developedCurve
        dMin = developedCurve.dMin
        range = max(developedCurve.dMax - developedCurve.dMin, 1e-3)
        let reversal = stock.isReversal
        let silver = stock.grainDensityLaw == .silver
        let gain: Float = silver ? 1 : Development.poolGain
        let kappa: Float = gain >= 1 ? 1 : -log(gain) / (1 - gain)

        // Exposure: the population that forms the reference curve. The basis is what one unit
        // of a class's weight forms through its own pool at the reference process, so the fit
        // stays linear in the weights.
        let classes = Exposure.classLogExposures
        let targets = Self.fitLogExposures.map {
            referenceCurve.density(logExposure: $0) - referenceCurve.dMin
        }
        let basis: [[Double]] = Self.fitLogExposures.map { x in
            classes.map { e0 -> Double in
                let p = Exposure.hitFraction(logExposure: x, classLogExposure: e0)
                let forming = reversal ? 1 - p : p
                let dye = Development.saturated(forming, gain: gain)
                return Double(reversal ? 1 - dye : dye)
            }
        }
        var weights = Self.nonNegativeLeastSquares(basis: basis, targets: targets.map(Double.init))
        var worst: Float = 0
        for (row, target) in zip(basis, targets) {
            let formed = zip(row, weights).reduce(0) { $0 + $1.0 * Double($1.1) }
            worst = max(worst, abs(Float(formed) - target))
        }
        let totalWeight = weights.reduce(0, +)
        let fogFraction = totalWeight > 0 ? min(stock.grainFogDensity / totalWeight, 0.5) : 0

        // Size from speed, over the span a record holds, centred on the weight's log-mean.
        let active = weights.indices.filter { weights[$0] > 1e-6 * (weights.max() ?? 0) }
        var logRadius = classes.map { -Exposure.sizeExponent * $0 }
        if !active.isEmpty {
            let mean = active.reduce(Float(0)) { $0 + weights[$1] * logRadius[$1] }
                / active.reduce(Float(0)) { $0 + weights[$1] }
            let half = log10(population.radiusSpan) / 2
            logRadius = logRadius.map { min(max($0, mean - half), mean + half) }
        }

        // Development: sublayers along speed, fastest first, at authored cumulative
        // density-weight boundaries.
        var bins: [Development.Bin] = []
        if !active.isEmpty {
            let ordered = active  // class index ascending is speed descending
            let activeWeight = ordered.reduce(Float(0)) { $0 + weights[$1] }
            var cuts: [Float] = []
            var boundary: Float = 0
            for share in population.sublayerShares.dropLast() {
                boundary += share
                cuts.append(boundary)
            }
            var members = [[Int]](repeating: [], count: Self.binCount)
            var cumulative: Float = 0
            for k in ordered {
                cumulative += weights[k]
                let fraction = cumulative / activeWeight - 1e-6
                let bin = min(cuts.firstIndex { fraction < $0 } ?? Self.binCount - 1, Self.binCount - 1)
                members[bin].append(k)
            }
            for ks in members where !ks.isEmpty {
                let weight = ks.reduce(Float(0)) { $0 + weights[$1] }
                let logMean = ks.reduce(Float(0)) { $0 + weights[$1] * logRadius[$1] } / weight
                bins.append(Development.Bin(
                    cloudRadiusMM: pow(10, logMean), dyePerCloud: 0, crystalsPerMM2: 0,
                    pool: 0, demandAtFull: weight * kappa, gain: 1,
                    classes: ks, shares: ks.map { weights[$0] / weight }))
            }
        }
        // The sublayers are what render, each drawing on one pool at its own mean developed
        // fraction, and that is not quite the sum of its classes each drawing on their own. So
        // the sublayer weights are refitted to the curve with their class shares held — a
        // linear fit again, in as many unknowns as there are sublayers — and the classes
        // follow their sublayer.
        if !bins.isEmpty {
            let binBasis: [[Double]] = Self.fitLogExposures.map { x in
                let fractions = classes.map { e0 in
                    Exposure.hitFraction(logExposure: x, classLogExposure: e0)
                }
                return bins.map { bin -> Double in
                    let developed = zip(bin.classes, bin.shares).reduce(Float(0)) {
                        $0 + fractions[$1.0] * $1.1
                    }
                    let forming = reversal ? 1 - developed : developed
                    let dye = Development.saturated(forming, gain: gain)
                    return Double(reversal ? 1 - dye : dye)
                }
            }
            let refitted = Self.nonNegativeLeastSquares(basis: binBasis,
                                                        targets: targets.map(Double.init))
            for i in bins.indices {
                let before = bins[i].demandAtFull / kappa
                let scale = before > 0 ? refitted[i] / before : 0
                bins[i].demandAtFull = refitted[i] * kappa
                for k in bins[i].classes { weights[k] *= scale }
            }
            worst = 0
            for (row, target) in zip(binBasis, targets) {
                let formed = zip(row, refitted).reduce(0) { $0 + $1.0 * Double($1.1) }
                worst = max(worst, abs(Float(formed) - target))
            }
        }
        // Empty bins — a record whose fit needed fewer sublayers — carry nothing: a zero count
        // table and a zero cloud, which the kernel adds as nothing.
        while bins.count < Self.binCount {
            bins.append(Development.Bin(cloudRadiusMM: 0, dyePerCloud: 0, crystalsPerMM2: 0,
                                        pool: 0, demandAtFull: 0, gain: 1, classes: [],
                                        shares: []))
        }

        // The fastest sublayer's cloud is the scan-resolved clump radius; the rest follow the
        // size ladder, and what each forms follows its area. Until the sheet's figure is in,
        // the dye per cloud is relative and the count is what the weight implies of it.
        let anchor = referenceStock.grainSizeMM * referenceStock.grainLayerSizeRatio[layer] * grainScale
        let fastest = bins[0].cloudRadiusMM
        for i in bins.indices where bins[i].cloudRadiusMM > 0 {
            let relative = bins[i].cloudRadiusMM / fastest
            bins[i].cloudRadiusMM = anchor * relative
            bins[i].dyePerCloud = pow(relative, Development.dyeExponent)
            bins[i].pool = silver ? 0 : bins[i].demandAtFull / -log(gain)
            bins[i].crystalsPerMM2 = bins[i].demandAtFull / bins[i].dyePerCloud
        }
        exposure = Exposure(weights: weights, logRadius: logRadius)
        development = Development(bins: bins, isReversal: reversal, isSilver: silver,
                                  fogFraction: fogFraction, developability: 1, fitError: worst)

        // The sheet's figure fixes the dye per crystal of the reference size at the reference
        // process, and with it the crystal count every weight implies.
        readNetDensity = referenceStock.granularityAnchorDensity(layer: layer)
        readSigma = referenceStock.grainStrength * referenceStock.grainLayerWeights[layer] * grainScale
        let referenceModel = Self.withCurve(self, referenceCurve)
        let unitVariance = referenceModel.apertureVariance(
            logExposure: referenceModel.logExposure(netDensity: readNetDensity))
        let perCloud = unitVariance > 0 ? readSigma * readSigma / unitVariance : 0
        for i in development.bins.indices where development.bins[i].cloudRadiusMM > 0 {
            development.bins[i].dyePerCloud *= perCloud
            development.bins[i].crystalsPerMM2 = development.bins[i].dyePerCloud > 0
                ? development.bins[i].demandAtFull / development.bins[i].dyePerCloud : 0
        }

        // A condition away from the reference process: the same coating, developed further or
        // less far. What the process reaches in the latent image and what each crystal grows
        // to are fitted to the measured curve with the population held.
        if !Self.sameCurve(referenceCurve, developedCurve) {
            refitDevelopment(to: developedCurve)
            // Where the condition measured its own granularity the count and the dye per
            // crystal follow it; where it did not, the coating's count stands and the pushed
            // grain is what the refit says it is.
            let measured = stock.grainStrength * stock.grainLayerWeights[layer] * grainScale
            if abs(measured - readSigma) > 1e-6 {
                let at = stock.granularityAnchorDensity(layer: layer)
                let modelled = sigma(netDensity: at)
                if modelled > 0 {
                    let scale = measured * measured / (modelled * modelled)
                    for i in development.bins.indices where development.bins[i].cloudRadiusMM > 0 {
                        development.bins[i].dyePerCloud *= scale
                        development.bins[i].crystalsPerMM2 /= scale
                    }
                }
                readNetDensity = at
                readSigma = measured
            }
        }
        // Applied after reference/process RMS anchoring so the same relative coating
        // change survives push/pull. Demand, radii, pools, and the mean tone fit stay fixed.
        if population.coatingDensityScale != 1 {
            for i in development.bins.indices {
                development.bins[i].crystalsPerMM2 *= population.coatingDensityScale
                development.bins[i].dyePerCloud /= population.coatingDensityScale
            }
            readSigma /= sqrt(population.coatingDensityScale)
        }
    }

    private static func withCurve(_ model: CrystalGrainModel, _ curve: CharacteristicCurve) -> CrystalGrainModel {
        var copy = model
        copy.curve = curve
        copy.dMin = curve.dMin
        copy.range = max(curve.dMax - curve.dMin, 1e-3)
        return copy
    }

    private static func sameCurve(_ a: CharacteristicCurve, _ b: CharacteristicCurve) -> Bool {
        fitLogExposures.allSatisfy {
            abs(a.density(logExposure: $0) - b.density(logExposure: $0)) < 1e-4
        }
    }

    /// The development stage's refit for a measured condition: over the developability grid,
    /// the per-sublayer gains that bring the developed sublayers' mean closest to the
    /// condition's curve above base, with the coating — the crystal counts, the clouds, the
    /// pools and the class shares — held. Each sublayer's gain is solved by golden-section
    /// coordinate descent, since the pool makes the dye concave in it; silver's is linear and
    /// the same search finds it.
    mutating func refitDevelopment(to developed: CharacteristicCurve) {
        let targets = Self.fitLogExposures.map { developed.density(logExposure: $0) - developed.dMin }
        let reference = development
        let coated = reference.bins.indices.filter { reference.bins[$0].demandAtFull > 0 }
        var best: (developability: Float, gains: [Float], error: Float, sse: Double)? = nil
        for developability in Development.developabilities {
            var trial = reference
            trial.developability = developability
            let fractions: [[Float]] = Self.fitLogExposures.map { x in
                trial.binFractions(exposure: exposure, logExposure: x)
            }
            func formed(_ gains: [Float], _ row: [Float]) -> Float {
                var total: Float = 0
                for b in coated {
                    total += Development.dye(
                        demand: reference.bins[b].demandAtFull * gains[b] * row[b],
                        pool: reference.bins[b].pool)
                }
                return total
            }
            func residual(_ gains: [Float]) -> Double {
                var sse = 0.0
                for (row, target) in zip(fractions, targets) {
                    let error = Double(formed(gains, row) - target)
                    sse += error * error
                }
                return sse
            }
            var gains = [Float](repeating: 1, count: reference.bins.count)
            for _ in 0..<40 {
                var moved: Float = 0
                for b in coated {
                    var low: Float = 0, high: Float = 6
                    let phi: Float = 0.6180339887
                    var c = high - phi * (high - low), d = low + phi * (high - low)
                    var probe = gains
                    probe[b] = c
                    var fc = residual(probe)
                    probe[b] = d
                    var fd = residual(probe)
                    for _ in 0..<30 {
                        if fc < fd {
                            high = d; d = c; fd = fc
                            c = high - phi * (high - low)
                            probe[b] = c
                            fc = residual(probe)
                        } else {
                            low = c; c = d; fc = fd
                            d = low + phi * (high - low)
                            probe[b] = d
                            fd = residual(probe)
                        }
                    }
                    let updated = (low + high) / 2
                    moved = max(moved, abs(updated - gains[b]))
                    gains[b] = updated
                }
                if moved < 1e-5 { break }
            }
            let sse = residual(gains)
            var worst: Float = 0
            for (row, target) in zip(fractions, targets) {
                worst = max(worst, abs(formed(gains, row) - target))
            }
            if best == nil || sse < best!.sse {
                best = (developability, gains, worst, sse)
            }
        }
        guard let best else { return }
        development.developability = best.developability
        development.fitError = best.error
        for b in coated {
            let gain = best.gains[b]
            development.bins[b].gain = gain
            development.bins[b].demandAtFull *= gain
            development.bins[b].dyePerCloud *= gain
        }
    }

    // MARK: - What the record states

    /// Dye-forming fraction of every class at `logExposure`, fog included.
    public func formingFractions(logExposure: Float) -> [Float] {
        development.formingFractions(exposure: exposure, logExposure: logExposure)
    }

    /// Each bin's mean dye-forming fraction at `logExposure`.
    public func binFractions(logExposure: Float) -> [Float] {
        development.binFractions(exposure: exposure, logExposure: logExposure)
    }

    /// Density above base the sublayers form at `logExposure` — what the kernel's mean is.
    public func meanDensity(logExposure: Float) -> Float {
        development.meanDensity(exposure: exposure, logExposure: logExposure)
    }

    /// The exposure at which the record forms `netDensity` above base, on the record's own
    /// curve as developed.
    public func logExposure(netDensity: Float) -> Float {
        let target = isReversal ? dMin + range - netDensity : dMin + netDensity
        return curve.logExposure(density: min(max(target, dMin), dMin + range))
    }

    /// Density fluctuation variance through the 48 µm aperture at `logExposure`, in density².
    public func apertureVariance(logExposure: Float) -> Float {
        development.apertureVariance(exposure: exposure, logExposure: logExposure)
    }

    /// RMS granularity through the 48 µm aperture where the record has formed `netDensity`.
    public func sigma(netDensity: Float) -> Float {
        apertureVariance(logExposure: logExposure(netDensity: netDensity)).squareRoot()
    }

    // MARK: - Kernel tables

    /// Mean latent-crystal count per pixel for each bin against the record's developed density
    /// as a fraction of its range, `samples` values from 0 to 1, for a lattice of `pxPerMM`
    /// pixels per millimetre: the exposure stage's field, read back through the curve.
    public func countTable(pxPerMM: Float) -> [[Float]] {
        let pixelArea = 1 / (pxPerMM * pxPerMM)
        var tables = [[Float]](repeating: [], count: bins.count)
        for i in 0..<Self.samples {
            let amount = Float(i) / Float(Self.samples - 1)
            let fractions = binFractions(logExposure: logExposure(netDensity: amount * range))
            for (b, bin) in bins.enumerated() {
                tables[b].append(bin.crystalsPerMM2 * pixelArea * fractions[b])
            }
        }
        return tables
    }

    /// Density one cloud of `bin` adds to the pixel it lands in, on a lattice of `pxPerMM`.
    public func densityPerCloud(bin: Int, pxPerMM: Float) -> Float {
        bins[bin].dyePerCloud * pxPerMM * pxPerMM
    }

    /// The mean-dye factor the kernel subtracts with: the sum over the cloud's lattice taps
    /// `K` of the marks' expectation of `1 - exp(-mark q K / C)`, `q` the density one cloud
    /// adds to its pixel and `C` the pool, so that by Campbell's theorem the marked Poisson
    /// field's expected dye is `C (1 - exp(-count × factor))`. The taps are the separable
    /// Gaussian the schedules lay: `sigmaPixels` read at integer offsets to `radius` and
    /// normalised. Silver's factor is `q`, the marks' mean being one.
    public static func meanDyeFactor(sigmaPixels: Float, radius: Int, densityPerCloud q: Float,
                                     pool: Float) -> Float {
        guard pool > 0 else { return q }
        guard q > 0 else { return 0 }
        let reach = max(radius, 0)
        var taps = (-reach...reach).map { exp(-Float($0 * $0) / (2 * max(sigmaPixels, 1e-3) * max(sigmaPixels, 1e-3))) }
        let total = taps.reduce(0, +)
        taps = taps.map { $0 / total }
        let heavy = Double(1 + Development.markDispersion)
        let light = Double(1 - Development.markDispersion)
        var factor: Double = 0
        for a in taps {
            for b in taps {
                let tap = Double(q * a * b / pool)
                factor += 1 - 0.5 * (exp(-heavy * tap) + exp(-light * tap))
            }
        }
        return Float(factor)
    }

    /// Gaussian sigma of a bin's cloud on the film, mm: half its radius, the convention the
    /// clump field uses for `grainSizeMM`.
    public func cloudSigmaMM(bin: Int) -> Float {
        bins[bin].cloudRadiusMM / 2
    }

    // MARK: - Fit

    /// Non-negative least squares by projected coordinate descent on the normal equations —
    /// deterministic, so every host packs the same population.
    static func nonNegativeLeastSquares(basis: [[Double]], targets: [Double]) -> [Float] {
        let n = basis.first?.count ?? 0
        var gram = [Double](repeating: 0, count: n * n)
        var moment = [Double](repeating: 0, count: n)
        for (row, target) in zip(basis, targets) {
            for i in 0..<n {
                moment[i] += row[i] * target
                for j in 0..<n { gram[i * n + j] += row[i] * row[j] }
            }
        }
        var weights = [Double](repeating: 0, count: n)
        for _ in 0..<5000 {
            var moved = 0.0
            for i in 0..<n where gram[i * n + i] > 0 {
                var residual = moment[i]
                for j in 0..<n where j != i { residual -= gram[i * n + j] * weights[j] }
                let updated = max(residual / gram[i * n + i], 0)
                moved = max(moved, abs(updated - weights[i]))
                weights[i] = updated
            }
            if moved < 1e-9 { break }
        }
        return weights.map(Float.init)
    }

    /// The population, one line per coated sublayer.
    public var report: String {
        var lines: [String] = []
        lines.append(String(
            format: "fit %.3f D, fog fraction %.4f, developability %.2f, read net %.2f D → σ48 %.4f",
            fitError, fogFraction, development.developability, readNetDensity, readSigma))
        for (i, bin) in bins.enumerated() where bin.cloudRadiusMM > 0 {
            let speeds = bin.classes.map { Exposure.classLogExposures[$0] }
            lines.append(String(
                format: "sublayer %d: cloud radius %.2f µm, dye per cloud %.4f D·µm², "
                    + "%.2f crystals/µm², pool %.2f D, demand at full %.2f D, gain %.2f, "
                    + "speed %+.1f…%+.1f",
                i, bin.cloudRadiusMM * 1000, bin.dyePerCloud * 1e6, bin.crystalsPerMM2 * 1e-6,
                bin.pool, bin.demandAtFull, bin.gain, speeds.min() ?? 0, speeds.max() ?? 0))
        }
        return lines.joined(separator: "\n")
    }
}
