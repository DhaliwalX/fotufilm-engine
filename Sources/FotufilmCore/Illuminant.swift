import Foundation

/// Reference spectral power distributions on `SpectralGrid`'s 380–780 nm axis.
/// Generated SPDs are normalized to 1 at 560 nm. `d65` retains its published normalization of
/// 100 at 560 nm; matrix derivation normalizes each solve by the illuminant white.
public enum Illuminant {
    /// Index of 560 nm on the grid: (560 − 380) / 5. The CIE anchors both the daylight
    /// component tables and the published D65 at this wavelength, so it is where every SPD
    /// here pins its normalization.
    static let anchorIndex = 36

    /// Returns a Planckian SPD normalized to 1 at 560 nm.
    /// It shares `SpectralGrid.blackbody`'s c2 = 14,387,769 nm·K constant with white balance.
    public static func planckian(kelvin: Float) -> [Float] {
        var values = SpectralGrid.blackbody(kelvinK: kelvin)
        let anchor = values[anchorIndex]
        guard anchor > 0 else { return values }
        for i in values.indices { values[i] /= anchor }
        return values
    }

    /// Returns the CIE daylight series normalized to 1 at 560 nm.
    /// Input is clamped to the CIE locus range of 4000–25000 K. The SPD is
    /// `S0 + M1·S1 + M2·S2` using unrounded component weights.
    public static func daylight(kelvin: Float) -> [Float] {
        let t = clamp(kelvin, 4000, 25000)
        // The locus polynomial is shared with white balance so a daylight matrix anchor and a
        // daylight white-balance target name the same chromaticity.
        let xy = WhiteBalance.daylightXY(t)
        let x = Double(xy.x), y = Double(xy.y)
        let m = 0.0241 + 0.2562 * x - 0.7341 * y
        let m1 = Float((-1.3515 - 1.7703 * x + 5.9114 * y) / m)
        let m2 = Float((0.0300 - 31.4424 * x + 30.0717 * y) / m)
        var values = (0..<SpectralGrid.count).map { i in
            s0[i] + m1 * s1[i] + m2 * s2[i]
        }
        // S1 and S2 are zero at 560 nm and S0 is 100 there, so the anchor is exactly 100.
        let anchor = values[anchorIndex]
        for i in values.indices { values[i] /= anchor }
        return values
    }

    /// Returns a Planckian SPD through 4000 K, a daylight SPD from 5000 K, and a linear blend
    /// between them. This matches `WhiteBalance.locusXY`.
    public static func atLocus(kelvin: Float) -> [Float] {
        let t = clamp(kelvin, 1000, 25000)
        if t <= 4000 { return planckian(kelvin: t) }
        if t >= 5000 { return daylight(kelvin: t) }
        let mix = (t - 4000) / 1000
        let warm = planckian(kelvin: t), cool = daylight(kelvin: t)
        return (0..<SpectralGrid.count).map { (1 - mix) * warm[$0] + mix * cool[$0] }
    }

    /// CIE standard illuminant A — the 2856 K tungsten lamp — as the Planckian radiator the
    /// CIE defines it to be. The warm anchor of the dual-illuminant matrix pair.
    public static let a: [Float] = planckian(kelvin: 2856)

    /// The published D65 table the whole model integrates against, renamed so call sites that
    /// pick illuminants read uniformly. Normalized to 100 at 560 nm as the CIE publishes it;
    /// see the type comment for why the scale difference against the generators is harmless.
    public static let d65: [Float] = SpectralGrid.d65

    /// CIE D50 at 5003 K, the reference illuminant used to judge reflection prints.
    public static let d50: [Float] = daylight(kelvin: 5003)

    /// Analytic 5400 K projection illuminant for the source example receivers.
    /// This preserves the public API without redistributing a transcribed projector dataset.
    public static let xenonProjection: [Float] = daylight(kelvin: 5400)

    // MARK: - CIE daylight components

    // The CIE 15 daylight component vectors on the grid's 5 nm axis, 380–780 nm: S0 is the
    // mean of the measured daylight spectra the series was derived from, S1 and S2 the first
    // two characteristic vectors of their variation (blue–yellow with temperature, and the
    // green–magenta residual). Published values, transcribed as printed.
    static let s0: [Float] = [
        63.4, 64.6, 65.8, 80.3, 94.8, 99.8, 104.8, 105.35,
        105.9, 101.35, 96.8, 105.35, 113.9, 119.75, 125.6, 125.55,
        125.5, 123.4, 121.3, 121.3, 121.3, 117.4, 113.5, 113.3,
        113.1, 111.95, 110.8, 108.65, 106.5, 107.65, 108.8, 107.05,
        105.3, 104.85, 104.4, 102.2, 100.0, 98.0, 96.0, 95.55,
        95.1, 92.1, 89.1, 89.8, 90.5, 90.4, 90.3, 89.35,
        88.4, 86.2, 84.0, 84.55, 85.1, 83.5, 81.9, 82.25,
        82.6, 83.75, 84.9, 83.1, 81.3, 76.6, 71.9, 73.1,
        74.3, 75.35, 76.4, 69.85, 63.3, 67.5, 71.7, 74.35,
        77.0, 71.1, 65.2, 56.45, 47.7, 58.15, 68.6, 66.8,
        65.0,
    ]
    static let s1: [Float] = [
        38.5, 36.75, 35.0, 39.2, 43.4, 44.85, 46.3, 45.1,
        43.9, 40.5, 37.1, 36.9, 36.7, 36.3, 35.9, 34.25,
        32.6, 30.25, 27.9, 26.1, 24.3, 22.2, 20.1, 18.15,
        16.2, 14.7, 13.2, 10.9, 8.6, 7.35, 6.1, 5.15,
        4.2, 3.05, 1.9, 0.95, 0, -0.8, -1.6, -2.55,
        -3.5, -3.5, -3.5, -4.65, -5.8, -6.5, -7.2, -7.9,
        -8.6, -9.05, -9.5, -10.2, -10.9, -10.8, -10.7, -11.35,
        -12.0, -13.0, -14.0, -13.8, -13.6, -12.8, -12.0, -12.65,
        -13.3, -13.1, -12.9, -11.75, -10.6, -11.1, -11.6, -11.9,
        -12.2, -11.2, -10.2, -9.0, -7.8, -9.5, -11.2, -10.8,
        -10.4,
    ]
    static let s2: [Float] = [
        3.0, 2.1, 1.2, 0.05, -1.1, -0.8, -0.5, -0.6,
        -0.7, -0.95, -1.2, -1.9, -2.6, -2.75, -2.9, -2.85,
        -2.8, -2.7, -2.6, -2.6, -2.6, -2.2, -1.8, -1.65,
        -1.5, -1.4, -1.3, -1.25, -1.2, -1.1, -1.0, -0.75,
        -0.5, -0.4, -0.3, -0.15, 0, 0.1, 0.2, 0.35,
        0.5, 1.3, 2.1, 2.65, 3.2, 3.65, 4.1, 4.4,
        4.7, 4.9, 5.1, 5.9, 6.7, 7.0, 7.3, 7.95,
        8.6, 9.2, 9.8, 10.0, 10.2, 9.25, 8.3, 8.95,
        9.6, 9.05, 8.5, 7.75, 7.0, 7.3, 7.6, 7.8,
        8.0, 7.35, 6.7, 5.95, 5.2, 6.3, 7.4, 7.1,
        6.8,
    ]
}
