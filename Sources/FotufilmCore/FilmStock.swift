import Foundation

/// How granularity varies with density — which is a property of the emulsion, not of the
/// grain model that renders it.
///
/// Selwyn's `sigma_D ∝ sqrt(D)` is what a single population of developed centres gives, and it
/// is the law this engine used for every material. It is wrong for both of the two it can be
/// checked against: a real colour negative is a mixture of sub-layers whose measured curve
/// peaks just above D-min and falls, and a real silver emulsion's grains hide one another, so
/// what fluctuates is covered area read through a finite aperture.
public enum GrainDensityLaw: Int32, Sendable, Codable {
    /// Chromogenic negative: the silver is bleached away and the image is a dye cloud per
    /// developed centre, but the coating is several sub-layers of different speed and crystal
    /// size. Kodak publishes the resulting curve for Vision3 250D and 500T; it rises to a peak
    /// 0.15–0.2 above D-min and falls thereafter, which `grainDensityProfile` states.
    case dyeCloud = 0
    /// Silver film: the developed grain is opaque, so what adds is *covered area*, not density.
    /// The Boolean (Siedentopf) variance read through an aperture much wider than the grain is
    /// `sigma_D² ∝ D * 10^(0.21004 D + 0.06114 D²)`, which is Selwyn at low density and
    /// steepens as the grains begin to hide one another — but far less steeply than the
    /// `sqrt(10^D - 1)` this engine used, which assumed a fixed correlation area.
    case silver = 1
    /// A dye-cloud emulsion whose granularity-against-density curve nobody publishes: every
    /// reversal stock in the pack. No sheet in `research/spectral/specs` plots one, and a
    /// negative's measured shape is not transferable to a material that develops backwards, so
    /// these keep Selwyn's plain `sigma_D ∝ sqrt(D)` until a curve is measured.
    case dyeCloudSelwyn = 2
}

/// A capture layer that develops and inhibits, but forms no image dye of its own.
///
/// Fujifilm's 4th Color Layer is the shipped example: REALA 500D coats a cyan-sensitive CL
/// record between the green and red ones whose developed image releases development inhibitor
/// into the dye-forming layers — Sasaki, Takahashi & Ikoma, "Color Reproduction of Fujicolor
/// REALA" (J. Soc. Photogr. Sci. Technol. Japan 52(1), 1989) state that the inter-image effect
/// reaches the red record only — and whose coupler forms no transported dye. So the record is a
/// *donor*: it needs an exposure, a development curve and a release row, and nothing
/// downstream — no dye, no grain stream, no plane in the interchange formats. That is what
/// keeps a fourth coated layer from being the four-wall project widening `dyeCount` would be.
public struct DonorCaptureLayer: Sendable {
    /// The record's name as the publication prints it ("CL").
    public var name: String
    /// Spectral sensitivity on `SpectralGrid`, in the same linear units as
    /// `FilmSpectralProfile.layerSensitivity`.
    public var sensitivity: [Float]
    /// The donor's own development curve, on the same normalized log-exposure axis as
    /// `curves`. KB-111E3 publishes the CL record's sensitivity and nothing else, so a pack
    /// that cannot know the curve states the green layer's shape: on the neutral axis the two
    /// records develop together, and the release amplitude absorbs the scale the curve cannot
    /// claim — the two are only ever identified jointly.
    public var curve: CharacteristicCurve
    /// Inhibitor released into each dye-forming layer per unit of the donor's activation, in
    /// the engine's R, G, B record order and log-exposure units, like `couplerInhibition`.
    /// Stated per receiver rather than derived from stack geometry because the publications
    /// state the topology directly — the CL's inhibitor reaches the red record only, and the
    /// 1989 film managed that from *above* the green layer, so the specificity is the
    /// inhibitor's chemistry, not the stack's gaps.
    public var inhibition: [Float]
    /// Exponent of the donor's normalized Hill release curve. 1 is the historical linear
    /// activation; values above 1 add a threshold and saturate toward full release.
    public var releaseGamma: Float
    /// Centre depth below the emulsion surface in micrometres, where the publication shows
    /// the stack. Descriptive; the release row above is what renders.
    public var depthUM: Float?

