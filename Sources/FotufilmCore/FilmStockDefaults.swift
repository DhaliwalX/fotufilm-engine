enum FilmStockDefaults {
    // Fitted per record against the four published Vision3 granularity-against-density
    // curves (50D, 250D, 200T, 500T), the amplitude of each sheet free. A stock that states
    // its own `grainDensityProfile` overrides this.
    static let grainDensityRecords: [[Float]] = [
        [20.0, 0.3373, 0.2629, 0.8187, 1.1811, 0.3212],
        [20.0, 0.3583, 0.3183, 1.6514, 1.4856, 0.3631],
        [20.0, 0.1069, 0.5457, 4.2644, 1.38, 0.3446],
    ]
    static let grainDensityProfile = GrainDensityProfile(records: grainDensityRecords)
}
