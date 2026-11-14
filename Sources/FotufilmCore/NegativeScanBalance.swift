import Foundation

/// How a reading fitted on the scan model (`NegativeScanModel.weights`) balances a frame. Two
/// things move a neutral off the film's grey scale. One is how steep each record reads, which
/// the film's age and development and the scan's own light and camera all set, and which the
/// model knows only as well as it knows them: a white lamp's red end alone moves red's by half.
/// The other is the scene's light and the film's drift, which a printer takes out with
/// filtration: the same exposure added to a record at every tone, moving it along the film's
/// own curve. One neutral cannot tell the two apart, and neither can one frame: its tonal steps
/// follow its picture, a sunset's reading red twice as steep as a meadow's on the same roll. A
/// roll that measured its tonal steps says the first (`contrast`); a frame without one keeps
/// the model's. The neutral then sets the exposure along each record's characteristic curve.
extension ApproximateNegativeScan {
    /// What a frame is balanced on.
    public enum BalanceMode: String, Codable, CaseIterable, Sendable {
        /// The frame's own neutral: one picked on it, else its average, else its densest end.
        case frame
        /// The neutral the roll's frames share, the same for each of them.
        case roll
        /// Nothing: the film as the scan model reads it.
        case none
    }

    /// What a framed picture's tones give its reading, each the scan channels' densities over
    /// the clear film.
    public struct Tones: Equatable, Sendable {
        /// The densest end, the highlights (`denseEnd(border:preview:)`), which times the print
        /// and stands for the neutral of a frame that has no average.
        public var denseEnd: SIMD3<Float>?
        /// A neutral picked on the frame, which takes the average's place.
        public var picked: SIMD3<Float>?
        /// The average (`average(border:preview:)`), which stands for the frame's neutral.
        public var average: SIMD3<Float>?
        /// The mid-tones (`midtone(border:preview:)`), which keep a small highlight far over
        /// them from timing the print (`timedHighlight`). Nil times it on the densest end.
        public var midtone: SIMD3<Float>?

        public init(denseEnd: SIMD3<Float>? = nil, picked: SIMD3<Float>? = nil,
                    average: SIMD3<Float>? = nil, midtone: SIMD3<Float>? = nil) {
            self.denseEnd = denseEnd
            self.picked = picked
            self.average = average
            self.midtone = midtone
        }
    }

    /// How far a reading's density strength goes: half to half again of what the scan reads.
    public static let strengthRange: ClosedRange<Float> = 0.5...1.5

    /// The balance of a frame read by the scan model for `setup`, its weights across the
    /// channels at `separation` (`NegativeScanModel.weights`): a neutral moved onto the film's
    /// grey scale along each record's characteristic curve (`exposure`), and the print's timing
    /// from the densest end and the mid-tones (`timedHighlight`). A `roll` that measured its
    /// tonal steps makes red and blue as steep against green as the film's (`gains`) before
    /// the neutral shifts each record's exposure.
    ///
    /// `strength` is how strong the scan's densities read: every density over the clear film is
    /// multiplied by it before the film is read, the three records alike, so the picture has
    /// that much more or less contrast and its colour balance and timing follow. A setup the
    /// model knows only roughly, an unmeasured camera or a light of another spectrum, reads
    /// the film a little flat or hard at one, and no frame says by how much.
    public static func balance(stock: FilmStock, setup: NegativeScanSetup, separation: Float,
                               mode: BalanceMode, tones: Tones,
                               roll: RollBalance? = nil, strength: Float = 1) -> Balance {
        let model = NegativeScanModel(stock: stock, setup: setup)
        let scale = strength.isFinite
            ? min(max(strength, strengthRange.lowerBound), strengthRange.upperBound) : 1
        let weights = setup.weights(model.weights(separation: separation),
                                    green: model.weights(separation: 0)[1].y).map { $0 * scale }
        var balance = Balance(gains: .one, highlightStops: nil, weights: weights)
        let dense = readable(tones.denseEnd)
        if let dense {
            let green = NegativeScanCrosstalk.apply(weights, dense).y
            if green > 0.05 {
                let curve = stock.curves[1]
                let stops = { (density: Float) in
                    curve.logExposure(density: curve.dMin + density) / log10(2)
                }
                balance.highlightStops = stops(green)
                if let midtone = readable(tones.midtone) {
                    balance.highlightStops = timedHighlight(
                        stops(green), midtone: stops(NegativeScanCrosstalk.apply(weights, midtone).y))
                }
            }
        }
        guard mode != .none else { return balance }
        if let slopes = roll?.slopes, slopes.count == 2 {
            balance.gains = contrast(stock: stock, weights: weights,
                                     slopes: SIMD2(slopes[0], slopes[1]))
        }
        // The roll's neutral when the frame is on its roll; else one picked on the frame; else
        // its average; else its densest end. One too thin to tell a colour from is passed over.
        let neutrals = [mode == .roll ? roll?.neutral(green: dense?.y) : nil,
                        readable(tones.picked), readable(tones.average), dense]
        if let neutral = neutrals.lazy.compactMap({ $0 }).first(
            where: { NegativeScanCrosstalk.apply(weights, $0).y > 0.05 }) {
            balance.exposure = exposure(stock: stock, weights: weights, gains: balance.gains,
                                        neutral: neutral)
        }
        return balance
    }