    public init(name: String, sensitivity: [Float], curve: CharacteristicCurve,
                inhibition: [Float], releaseGamma: Float = 1,
                depthUM: Float? = nil) {
        self.name = name
        self.sensitivity = sensitivity
        self.curve = curve
        self.inhibition = inhibition
        self.releaseGamma = releaseGamma
        self.depthUM = depthUM
    }
}

/// Full physical description of a film stock plus the print/scan stage used to turn the negative
/// back into a positive image.
public struct FilmStock: Sendable {

    /// How many capture layers this emulsion coats, read from the stock rather than assumed:
    /// the dye-forming records plus the donor layers that develop without forming a dye.
    ///
    /// Three is not a fact about film. Fujifilm REALA 500D coats four — the cyan-sensitive CL
    /// donor between the green and red ones, printed as a fourth record on KB-111E3 — and a
    /// pack now carries it as a `DonorCaptureLayer`.
    public var captureLayerCount: Int { curves.count + donorLayers.count }

    /// Supported dye-forming capture-layer count. The film-output LUT is three-dimensional, image
    /// transport uses three planes, and the packed kernel ABI uses fixed three-float slots. Layer ID
    /// 3 is reserved for the shared grain field. Donor layers use the separate `donorLayers` path.
    public static let supportedCaptureLayerCounts: ClosedRange<Int> = 3...3

    /// How many donor layers the render path can carry: the packed kernel configuration
    /// appends six curve parameters and three release weights for exactly one
    /// (`FOTUFILM_CONFIG_DONOR_CURVE`/`FOTUFILM_CONFIG_DONOR_RELEASE`). A second donor is more
    /// appended slots and a wider blur, not a new mechanism.
    public static let supportedDonorLayerCounts: ClosedRange<Int> = 0...1

    /// How many image dyes a colour stock forms. Not the same quantity as `captureLayerCount`,
    /// and equal to it only because every stock shipped so far coats three layers:
    /// `SpectralRuntime.transmissionRGB` pairs density *i* with dye *i*, which is the line
    /// that makes the two counts one.
    public static let dyeCount = 3

    public var name: String

    /// Legacy 3x3 RGB exposure fallback used only if the bundled RGB-to-
    /// spectrum resource cannot load.
    public var sensitivity: [[Float]]
    /// The fixed scene illuminant this emulsion was balanced for. This is stock data, not an
    /// automatic white-balance measurement: loading a tungsten stock changes the reference to
    /// 3200 K and leaves a daylight scene blue unless an optical conversion filter is fitted.
    public var referenceIlluminantKelvin: Float
    /// Full wavelength-domain capture and image-dye data. `sensitivity` is retained as a compact
    /// calibration diagnostic and compatibility surface; the renderer uses this profile for
    /// exposure and output optics.
    public var spectralProfile: FilmSpectralProfile

    /// Increasing dye-formation curves.
    public var curves: [CharacteristicCurve]

    /// Coated capture layers beyond the dye-forming three: records that develop and release
    /// inhibitor but form no image dye. Empty for every stock that coats exactly what it dyes.
    public var donorLayers: [DonorCaptureLayer]

    /// Veiling glare of the taking lens as a fraction of the average scene exposure.
    public var flare: Float
    /// Per-layer light diffusion (turbidity) inside the emulsion pack, as a
    /// Gaussian sigma in millimeters on the film.
    public var emulsionDiffusionMM: [Float]
    /// How much of the emulsion MTF is separated onto a luminance channel
    /// rather than left on the three per-layer records.
    public var mtfLumaShare: Float
    /// Gaussian sigma in millimeters for the luminance arm of the emulsion MTF.
    public var lumaDiffusionMM: Float
    /// Optional second positive diffusion scale per layer. Together with
    /// `emulsionDiffusionPrimaryShare`, this represents a multi-speed emulsion's measured
    /// two-scale roll-off without permitting a non-physical negative point-spread function.
    public var emulsionDiffusionSecondaryMM: [Float]
    /// Fraction carried by `emulsionDiffusionMM`; the balance is carried by the secondary scale.
    /// [1, 1, 1] is the original single-Gaussian MTF exactly.
    public var emulsionDiffusionPrimaryShare: [Float]

