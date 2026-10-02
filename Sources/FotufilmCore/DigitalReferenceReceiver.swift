import Foundation

/// How a developed film's tone is placed on Digital Reference. On a negative — colour or
/// monochrome — all three share the film-base black: the darkest exposure a negative can
/// deliver, its own base, renders as display black. They differ in the curve above it and in
/// whether the frame's own highlights set white. On a transparent positive there is no print
/// stage and no curve to choose: the reference exposure is the slide itself, mid-grey at 18%
/// with the clear base above display white, and the other two normalise it to SDR the way a
/// slide scanner does — the base to white, or the frame's brightest content to white.
public enum DigitalReferenceStyle: String, CaseIterable, Sendable, Identifiable, Codable {
    /// A print made at a standard, calibrated exposure: mid-grey at a fixed density, one fixed
    /// receiver curve for every stock. Deterministic and batch-consistent; the stock's own contrast
    /// and the scene's colour survive as they are.
    case referenceExposure = "reference-exposure"
    /// The same fixed anchoring with a graded paper's characteristic curve: a straight line at
    /// grade-2 contrast that rolls into paper white through a soft shoulder and into paper black
    /// through a firm toe. A uniform highlight roll-off across stocks.
    case gradedPrint = "graded-print"
    /// Per-frame timing on the graded curve, the way a minilab scanner re-times each frame: the
    /// whole frame shifts until its brightest content sits at white, at the stock's own contrast,
    /// with white held two and a half to three and a half stops over the frame's median so a lamp
    /// clips and a dusk stays dusk. A normal or dense negative keeps its base black; a thin one's
    /// base lifts toward a soft dark grey. A colour negative's red and blue are re-timed half way
    /// toward a neutral frame. On a positive, the frame's brightest content sets white and
    /// nothing else moves.
    case autoLevels = "auto-levels"

    public static let `default`: DigitalReferenceStyle = .autoLevels

    public var id: String { rawValue }

    /// Affine receiver placement for hosts that prepare their own packed configurations.
    /// The scene measurement is in stops over mid-grey, after input exposure.
    public func receiverLevels(for stock: FilmStock, sceneHighlightStops: Float? = nil,
                               exposureEV: Float = 0) -> (scale: Float, shift: Float) {
        DigitalReferenceReceiver.levels(for: stock, style: self,
                                       sceneHighlightStops: sceneHighlightStops,
                                       exposureEV: exposureEV)
    }

    /// The read Auto Levels balances a colour negative's records on, at a scene exposure `stops`
    /// over mid-grey and the graded contrast it prints at, for hosts that tabulate it. Nil where
    /// Auto Levels leaves the stock's colour alone.
    public static func autoLevelsColourRead(for stock: FilmStock, stops: Float) -> Float? {
        guard DigitalReferenceReceiver.metersColour(stock) else { return nil }
        return DigitalReferenceReceiver.gradedBaseRead / DigitalReferenceReceiver.baseRead(for: stock)
            * DigitalReferenceReceiver.read(for: stock, stops: stops)
    }

    /// Auto Levels' metering rule, for hosts that meter it on their own GPU as
    /// `FilmEngineInvocation.setToneBase` does on the CPU.
    public enum AutoLevelsRule {
        /// White's span over the scene's median and the most a frame is lifted, in stops.
        public static let whiteSpan = DigitalReferenceReceiver.retimeWhiteSpan
        public static let liftLimit = DigitalReferenceReceiver.retimeLiftLimit
        /// The print's white over the stop it prints mid-grey, and its black with detail under
        /// white, in stops of scene light.
        public static let printWhiteOverGrey = DigitalReferenceReceiver.printWhiteOverGrey
        public static let printRange = DigitalReferenceReceiver.printRange
        public static let shadowLiftShare = DigitalReferenceReceiver.shadowLiftShare
        /// The share of a colour negative's cast taken out, the largest cast read, and the floor a
        /// lit cell clears, in stops.
        public static let colourShare = DigitalReferenceReceiver.autoColourShare
        public static let colourReach = DigitalReferenceReceiver.autoColourReach
        public static let litFloorStops = ToneBaseMeasurement.litFloorStops

        /// Whether the rule places a stock's film exposure and moves its tone.
        public static func placesFilm(_ stock: FilmStock) -> Bool {
            DigitalReferenceReceiver.keysTone(stock)
        }

        /// Whether the rule balances a stock's records.
        public static func metersColour(_ stock: FilmStock) -> Bool {
            DigitalReferenceReceiver.metersColour(stock)
        }
    }