    /// What red's and blue's densities over the clear film are multiplied by so `neutral`, the
    /// scan channels' densities of a grey over the clear film, reads as the film's grey of its
    /// green: the densities the film's other records give the exposure its green record reads,
    /// over the densities they read. Held inside `gainRange`; one for a record the neutral reads
    /// too thin to tell, or on a black-and-white film.
    static func gains(stock: FilmStock, weights: [SIMD3<Float>],
                      neutral: SIMD3<Float>) -> SIMD3<Float> {
        guard !stock.isMonochrome else { return .one }
        let read = NegativeScanCrosstalk.apply(weights, neutral)
        let green = stock.curves[1].logExposure(density: stock.curves[1].dMin + read.y)
        var gains = SIMD3<Float>.one
        for record in [0, 2] where read[record] > 0.05 {
            let expected = stock.curves[record].density(logExposure: green)
                - stock.curves[record].dMin
            gains[record] = min(max(expected / read[record], gainRange.lowerBound),
                                gainRange.upperBound)
        }
        return gains
    }

    /// The log exposure to add to red and blue so `neutral`, the scan channels' densities of a
    /// grey over the clear film, reads as the film's grey of its green: the exposure its green
    /// record reads, less the exposure each other record reads. It moves a record's straight
    /// line by no more density than the neutral is off its grey: a neutral on the shoulder,
    /// where the curve is flat, would otherwise ask for an exposure several times that, and
    /// tint every tone below it. Held inside `exposureRange`; none for a record the neutral
    /// reads too thin to place on its curve, or on a black-and-white film.
    static func exposure(stock: FilmStock, weights: [SIMD3<Float>], gains: SIMD3<Float>,
                         neutral: SIMD3<Float>) -> SIMD3<Float> {
        guard !stock.isMonochrome else { return .zero }
        let read = NegativeScanCrosstalk.apply(weights, neutral) * gains
        let green = stock.curves[1].logExposure(density: stock.curves[1].dMin + read.y)
        let slopes = greySlopes(stock)
        var exposure = SIMD3<Float>.zero
        for record in [0, 2] where read[record] > 0.05 {
            let curve = stock.curves[record]
            var moved = green - curve.logExposure(density: curve.dMin + read[record])
            if let slopes {
                // On the straight line this is the exposure itself; past the knee it is less.
                let off = curve.density(logExposure: green) - curve.dMin - read[record]
                let limit = abs(off) / slopes[record]
                moved = min(max(moved, -limit), limit)
            }
            exposure[record] = min(max(moved, exposureRange.lowerBound),
                                   exposureRange.upperBound)
        }
        return exposure
    }

    private static func readable(_ density: SIMD3<Float>?) -> SIMD3<Float>? {
        density.flatMap { d in (0..<3).allSatisfy({ d[$0].isFinite }) ? d : nil }
    }
}
