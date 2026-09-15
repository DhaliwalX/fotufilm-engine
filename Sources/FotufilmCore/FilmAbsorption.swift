import Foundation

extension SpectralRuntime {
    /// Convert total characteristic-record densities to a spectrum with an independent base:
    /// D(lambda) = Dmin(lambda) + sum((record - recordDmin) * dye(lambda)).
    /// A condenser's Callier coefficient scales the same complete diffuse spectrum that
    /// the historical path scales; retained silver remains a separate neutral contribution.
    static func filmDensityOffset(for stock: FilmStock, scale: Float = 1) -> [Float]? {
        guard let base = stock.spectralProfile.minimumDensity else { return nil }
        let dyes = stock.spectralProfile.imageDyeDensity
        let minimum = stock.curves.map(\.dMin)
        return base.indices.map { i in
            (base[i] - minimum[0] * dyes[0][i] - minimum[1] * dyes[1][i]
                - minimum[2] * dyes[2][i]) * scale
        }
    }

    static func transmissionRGB(density: [Float], stock: FilmStock,
                                flare: Float = 0, neutralDensity: Float = 0,
                                illuminant: [Float]? = nil) -> SIMD3<Float> {
        transmissionRGB(density: density, dyes: stock.spectralProfile.imageDyeDensity,
                        flare: flare, neutralDensity: neutralDensity, illuminant: illuminant,
                        densityOffset: filmDensityOffset(for: stock))
    }

    static func paperExposure(density: [Float], stock: FilmStock,
                              lamp: [Float], paperSensitivity: [[Float]],
                              neutralDensity: Float = 0, densityScale: Float = 1) -> SIMD3<Float> {
        paperExposure(density: density, dyes: stock.spectralProfile.imageDyeDensity,
                      lamp: lamp, paperSensitivity: paperSensitivity, neutralDensity: neutralDensity,
                      densityOffset: filmDensityOffset(for: stock, scale: densityScale))
    }
}