    public var name: String {
        switch self {
        case .referenceExposure: return "Reference Exposure"
        case .gradedPrint: return "Graded Print"
        case .autoLevels: return "Auto Levels"
        }
    }

    public var detail: String {
        switch self {
        case .referenceExposure:
            return "Fixed calibrated exposure; mid-grey and contrast never depend on the frame."
        case .gradedPrint:
            return "Fixed exposure through a graded paper curve with a soft highlight shoulder; "
                + "a positive's clear base sets white."
        case .autoLevels:
            return "Re-times each frame like a lab scan: its brightest content sets white."
        }
    }

    /// Whether the tone curve lives in the output table rather than the kernel's paper curve.
    var usesGradedCurve: Bool { self != .referenceExposure }
}

/// Fixed spectral receiver for color negatives on Digital Reference. Equal-energy illumination
/// reads the developed image dyes through broad RA-4 sensitivity bands. A common density matrix
/// separates their overlap against the public synthetic negative dye basis, then a common curve
/// delivers the records directly in Display P3. These are explicit modeling choices, not
/// measurements of a scanner or display. No capture-stock inverse is applied.
///
/// Only the stock's reference exposure is balanced. Its layer contrast, toe/shoulder differences,
/// and spectral dye interactions survive at other exposures and for chromatic subjects.
///
/// A monochrome negative reads its own neutral curve directly (`PrintPaper.readsLayersDirectly`)
/// and develops along its legacy paper curve; the styles' film-base black, graded curve and
/// levels apply to that read exactly as they do to the colour receiver's. A transparent positive
/// on the graded styles is read as its own transmittance and levelled in the same slots
/// (`PrintPaper.levelsPositive`).
enum DigitalReferenceReceiver {
    /// Independent receiver offsets after automatic levels, on Digital Reference and Lab Scan. One
    /// relative unit is 0.30 log10 receiver-exposure units, not a calibrated scanner step or
    /// optical filter density.
    static func colourShift(_ cmy: SIMD3<Float>, stock: FilmStock,
                            paper: PrintPaper) -> SIMD3<Float> {
        guard paper == .screen || paper == .labScan, !stock.isReversal, !stock.isMonochrome,
              !stock.isReflectionPrint else { return .zero }
        return SIMD3((0..<3).map { channel in
            let value = cmy[channel]
            return value.isFinite ? min(max(value, -1), 1) * 0.30 : 0
        })
    }

    static let illuminant = SpectralGrid.equalEnergy
    static let sensitivity = SpectralGrid.paperSensitivity

    /// The receiver's mid-grey density above base, `PrintPaper.screen.midDensity`.
    static let anchorDensity: Float = 0.744

    /// Common digital density scale for `.referenceExposure`, independent of the selected
    /// negative's legacy paper curve. Retains the previous still-film display range without
    /// fitting away stock differences.
    static let referenceCurve = CharacteristicCurve(
        dMin: 0.07, gamma: 2.60, toe: -0.52, toeWidth: 0.16,
        shoulder: 0.42, shoulderWidth: 0.14)

    /// A straight line for the graded styles, so the kernel hands the output table the receiver's
    /// relative log exposure and the graded curve is applied there. Its range covers 0.8 above the
    /// anchor (4.6 stops on a gamma-0.6 negative, past where the graded shoulder is white) and 0.9
    /// below it (past every stock's base once the levels have placed it).
    static let straightCurve = CharacteristicCurve(
        dMin: 0, gamma: 1, toe: -0.8, toeWidth: 0.01,
        shoulder: 0.9, shoulderWidth: 0.01)

    /// A straight line for a levelled positive. The film table hands over the slide's own density
    /// above mid-grey, so the anchor sits at `anchorDensity` and the range runs from display
    /// white — a base brought to it, or content brightened past it — down 3.5 D, past every
    /// slide's maximum density once the levels have placed it.
    static let positiveCurve = CharacteristicCurve(
        dMin: 0, gamma: 1, toe: -anchorDensity, toeWidth: 0.01,
        shoulder: 3.5 - anchorDensity, shoulderWidth: 0.01)

    /// The curve `.referenceExposure` develops a record along: the receiver's own for a colour
    /// negative, the stock's legacy paper curve for monochrome, which every monochrome pack
    /// publishes with the same shape.
    static func referenceCurve(for stock: FilmStock) -> CharacteristicCurve {
        stock.isMonochrome ? stock.paperCurve : referenceCurve
    }

