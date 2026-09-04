import Foundation

/// One-tap development settings: exposure and tone recovery solved so the
/// scene lands inside the film's own latitude.
public enum AutoAdjustment {
    public struct Solution: Equatable, Sendable {
        /// Exposure compensation, in stops; bounded to +/- 3.
        public var exposureEV: Float
        /// Highlight recovery, -1...0: the solve only ever protects
        /// highlights, never pushes them further up.
        public var highlights: Float
        /// Shadow recovery, 0...1: likewise only ever lifts.
        public var shadows: Float

        public static let neutral = Solution(exposureEV: 0, highlights: 0, shadows: 0)
    }

    /// Scene stops that survive to the print with tonal separation, relative to metered mid-grey.
    public static func latitude(
        stock: FilmStock, printCorrection: Float = 0.05,
        paper: PrintPaper = .default
    ) -> (shadows: Float, highlights: Float) {
        let key = LatitudeKey(
            tables: SpectralRuntime.cacheIdentifier(for: stock, paper: paper),
            correction: printCorrection)
        latitudeLock.lock()
        if let found = latitudeCache[key] {
            latitudeLock.unlock()
            return found
        }
        latitudeLock.unlock()
        let step: Float = 0.25
        let reach: Float = 12
        let stops = Array(stride(from: -reach, through: reach, by: step))
        let scale = SpectralRuntime.neutralToneScale(
            stops: stops, stock: stock, paper: paper,
            printCorrection: printCorrection)
        let logScale = scale.map { log2(max($0, 1e-6)) }
        func slope(_ index: Int) -> Float {
            (logScale[index + 1] - logScale[index - 1]) / (2 * step)
        }
        func separation(_ index: Int) -> Float {
            let value = slope(index)
            return paper.isNegative ? abs(value) : value
        }
        let mid = stops.count / 2
        let floor = kSlopeFloor * max(separation(mid), 1e-4)
        var high = mid, low = mid
        while high + 1 < stops.count - 1, separation(high + 1) >= floor { high += 1 }
        while low - 1 > 0, separation(low - 1) >= floor { low -= 1 }
        let window = (shadows: stops[low], highlights: stops[high])
        latitudeLock.lock()
        latitudeCache[key] = window
        latitudeLock.unlock()
        return window
    }

    /// The window is asked for on every HDR develop, and the scale walk behind it integrates
    /// the spectral model at 97 wedge points — once per stock, paper and correction is enough.
    private struct LatitudeKey: Hashable {
        var tables: UInt64
        var correction: Float
    }
    private static var latitudeCache: [LatitudeKey: (shadows: Float, highlights: Float)] = [:]
    private static let latitudeLock = NSLock()

    /// Fraction of the mid-grey gradient below which a tone no longer
    /// meaningfully separates from its neighbours.
    static let kSlopeFloor: Float = 0.2

    /// The three order statistics the solve reads a scene through, taken once.
    public struct SceneStops: Equatable, Sendable {
        public var median: Float
        public var bright: Float
        public var dark: Float

        public init(median: Float, bright: Float, dark: Float) {
            self.median = median
            self.bright = bright
            self.dark = dark
        }

        /// Nil for an empty scene, which is the same thing the solve treats as neutral.
        public init?(regionStops: [Float]) {
            self.init(sortedRegionStops: regionStops.sorted())
        }

        /// For a caller that has already sorted them, and would otherwise
        /// sort the same four thousand floats twice.
        public init?(sortedRegionStops sorted: [Float]) {
            guard !sorted.isEmpty else { return nil }
            func percentile(_ q: Float) -> Float {
                let position = q * Float(sorted.count - 1)
                let low = Int(position)
                let high = min(low + 1, sorted.count - 1)
                let fraction = position - Float(low)
                return sorted[low] + fraction * (sorted[high] - sorted[low])
            }
            self.init(median: percentile(0.5), bright: percentile(0.995),
                      dark: percentile(0.005))
        }
    }

    /// Solves exposure, highlights and shadows for a scene described by its regional log-luminances
    /// (`ToneBaseMeasurement.regionStops`, metered neutrally: balance 1, gain 1).
    public static func solve(
        regionStops: [Float], stock: FilmStock, printCorrection: Float = 0.05
    ) -> Solution {
        guard let scene = SceneStops(regionStops: regionStops) else {
            return .neutral
        }
        return solve(scene: scene,
                     window: latitude(stock: stock,
                                      printCorrection: printCorrection))
    }

    /// The same solve, for a caller that already has the scene's statistics and the film's window.
    public static func solve(
        scene: SceneStops, window: (shadows: Float, highlights: Float)
    ) -> Solution {
        let median = scene.median
        let bright = scene.bright
        let dark = scene.dark

        var exposure = kMedianTarget - median
        exposure = min(exposure, window.highlights - bright)
        exposure = min(max(exposure, -3), 3)

        var highlights: Float = 0
        let excessHigh = (bright + exposure) - (window.highlights - kHighlightHeadroom)
        if excessHigh > 0 {
            highlights = -min(1, excessHigh / max(3 * toneMask(bright + exposure), 1e-3))
        }
        var shadows: Float = 0
        let excessLow = (window.shadows + kShadowHeadroom) - (dark + exposure)
        if excessLow > 0 {
            shadows = min(1, excessLow / max(3 * toneMask(-(dark + exposure)), 1e-3))
        }
        return Solution(exposureEV: exposure, highlights: highlights,
                        shadows: shadows)
    }

    /// How completely the recovery shift applies at `stops` from mid-grey — the engine's own
    /// fade, which reaches full strength six stops out (`creative_exposure` keys the same way).
    static func toneMask(_ stops: Float) -> Float {
        let t = min(max(stops / 6, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Where an SDR source's diffuse white sits, in stops above metered mid-grey — the 18%
    /// grey card of photographic practice, and the reference-white anchor ITU-R BT.2408
    /// hangs HDR production on.
    public static let kDiffuseWhiteStops: Float = -log2(0.18)

    /// The highlight recovery that fits a source's declared headroom into the film's window —
    /// the same pre-emulsion light shaping `solve` drives from measured content, driven here
    /// by what the container states it recorded (the ISO 21496-1 gain-map declaration an HDR
    /// photograph carries). The shape follows the industry's HDR-to-limited-range practice —
    /// ITU-R BT.2408 anchors diffuse white and everything below it, ITU-R BT.2446 rolls the
    /// range above off through a knee that keeps separating tones up to the content peak —
    /// so only the range the headroom adds beyond both the window's edge and the SDR ceiling
    /// is compressed. An SDR source (headroom 1) and a stock whose latitude already covers
    /// the declared range both come back 0 — and the develop stays untouched.
    public static func headroomHighlights(
        contentHeadroom: Float, window: (shadows: Float, highlights: Float)
    ) -> Float {
        guard contentHeadroom > 1 else { return 0 }
        let top = kDiffuseWhiteStops + log2(contentHeadroom)
        let excess = top - max(window.highlights, kDiffuseWhiteStops)
        guard excess > 0 else { return 0 }
        return -min(1, excess / max(3 * toneMask(top), 1e-3))
    }

    /// Where the scene's median region is metered to, in stops from mid-grey.
    public static let kMedianTarget: Float = -2.0 / 3.0

    /// How far inside the latitude edge recovery lands the brightest regions.
    static let kHighlightHeadroom: Float = 1.0

    /// The shadow-side margin.
    static let kShadowHeadroom: Float = 0.5
}
