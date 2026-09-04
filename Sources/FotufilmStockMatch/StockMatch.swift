import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Which film in the pack this photograph is least damaged by.
public enum StockMatch {

    /// Everything about a photograph this scorer reads, measured once and asked of every film.
    public struct SceneDescription: Equatable, Sendable {
        /// Regional log-luminances in stops from metered mid-grey —
        /// `ToneBaseMeasurement.regionStops`, the same statistics the auto development solves from,
        /// so a specular glint appears as one cell rather than as "the highlights".
        public let regionStops: [Float]

        /// The same, sorted, and the three order statistics the solve reads off them.
        public let sortedStops: [Float]
        public let toneStatistics: AutoAdjustment.SceneStops?

        /// Median linear saturation, `(max - min) / max` over the pixels
        /// bright enough to have a colour at all.
        public let chromaMedian: Float

        /// The 95th percentile of the same measure — how colourful the most
        /// colourful parts of the picture already are.
        public let chromaHigh: Float

        /// Fraction of the frame above display white, where the pre-emulsion roll's knee sits.
        public let specularFraction: Float

        /// Mean absolute difference in log2 luminance between adjacent
        /// pixels: the picture's own texture, in stops per pixel.
        public let textureEnergy: Float

        /// Fraction of the frame the subject detector claimed, or nil where
        /// nothing was detected or the detector never ran.
        public let subjectFraction: Float?

        public init(regionStops: [Float], chromaMedian: Float,
                    chromaHigh: Float, specularFraction: Float,
                    textureEnergy: Float, subjectFraction: Float? = nil) {
            self.regionStops = regionStops
            let sorted = regionStops.sorted()
            self.sortedStops = sorted
            self.toneStatistics = AutoAdjustment.SceneStops(
                sortedRegionStops: sorted)
            self.chromaMedian = chromaMedian
            self.chromaHigh = chromaHigh
            self.specularFraction = specularFraction
            self.textureEnergy = textureEnergy
            self.subjectFraction = subjectFraction
        }

        /// Whether this photograph has so little colour in it that a
        /// monochrome film would not be discarding anything.
        public var readsAsColourless: Bool {
            chromaHigh < kColourlessCeiling
        }
    }

    /// One film's fit, kept as its parts rather than a single number, because a total that cannot
    /// be taken apart cannot be argued with — and the one thing this feature will be asked, every
    /// time it picks something surprising, is *why*.
    public struct Fit: Equatable, Sendable {
        /// How far the film's latitude drags exposure off the metered placement, in stops.
        public var meterMiss: Float
        /// How much of the frame falls outside the latitude once exposure has been placed — the
        /// fraction of the scene's regions, scaled into stops.
        public var outsideLatitude: Float
        /// How hard the tone recovery has to work to land the frame inside the window, 0…2 across
        /// both controls, scaled into stops.
        public var recoveryDemand: Float
        /// Grain the picture has no texture to hide, scaled into stops.
        public var grainExposure: Float

        /// Whether this film is a candidate at all.
        public var isEligible: Bool

        public var total: Float {
            meterMiss + outsideLatitude + recoveryDemand + grainExposure
        }

        public init(meterMiss: Float, outsideLatitude: Float,
                    recoveryDemand: Float, grainExposure: Float,
                    isEligible: Bool) {
            self.meterMiss = meterMiss
            self.outsideLatitude = outsideLatitude
            self.recoveryDemand = recoveryDemand
            self.grainExposure = grainExposure
            self.isEligible = isEligible
        }
    }

    /// Scores one film against one scene, without developing anything.
    public static func fit(
        scene: SceneDescription, stock: FilmStock,
        printCorrection: Float = 0.05
    ) -> Fit {
        let raw = analytic(scene: scene, stock: stock,
                           printCorrection: printCorrection)
        return Fit(meterMiss: kMeterWeight * raw.features[.meterMiss],
                   outsideLatitude: kOutsideWeight
                    * raw.features[.outsideLatitude],
                   recoveryDemand: kRecoveryWeight
                    * raw.features[.recoveryDemand],
                   grainExposure: kGrainWeight
                    * raw.features[.grainOnSmoothFrame],
                   isEligible: raw.isEligible)
    }

    /// The same reading, unweighted.
    public static func analytic(
        scene: SceneDescription, stock: FilmStock,
        printCorrection: Float = 0.05
    ) -> (features: StockFeatures, isEligible: Bool) {
        var features = StockFeatures()
        features[.grainAmount] = stock.grainStrength / kReferenceGrain

        let eligible = !stock.isMonochrome || scene.readsAsColourless
        guard let tones = scene.toneStatistics else {
            return (features, eligible)
        }

        let window = AutoAdjustment.latitude(stock: stock,
                                             printCorrection: printCorrection)
        let solution = AutoAdjustment.solve(scene: tones, window: window)

        let wanted = AutoAdjustment.kMedianTarget - tones.median
        features[.meterMiss] = abs(wanted - solution.exposureEV)

        let sorted = scene.sortedStops
        let below = firstIndex(in: sorted,
                               atOrAbove: window.shadows - solution.exposureEV)
        let above = sorted.count
            - firstIndex(in: sorted,
                         above: window.highlights - solution.exposureEV)
        features[.outsideLatitude] = Float(below + above) / Float(sorted.count)

        features[.recoveryDemand] = abs(solution.highlights) + solution.shadows

        let smoothness = exp(-scene.textureEnergy / kTextureScale)
        features[.grainOnSmoothFrame] = smoothness * features[.grainAmount]

        return (features, eligible)
    }

    /// Index of the first element that is not below `value` — equivalently,
    /// how many are strictly below it.
    static func firstIndex(in sorted: [Float], atOrAbove value: Float) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Index of the first element strictly above `value`.
    static func firstIndex(in sorted: [Float], above value: Float) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Above this much saturation in the most colourful twentieth of the frame, the photograph has
    /// colour and a monochrome film would be throwing it away.
    public static let kColourlessCeiling: Float = 0.06

    /// Stops charged per stop the film's latitude drags exposure off the metered placement.
    static let kMeterWeight: Float = 1

    /// Stops charged for the whole frame falling outside the film's window.
    static let kOutsideWeight: Float = 4

    /// Stops charged per unit of tone-recovery travel.
    static let kRecoveryWeight: Float = 1.0 / 3.0

    /// Stops charged for a reference-grain film on a perfectly smooth picture.
    static let kGrainWeight: Float = 1.0 / 3.0

    /// Texture, in stops per pixel, at which a picture hides half a film's grain.
    static let kTextureScale: Float = 0.08

    /// The grain strength the weight above is quoted against — roughly a
    /// 400-speed colour negative, the middle of the pack.
    static let kReferenceGrain: Float = 0.01
}