    static func curve(for style: DigitalReferenceStyle, stock: FilmStock) -> CharacteristicCurve {
        if stock.isReversal { return positiveCurve }
        return style.usesGradedCurve ? straightCurve : referenceCurve(for: stock)
    }

    // MARK: Film-base black

    /// Receiver log exposure, relative to the anchor, where `.referenceExposure` places the film
    /// base: 0.03 D short of the curve's asymptote, so black-point compensation carries it to zero.
    static func referenceBaseTarget(for stock: FilmStock) -> Float {
        let curve = referenceCurve(for: stock)
        let anchor = curve.logExposure(density: curve.dMin + anchorDensity)
        return curve.logExposure(density: curve.dMax - 0.03) - anchor
    }

    /// Shadow-side stretch for `.referenceExposure`: 1 at the anchor, `scale` well below it, C1 at
    /// the join, so the highlight side is untouched and the base lands on the target.
    static func stretchShadows(_ v: Float, scale: Float) -> Float {
        guard v > 0 else { return v }
        return v + (scale - 1) * v * (1 - exp(-v / 0.08))
    }

    /// The stock's base-to-mid-grey distance on the green record, which is what the receiver reads
    /// for a neutral wedge: its unmix holds an equal-channel exposure exactly on the neutral axis.
    /// Monochrome is read on its neutral curve, the mean of its records, as `screenReading` does.
    static func baseRead(for stock: FilmStock) -> Float {
        guard !stock.isMonochrome else {
            let dMin = stock.curves.map(\.dMin).reduce(0, +) / 3
            return max(SpectralRuntime.neutralDensity(stock, 0) - dMin, 0.05)
        }
        let green = stock.curves[1]
        return max(green.density(logExposure: 0) - green.dMin, 0.05)
    }

    /// Receiver read at a scene exposure `stops` over mid-grey: denser negative, less light.
    static func read(for stock: FilmStock, stops: Float) -> Float {
        guard !stock.isMonochrome else {
            return SpectralRuntime.neutralDensity(stock, 0)
                - SpectralRuntime.neutralDensity(stock, stops * log10(2))
        }
        let green = stock.curves[1]
        return green.density(logExposure: 0) - green.density(logExposure: stops * log10(2))
    }

    // MARK: Graded curve

    /// Normalised log value the graded curve's anchor sits at; the unit stretch runs from the
    /// frame's dense end (0) to its thin end (1), and 0.46 is where a typical negative's mid-grey
    /// falls on it.
    static let gradedAnchorVal: Float = 0.46
    /// The film base on the unit stretch. The shadow half anchors this to display black.
    static let gradedBaseVal: Float = 1.0
    /// Where the frame's brightest content is placed by `.autoLevels`: just inside the dense end,
    /// so the very peak goes to white and the content below it keeps the shoulder's separation.
    static let gradedWhiteVal: Float = 0.02
    /// Receiver log exposure per unit of the stretch: a typical negative's base-to-mid distance
    /// spans the 0.54 between the anchor and the thin end.
    static let gradedReadPerVal: Float = 0.73 / 0.54

    /// Read units the graded styles place the base and the frame white at.
    static var gradedBaseRead: Float { (gradedBaseVal - gradedAnchorVal) * gradedReadPerVal }
    static var gradedWhiteRead: Float { (gradedWhiteVal - gradedAnchorVal) * gradedReadPerVal }

    /// The calibrated graded curve's paper grade — the public entry points' default, spelled out
    /// there as the literal 2 — and the range a variable-contrast paper offers.
    static let referenceGrade: Float = 2
    static let gradeRange: ClosedRange<Float> = 0...5

    /// The graded curve's straight-line slope at a paper grade. ISO(R) log-exposure ranges run
    /// from about 160 at grade 0 to 52 at grade 5, an even 0.225 per grade in the log, and the
    /// slope is their reciprocal about the calibrated 2.894 at grade 2.
    static func gradedSlope(grade: Float) -> Float {
        let grade = min(max(grade, gradeRange.lowerBound), gradeRange.upperBound)
        return 2.894 * exp(0.225 * (grade - referenceGrade))
    }

