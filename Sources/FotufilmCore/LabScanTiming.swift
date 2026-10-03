import Foundation

/// Lab Scan's per-frame setup: the auto setup a minilab scanner runs on every frame before the
/// operator sees it, and the operator's own density and colour keys. The scanner sets the frame's
/// density on its median, taking out part of the frame's misexposure, and steepens it about the
/// film's toe, within a limit, until its brightest content would reach white; that content never
/// scans past white. A flat frame keeps its key instead of having its brightest content printed
/// white. An unmetered frame scans at the fixed profile, keyed by the operator alone.
///
/// The scanner levels its scan, not the film: each record's contrast and shift are set where its
/// own read of a grey lands the frame's shadows and highlight where the fixed profile scans the
/// greys the setup places them on, so a grey stays grey through records whose curves differ, and
/// the film keeps the exposure it had. Exposing the film further to steepen it would carry bright
/// colours into its shoulder, which turns them. The colour keys ride the light the film's layers
/// receive, so a key is the same colour from the shadows to the highlights, and so does the
/// operator's lightening, so the film base still scans black.
public enum LabScanTiming {
    /// Scan density the metered highlight lands on: a bright white short of paper white, so
    /// broad highlights keep the curve's toe separation instead of bleaching.
    static let whiteDensity: Float = 0.08
    /// The most a frame is steepened past the stock's contrast to bring its highlight to white.
    public static let maxStretch: Float = 1.5

    /// How far over the scene's median the metered highlight may sit before the excess is taken
    /// for a lamp, a sky or a window, and the share of that excess, at most two stops, that the
    /// white point is lowered by: a backlit subject opens up partway while the sky stays on the
    /// toe, and a specular or the sun does not hold the frame down.
    public static let highlightSpan: Float = 3
    public static let backlightShare: Float = 0.5
    public static let backlightMaxStops: Float = 2

    /// The share of the median's distance from mid-grey the scanner's density takes out.
    public static let keyShare: Float = 0.5

    /// A full colour key's change to its layer's exposure, in log10 units: about the change a
    /// CC30 filter makes to a print's exposure, carried back through a negative's contrast.
    public static let keyReach: Float = 0.5

    /// The highlight the white point is set on, from the whole-frame measurement, in stops.
    static func highlight(_ scene: AutoAdjustment.SceneStops) -> Float {
        let excess = max(0, scene.bright - scene.median - highlightSpan)
        return scene.bright - min(backlightMaxStops, backlightShare * excess)
    }

    /// The scanner's dodging: a frame whose content reaches further from its median than a print
    /// holds has its bright regions held down and its dark regions opened up, each region by its
    /// own brightness, so broad highlights keep their detail and shadows their texture while local
    /// contrast stays. The white point is still set on the undodged highlight, so the mid-tones
    /// print where they would and the held highlights come in under white. A frame inside the
    /// print's range is not dodged. The hold and lift ride the
    /// highlight and shadow controls' masks, keyed regionally on the frame's median.
    public struct Dodge: Equatable, Sendable {
        /// Highlight hold and shadow lift, in the tone controls' units.
        public var hold: Float
        public var lift: Float
        /// The stop the regions are keyed on: the frame's median.
        public var key: Float
    }

    /// Stops past the median the frame's ends may reach before they are dodged, and the further
    /// stops over which the dodge comes in fully.
    static let dodgeHighlightSpan: Float = 3
    static let dodgeShadowSpan: Float = 3.5
    static let dodgeRamp: Float = 3
    /// The fullest hold and lift.
    static let dodgeMaxHold: Float = 0.15
    static let dodgeMaxLift: Float = 0.2

    /// The most of the scanner's own dodge a frame may take.
    public static let dodgingRange: ClosedRange<Float> = 0...2

    /// The dodge for a frame with this whole-frame measurement, `strength` times the scanner's.
    public static func dodge(_ scene: AutoAdjustment.SceneStops, strength: Float = 1) -> Dodge {
        func ramp(_ reach: Float, _ span: Float) -> Float {
            min(max((reach - span) / dodgeRamp, 0), 1)
        }
        let share = strength.isFinite
            ? min(max(strength, dodgingRange.lowerBound), dodgingRange.upperBound) : 1
        return Dodge(
            hold: min(share * dodgeMaxHold * ramp(scene.bright - scene.median, dodgeHighlightSpan), 1),
            lift: min(share * dodgeMaxLift * ramp(scene.median - scene.dark, dodgeShadowSpan), 1),
            key: scene.median)
    }

