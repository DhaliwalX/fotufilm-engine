import Foundation

/// How a reading fitted on the scan model (`NegativeScanModel.weights`) balances a frame. The fit
/// reads the film's own densities, so a neutral lit as the film expects already lies on the
/// film's grey scale. What is left is the scene's light and the film's own drift, which a printer
/// takes out with filtration: the same density added to a record at every tone.
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
    /// channels at `separation` (`NegativeScanModel.weights`): a neutral offset onto the film's
    /// grey scale, and the highlights' exposure from the densest end. A measured `roll` also
    /// makes red and blue as steep against green as the film's own (`contrast`), whichever
    /// neutral the frame is balanced on.
    public static func balance(stock: FilmStock, setup: NegativeScanSetup, separation: Float,
                               mode: BalanceMode, tones: Tones,
                               roll: RollBalance? = nil) -> Balance {
        let weights = NegativeScanModel(stock: stock, setup: setup).weights(separation: separation)
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
        if let slopes = roll?.slopes, slopes.count == 2 {
            balance.gains = contrast(stock: stock, weights: weights,
                                     slopes: SIMD2(slopes[0], slopes[1]))
        }
        // The roll's neutral when the frame is on its roll; else one picked on the frame; else
        // its densest end. One too thin to tell a colour from is passed over.
        let neutrals = [mode == .roll ? roll?.neutral(green: dense?.y) : nil,
                        readable(tones.picked), dense]
        if let neutral = neutrals.lazy.compactMap({ $0 }).first(
            where: { NegativeScanCrosstalk.apply(weights, $0).y > 0.05 }) {
            balance.offset = offset(stock: stock, weights: weights, gains: balance.gains,
                                    neutral: neutral)
        }
        return balance
    }

    /// The density to add to red and blue so `neutral`, the scan channels' densities of a grey
    /// over the clear film, reads as the film's grey of its green: the exposure its green record
    /// reads, and the densities the film's other records give that exposure. Held inside
    /// `offsetRange`; none on a black-and-white film.
    static func offset(stock: FilmStock, weights: [SIMD3<Float>], gains: SIMD3<Float>,
                       neutral: SIMD3<Float>) -> SIMD3<Float> {
        guard !stock.isMonochrome else { return .zero }
        let read = NegativeScanCrosstalk.apply(weights, neutral) * gains
        let exposure = stock.curves[1].logExposure(density: stock.curves[1].dMin + read.y)
        var offset = SIMD3<Float>.zero
        for record in [0, 2] {
            let expected = stock.curves[record].density(logExposure: exposure)
                - stock.curves[record].dMin
            offset[record] = min(max(expected - read[record], offsetRange.lowerBound),
                                 offsetRange.upperBound)
        }
        return offset
    }

    private static func readable(_ density: SIMD3<Float>?) -> SIMD3<Float>? {
        density.flatMap { d in (0..<3).allSatisfy({ d[$0].isFinite }) ? d : nil }
    }
}
