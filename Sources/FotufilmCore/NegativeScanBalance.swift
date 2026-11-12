import Foundation

/// How a reading fitted on the scan model (`NegativeScanModel.weights`) balances a frame. Two
/// things move a neutral off the film's grey scale. One is how steep each record reads, which
/// the film's age and development and the scan's own light and camera all set, and which the
/// model knows only as well as it knows them: a white lamp's red end alone moves red's by half.
/// The other is the scene's light and the film's drift, which a printer takes out with
/// filtration: the same exposure added to a record at every tone, moving it along the film's
/// own curve. One neutral cannot tell the two apart. A roll that measured its tonal steps says
/// the first (`contrast`), and the neutral then sets the exposure. Without one, the neutral
/// sets each record's gain, which holds the greys between the clear film and the neutral
/// however steep the records read.
extension ApproximateNegativeScan {
    /// What a frame is balanced on.
    public enum BalanceMode: String, Codable, CaseIterable, Sendable {
        /// The frame's own neutral: one picked on it, else its densest end.
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
        /// and stands for the frame's neutral.
        public var denseEnd: SIMD3<Float>?
        /// A neutral picked on the frame, which takes the densest end's place.
        public var picked: SIMD3<Float>?

        public init(denseEnd: SIMD3<Float>? = nil, picked: SIMD3<Float>? = nil) {
            self.denseEnd = denseEnd
            self.picked = picked
        }
    }

    /// The balance of a frame read by the scan model for `setup`, its weights across the
    /// channels at `separation` (`NegativeScanModel.weights`): a neutral moved onto the film's
    /// grey scale, and the highlights' exposure from the densest end. A `roll` that measured its
    /// tonal steps makes red and blue as steep against green as the film's own (`contrast`),
    /// and the neutral then moves them by an exposure; without one the neutral scales them.
    public static func balance(stock: FilmStock, setup: NegativeScanSetup, separation: Float,
                               mode: BalanceMode, tones: Tones,
                               roll: RollBalance? = nil) -> Balance {
        let model = NegativeScanModel(stock: stock, setup: setup)
        let weights = setup.weights(model.weights(separation: separation),
                                    green: model.weights(separation: 0)[1].y)
        var balance = Balance(gains: .one, highlightStops: nil, weights: weights)
        let dense = readable(tones.denseEnd)
        if let dense {
            let green = NegativeScanCrosstalk.apply(weights, dense).y
            if green > 0.05 {
                balance.highlightStops = stock.curves[1]
                    .logExposure(density: stock.curves[1].dMin + green) / log10(2)
            }
        }
        guard mode != .none else { return balance }
        var steepened = false
        if let slopes = roll?.slopes, slopes.count == 2 {
            balance.gains = contrast(stock: stock, weights: weights,
                                     slopes: SIMD2(slopes[0], slopes[1]))
            steepened = true
        }
        // The roll's neutral when the frame is on its roll; else one picked on the frame; else
        // its densest end. One too thin to tell a colour from is passed over.
        let neutrals = [mode == .roll ? roll?.neutral(green: dense?.y) : nil,
                        readable(tones.picked), dense]
        if let neutral = neutrals.lazy.compactMap({ $0 }).first(
            where: { NegativeScanCrosstalk.apply(weights, $0).y > 0.05 }) {
            if steepened {
                balance.exposure = exposure(stock: stock, weights: weights, gains: balance.gains,
                                            neutral: neutral)
            } else {
                balance.gains = gains(stock: stock, weights: weights, neutral: neutral)
            }
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
    /// record reads, less the exposure each other record reads. Held inside `exposureRange`;
    /// none for a record the neutral reads too thin to place on its curve, or on a
    /// black-and-white film.
    static func exposure(stock: FilmStock, weights: [SIMD3<Float>], gains: SIMD3<Float>,
                         neutral: SIMD3<Float>) -> SIMD3<Float> {
        guard !stock.isMonochrome else { return .zero }
        let read = NegativeScanCrosstalk.apply(weights, neutral) * gains
        let green = stock.curves[1].logExposure(density: stock.curves[1].dMin + read.y)
        var exposure = SIMD3<Float>.zero
        for record in [0, 2] where read[record] > 0.05 {
            let own = stock.curves[record]
                .logExposure(density: stock.curves[record].dMin + read[record])
            exposure[record] = min(max(green - own, exposureRange.lowerBound),
                                   exposureRange.upperBound)
        }
        return exposure
    }

    private static func readable(_ density: SIMD3<Float>?) -> SIMD3<Float>? {
        density.flatMap { d in (0..<3).allSatisfy({ d[$0].isFinite }) ? d : nil }
    }
}