    /// A graded paper's H&D curve, per channel, from the unit stretch to display-linear
    /// transmittance. A straight line of slope `k` through the pivot, a slight midtone S, a soft
    /// softplus shoulder into paper white and a firmer softplus toe into paper black at 2.3 D,
    /// then black-point compensation so that paper black is display black. The pivot is solved so
    /// the anchor prints 18% after compensation at every grade: the anchor's own point on the
    /// line, `vStar`, is held and the pivot moves with the slope.
    static func gradedTransmittance(val: Float, grade: Float = referenceGrade) -> Float {
        func softplus(_ x: Float) -> Float { x > 0 ? x + log1p(exp(-x)) : log1p(exp(x)) }
        let k = gradedSlope(grade: grade), vStar: Float = 0.6955
        let pivot = gradedAnchorVal - vStar / k
        let dMinEff: Float = 0.004, dMaxEff: Float = 2.295, aHl: Float = 3.0, aSh: Float = 6.0
        var v = k * (val - pivot)
        v += 0.05 * 0.6 * tanh((v - vStar) / 0.6)
        let v1 = dMinEff + softplus(aHl * (v - dMinEff)) / aHl
        let d = dMaxEff - softplus(aSh * (dMaxEff - v1)) / aSh
        let black = pow(10, -2.3) as Float
        return min(max((pow(10, -d) - black) / (1 - black), 0), 1)
    }

    // MARK: Levels

    /// The affine the kernel applies to the receiver's relative log exposure for the graded
    /// styles, in the paper mid-point and contrast slots: `read' = scale * read + shift`. Both
    /// graded styles print at the stock's graded contrast, the scale that puts its film base on
    /// `gradedBaseRead`. `.gradedPrint` holds the anchor. `.autoLevels` re-times the frame the way
    /// a lab scanner does, shifting every record alike so the metered highlight lands on
    /// `gradedWhiteRead`; the base then falls wherever the frame's exposure puts it. It falls back
    /// to the graded print when no measurement is available.
    ///
    /// A transparent positive has no curve to grade, only a gain: its levels are a shift alone,
    /// `positiveLevels`. An integral print is already a print and takes none.
    ///
    /// `sceneHighlightStops` is metered after the edit's `exposureEV`, as hosts supply it. The
    /// re-time takes the frame as the camera made it, before that exposure, so the edit's
    /// exposure still brightens or darkens the result rather than being timed back out.
    static func levels(for stock: FilmStock, style: DigitalReferenceStyle,
                       sceneHighlightStops: Float?,
                       exposureEV: Float = 0) -> (scale: Float, shift: Float) {
        guard style.usesGradedCurve, !stock.isReflectionPrint else { return (1, 0) }
        let sceneHighlightStops = sceneHighlightStops.map { $0 - exposureEV }
        if stock.isReversal {
            return (1, positiveShift(for: stock, style: style,
                                     sceneHighlightStops: sceneHighlightStops))
        }
        let base = baseRead(for: stock)
        switch style {
        case .referenceExposure:
            return (1, 0)
        case .gradedPrint:
            return (gradedBaseRead / base, 0)
        case .autoLevels:
            let scale = gradedBaseRead / base
            guard let measured = sceneHighlightStops, measured.isFinite else { return (scale, 0) }
            return (scale, retimeShift(for: stock, highlightStops: measured))
        }
    }

    /// The shift that lands a highlight `highlightStops` over mid-grey on the graded white, at
    /// the stock's graded contrast.
    static func retimeShift(for stock: FilmStock, highlightStops: Float) -> Float {
        let scale = gradedBaseRead / baseRead(for: stock)
        return gradedWhiteRead - scale * read(for: stock, stops: min(max(highlightStops, -12), 12))
    }

    /// The print's room in stops of scene light: its white, where `.autoLevels` re-times a frame's
    /// highlight (L* 95), sits `printWhiteOverGrey` over the stop it prints mid-grey, and its
    /// black with detail `printRange` under that white, where the shadow toe reaches L* 5 on a
    /// typical negative, about 3.3 stops under grey.
    static let printWhiteOverGrey: Float = 3
    static let printRange: Float = 6.3
    /// Stops over the frame's median `.autoLevels` places white at: the frame's own highlight
    /// (its 99.5th percentile), held inside this span. The median prints within half a stop of
    /// mid-grey: lighter on a frame whose highlights sit close to it, a fog or a white flower,
    /// which keeps its lightness without being stretched to white, and darker on one whose
    /// highlights reach far, which keeps its shadows deep.
    static let retimeWhiteSpan: ClosedRange<Float> = 2.5...3.5
    /// The most `.autoLevels` brightens a frame over the exposure it was taken at, in stops: a
    /// night, a stage or a candle-lit room the photographer exposed for its lights stays dark, as
    /// a scanner's auto-exposure leaves a frame it cannot lift without plainly getting it wrong.
    static let retimeLiftLimit: Float = 2.5