    /// A frame's setup: each of the film's layers forms at log exposure x the density it would
    /// form at `x + shift + keys[layer]`, and each of the scan's records reads `scale[record]`
    /// times its read, plus `print[record]`, on the print stage's axis.
    public struct Setup: Equatable, Sendable {
        /// The film's exposure change in log10 units: the operator's lightening.
        public var shift: Float
        /// The colour keys, each layer's own log10 exposure change.
        public var keys: SIMD3<Float>
        /// The scan's levels: each record's contrast and shift.
        public var scale: SIMD3<Float>
        public var print: SIMD3<Float>

        public static let identity = Setup(shift: 0, keys: .zero)

        public init(shift: Float, keys: SIMD3<Float>, scale: SIMD3<Float> = .one,
                    print: SIMD3<Float> = .zero) {
            self.shift = shift
            self.keys = keys
            self.scale = scale
            self.print = print
        }

        /// The stock's records as this setup exposes them.
        public func curves(for stock: FilmStock) -> [CharacteristicCurve] {
            stock.curves.enumerated().map { $1.reexposed(offset: shift + keys[$0]) }
        }

        /// A capture layer that answers no colour key, such as a donor layer: the lightening
        /// alone.
        public func uncoloured(_ curve: CharacteristicCurve) -> CharacteristicCurve {
            curve.reexposed(offset: shift)
        }
    }

    /// Stops under the median, and the least span over it, of the two greys each record is
    /// levelled at: they bracket the frame's shadows and its highlight.
    public static let recordAnchorBelow: Float = 2
    public static let recordAnchorSpan: Float = 1.5

    /// The setup for a frame metered at `sceneHighlightStops` and `sceneMedianStops` after the
    /// edit's `exposureEV`, lightened by the operator's `scanExposure` stops and keyed by `keys`
    /// (cyan, magenta and yellow, each −1…1, taking out red, green and blue). The scanner sets up
    /// the negative as it was exposed, so the edit's exposure is taken back out of the reading and
    /// still lightens or darkens the scan by its own stops; so does the operator's density.
    ///
    /// The steepening pivots on the film's toe, where its straight line meets the base: the base
    /// stays black and the frame opens upward until its highlight would scan at white. The
    /// density then darkens the frame toward its key, `keyShare` of the median's distance from
    /// mid-grey taken out, but never lightens it: lifting a frame past its own toe would lift the
    /// black a dark frame is made of. A highlight already past white at the stock's contrast
    /// darkens the frame until it scans at white. A frame lightened past its setup takes the rest
    /// on the film.
    public static func setup(for stock: FilmStock, sceneHighlightStops: Float?,
                             sceneMedianStops: Float?, exposureEV: Float = 0,
                             scanExposure: Float = 0, keys: SIMD3<Float> = .zero) -> Setup {
        guard !stock.isReversal, !stock.isReflectionPrint else { return .identity }
        let colour = stock.isMonochrome ? SIMD3<Float>.zero : SIMD3((0..<3).map { layer in
            keys[layer].isFinite ? -keyReach * min(max(keys[layer], -1), 1) : 0
        })
        let points = profilePoints(for: stock)
        let ev = exposureEV.isFinite ? exposureEV : 0
        var contrast: Float = 1
        var middle: Float = 0
        var highlight: Float = 0
        var stops = scanExposure.isFinite ? min(max(scanExposure, -6), 6) : 0
        let metered = sceneHighlightStops?.isFinite == true && sceneMedianStops?.isFinite == true
        if metered, let high = sceneHighlightStops, let median = sceneMedianStops {
            middle = min(max(median - ev, -12), 12)
            highlight = max(min(max(high - ev, -12), 12), middle)
            let reach = highlight - points.toe
            contrast = reach > 1e-3
                ? min(max((points.white - points.toe) / reach, 1), maxStretch) : maxStretch
        } else if stops == 0 {
            return Setup(shift: 0, keys: colour)
        }
        func placed(_ stops: Float) -> Float { points.toe + contrast * (stops - points.toe) }
        if metered {
            stops += min(0, (1 - keyShare) * middle - placed(middle),
                         points.white - placed(highlight))
        }
        // A grey at stop x reaches the film at x + ev, lightened by `lift`, and each record scans
        // it where the fixed profile scans the grey at placed(x) + ev + stops, exactly at the two
        // greys bracketing the frame.
        let lift = max(stops, 0)
        let low = middle - recordAnchorBelow
        let high = max(highlight, middle + recordAnchorSpan)
        func read(_ stops: Float) -> SIMD3<Float> { reads(for: stock, stops: stops) * points.masking }
        let (readLow, readHigh) = (read(low + ev + lift), read(high + ev + lift))
        let targetLow = read(placed(low) + ev + stops)
        let targetHigh = read(placed(high) + ev + stops)
        var scale = SIMD3<Float>.one
        for c in 0..<3 where abs(readHigh[c] - readLow[c]) > 1e-3 {
            scale[c] = (targetHigh[c] - targetLow[c]) / (readHigh[c] - readLow[c])
        }
        return Setup(shift: lift * Float(log10(2.0)), keys: colour, scale: scale,
                     print: targetLow - scale * readLow)
    }

