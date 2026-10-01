import Foundation

/// Lab Scan's per-frame levels: the auto setup a minilab scanner runs on every frame before the
/// operator sees it. The scanner sets the frame's black point on the film base and its white
/// point on the frame's brightest content, steepening the scan within a limit to reach both; a
/// frame too dense to need it keeps the stock's contrast and only shifts. It has no controls; an
/// unmetered frame scans at the fixed profile.
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
    static let maxStretch: Float = 1.5

    /// How far over the scene's median the metered highlight may sit before the excess is taken
    /// for a lamp, a sky or a window, and the share of that excess, at most two stops, that the
    /// white point is lowered by: a backlit subject opens up partway while the sky stays on the
    /// toe, and a specular or the sun does not hold the frame down.
    static let highlightSpan: Float = 3
    static let backlightShare: Float = 0.5
    static let backlightMaxStops: Float = 2

    /// The highlight the white point is set on, from the whole-frame measurement, in stops.
    static func highlight(_ scene: AutoAdjustment.SceneStops) -> Float {
        let excess = max(0, scene.bright - scene.median - highlightSpan)
        return scene.bright - min(backlightMaxStops, backlightShare * excess)
    }

    /// The levels for a frame whose highlight was metered at `sceneHighlightStops`, after the
    /// edit's `exposureEV`, printed through records of contrast `masking`. The scanner sets up the
    /// negative as it was exposed, so the edit's exposure is taken back out of the reading and
    /// still lightens or darkens the scan. Green sets both points; red and blue keep the timed
    /// mid-grey and are steepened only where their base would otherwise scan lighter than black,
    /// the way a scanner's black point keeps the film's mask out of the shadows.
    public static func levels(for stock: FilmStock, sceneHighlightStops: Float?,
                              exposureEV: Float = 0, masking: SIMD3<Float> = .one)
        -> (scale: SIMD3<Float>, shift: Float) {
        guard let measured = sceneHighlightStops, measured.isFinite, !stock.isReversal,
              !stock.isReflectionPrint else { return (.one, 0) }
        let white = scanExposure(stock, density: whiteDensity)
        let black = scanExposure(stock, density: blackDensity)
        let high = reads(for: stock, stops: min(max(measured - exposureEV, -12), 12)).y
            * masking.y
        let base = reads(for: stock, stops: nil) * masking
        let green = min(max((black - white) / max(base.y - high, 0.05), 1), maxStretch)
        // Whichever point the scale cannot also reach gives way: a dense frame's base scans
        // past black, a thin frame's highlight short of white.
        let shift = max(white - green * high, black - green * base.y)
        // A red or blue base that would scan lighter than black is steepened onto it; one that
        // already scans black keeps the green contrast, and with it the film's colour.
        let toBlack = { (read: Float) in
            min(max((black - shift) / max(read, 0.05), green), green * maxStretch) }
        return (SIMD3(toBlack(base.x), green, toBlack(base.z)), shift)
    }

    /// The scan curve's log exposure, relative to its mid-grey origin, that scans `density`.
    static func scanExposure(_ stock: FilmStock, density: Float) -> Float {
        let curve = PrintPaper.labScan.printCurve(for: stock)
        return curve.logExposure(density: curve.dMin + density)
            - PrintPaper.labScan.printExposureMidpoints(for: stock)[1]
    }

    /// What the scanner's records read of a neutral patch `stops` over mid-grey, or of the bare
    /// film base for nil: log light relative to mid-grey, the print stage's own axis.
    static func reads(for stock: FilmStock, stops: Float?) -> SIMD3<Float> {
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