    /// The highlight `.autoLevels` re-times a frame on, from the whole-frame measurement, which
    /// `exposureEV`, the edit's exposure, already brightened.
    static func retimeHighlight(_ scene: AutoAdjustment.SceneStops, exposureEV: Float = 0) -> Float {
        let white = min(max(scene.bright, scene.median + retimeWhiteSpan.lowerBound),
                        scene.median + retimeWhiteSpan.upperBound)
        return max(white, exposureEV + printWhiteOverGrey - retimeLiftLimit)
    }

    /// The scene stop `.autoLevels` prints mid-grey, for the highlight it re-times on. The
    /// highlight hold and the shadow lift are keyed on it.
    static func toneKey(white: Float) -> Float { white - printWhiteOverGrey }

    /// The film exposure `.autoLevels` gives a negative over the one it was taken at, in stops:
    /// what puts the stop it prints mid-grey on the film's own mid-grey, more for an under-exposed
    /// frame and less for an over-exposed one, and the print is re-timed to take it back out. A negative keeps a highlight many stops over, but its shadows end a few
    /// stops under, on the base; placed so, every frame's dark end lies on the film as its bright
    /// end does, and the shadow toe reads it the same way. `exposureEV` is the edit's, which the
    /// meter's reading holds.
    static func filmBoost(for stock: FilmStock, white: Float, exposureEV: Float = 0) -> Float {
        guard keysTone(stock) else { return 0 }
        return exposureEV - toneKey(white: white)
    }

    /// Whether `.autoLevels` keys the tone controls on its print grey: a negative's, whose print
    /// it places.
    static func keysTone(_ stock: FilmStock) -> Bool { !stock.isReversal && !stock.isReflectionPrint }

    /// The scene-referred highlight hold and shadow lift, 0...1, `.autoLevels` gives a negative
    /// whose ends reach past the print from `white`, the highlight it re-times on. Each end is
    /// treated alike, its control pulling it in by the stops it reaches past and the print's grey
    /// keeping its place; the shadows by `shadowLiftShare` of them. None for an end that fits.
    /// How much of its overflow the shadow end is lifted by. A print gives its shadows a firmer
    /// landing than its highlights and keeps its blacks rich; lifted the whole way, deep shade
    /// flattens into grey.
    static let shadowLiftShare: Float = 0.75

    static func toneCompression(for stock: FilmStock, _ scene: AutoAdjustment.SceneStops,
                                white: Float) -> (hold: Float, lift: Float) {
        guard keysTone(stock) else { return (0, 0) }
        // The tone masks move a pixel `reach` stops from the key by 3 · amount · smoothstep(reach / 6).
        func amount(overflow: Float, room: Float) -> Float {
            guard overflow > 0 else { return 0 }
            let t = min((room + overflow) / 6, 1)
            return min(overflow / (3 * t * t * (3 - 2 * t)), 1)
        }
        return (amount(overflow: scene.bright - white, room: printWhiteOverGrey),
                shadowLiftShare * amount(overflow: white - printRange - scene.dark,
                                         room: printRange - printWhiteOverGrey))
    }

    /// The share of a frame's cast `.autoLevels` takes out of a colour negative, re-timing red
    /// and blue toward where the frame's lit median prints neutral. Half the way, as a lab
    /// scanner's automatic colour leaves part of a sunset or a lamp-lit room, and the stock its
    /// own palette.
    static let autoColourShare: Float = 0.5
    /// The largest cast it reads, in stops of scene light per record.
    static let autoColourReach: Float = 2

    /// The per-record shifts added to the levels' own. `channelMedians` is
    /// `ToneBaseMeasurement.channelMedians`, in stops over mid-grey metered like the highlight.
    static func autoColourShift(for stock: FilmStock, channelMedians: SIMD3<Float>?,
                                exposureEV: Float = 0) -> SIMD3<Float> {
        guard metersColour(stock), let medians = channelMedians,
              medians.x.isFinite, medians.y.isFinite, medians.z.isFinite else { return .zero }
        let read = { DigitalReferenceStyle.autoLevelsColourRead(for: stock, stops: $0) ?? 0 }
        let green = medians.y - exposureEV
        func shift(_ median: Float) -> Float {
            let cast = min(max(median - exposureEV - green, -autoColourReach), autoColourReach)
            return read(green) - read(green + cast)
        }
        return autoColourShare * SIMD3(shift(medians.x), 0, shift(medians.z))
    }

