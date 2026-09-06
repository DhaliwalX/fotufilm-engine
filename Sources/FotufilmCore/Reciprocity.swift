import Foundation

/// Reciprocity failure shifts each layer's characteristic curve for long exposures. Corrections
/// follow stock data as `rate × log10(time / threshold)` and stop at the last stated exposure.
/// Stocks without reciprocity data remain unchanged.

/// Where a particular emulsion leaves the law, as its datasheet says.
public struct ReciprocityFailure: Codable, Sendable, Equatable {
    /// Exposures at or under this many seconds are inside the law.
    public var thresholdSeconds: Float
    /// Stops lost per decade past the threshold. Zero represents a stated no-correction interval.
    public var lostStopsPerDecade: Float
    /// Last exposure covered by the source data. The correction is held constant beyond it. Nil
    /// represents an open-ended published rule.
    public var statedThroughSeconds: Float?
    /// Per-record rate multipliers in R, G, B order with mean 1. Nil uses the default colour
    /// ordering; monochrome uses 1.
    public var layerWeights: [Float]?

    public init(thresholdSeconds: Float, lostStopsPerDecade: Float,
                statedThroughSeconds: Float? = nil,
                layerWeights: [Float]? = nil) {
        self.thresholdSeconds = thresholdSeconds
        self.lostStopsPerDecade = lostStopsPerDecade
        self.statedThroughSeconds = statedThroughSeconds
        self.layerWeights = layerWeights
    }
}

extension FilmStock {

    /// Relative failure rate of the R, G, B records for a stated colour table
    /// without its own weights: green holds, red goes first.
    static let reciprocityLayerWeights: [Float] = [1.2, 0.8, 1.0]

    /// Applies the stock's stated reciprocity correction for an exposure duration. Returns the
    /// stock unchanged when data is absent or the duration is within the stated threshold.
    public func reciprocity(shutterSeconds seconds: Float) -> FilmStock {
        guard let stated = reciprocityFailure else { return self }
        guard seconds > stated.thresholdSeconds,
              stated.lostStopsPerDecade > 0 else { return self }
        var met = self
        // The row ends where the sheet ends: past the last stated column the
        // correction holds its final value rather than growing along a line the
        // sheet never drew.
        let covered = min(seconds, stated.statedThroughSeconds ?? seconds)
        let decades = log10(covered / stated.thresholdSeconds)
        let perStop = Float(log10(2.0))
        for layer in 0..<3 {
            // A stated rate is the sheet's own correction row: a monochrome
            // record carries it whole, and a colour stock spreads it about a
            // mean of 1 so the row stays what the photographer read.
            let weight = stated.layerWeights?[layer]
                ?? (isMonochrome ? 1 : FilmStock.reciprocityLayerWeights[layer])
            let lost = stated.lostStopsPerDecade * decades * weight * perStop
            met.curves[layer].toe += lost
            met.curves[layer].shoulder += lost
            met.curves[layer].sampled = curves[layer].sampled?.shifted(logExposure: lost)
        }
        return met
    }
}
