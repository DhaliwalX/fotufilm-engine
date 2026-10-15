import Foundation

/// Undoes the crosstalk between a scan's channels and a colour negative's dyes. A camera or
/// scanner channel is broader than the dye it is read for, so it also sees some of the other two:
/// a red channel reads mostly cyan dye and a little magenta and yellow. Read one channel per
/// record, the records share part of each other's density and the print's colour is muddied.
///
/// The scan is linear Rec. 2020, whose channels see the spectrum as the Rec. 2020 primaries'
/// colour-matching functions do, through a flat lamp (`SpectralGrid.equalEnergy`). Each channel's
/// density of each dye, `A[channel][dye]`, is that dye's spectral density weighted by the
/// channel's sensitivity, and `A⁻¹` reads dye density back from the channels' densities. Each of
/// its rows is scaled to sum to one, so a neutral the scan reads stays neutral at every density
/// and the frame's balance still times the print. `strength` blends from one channel per record
/// (0) to the full correction (1): a scan made under narrowband RGB light has little crosstalk to
/// undo, one made by a camera under white light the most.
public enum NegativeScanCrosstalk {
    public static let range: ClosedRange<Float> = 0...1

    /// What each film record reads from the scan: rows are records, columns the scan's red,
    /// green and blue densities over the clear film. A monochrome film reads green alone.
    public static func weights(for stock: FilmStock, strength: Float) -> [SIMD3<Float>] {
        if stock.isMonochrome { return Array(repeating: SIMD3(0, 1, 0), count: 3) }
        return weights(dyes: stock.spectralProfile.imageDyeDensity, strength: strength)
    }

    /// The weights for a scan read without a film (`PlainNegativeScan`): the dyes of a typical
    /// colour negative.
    public static func plainWeights(strength: Float) -> [SIMD3<Float>] {
        weights(dyes: plainDyes, strength: strength)
    }

    /// Rows `strength` of the way from the identity to `A⁻¹` for `dyes`, on the spectral grid,
    /// each row scaled to sum to one. The identity where the dyes cannot be told apart.
    static func weights(dyes: [[Float]], strength: Float) -> [SIMD3<Float>] {
        let identity = [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        let strength = min(max(strength.isFinite ? strength : 0, range.lowerBound), range.upperBound)
        guard strength > 0, let unmix = invert(channelDensities(dyes: dyes)),
              unmix.allSatisfy({ $0.sum() > 0.1 }) else { return identity }
        return (0..<3).map { identity[$0] + strength * (unmix[$0] / unmix[$0].sum() - identity[$0]) }
    }

    /// `A`, rows the scan's channels and columns the dyes: each channel's density per unit of each
    /// dye, linearised about clear film. A neutral transmits every wavelength alike, so this is the
    /// same about any neutral.
    static func channelDensities(dyes: [[Float]]) -> [SIMD3<Float>] {
        (0..<3).map { channel in
            var row = SIMD3<Float>.zero
            var total: Float = 0
            for i in 0..<SpectralGrid.count {
                let weight = sensitivities[i][channel]
                total += weight
                row += weight * SIMD3(dyes[0][i], dyes[1][i], dyes[2][i])
            }
            return row / total
        }
    }

    /// The Rec. 2020 channels' spectral sensitivities, per grid wavelength.
    static let sensitivities: [SIMD3<Float>] = (0..<SpectralGrid.count).map { i in
        SpectralGrid.linearRec2020(fromXYZ: SIMD3(SpectralGrid.xBar[i], SpectralGrid.yBar[i],
                                                  SpectralGrid.zBar[i]))
            * SpectralGrid.equalEnergy[i]
    }

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