    /// Whether `.autoLevels` balances this stock's colour, and so meters each record.
    static func metersColour(_ stock: FilmStock) -> Bool {
        !stock.isReversal && !stock.isMonochrome && !stock.isReflectionPrint
    }

    // MARK: Positive levels

    /// How far past the clear base `.autoLevels` may brighten a positive, in log exposure: three
    /// stops, the most a scanner's auto-exposure lifts a thin slide before it is plainly wrong.
    static let positiveLiftLimit: Float = 0.9

    /// The density the kernel adds to a positive's read for the graded styles. The film table
    /// carries the slide's density above its 18% mid-grey, so a shift of `s` scales the whole
    /// frame by `10^-s`. `.gradedPrint` brings the clear base's brightest channel to display
    /// white; `.autoLevels` brings the frame's metered highlight there instead, never darker than
    /// the base-white print and never more than `positiveLiftLimit` brighter, falling back to it
    /// when no measurement is available.
    static func positiveShift(for stock: FilmStock, style: DigitalReferenceStyle,
                              sceneHighlightStops: Float?) -> Float {
        let read = SpectralRuntime.positiveScreenRead(for: stock)
        let baseWhite = -read.base
        switch style {
        case .referenceExposure:
            return 0
        case .gradedPrint:
            return baseWhite
        case .autoLevels:
            guard let measured = sceneHighlightStops, measured.isFinite else { return baseWhite }
            let stops = min(max(measured, 0.5), 12)
            let highlight = -read.luminance(stops: stops)
            return min(max(highlight, baseWhite - positiveLiftLimit), baseWhite)
        }
    }

    /// A levelled positive's display value from its kernel-curve density: the slide's own
    /// transmittance, mid-grey at 18%, with the curve's floor at display white.
    static func positiveRGB(density: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(pow(10, -density.x), pow(10, -density.y), pow(10, -density.z))
    }

