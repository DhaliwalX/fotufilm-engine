import Foundation

enum Densitometry {

    /// ISO Status A log10 spectral products at 10 nm, peak 5.000: Hunt, *The Reproduction of
    /// Colour*, 6th ed., Table 14.1, columns P_AR, P_AG, P_AB.
    private static let statusATenNM: [[(nm: Float, logProduct: Float)]] = [
        [(600, 2.568), (610, 4.638), (620, 5.000), (630, 4.871), (640, 4.604),
         (650, 4.286), (660, 3.900), (670, 3.551), (680, 3.165), (690, 2.776),
         (700, 2.383), (710, 1.970), (720, 1.551), (730, 1.141), (740, 0.741),
         (750, 0.341)],
        [(500, 1.650), (510, 3.822), (520, 4.782), (530, 5.000), (540, 4.906),
         (550, 4.644), (560, 4.221), (570, 3.609), (580, 2.766), (590, 1.579)],
        [(420, 3.602), (430, 4.819), (440, 5.000), (450, 4.912), (460, 4.620),
         (470, 4.040), (480, 2.989), (490, 1.566), (500, 0.165)],
    ]

    /// The three bands on the engine's grid, carried from 10 nm linearly and zero outside.
    static let statusA: [[Float]] = statusATenNM.map { band in
        SpectralGrid.wavelengths.map { wavelength -> Float in
            guard let first = band.first, let last = band.last,
                  wavelength >= first.nm, wavelength <= last.nm else { return 0 }
            for i in 0..<(band.count - 1) where wavelength <= band[i + 1].nm {
                let low = band[i], high = band[i + 1]
                let t = (wavelength - low.nm) / (high.nm - low.nm)
                let lowValue = pow(Float(10), low.logProduct - 5)
                let highValue = pow(Float(10), high.logProduct - 5)
                return lowValue + t * (highValue - lowValue)
            }
            return pow(Float(10), last.logProduct - 5)
        }
    }

    private static let statusAIntegral: [Float] = statusA.map { $0.reduce(0, +) }

    static func statusADensity(transmittance: [Float]) -> SIMD3<Float> {
        var read = SIMD3<Float>(repeating: 0)
        for channel in 0..<3 {
            var sum: Float = 0
            let band = statusA[channel]
            for i in 0..<SpectralGrid.count { sum += band[i] * transmittance[i] }
            read[channel] = -log10(max(sum / statusAIntegral[channel], 1e-12))
        }
        return read
    }

    static func transmittance(amounts: SIMD3<Float>, dyes: [[Float]]) -> [Float] {
        var result = [Float](repeating: 0, count: SpectralGrid.count)
        for i in 0..<SpectralGrid.count {
            let density = amounts.x * dyes[0][i] + amounts.y * dyes[1][i]
                + amounts.z * dyes[2][i]
            result[i] = pow(10, -density)
        }
        return result
    }

    static func statusADensity(amounts: SIMD3<Float>, dyes: [[Float]]) -> SIMD3<Float> {
        statusADensity(transmittance: transmittance(amounts: amounts, dyes: dyes))
    }
}

/// Carries a sheet's Status A integral densities back to the dye amounts behind them, so a
/// spectrum is composed from dye and not from densitometer readings. Amounts stay non-negative:
/// each record riding its own curve can ask for triples no real dye set can make.
struct PrintDyeUnmix: Sendable {
    let dyes: [[Float]]
    private let dye: [SIMD3<Float>]
    private let band: [SIMD3<Float>]
    private let solver: StatusADyeUnmix

    /// log2(10), for 10^-d as exp2 in the table-build inner loop.
    private static let log2Of10: Float = 3.321928

    init(dyes: [[Float]]) {
        self.dyes = dyes
        self.dye = (0..<SpectralGrid.count).map {
            SIMD3(dyes[0][$0], dyes[1][$0], dyes[2][$0])
        }
        let integrals = Densitometry.statusA.map { $0.reduce(0, +) }
        self.band = (0..<SpectralGrid.count).map { i in
            SIMD3(Densitometry.statusA[0][i] / integrals[0],
                  Densitometry.statusA[1][i] / integrals[1],
                  Densitometry.statusA[2][i] / integrals[2])
        }
        self.solver = StatusADyeUnmix(dyes: dyes)
    }

    func read(_ amounts: SIMD3<Float>) -> SIMD3<Float> {
        var sum = SIMD3<Float>(repeating: 0)
        for i in 0..<dye.count {
            let density = amounts.x * dye[i].x + amounts.y * dye[i].y
                + amounts.z * dye[i].z
            sum += band[i] * exp2(-density * Self.log2Of10)
        }
        return SIMD3(-log10(max(sum.x, 1e-12)), -log10(max(sum.y, 1e-12)),
                     -log10(max(sum.z, 1e-12)))
    }

    func amounts(forStatusA target: SIMD3<Float>) -> SIMD3<Float> {
        // Active-set nonnegative Gauss-Newton (`StatusADyeUnmix`): zero density above base unmixes
        // to exact zero so paper white reaches display white, while unreachable Status A triples
        // project orthogonally onto the nonnegative dye gamut boundary without cross-band twist.
        solver.amounts(forStatusA: target)
    }
}
