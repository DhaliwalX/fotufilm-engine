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
    /// Per-frame levels on the graded curve: the frame's brightest content sets white and the film
    /// base sets black, the way a minilab scanner normalises each frame. Resolves bright windows
    /// and skies by re-exposing the rest of the frame around them. On a positive, the frame's
    /// brightest content sets white and nothing else moves.
    case autoLevels = "auto-levels"

    public static let `default`: DigitalReferenceStyle = .autoLevels

    public var id: String { rawValue }

    /// Affine receiver placement for hosts that prepare their own packed configurations.
    /// The scene measurement is in stops over mid-grey, after input exposure.
    public func receiverLevels(for stock: FilmStock, sceneHighlightStops: Float? = nil)
        -> (scale: Float, shift: Float) {
        DigitalReferenceReceiver.levels(for: stock, style: self,
                                       sceneHighlightStops: sceneHighlightStops)
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
            return "The frame's brightest content sets white and a negative's film base sets black."
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

    /// A graded paper's H&D curve, per channel, from the unit stretch to display-linear
    /// transmittance. A straight line of slope `k` through the pivot, a slight midtone S, a soft
    /// softplus shoulder into paper white and a firmer softplus toe into paper black at 2.3 D,
    /// then black-point compensation so that paper black is display black. The pivot is solved so
    /// the anchor prints 18% after compensation.
    static func gradedTransmittance(val: Float) -> Float {
        func softplus(_ x: Float) -> Float { x > 0 ? x + log1p(exp(-x)) : log1p(exp(x)) }
        let k: Float = 2.894, pivot: Float = 0.2197, vStar: Float = 0.6955
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
    /// styles, in the paper mid-point and contrast slots: `read' = scale * read + shift`. The film
    /// base always lands on `gradedBaseRead`. `.gradedPrint` holds the anchor and scales only for
    /// the base; `.autoLevels` also places the frame's metered highlight on `gradedWhiteRead`,
    /// falling back to the fixed graded print when no measurement is available.
    ///
    /// A transparent positive has no curve to grade, only a gain: its levels are a shift alone,
    /// `positiveLevels`. An integral print is already a print and takes none.
    static func levels(for stock: FilmStock, style: DigitalReferenceStyle,
                       sceneHighlightStops: Float?) -> (scale: Float, shift: Float) {
        guard style.usesGradedCurve, !stock.isReflectionPrint else { return (1, 0) }
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
            guard let measured = sceneHighlightStops, measured.isFinite else {
                return (gradedBaseRead / base, 0)
            }
            let stops = min(max(measured, 0.5), 12)
            let high = read(for: stock, stops: stops)
            // Bounded so a flat frame is not stretched without limit; a metered highlight
            // within half a stop of mid-grey is treated as no highlight at all.
            let scale = min(max((gradedBaseRead - gradedWhiteRead) / max(base - high, 0.1),
                                0.5), 2.0)
            return (scale, gradedBaseRead - scale * base)
        }
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

    /// Digital output has display primaries, not a second set of photographic paper dyes.
    /// `density` is each record's kernel-curve density above base. For `.referenceExposure` that
    /// is the reference curve's own density, carried to display black by black-point compensation
    /// of the curve's floor. For the graded styles the kernel curve is straight, so the density is
    /// the anchor plus the levelled relative log exposure, and the graded curve is applied here.
    /// A positive's density is its own, levelled, and is simply transmitted.
    static func rgb(density: SIMD3<Float>, style: DigitalReferenceStyle,
                    stock: FilmStock) -> SIMD3<Float> {
        if stock.isReversal { return positiveRGB(density: density) }
        let referenceCurve = referenceCurve(for: stock)
        if style.usesGradedCurve {
            let val = (density - anchorDensity) / gradedReadPerVal + gradedAnchorVal
            let baseTarget = referenceBaseTarget(for: stock)
            func mixed(_ relative: Float, _ value: Float) -> Float {
                let highlight = gradedTransmittance(val: value)
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
            return SIMD3(mixed(relative.x, val.x), mixed(relative.y, val.y),
                         mixed(relative.z, val.z))
        }
        let floor = pow(10, -(referenceCurve.dMax - referenceCurve.dMin)) as Float
        let t = SIMD3(pow(10, -density.x), pow(10, -density.y), pow(10, -density.z))
        let c = (t - floor) / (1 - floor)
        return SIMD3(max(c.x, 0), max(c.y, 0), max(c.z, 0))
    }
}