    /// The receiver's small-signal density response at a neutral synthetic negative. Because
    /// the reference dyes partition unity, equal amounts transmit a constant spectrum. The
    /// derivative of measured density is therefore the band-weighted mean of each dye.
    /// This characterizes the receiver once, without looking at a selected stock or its curves.
    private static let densityUnmix: [SIMD3<Float>] = {
        let dyes = SpectralGrid.dyes(family: .kodakNegative)
        let rows: [SIMD3<Float>] = (0..<3).map { band in
            var response = SIMD3<Float>(repeating: 0)
            var total: Float = 0
            for i in 0..<SpectralGrid.count {
                let weight = illuminant[i] * sensitivity[band][i]
                total += weight
                for dye in 0..<3 { response[dye] += weight * dyes[dye][i] }
            }
            return response / total
        }
        func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z,
                  a.x * b.y - a.y * b.x)
        }
        let a = cross(rows[1], rows[2])
        let b = cross(rows[2], rows[0])
        let c = cross(rows[0], rows[1])
        // Transpose the cofactors into inverse rows. Normalizing their sums cancels the
        // common determinant and holds an equal-channel exposure exactly on the neutral axis.
        return (0..<3).map { i in
            let row = SIMD3(a[i], b[i], c[i])
            return row / (row.x + row.y + row.z)
        }
    }()

    static func read(_ relativeLogEnergy: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(densityUnmix.map { row in
            row.x * relativeLogEnergy.x + row.y * relativeLogEnergy.y
                + row.z * relativeLogEnergy.z
        })
    }

    /// The log exposure the screen conversion's exposure adds to every read, in the paper
    /// mid-point slots, for a change of `stops` in what mid-grey displays at. A positive's
    /// levelled density is its own, so a stop is a stop. A negative's read is amplified by the
    /// curve it prints through, whose slope at the anchor depends on the style, the grade and
    /// the stock's own curve, so the read that moves mid-grey by exactly the stated stops is
    /// solved on that curve rather than guessed from its nominal gamma. Lighter is less density.
    static func exposureShift(stops: Float, stock: FilmStock, style: DigitalReferenceStyle,
                              grade: Float) -> Float {
        guard stops != 0 else { return 0 }
        if stock.isReversal { return -stops * log10(2) }
        let curve = curve(for: style, stock: stock)
        let xMid = curve.logExposure(density: curve.dMin + anchorDensity)
        // Mid-grey's green output at a read shift, exactly as the kernel and output table place it.
        func output(_ shift: Float) -> Float {
            let density = curve.density(logExposure: xMid + shift) - curve.dMin
            return rgb(density: SIMD3(repeating: density), style: style, stock: stock,
                       grade: grade).y
        }
        let target = output(0) * exp2(stops)
        // Output falls as the read rises; bisect the read for the target.
        var low: Float = -3, high: Float = 3
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if output(mid) > target { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// Digital output has display primaries, not a second set of photographic paper dyes.
    /// `density` is each record's kernel-curve density above base. For `.referenceExposure` that
    /// is the reference curve's own density, carried to display black by black-point compensation
    /// of the curve's floor. For the graded styles the kernel curve is straight, so the density is
    /// the anchor plus the levelled relative log exposure, and the graded curve is applied here.
    /// A positive's density is its own, levelled, and is simply transmitted.
    static func rgb(density: SIMD3<Float>, style: DigitalReferenceStyle,
                    stock: FilmStock, grade: Float = referenceGrade) -> SIMD3<Float> {
        if stock.isReversal { return positiveRGB(density: density) }
        let referenceCurve = referenceCurve(for: stock)
        if style.usesGradedCurve {
            let val = (density - anchorDensity) / gradedReadPerVal + gradedAnchorVal
            let baseTarget = referenceBaseTarget(for: stock)
            func mixed(_ relative: Float, _ value: Float) -> Float {
                let highlight = gradedTransmittance(val: value, grade: grade)
                let anchor = referenceCurve.logExposure(density: referenceCurve.dMin + anchorDensity)
                let shadowRead = stretchShadows(relative, scale: baseTarget / gradedBaseRead)
                let shadowDensity = referenceCurve.density(logExposure: anchor + shadowRead)
                    - referenceCurve.dMin
                let floor = pow(10, -(referenceCurve.dMax - referenceCurve.dMin)) as Float
                let shadow = max((pow(10, -shadowDensity) - floor) / (1 - floor), 0)
                // C1 blend through mid-grey: the graded highlight shoulder over film-base blacks.
                let t = min(max((relative + 0.04) / 0.08, 0), 1)
                let blend = t * t * (3 - 2 * t)
                return highlight * (1 - blend) + shadow * blend
            }
            let relative = density - anchorDensity
            // Auto Levels' shadows fall along its log toe instead of the stretched reference
            // curve, joined to the graded highlights through mid-grey the same way.
            if style == .autoLevels {
                let toe = ScreenShadowToe.shared(for: stock)
                func logged(_ relative: Float, _ value: Float) -> Float {
                    let highlight = gradedTransmittance(val: value, grade: grade)
                    let shadow = toe.transmittance(relative: relative)
                    let t = min(max((relative + 0.04) / 0.08, 0), 1)
                    let blend = t * t * (3 - 2 * t)
                    return highlight * (1 - blend) + shadow * blend
                }
                return SIMD3(logged(relative.x, val.x), logged(relative.y, val.y),
                             logged(relative.z, val.z))
            }
            return SIMD3(mixed(relative.x, val.x), mixed(relative.y, val.y),
                         mixed(relative.z, val.z))
        }
        let floor = pow(10, -(referenceCurve.dMax - referenceCurve.dMin)) as Float
        let t = SIMD3(pow(10, -density.x), pow(10, -density.y), pow(10, -density.z))
        let c = (t - floor) / (1 - floor)
        return SIMD3(max(c.x, 0), max(c.y, 0), max(c.z, 0))
    }
}

/// Auto Levels' shadow half on the screen: a log curve in the stops of scene light under
/// mid-grey. Each stop down gives up a little less lightness than the one above it, so the
/// shadows keep their separation all the way down to where the negative stops recording, rather
/// than meeting black a few stops under grey, and black stays black. The output table is indexed
/// by the levelled read, so the toe reads it back through the stock's own curve, where every
/// screen negative is placed with its print grey on the film's grey, undoing the negative's toe
/// before laying its own.
struct ScreenShadowToe {
    /// The toe's slope at mid-grey, in L* per stop.
    static let greySlope: Float = 30
    /// The share of its base read past which a negative records no more shadow: the log curve
    /// would reach black there.
    static let recordedShare: Float = 0.9
    /// The lightness under which the toe finishes on the film's read instead of its stops,
    /// falling to black at the film base. The film packs its last stops into a sliver of read,
    /// so finished on stops the curve would reach black inside one cell of the print table and
    /// leave a corner there, a record clipping while the others carry on.
    static let finishLightness: Float = 6
    /// The share of its base read where the finish reaches black: a cell of the print table
    /// short of the base, so the base itself prints black.
    static let blackShare: Float = 0.92

    private static let stride: Float = 0.02
    private static let lowest: Float = -16
    /// The levelled read at each film stop from `lowest` up, which falls as the stops rise.
    private let reads: [Float]
    /// The film stop the print takes for mid-grey, where the levelled read is zero.
    private let anchorStops: Float
    /// Stops under mid-grey where the log curve would reach black, its width, and the L* it
    /// starts from.
    private let depth: Float
    private let width: Float
    private let grey: Float
    /// The finish: the levelled reads where it starts and where it reaches black, and the power
    /// it falls with, which matches the log curve's slope where they meet.
    private let finishRead: Float
    private let blackRead: Float
    private let finishPower: Float

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache = BoundedCache<UInt64, ScreenShadowToe>(limit: 16)

    static func shared(for stock: FilmStock) -> ScreenShadowToe {
        let key = SpectralRuntime.cacheIdentifier(for: stock, paper: .screen)
        lock.lock()
        if let found = cache.value(for: key) {
            lock.unlock()
            return found
        }
        lock.unlock()
        let toe = ScreenShadowToe(stock: stock)
        lock.lock()
        cache.insert(toe, for: key)
        lock.unlock()
        return toe
    }

    private init(stock: FilmStock) {
        let base = DigitalReferenceReceiver.baseRead(for: stock)
        let scale = DigitalReferenceReceiver.gradedBaseRead / base
        let shift = DigitalReferenceReceiver.retimeShift(
            for: stock, highlightStops: DigitalReferenceReceiver.printWhiteOverGrey)
        let count = Int((6 - Self.lowest) / Self.stride) + 1
        let reads = (0..<count).map {
            scale * DigitalReferenceReceiver.read(for: stock,
                                                  stops: Self.lowest + Float($0) * Self.stride)
                + shift
        }
        self.reads = reads
        anchorStops = Self.stops(relative: 0, in: reads)
        depth = anchorStops - Self.stops(relative: scale * Self.recordedShare * base + shift,
                                         in: reads)
        let y = DigitalReferenceReceiver.gradedTransmittance(
            val: DigitalReferenceReceiver.gradedAnchorVal)
        let grey = 116 * cbrt(y) - 16
        // The width that gives the toe `greySlope` at mid-grey.
        var low: Float = 1e-3, high: Float = 20
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if grey / (mid * log(1 + depth / mid)) > Self.greySlope { low = mid } else { high = mid }
        }
        let width = (low + high) / 2
        self.width = width
        self.grey = grey
        let span = log(1 + depth / width)
        let under = width * (exp((1 - Self.finishLightness / grey) * span) - 1)
        let stop = anchorStops - under
        func read(_ stop: Float) -> Float {
            let position = (stop - Self.lowest) / Self.stride
            let index = min(max(Int(position), 0), reads.count - 2)
            return reads[index] + (position - Float(index)) * (reads[index + 1] - reads[index])
        }
        finishRead = read(stop)
        blackRead = scale * Self.blackShare * base + shift
        let lightnessPerStop = grey / ((width + under) * span)
        let readPerStop = (read(stop - 0.01) - read(stop + 0.01)) / 0.02
        finishPower = max(lightnessPerStop / readPerStop * (blackRead - finishRead)
                            / Self.finishLightness, 1)
    }

    /// The film stop whose levelled read is `relative`, held at the ends of the table.
    private static func stops(relative: Float, in reads: [Float]) -> Float {
        guard relative < reads[0] else { return lowest }
        guard relative > reads[reads.count - 1] else {
            return lowest + Float(reads.count - 1) * stride
        }
        var low = 0, high = reads.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if reads[mid] > relative { low = mid } else { high = mid }
        }
        let span = reads[low] - reads[high]
        let fraction = span > 0 ? (reads[low] - relative) / span : 0
        return lowest + (Float(low) + fraction) * stride
    }

    /// Display-linear output for a levelled read on the shadow side of mid-grey.
    func transmittance(relative: Float) -> Float {
        let lightness: Float
        if relative >= finishRead {
            let toBlack = max(blackRead - relative, 0) / max(blackRead - finishRead, 1e-6)
            lightness = Self.finishLightness * pow(min(toBlack, 1), finishPower)
        } else {
            let under = max(anchorStops - Self.stops(relative: relative, in: reads), 0)
            lightness = grey * (1 - log(1 + under / width) / log(1 + depth / width))
        }
        return lightness > 8 ? pow((lightness + 16) / 116, 3) : lightness / (24389 / 27)
    }
}