    /// Inhibition matrix K: development inhibitors released in layer j reduce the effective log
    /// exposure of layer i by K[i][j] * activation(j).
    public var couplerInhibition: [[Float]]
    /// Per-donor exponents for the normalized inhibitor-release curve. 1 is linear; values above
    /// 1 model the chemical threshold and saturation before the released inhibitor diffuses.
    public var couplerReleaseGamma: [Float]
    /// Where `couplerInhibition` came from, when it came from somewhere.
    public var couplerGeometry: CouplerGeometry? {
        didSet {
            if let couplerGeometry { couplerInhibition = couplerGeometry.matrix() }
        }
    }
    /// Diffusion distance of the inhibitors in millimeters on the film.
    public var couplerDiffusionMM: Float

    /// Strength of the intra-layer adjacency effect: each layer's development is shifted by
    /// `-adjacencyStrength * (blur(a) - a)` in log exposure, where `a` is the layer's development
    /// activation.
    public var adjacencyStrength: Float
    /// Diffusion distance of the adjacency mechanism in millimeters.
    public var adjacencyRadiusMM: Float

    /// RMS granularity: the standard deviation of density measured through the standard
    /// 48-micrometre aperture at the condition the datasheets state — net diffuse density 1.0
    /// above base for a negative material (a published figure of 17 is 0.017 here), gross
    /// diffuse density 1.0 for a reversal. It is a property of the film, not of the render,
    /// so the engine converts it to a per-pixel amplitude against the aperture, the clump
    /// size and the read density; see `granularityApertureResponse` and
    /// `granularityAnchorActivation(layer:)`.
    public var grainStrength: Float
    /// Grain clump radius in millimeters on the film.
    public var grainSizeMM: Float
    /// Per-layer relative grain weights; the blue-sensitive layer of color
    /// negative is typically the grainiest.
    public var grainLayerWeights: [Float]
    /// Fraction of each layer's grain *variance* carried by a single field common to all three
    /// layers, rather than by that layer's own emulsion.
    public var grainLumaCorrelation: Float
    /// Fraction of the published granularity's *variance* carried by a coarse second clump
    /// population — the soft mottle a real emulsion's crystal-size distribution lays under
    /// the sharp grain, which one radius cannot express. 0 — the default, and every pack
    /// that says nothing — is the single-radius field, bit-identically.
    public var grainMottleShare: Float
    /// The coarse population's clump radius as a multiple of `grainSizeMM`.
    public var grainMottleSizeRatio: Float
    /// Per-layer clump radius as a multiple of `grainSizeMM`. A colour negative coats the
    /// blue-sensitive layer on top with the coarsest crystals and the widest dye clouds, so its
    /// grain is both louder — `grainLayerWeights` — and lower in frequency, which one radius
    /// cannot express. [1, 1, 1], the default and every pack that says nothing, is the
    /// single-radius field bit-identically.
    public var grainLayerSizeRatio: [Float]
    /// Which granularity-against-density law the emulsion obeys; see `GrainDensityLaw`.
    /// Defaults to the material: silver for a monochrome stock, the measured chromogenic
    /// negative shape for a colour negative, and Selwyn for a reversal, whose curve is
    /// unpublished. Stated explicitly because the material and the law cross — a chromogenic
    /// black-and-white stock is a dye cloud.
    public var grainDensityLaw: GrainDensityLaw
    /// The chromogenic negative's granularity-against-density shape, read only under
    /// `GrainDensityLaw.dyeCloud`: `[amplitude, toeDensity, decayDensity]` of
    ///
    ///     sigma²(D) ∝ (1 - e^(-D/toe)) * (1 + amplitude * e^(-D/decay))
    ///
    /// at `D = net density + grainFogDensity`, normalised at the density the published figure
    /// is read at. The default is an illustrative analytic shape; measured packs
    /// provide their own coefficients.
    public var grainDensityProfile: [Float]
    /// Density of the developed fog: unexposed crystals that cross threshold anyway. These are
    /// development centres like any other, so they carry granularity, which is why a fresh
    /// emulsion is not perfectly clean at D-min and an aged one is visibly less so. This is the
    /// *developed* part of D-min only — the base's own dye is a filter, not grain.
    public var grainFogDensity: Float

