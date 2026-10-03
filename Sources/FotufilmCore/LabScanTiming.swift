import Foundation

/// Lab Scan's per-frame levels: the auto setup a minilab scanner runs on every frame before the
/// operator sees it. The scanner steepens the scan, within a limit, until the frame's brightest
/// content would reach white and the film base black, and sets its density on the frame's median,
/// taking out part of the frame's misexposure; neither the highlight nor the base may then scan
/// past its point. A flat frame keeps its key instead of having its brightest content printed
/// white. An unmetered frame scans at the fixed profile.
///
/// The levels ride the print stage's existing slots, as Digital Reference's do: `scale`
/// multiplies the records' contrast and `shift` moves the scan curve's exposure origin, both in
/// the scan's log-exposure units relative to mid-grey, so no table is rebuilt per frame.
public enum LabScanTiming {
    /// Scan density the metered highlight lands on: a bright white short of paper white, so
    /// broad highlights keep the curve's toe separation instead of bleaching.
    static let whiteDensity: Float = 0.08
    /// Scan density the film base lands on: where a normally exposed negative's base scans at
    /// the fixed profile.
    static let blackDensity: Float = 2.2
    /// The most a frame is steepened past the stock's contrast to reach both points.
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

    /// The scan curve's read shift that lightens mid-grey by `stops`: the scanner's density key,
    /// on the axis the timing's shift rides.
    static func densityShift(stops: Float, stock: FilmStock) -> Float {
        guard stops != 0, stops.isFinite else { return 0 }
        let curve = PrintPaper.labScan.printCurve(for: stock)
        let mid = PrintPaper.labScan.printExposureMidpoints(for: stock)[1]
        func output(_ shift: Float) -> Float {
            pow(10, -(curve.density(logExposure: mid + shift) - curve.dMin))
        }
        let target = output(0) * exp2(min(max(stops, -6), 6))
        // Output falls as the read rises; bisect the read for the target.
        var low: Float = -3, high: Float = 3
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if output(middle) > target { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }


    /// The levels for a frame whose highlight and median were metered at `sceneHighlightStops`
    /// and `sceneMedianStops`, after the edit's `exposureEV`, printed through records of contrast
    /// `masking`. The scanner sets up the negative as it was exposed, so the edit's exposure is
    /// taken back out of the reading and still lightens or darkens the scan. Green sets both
    /// points and the key; red and blue are timed to the same exposures through their own reads
    /// (`recordLevels`), so a grey the fixed profile scans neutral still scans neutral. Without a
    /// median the frame is placed on its points alone and every record takes green's levels.
    public static func levels(for stock: FilmStock, sceneHighlightStops: Float?,
                              sceneMedianStops: Float? = nil,
                              exposureEV: Float = 0, masking: SIMD3<Float> = .one)
        -> (scale: SIMD3<Float>, shift: SIMD3<Float>) {
        guard let measured = sceneHighlightStops, measured.isFinite, !stock.isReversal,
              !stock.isReflectionPrint else { return (.one, .zero) }
        let white = scanExposure(stock, density: whiteDensity)
        let black = scanExposure(stock, density: blackDensity)
        let highStops = min(max(measured - exposureEV, -12), 12)
        let high = reads(for: stock, stops: highStops).y * masking.y
        let base = reads(for: stock, stops: nil).y * masking.y
        let green = min(max((black - white) / max(base - high, 0.05), 1), maxStretch)
        // Whichever point the scale cannot also reach gives way: a dense frame's base scans
        // past black, a thin frame's highlight short of white.
        let placed = max(white - green * high, black - green * base)
        guard let median = sceneMedianStops, median.isFinite else {
            return (SIMD3(repeating: green), SIMD3(repeating: placed))
        }
        let medianStops = min(max(median - exposureEV, -12), 12)
        let shift = max(placed, keyShift(for: stock, medianStops: medianStops, green: green,
                                         masking: masking.y))
        return recordLevels(for: stock, green: green, shift: shift, medianStops: medianStops,
                            highlightStops: highStops, masking: masking)
    }

    /// Stops under the median, and the least span over it, of the two exposures red and blue are
    /// timed at: they bracket the frame's shadows and its highlight.
    public static let recordAnchorBelow: Float = 2
    public static let recordAnchorSpan: Float = 1.5

    /// Red's and blue's levels for green's `green` and `shift`: each record scans the frame's
    /// shadow and highlight anchors where its own read of the exposures green times them to would
    /// scan at the fixed profile. A record's curve differs from green's, so an equal shift on
    /// every record would scan bright greys one colour and dark greys another.
    public static func recordLevels(for stock: FilmStock, green: Float, shift: Float,
                                    medianStops: Float, highlightStops: Float,
                                    masking: SIMD3<Float>)
        -> (scale: SIMD3<Float>, shift: SIMD3<Float>) {
        let low = medianStops - recordAnchorBelow
        let high = max(highlightStops, medianStops + recordAnchorSpan)
        let readLow = reads(for: stock, stops: low) * masking
        let readHigh = reads(for: stock, stops: high) * masking
        let timedLow = reads(for: stock, stops: greenStops(
            for: stock, read: (green * readLow.y + shift) / masking.y)) * masking
        let timedHigh = reads(for: stock, stops: greenStops(
            for: stock, read: (green * readHigh.y + shift) / masking.y)) * masking
        var scale = SIMD3(repeating: green)
        var shifts = SIMD3(repeating: shift)
        for c in [0, 2] where abs(readHigh[c] - readLow[c]) > 1e-3 {
            scale[c] = (timedHigh[c] - timedLow[c]) / (readHigh[c] - readLow[c])
            shifts[c] = timedLow[c] - scale[c] * readLow[c]
        }
        return (scale, shifts)
    }

    /// The stop, from mid-grey, whose green read is `read`: the green read falls as exposure
    /// rises.
    static func greenStops(for stock: FilmStock, read: Float) -> Float {
        var low: Float = -16, high: Float = 16
        for _ in 0..<32 {
            let middle = (low + high) / 2
            if reads(for: stock, stops: middle).y > read { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    /// The shift that sets the scan's density on a frame whose median sits `medianStops` from
    /// mid-grey before the edit's exposure, scanned at contrast `green`: the median scans where
    /// the fixed profile scans a patch `keyShare` of the way back to mid-grey.
    public static func keyShift(for stock: FilmStock, medianStops: Float, green: Float,
                                masking: Float) -> Float {
        let stops = min(max(medianStops, -12), 12)
        return masking * (reads(for: stock, stops: (1 - keyShare) * stops).y
            - green * reads(for: stock, stops: stops).y)
    }


    /// The scan curve's log exposure, relative to its mid-grey origin, that scans `density`.
    static func scanExposure(_ stock: FilmStock, density: Float) -> Float {
        let curve = PrintPaper.labScan.printCurve(for: stock)
        return curve.logExposure(density: curve.dMin + density)
            - PrintPaper.labScan.printExposureMidpoints(for: stock)[1]
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