    /// The fixed profile's points: where it scans a neutral at `whiteDensity` and the film's toe,
    /// where its green record's straight line through mid-grey meets the read of the bare base,
    /// both in stops over mid-grey; and each record's contrast on the print stage.
    public struct Points: Equatable, Sendable {
        public var white: Float
        public var toe: Float
        public var masking: SIMD3<Float>
    }

    public static func profilePoints(for stock: FilmStock) -> Points {
        let key = SpectralRuntime.cacheIdentifier(for: stock, paper: .labScan)
        if let cached = pointsCache.value(for: key) { return cached }
        let curve = PrintPaper.labScan.printCurve(for: stock)
        let masking = SIMD3(stock.printingContrastScale(
            correction: FotufilmEngine.Options().printCorrection, paper: .labScan))
        let read = (curve.logExposure(density: curve.dMin + whiteDensity)
            - PrintPaper.labScan.printExposureMidpoints(for: stock)[1]) / masking.y
        // The green read falls as exposure rises; bisect the stop for the read.
        var low: Float = -16, high: Float = 16
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if reads(for: stock, stops: middle).y > read { low = middle } else { high = middle }
        }
        let stop = reads(for: stock, stops: -0.5).y - reads(for: stock, stops: 0.5).y
        let toe = -(reads(for: stock, stops: nil).y - reads(for: stock, stops: 0).y)
            / max(stop, 1e-3)
        let points = Points(white: (low + high) / 2, toe: min(toe, -1), masking: masking)
        pointsCache.store(points, for: key)
        return points
    }

    private static let pointsCache = PointsCache()

    private final class PointsCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UInt64: Points] = [:]

        func value(for key: UInt64) -> Points? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        func store(_ value: Points, for key: UInt64) {
            lock.lock()
            values[key] = value
            lock.unlock()
        }
    }

    /// What the scanner's records read of a neutral patch `stops` over mid-grey, or of the bare
    /// film base for nil: log light relative to mid-grey, the print stage's own axis.
    public static func reads(for stock: FilmStock, stops: Float?) -> SIMD3<Float> {
        let paper = PrintPaper.labScan
        let callier = SpectralRuntime.callierCoefficient(1, stock: stock, paper: paper)
        let logExposure = (stops ?? -40) * Float(log10(2.0))
        func density(_ logExposure: Float) -> [Float] {
            (0..<3).map { stock.developedDensity(layer: $0, logExposure: logExposure) * callier }
        }
        let mid = SpectralRuntime.printingIllumination(
            stock: stock, paper: paper, density: density(0),
            dyes: stock.spectralProfile.imageDyeDensity, densityScale: callier)
        let energy = SpectralRuntime.paperExposure(
            density: density(logExposure), stock: stock, lamp: mid.lamp,
            paperSensitivity: paper.sensitivity, densityScale: callier)
        let ratio = SIMD3((0..<3).map {
            log10(max(energy[$0], 1e-12) / max(mid.referenceEnergy[$0], 1e-12))
        })
        return ratio + SpectralRuntime.referenceCastOffset(midEnergy: mid.referenceEnergy,
                                                           stock: stock, paper: paper)
    }
}