    /// Fraction of each layer's exposure that reaches the back of the film base, reflects, and
    /// returns to expose the layer a second time.
    public var halationStrength: [Float]
    /// Presentation multiplier applied to `halationStrength` alongside
    /// `Options.halationScale`. Shipped stocks use 1 so the resting control renders the
    /// calibrated returned-light fraction directly. The field remains part of the pack format
    /// for compatibility with external and experimental stock definitions.
    public var halationLookScale: Float
    /// Gaussian sigma in millimeters of the support's impurity scatter, convolved over the
    /// returned light. A real base is never optically clean — haze in the acetate, plasticizer,
    /// backing roughness — so the reflex ring's edge is softer than the clean-support geometry
    /// says. 0 is the clean support and every earlier render, bit-identically.
    public var halationHazeMM: Float
    /// Independently calibrated spatial shape of the returned light. `nil` preserves the legacy
    /// model that infers shape from `halationStrength`.
    public var halationProfile: HalationProfile?
    /// A provisional spatial shape for use when no independently calibrated profile exists.
    /// Rendering ignores it unless the caller explicitly enables estimated profiles.
    public var estimatedHalationProfile: HalationProfile?
    /// The spectral return matrix, receiver rows by source columns: each record's returned
    /// exposure per unit direct exposure of each source record, integrated over the
    /// per-wavelength stack transmission of the return trip (coloured masking couplers, AH
    /// undercoat, yellow filter). Only the row shapes are rendered — `halationStrength` stays
    /// the amplitude — and `nil` keeps the whole share on the diagonal, the legacy scalar mix.
    public var halationReturnMatrix: [[Float]]?

    /// Characteristic curve of the print paper (identical shape per channel;
    /// per-channel neutrality comes from printer-light calibration).
    public var paperCurve: CharacteristicCurve
    /// Paper density that a correctly exposed mid-gray should land on.
    public var paperMidDensity: Float

    /// Where this emulsion leaves the reciprocity law, when its datasheet states a
    /// long-exposure table. nil keeps the classic one-stop-per-decade rule.
    public var reciprocityFailure: ReciprocityFailure?

    /// Complete sensitometric results for non-reference development conditions. `nil` means the
    /// pack has no measured push/pull family and the engine will reject a non-zero request.
    public var developmentProfile: FilmDevelopmentProfile?

    /// True for black-and-white stocks: exposure is panchromatic and the output is forced neutral.
    public var isMonochrome: Bool
    /// True for direct-positive reversal stocks.
    public var isReversal: Bool

    /// True for a direct positive that is viewed *by reflection* — an integral instant sheet, where
    /// the developed image is the print.
    public var isReflectionPrint: Bool

    /// The finished positive this emulsion was designed to be printed onto, where it was designed
    /// for a particular one. A motion-picture camera negative is built to be timed onto a release
    /// print stock and carries the mask density and contrast that assumes it; a still negative is
    /// built for RA-4 paper. `nil` means the stock states no preference and takes the engine's
    /// default sheet.
    ///
    /// This is the stock's *native* medium, not a restriction: any medium a stock can reach stays
    /// reachable, and an explicit request always wins over this.
    public var nativePrintMedium: PrintPaper?

