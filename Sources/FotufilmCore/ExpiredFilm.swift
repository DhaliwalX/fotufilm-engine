import Foundation

/// Applies room-temperature ageing as speed loss, base fog, and increased granularity.
/// The model uses one stop of speed loss per decade with layer-specific weights; fog is
/// proportional to speed loss, and grain amplification is proportional to mean fog.
extension FilmStock {

    /// The lab rule: one stop per decade at room temperature.
    static let expiredSpeedLossStopsPerDecade: Float = 1

    /// How each layer weathers, in the engine's R, G, B record order. The
    /// blue-sensitive layer ages fastest, the red-sensitive slowest.
    static let expiredLayerWeights: [Float] = [0.7, 1.0, 1.3]

    /// Fog density a layer gains per stop of speed it loses — one mechanism, one
    /// proportionality. At the decade mark this puts +0.10 D on the blue layer's
    /// base, inside the range decade-old C-41 measures.
    static let expiredFogPerStopLost: Float = 0.08

    /// Additional grain amplitude per unit of mean fog. Density-dependent granularity is handled
    /// separately by `grainFogDensity`.
    static let expiredGrainPerFog: Float = 1

    /// The stock as `years` past its process-by date leaves it. 0 is `self`, exactly.
    public func expired(years: Float) -> FilmStock {
        guard years > 0 else { return self }
        var aged = self
        let decades = years / 10
        let perStop = Float(log10(2.0))
        var fogTotal: Float = 0
        for layer in 0..<3 {
            let lostStops = FilmStock.expiredSpeedLossStopsPerDecade * decades
                * FilmStock.expiredLayerWeights[layer]
            let fog = FilmStock.expiredFogPerStopLost * lostStops
            fogTotal += fog
            // Speed loss is a pure translation of the curve up the exposure axis:
            // the emulsion needs that much more light for the same density.
            aged.curves[layer].toe += lostStops * perStop
            aged.curves[layer].shoulder += lostStops * perStop
            aged.curves[layer].dMin += fog
            aged.curves[layer].sampled = curves[layer].sampled?.shifted(
                logExposure: lostStops * perStop, density: fog)
        }
        aged.grainStrength *= 1 + FilmStock.expiredGrainPerFog * (fogTotal / 3)
        // The fog the emulsion gained is developed density, so the density law reads granularity
        // off it directly — this is what makes an aged negative grainy in its thin shadows,
        // where a fresh one is nearly clean.
        aged.grainFogDensity += fogTotal / 3
        return aged
    }
}
