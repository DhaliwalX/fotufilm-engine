enum FilmStockDefaults {
    // Fitted against the Vision3 family's published granularity-against-density curves.
    // A stock that states its own `grainDensityProfile` overrides this.
    static let grainDensityProfile: [Float] = [5.1682, 0.117436, 0.421188]
}