    public init(
        name: String,
        sensitivity: [[Float]],
        referenceIlluminantKelvin: Float = 5500,
        spectralProfile: FilmSpectralProfile? = nil,
        curves: [CharacteristicCurve],
        donorLayers: [DonorCaptureLayer] = [],
        flare: Float = 0.008,
        emulsionDiffusionMM: [Float] = [0, 0, 0],
        emulsionDiffusionSecondaryMM: [Float] = [0, 0, 0],
        emulsionDiffusionPrimaryShare: [Float] = [1, 1, 1],
        mtfLumaShare: Float = 0,
        lumaDiffusionMM: Float? = nil,
        couplerInhibition: [[Float]],
        couplerReleaseGamma: [Float] = [1, 1, 1],
        couplerGeometry: CouplerGeometry? = nil,
        couplerDiffusionMM: Float,
        adjacencyStrength: Float = 0,
        adjacencyRadiusMM: Float = 0,
        grainStrength: Float,
        grainSizeMM: Float,
        grainLayerWeights: [Float],
        grainLumaCorrelation: Float = 0,
        grainMottleShare: Float = 0,
        grainMottleSizeRatio: Float = 3,
        grainLayerSizeRatio: [Float] = [1, 1, 1],
        grainDensityLaw: GrainDensityLaw? = nil,
        grainDensityProfile: [Float]? = nil,
        grainFogDensity: Float = FilmStock.defaultGrainFogDensity,
        halationStrength: [Float],
        halationLookScale: Float = 1,
        halationHazeMM: Float = 0,
        halationProfile: HalationProfile? = nil,
        estimatedHalationProfile: HalationProfile? = nil,
        halationReturnMatrix: [[Float]]? = nil,
        paperCurve: CharacteristicCurve,
        paperMidDensity: Float = 0.744,
        reciprocityFailure: ReciprocityFailure? = nil,
        developmentProfile: FilmDevelopmentProfile? = nil,
        isMonochrome: Bool = false,
        isReversal: Bool = false,
        isReflectionPrint: Bool = false,
        nativePrintMedium: PrintPaper? = nil
    ) {
        self.name = name
        self.sensitivity = FilmStock.rowNormalized(sensitivity)
        self.referenceIlluminantKelvin = referenceIlluminantKelvin
        self.spectralProfile = spectralProfile ?? .approximation(
            sensitivity: self.sensitivity, monochrome: isMonochrome,
            reversal: isReversal)
        self.curves = curves
        self.donorLayers = donorLayers
        self.flare = flare
        self.emulsionDiffusionMM = emulsionDiffusionMM
        self.emulsionDiffusionSecondaryMM = emulsionDiffusionSecondaryMM
        self.emulsionDiffusionPrimaryShare = emulsionDiffusionPrimaryShare
        self.mtfLumaShare = mtfLumaShare
        let weights = ColorScience.luminanceWeights
        let layerVariance = (0..<3).map { layer -> Float in
            let primary = emulsionDiffusionMM.indices.contains(layer)
                ? emulsionDiffusionMM[layer] : 0
            let secondary = emulsionDiffusionSecondaryMM.indices.contains(layer)
                ? emulsionDiffusionSecondaryMM[layer] : 0
            let share = emulsionDiffusionPrimaryShare.indices.contains(layer)
                ? min(max(emulsionDiffusionPrimaryShare[layer], 0), 1) : 1
            return share * primary * primary + (1 - share) * secondary * secondary
        }
        let meanVariance = zip(layerVariance, [weights.0, weights.1, weights.2])
            .reduce(Float(0)) { $0 + $1.1 * $1.0 }
        self.lumaDiffusionMM = lumaDiffusionMM ?? meanVariance.squareRoot()
        self.couplerGeometry = couplerGeometry
        self.couplerInhibition = couplerGeometry?.matrix() ?? couplerInhibition
        self.couplerReleaseGamma = couplerReleaseGamma
        self.couplerDiffusionMM = couplerDiffusionMM
        self.adjacencyStrength = adjacencyStrength
        self.adjacencyRadiusMM = adjacencyRadiusMM
        self.grainStrength = grainStrength
        self.grainSizeMM = grainSizeMM
        self.grainLayerWeights = grainLayerWeights
        self.grainLumaCorrelation = isMonochrome
            ? 1 : min(max(grainLumaCorrelation, 0), 1)
        self.grainMottleShare = min(max(grainMottleShare, 0), 0.9)
        self.grainMottleSizeRatio = max(grainMottleSizeRatio, 1)
        self.grainLayerSizeRatio = grainLayerSizeRatio.count == 3
            ? grainLayerSizeRatio.map { max($0, 0.05) } : [1, 1, 1]
        self.grainDensityLaw = grainDensityLaw
            ?? (isMonochrome ? .silver : (isReversal ? .dyeCloudSelwyn : .dyeCloud))
        self.grainDensityProfile = grainDensityProfile?.count == 3
            ? grainDensityProfile! : FilmStock.defaultGrainDensityProfile
        self.grainFogDensity = max(grainFogDensity, 0)
        self.halationStrength = halationStrength
        self.halationLookScale = max(halationLookScale, 0)
        self.halationHazeMM = max(halationHazeMM, 0)
        self.halationProfile = halationProfile
        self.estimatedHalationProfile = estimatedHalationProfile
        self.halationReturnMatrix = halationReturnMatrix
        self.paperCurve = paperCurve
        self.paperMidDensity = paperMidDensity
        self.reciprocityFailure = reciprocityFailure
        self.developmentProfile = developmentProfile
        self.isMonochrome = isMonochrome
        self.isReversal = isReversal
        self.isReflectionPrint = isReversal && isReflectionPrint
        // A reversal stock is its own positive and never meets a printing medium, so a preference
        // it cannot act on is dropped here rather than carried to a caller that would honour it.
        self.nativePrintMedium = isReversal ? nil : nativePrintMedium
    }

