import Foundation

/// Undoes the crosstalk between a scan's channels and a colour negative's dyes. A camera or
/// scanner channel is broader than the dye it is read for, so it also sees some of the other two:
/// a red channel reads mostly cyan dye and a little magenta and yellow. Read one channel per
/// record, the records share part of each other's density and the print's colour is muddied.
///
/// Each channel's density of each dye, `A[channel][dye]`, is that dye's spectral density weighted
/// by the channel's sensitivity under the scan's light (`Light`), and `A⁻¹` reads dye density back
/// from the channels' densities. Each of its rows is then scaled so the frame's own grey reads as
/// it did: the densest end, which the frame's balance takes as a neutral highlight, keeps its
/// densities, and with it the greys of the film, which lie along it from the clear base. Scaling
/// a row leaves what it takes out of the other dyes, so colours still separate. `strength` blends
/// from one channel per record (0) to the full correction (1).
public enum NegativeScanCrosstalk {
    public static let range: ClosedRange<Float> = 0...1

    /// The light a scan was made under, which sets how broad its channels are.
    public enum Light: String, Codable, CaseIterable, Sendable {
        /// A camera or scanner under white light: the scan's linear Rec. 2020 channels see the
        /// spectrum as the Rec. 2020 primaries' colour-matching functions do, through a flat lamp.
        case white
        /// One exposure under each of a red, green and blue LED, merged (`TrichromaticRoll`): each
        /// channel sees its own LED's narrow band, peaks 625, 522 and 455 nm.
        case rgb
    }

    /// How far a reading undoes crosstalk, and the light the scan was made under.
    public struct Correction: Equatable, Sendable {
        public var strength: Float
        public var light: Light

        public init(strength: Float = 0, light: Light = .white) {
            self.strength = strength
            self.light = light
        }

        public static let none = Correction()

        public var isValid: Bool { strength.isFinite && range.contains(strength) }
    }

    /// What each film record reads from the scan: rows are records, columns the scan's red,
    /// green and blue densities over the clear film. `neutral` is the frame's densest end over the
    /// clear film, which keeps its densities; nil keeps equal densities. A monochrome film reads
    /// green alone.
    public static func weights(for stock: FilmStock, correction: Correction,
                               neutral: SIMD3<Float>?) -> [SIMD3<Float>] {
        if stock.isMonochrome { return Array(repeating: SIMD3(0, 1, 0), count: 3) }
        return weights(dyes: stock.spectralProfile.imageDyeDensity, correction: correction,
                       neutral: neutral)
    }

    /// The weights for a scan read without a film (`PlainNegativeScan`): the dyes of a typical
    /// colour negative.
    public static func plainWeights(correction: Correction, neutral: SIMD3<Float>?) -> [SIMD3<Float>] {
        weights(dyes: plainDyes, correction: correction, neutral: neutral)
    }

    /// Rows `strength` of the way from the identity to `A⁻¹` for `dyes`, each row scaled to keep
    /// `neutral`. The identity where the dyes cannot be told apart.
    static func weights(dyes: [[Float]], correction: Correction,
                        neutral: SIMD3<Float>?) -> [SIMD3<Float>] {
        let identity = [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        let strength = correction.strength.isFinite
            ? min(max(correction.strength, range.lowerBound), range.upperBound) : 0
        guard strength > 0, let unmix = invert(channelDensities(dyes: dyes, light: correction.light))
        else { return identity }
        let full = held(unmix, neutral: neutral)
        return (0..<3).map { identity[$0] + strength * (full[$0] - identity[$0]) }
    }

    /// `rows` each scaled so `neutral` reads as itself, or to sum to one, keeping equal densities,
    /// where the frame gives no neutral to keep or a row would have to scale by more than two.
    static func held(_ rows: [SIMD3<Float>], neutral: SIMD3<Float>?) -> [SIMD3<Float>] {
        func scales(_ target: SIMD3<Float>) -> [Float]? {
            let scales = (0..<3).map { target[$0] / (rows[$0] * target).sum() }
            return scales.allSatisfy({ $0.isFinite && (0.5...2).contains($0) }) ? scales : nil
        }
        let readable = neutral.flatMap { n in
            (0..<3).allSatisfy({ n[$0].isFinite && n[$0] > 0.05 }) ? n : nil
        }
        guard let scale = readable.flatMap(scales) ?? scales(.one) else { return rows }
        return (0..<3).map { rows[$0] * scale[$0] }
    }

    /// `A`, rows the scan's channels and columns the dyes: each channel's density per unit of each
    /// dye under `light`, linearised about clear film. A neutral transmits every wavelength alike,
    /// so this is the same about any neutral.
    static func channelDensities(dyes: [[Float]], light: Light) -> [SIMD3<Float>] {
        let sensitivity = sensitivities(light)
        return (0..<3).map { channel in
            var row = SIMD3<Float>.zero
            var total: Float = 0
            for i in 0..<SpectralGrid.count {
                let weight = sensitivity[i][channel]
                total += weight
                row += weight * SIMD3(dyes[0][i], dyes[1][i], dyes[2][i])
            }
            return row / total
        }
    }

    static func sensitivities(_ light: Light) -> [SIMD3<Float>] {
        light == .white ? whiteSensitivities : rgbSensitivities
    }

    /// The Rec. 2020 channels' spectral sensitivities, per grid wavelength.
    static let whiteSensitivities: [SIMD3<Float>] = (0..<SpectralGrid.count).map { i in
        SpectralGrid.linearRec2020(fromXYZ: SIMD3(SpectralGrid.xBar[i], SpectralGrid.yBar[i],
                                                  SpectralGrid.zBar[i]))
            * SpectralGrid.equalEnergy[i]
    }

    /// Red, green and blue LEDs (a SmallRig RM120's, measured on a scanning camera): Gaussian
    /// bands at their peaks and full widths at half maximum, in nm.
    static let rgbSensitivities: [SIMD3<Float>] = {
        let bands: [(peak: Float, width: Float)] = [(625, 18), (522, 30), (455, 22)]
        return SpectralGrid.wavelengths.map { wavelength in
            SIMD3(bands.map { band in
                let sigma = band.width / 2.3548
                return exp(-0.5 * pow((wavelength - band.peak) / sigma, 2))
            })
        }
    }()

    static let plainDyes = SpectralGrid.dyes(family: .kodakNegative)

    /// Rows times `density`.
    @inlinable
    public static func apply(_ weights: [SIMD3<Float>], _ density: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3((weights[0] * density).sum(), (weights[1] * density).sum(),
              (weights[2] * density).sum())
    }

    private static func invert(_ rows: [SIMD3<Float>]) -> [SIMD3<Float>]? {
        func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }
        let determinant = (rows[0] * cross(rows[1], rows[2])).sum()
        guard abs(determinant) > 1e-6, determinant.isFinite else { return nil }
        // The inverse's columns are the cross products of the rows over the determinant.
        let c0 = cross(rows[1], rows[2]) / determinant
        let c1 = cross(rows[2], rows[0]) / determinant
        let c2 = cross(rows[0], rows[1]) / determinant
        return [SIMD3(c0.x, c1.x, c2.x), SIMD3(c0.y, c1.y, c2.y), SIMD3(c0.z, c1.z, c2.z)]
    }
}
