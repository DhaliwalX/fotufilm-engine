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
/// **A dye cloud's size follows from its dye and its coupler.** Couplers are dispersed evenly
/// through a sublayer (Hunt, *The Reproduction of Colour* §18.7: oil globules a tenth of the
/// grain's diameter), so the most dye any point of the sublayer can form is its coupler
/// capacity — the sublayer's pool, which is also what a fully developed sublayer reaches. The
/// oxidised developer a developed crystal releases spreads as a Gaussian demand and forms dye up
/// to that capacity, `C (1 - exp(-demand / C))`, summed with every other cloud of the sublayer
/// before it saturates: clouds are dense and flat-topped where they formed, and merge where they
/// meet. The cloud's width is solved so that its dye, read as a densitometer reads it, is the
/// dye per crystal the sheet implies. Silver is the same construction with an opaque grain,
/// `silverGrainDensity`, in place of the coupler capacity — which makes the grain's projected
/// area Nutting's `D = 0.434 n a` read backwards from the sheet.
///
/// **No cloud is narrower than its crystal.** Where the sheet's dye per crystal would make a cloud
/// narrower than `dyeCloudSpread` times its crystal — a silver grain narrower than the crystal
/// itself — the cloud keeps that width and its demand stays below saturation instead, so it forms
/// the same dye fainter: the sheet fixes how much dye a crystal forms, not how it is spread, and a
/// cloud cannot be smaller than what formed it. The sublayer's capacity is unchanged, so where
/// clouds overlap they still fill it.
/// Crystal widths follow the population's size ladder down from `fastestCrystalMM`.
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
    /// Peak oxidised-developer demand of a dye cloud over its sublayer's coupler capacity: how
    /// far past saturation the cloud's centre is, which sets how flat its top is and how soft its
    /// rim. Not measured; a stance.
    public static let dyeCloudEdge: Float = 4
    /// The same for a developed silver grain, whose edge is the crystal's own.
    public static let silverGrainEdge: Float = 12
    /// Local density of a developed silver grain: transmits one percent. Not measured; a stance.
    public static let silverGrainDensity: Float = 2
    /// Width of a record's fastest crystals, mm; slower classes follow the size ladder. Not
    /// measured; a stance near the 1–2 µm tabular crystals of fast negative emulsions.
    public static let fastestCrystalMM: Float = 0.0012
    /// Narrowest dye cloud as a multiple of its crystal's width: oxidised developer spreads past
    /// the crystal before it couples. Not measured; a stance.
    public static let dyeCloudSpread: Float = 2
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

    /// One coated sublayer of a record, as this model lays it.
    public struct Sublayer: Sendable {
        /// Crystals coated per mm².
        public var coatedPerMM2: Float
        /// Gaussian sigma of the demand one developed crystal of mark 1 releases, mm.
        public var sigmaMM: Float
        /// Peak demand of a mark-1 crystal, density.
        public var peakDemand: Float
        /// Most density a point of the sublayer can form.
        public var capacity: Float
        /// Peak demand over capacity of a cloud free to take its own width.
        public var edge: Float
        /// Narrowest demand sigma a cloud of this sublayer may take, mm.
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

        init(coatedPerMM2: Float, capacity: Float, edge: Float, smallestSigmaMM: Float,
             dyePerCloudMM2: Float, cellMM: Float, forming: [Float]) {
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

        /// Sets the cloud from its dye: as wide as its edge makes it, or held at its narrowest
        /// width with its peak demand lowered until it forms that dye.
        mutating func shape() {
            var peak = edge
            let free = (dyePerCloudMM2 / FilmGrain.unitCloudDye(capacity: capacity, edge: edge))
                .squareRoot()
            if free >= smallestSigmaMM {
                sigmaMM = free
            } else {
                sigmaMM = smallestSigmaMM
                let wanted = dyePerCloudMM2 / (smallestSigmaMM * smallestSigmaMM)
                var low = log(edge * 1e-5), high = log(edge)
                for _ in 0..<40 {
                    let mid = (low + high) / 2
                    if FilmGrain.unitCloudDye(capacity: capacity, edge: exp(mid)) < wanted {
                        low = mid
                    } else {
                        high = mid
                    }
                }
                peak = exp((low + high) / 2)
            }
            peakDemand = peak * capacity
            voidIntegralMM2 = sigmaMM * sigmaMM * FilmGrain.unitVoidIntegral(edge: peak)
        }

        /// Radius at which a mark-1 cloud has formed half its capacity, mm.
        public var halfCapacityRadiusMM: Float {
            let formed = -log(0.5) // demand = C ln 2 gives C/2
            let ratio = peakDemand / max(capacity, 1e-6)
            guard ratio > Float(formed) else { return 0 }
            return sigmaMM * (2 * log(ratio / Float(formed))).squareRoot()
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

    /// The population of `stock` as developed; `reference` is the same roll at the pack's
    /// reference process, as `CrystalGrainModel` takes it.
    public init(stock: FilmStock, reference: FilmStock? = nil, grainScale: Float = 1) {
        monochrome = stock.isMonochrome
        key = Self.anchorKey(stock: stock, grainScale: grainScale)
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
                let edge = silver ? Self.silverGrainEdge : Self.dyeCloudEdge
                // The crystal's width on the ladder, and the narrowest cloud it forms, as the
                // width at half capacity of a demand Gaussian: 2σ √(2 ln(edge / ln 2)).
                let crystal = Self.fastestCrystalMM * bin.cloudRadiusMM / fastest
                let narrowest = crystal * (silver ? 1 : Self.dyeCloudSpread)
                let smallestSigma = narrowest / (2 * (2 * log(edge / Float(M_LN2))).squareRoot())
                // About eight coated crystals per cell keeps the Poisson draw short.
                let cell = min(max((8 / bin.crystalsPerMM2).squareRoot(), 0.00025), 0.004)
                sublayers.append(Sublayer(coatedPerMM2: bin.crystalsPerMM2,
                                          capacity: silver ? Self.silverGrainDensity : max(bin.pool, 0.05),
                                          edge: edge, smallestSigmaMM: smallestSigma,
                                          dyePerCloudMM2: bin.dyePerCloud, cellMM: cell,
                                          forming: fractions.map { $0[b] }))
            }
            return Record(sublayers: sublayers, dMin: lo, dMax: hi)
        }
        anchorToSheet(anchors, key: key)
    }

    // MARK: - The sheet's anchor

    /// Scale factors already solved, per stock and grain scale.
    private static let anchorCache = AnchorCache()

    private final class AnchorCache: @unchecked Sendable {
        private let lock = NSLock()
        private var factors: [String: [Float]] = [:]
        func get(_ key: String) -> [Float]? { lock.lock(); defer { lock.unlock() }; return factors[key] }
        func set(_ key: String, _ value: [Float]) { lock.lock(); factors[key] = value; lock.unlock() }
    }

    static func anchorKey(stock: FilmStock, grainScale: Float) -> String {
        "\(stock.name)|\(grainScale)|\(stock.grainStrength)|\(stock.grainLayerWeights)|\(stock.grainSizeMM)"
            + "|\(stock.curves.map { [$0.dMin, $0.dMax] })"
    }

    /// The crystal population's dye per crystal was set so that an additive density field
    /// reads the sheet's RMS granularity. Clouds that saturate and light that averages read
    /// differently, so the anchor is taken again on this model's own render: a flat patch at
    /// the sheet's read density, read through the 48 µm aperture, and each crystal's dye
    /// scaled until it reads the sheet — its count by the inverse, so the mean holds and the
    /// cloud's area follows its dye. How far the reading moves with the dye depends on how full
    /// the clouds are, so each step takes the slope the last one measured.
    mutating func anchorToSheet(_ anchors: [(gross: Float, sigma: Float)], key: String) {
        if let cached = Self.anchorCache.get(key) {
            for r in 0..<3 { scale(record: r, by: cached[r]) }
            return
        }
        var solved = [Float](repeating: 1, count: 3)
        let active = monochrome ? [1] : [0, 1, 2]
        for r in active where !records[r].sublayers.isEmpty && anchors[r].sigma > 0 {
            var slope: Float = 0.5
            var last: (factor: Float, sigma: Float)?
            for _ in 0..<Self.anchorPasses {
                let measured = sigma48(record: r, gross: anchors[r].gross)
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
        Self.anchorCache.set(key, solved)
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
        Self.tileSigma48(tileLight(record: r, gross: gross, seed: Self.tileSeed))
    }

    /// Dye one cloud of unit demand sigma forms as a densitometer reads it — the small-signal
    /// density-area `0.434 ∫ (1 - 10^-dye)` — averaged over the crystals' gamma marks.
    static func unitCloudDye(capacity: Float, edge: Float) -> Float {
        let shape = Double(markShape)
        // Marks at the gamma's quantile midpoints: deterministic and smooth enough.
        let quantiles = 24
        var total = 0.0
        for q in 0..<quantiles {
            let p = (Double(q) + 0.5) / Double(quantiles)
            let mark = gammaQuantile(p, shape: shape) / shape
            let peak = Double(edge) * mark
            var area = 0.0
            let steps = 400
            let top = 8.0
            for i in 0..<steps {
                let rho = (Double(i) + 0.5) * top / Double(steps)
                let demand = peak * exp(-rho * rho / 2)
                let dye = Double(capacity) * (1 - exp(-demand))
                area += (1 - pow(10, -dye)) * rho * (top / Double(steps))
            }
            total += 0.4342944819 * 2 * Double.pi * area
        }
        return Float(total / Double(quantiles))
    }

    /// `E_mark ∫ (1 - exp(-edge · mark · e^{-ρ²/2})) d²ρ` for a unit demand sigma.
    static func unitVoidIntegral(edge: Float) -> Float {
        let shape = Double(markShape)
        let quantiles = 24
        var total = 0.0
        for q in 0..<quantiles {
            let mark = gammaQuantile((Double(q) + 0.5) / Double(quantiles), shape: shape) / shape
            total += Double(occupiedArea(peak: edge * Float(mark)))
        }
        return Float(total / Double(quantiles))
    }

    /// `∫ (1 - exp(-peak · e^{-ρ²/2})) d²ρ` in closed form, `2π Ein(peak)`: the share of the
    /// capacity a cloud of unit demand sigma fills, as an area.
    static func occupiedArea(peak: Float) -> Float {
        let p = Double(max(peak, 0))
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
            let reach = resolvedShare > 0 ? 4.2 * sigma : 3 * sigma + h
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
                            let side = sigma * Self.occupiedArea(peak: edge * mark).squareRoot() / h
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