    func resolvedHalationProfile(useEstimate: Bool) -> HalationProfile? {
        halationProfile ?? (useEstimate ? estimatedHalationProfile : nil)
    }

    static func rowNormalized(_ m: [[Float]]) -> [[Float]] {
        m.map { row in
            let s = row.reduce(0, +)
            return row.map { $0 / s }
        }
    }

    /// Developed fog a fresh emulsion carries, in density above the base's own dye.
    ///
    /// Kept small and shared: it is what keeps granularity finite rather than zero at D-min,
    /// where the only development centres are the ones that crossed threshold in the dark.
    /// `expired(years:)` raises it with the fog it adds, which is the mechanism that makes
    /// aged film grainy in its shadows.
    public static let defaultGrainFogDensity: Float = 0.03

    /// Illustrative density response for synthetic examples. Measured packs supply their own.
    public static let defaultGrainDensityProfile: [Float] = FilmStockDefaults.grainDensityProfile

    /// Expected dye-cloud clumps per square millimetre. The Poisson field derives intensity as
    /// `-ln(1 - a) / (πr²)` from coverage `a` and `grainSizeMM`. A silver clump is a measured
    /// correlation length instead, so its continuous source field does not use this count.
    public var grainClumpsPerMM2: Float {
        let coverage = min(max(grainAnchorCoverage, 1e-4), 0.99)
        return -log(1 - coverage) / (Float.pi * grainSizeMM * grainSizeMM)
    }

    /// Covered fraction the datasheet's read density implies, under whichever law the emulsion
    /// obeys. The green record stands for the pack: the count is one field's texture parameter,
    /// not a per-layer calibration.
    var grainAnchorCoverage: Float {
        let anchor = granularityAnchorDensity(layer: 1) + grainFogDensity
        return 1 - pow(10, -max(anchor, 1e-3))
    }

    /// Radius of the aperture RMS granularity is defined through: the standard 48 µm
    /// microdensitometer aperture, so 0.024 mm.
    public static let granularityApertureRadiusMM: Float = 0.024

    /// Gaussian sigma that renders one clump of radius `grainSizeMM`.
    ///
    /// `grainClumpsPerMM2` models dye clumps as discs of area `pi * r^2`. A disc of radius r and a
    /// Gaussian of sigma r/2 average white noise identically — both integrate their squared kernel
    /// to 1 / (pi r^2) — so r/2 is the sigma whose correlation area matches that clump. The same
    /// width parameterizes silver's continuous field without treating each clump as one event.
    public var grainClumpSigmaMM: Float { grainSizeMM / 2 }

    /// Fraction of clump-field granularity retained by the standard 48 µm aperture.
    /// For a Gaussian clump and circular aperture, the exact response is:
    ///
    ///     sqrt(1 - e^-z (I0(z) + I1(z))),   z = R^2 / (2 sigma^2)
    ///
    /// The response approaches 1 as clump size approaches zero.
    public static func granularityApertureResponse(clumpSigmaMM sigma: Float) -> Float {
        guard sigma > 0 else { return 1 }
        let z = granularityApertureRadiusMM * granularityApertureRadiusMM
            / (2 * sigma * sigma)
        let lost = scaledBesselI0(z) + scaledBesselI1(z)
        return max(1 - lost, 1e-4).squareRoot()
    }

    /// The density above base the published granularity is read at, per record: net diffuse
    /// density 1.0 for a negative material, gross diffuse density 1.0 for a reversal — the two
    /// conditions the sheets actually state. The clamp keeps a curve too short to reach the read
    /// density from anchoring outside its own scale.
    public func granularityAnchorDensity(layer: Int) -> Float {
        let curve = curves[layer]
        let net: Float = isReversal ? 1 - curve.dMin : 1
        let range = curve.dMax - curve.dMin
        guard range > 0 else { return 0.5 }
        return min(max(net, 0.05 * range), 0.9 * range)
    }

    /// The activation (normalized density above base) the published granularity is read at.
    public func granularityAnchorActivation(layer: Int) -> Float {
        let range = curves[layer].dMax - curves[layer].dMin
        guard range > 0 else { return 0.5 }
        return granularityAnchorDensity(layer: layer) / range
    }

    /// Granularity variance of a chromogenic negative at diffuse density `density`, in
    /// arbitrary units. Mirrors `dye_cloud_granularity_variance` in FotufilmHalideShared.h,
    /// where the shape and its provenance are stated.
    func dyeCloudGranularityVariance(_ density: Float) -> Float {
        let amplitude = grainDensityProfile[0]
        let toe = max(grainDensityProfile[1], 1e-4)
        let decay = max(grainDensityProfile[2], 1e-4)
        return (1 - exp(-density / toe)) * (1 + amplitude * exp(-density / decay))
    }

    /// Granularity variance of a silver emulsion at diffuse density `density`, in arbitrary
    /// units. Mirrors `silver_granularity_variance` in FotufilmHalideShared.h.
    func silverGranularityVariance(_ density: Float) -> Float {
        density * pow(10, 0.21004 * density + 0.06114 * density * density)
    }

    /// Granularity at `netDensity`, relative to the datasheet read density, under whichever law
    /// the emulsion obeys. Fog density is included at both the anchor and requested density.
    public func grainDensityModulation(layer: Int, netDensity: Float) -> Float {
        let anchor = granularityAnchorDensity(layer: layer) + grainFogDensity
        let here = max(netDensity, 0) + grainFogDensity
        guard anchor > 0 else { return 0 }
        let ratio: Float
        switch grainDensityLaw {
        case .dyeCloud:
            ratio = dyeCloudGranularityVariance(here)
                / max(dyeCloudGranularityVariance(anchor), 1e-6)
        case .silver:
            ratio = silverGranularityVariance(here)
                / max(silverGranularityVariance(anchor), 1e-6)
        case .dyeCloudSelwyn:
            ratio = here / anchor
        }
        return max(ratio, 0).squareRoot()
    }

    public func developedDensity(layer: Int, logExposure: Float) -> Float {
        let curve = curves[layer]
        let formed = curve.density(logExposure: logExposure)
        return isReversal ? curve.dMin + curve.dMax - formed : formed
    }

    /// Scales each layer's contrast around its calibrated midpoint relative to green.
    /// Zero preserves optical-printer timing and filtration only; positive values interpolate
    /// toward `SpectralRuntime.neutralPrintingBalance`.
    public func printingContrastScale(correction: Float,
                                      paper: PrintPaper = .default) -> [Float] {
        guard !isMonochrome, paper.acceptsPrintCorrection, paper != .labScan else {
            return [1, 1, 1]
        }
        let balance = SpectralRuntime.neutralPrintingBalance(for: self, paper: paper)
        return balance.map { 1 + correction * ($0 - 1) }
    }

}

extension FilmStock {
    /// The stock a film-free develop names.
    ///
    /// `FilmEngineInvocation` builds its configuration from a stock, and a photograph with
    /// nothing in the gate has none — so it names this one, and a variant carrying
    /// `FilmEngineFeature.noFilm` reads not one slot it filled. The values below are therefore
    /// arbitrary rather than meaningful, and deliberately the plainest thing that satisfies the
    /// initialiser: a neutral emulsion, no grain, no halation, no couplers.
    ///
    /// `FilmEngineInvocation` also skips the spectral derivation for a no-film invocation, so
    /// naming this costs no table build and takes no room in the cache.
    /// `testNoFilmIgnoresWhichStockWasNamed` is what keeps "reads nothing it filled" true.
    public static let noFilm = FilmStock(
        name: "No film",
        sensitivity: [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
        curves: [
            CharacteristicCurve(dMin: 0, gamma: 1, toe: -2, toeWidth: 0.2,
                                shoulder: 2, shoulderWidth: 0.2),
            CharacteristicCurve(dMin: 0, gamma: 1, toe: -2, toeWidth: 0.2,
                                shoulder: 2, shoulderWidth: 0.2),
            CharacteristicCurve(dMin: 0, gamma: 1, toe: -2, toeWidth: 0.2,
                                shoulder: 2, shoulderWidth: 0.2),
        ],
        couplerInhibition: [[0, 0, 0], [0, 0, 0], [0, 0, 0]],
        couplerDiffusionMM: 0,
        grainStrength: 0,
        grainSizeMM: 0,
        grainLayerWeights: [1, 1, 1],
        halationStrength: [0, 0, 0],
        paperCurve: CharacteristicCurve(dMin: 0, gamma: 1, toe: -2,
                                        toeWidth: 0.2, shoulder: 2,
                                        shoulderWidth: 0.2))
}
