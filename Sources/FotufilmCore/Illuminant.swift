import Foundation

/// Reference spectral power distributions on `SpectralGrid`'s 380–780 nm axis.
/// Locus spectra use the CIE 560 nm table convention; tinted spectra have arbitrary scale.
/// Film exposure normalizes every spectrum to equal photometric Y.
public enum Illuminant {
    /// Index of 560 nm on the grid: (560 − 380) / 5. The CIE anchors both the daylight
    /// component tables and the published D65 at this wavelength, so it is where every SPD
    /// in the locus generators pins its tabular normalization.
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

    /// Returns a Planckian SPD through 4000 K, a daylight SPD from 5000 K, and a smooth blend
    /// between them. White balance derives its locus by integrating this spectrum.
    public static func atLocus(kelvin: Float) -> [Float] {
        let t = clamp(kelvin, 1000, 25000)
        if t <= 4000 { return planckian(kelvin: t) }
        if t >= 5000 { return daylight(kelvin: t) }
        let s = (t - 4000) / 1000
        let mix = s * s * (3 - 2 * s)
        let warm = planckian(kelvin: t), cool = daylight(kelvin: t)
        return (0..<SpectralGrid.count).map { (1 - mix) * warm[$0] + mix * cool[$0] }
    }

    /// Smooth, positive approximation to a lamp of the stated chromaticity. Tint changes the
    /// spectrum, not the image's RGB channels. A chromaticity cannot identify a measured lamp's
    /// spectrum; this is a minimum-relative-entropy deformation of the chosen locus spectrum.
    public static func spectrum(_ balance: WhiteBalance) -> [Float] {
        let base = atLocus(kelvin: balance.kelvin)
        guard balance.tint != 0 else { return base }
        return matching(WhiteBalance.chromaticity(kelvin: balance.kelvin, tint: balance.tint),
                        base: base)
    }

    static func matching(_ xy: SIMD2<Float>, base: [Float]) -> [Float] {
        precondition(xy.x.isFinite && xy.y.isFinite && xy.x > 0 && xy.y > 0,
                     "invalid illuminant chromaticity")
        let origin = WhiteBalance.uvFromXY(chromaticity(base))
        let xy = WhiteBalance.boundedChromaticity(
            fromUV: origin, displacement: WhiteBalance.uvFromXY(xy) - origin)
        let x = Double(xy.x / xy.y), z = Double((1 - xy.x - xy.y) / xy.y)
        let u = (0..<SpectralGrid.count).map {
            Double(SpectralGrid.xBar[$0]) - x * Double(SpectralGrid.yBar[$0])
        }
        let v = (0..<SpectralGrid.count).map {
            Double(SpectralGrid.zBar[$0]) - z * Double(SpectralGrid.yBar[$0])
        }
        var a = 0.0, b = 0.0
        var result = base.map(Double.init)
        for _ in 0..<128 {
            var f = 0.0, g = 0.0, aa = 0.0, ab = 0.0, bb = 0.0
            for i in result.indices {
                result[i] = Double(base[i]) * exp(a * u[i] + b * v[i])
                f += result[i] * u[i]
                g += result[i] * v[i]
                aa += result[i] * u[i] * u[i]
                ab += result[i] * u[i] * v[i]
                bb += result[i] * v[i] * v[i]
            }
            if max(abs(f), abs(g)) < 1e-10 { break }
            let determinant = aa * bb - ab * ab
            precondition(determinant > 0, "illuminant chromaticity is outside the spectral support")
            let da = (bb * f - ab * g) / determinant
            let db = (aa * g - ab * f) / determinant
            let scale = min(1, 1 / max(abs(da), abs(db)))
            a -= scale * da
            b -= scale * db
        }
        let values = result.map(Float.init)
        let white = chromaticity(values)
        precondition(abs(white.x - xy.x) < 1e-5 && abs(white.y - xy.y) < 1e-5,
                     "illuminant chromaticity solve did not converge")
        return values
    }

    public static func chromaticity(_ spectrum: [Float]) -> SIMD2<Float> {
        let xyz = SpectralGrid.xyz(spectrum: spectrum)
        precondition(xyz.sum().isFinite && xyz.sum() > 0, "illuminant must contain visible energy")
        return SIMD2(xyz.x, xyz.y) / xyz.sum()
    }

    /// Relative photometric normalization. Equal-Y lights keep exposure independent of the
    /// arbitrary SPD scale, including lamps with no energy at the old 560 nm anchor.
    static func luminance(_ spectrum: [Float]) -> Float {
        precondition(spectrum.count == SpectralGrid.count)
        let y = zip(spectrum, SpectralGrid.yBar).reduce(Double(0)) {
            $0 + Double($1.0) * Double($1.1)
        }
        precondition(y.isFinite && y > 0, "illuminant must contain visible energy")
        return Float(y)
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

    /// A xenon short-arc cinema projector measured through its optics, normalized to 1.0 at
    /// 560 nm like the generators above. This raw measurement is retained as the spectral source
    /// for the calibrated reference below.
    ///
    /// This is the one illuminant here that is *measured* rather than constructed — there is no
    /// CIE series for an arc lamp, and a projected print is not viewed by daylight or by a
    /// blackbody. It matters because a release print's dyes are published at the amounts that
    /// form a visual neutral *under this lamp* (see `Vision2383PrintSpectra.dyeDensity`), so
    /// reading them under anything else is reading them against a white they were not drawn for.
    ///
    /// Source: `colour.SDS_LIGHT_SOURCES["Kinoton 75P"]` from the colour-science library,
    /// Copyright 2013 Colour Developers, BSD-3-Clause. Redistributing this table in source form
    /// requires the licence's copyright notice, conditions and disclaimer, which are reproduced
    /// in full in `THIRD_PARTY_NOTICES.md`; this note on its own would not satisfy that. The
    /// naming here is factual attribution: under the licence's third clause it is not an
    /// endorsement by the Colour Developers or their contributors.
    ///
    /// The lamp is a Kinoton FP-75-series 35 mm projector. Transcribed from the shipped table,
    /// not digitised from a plot: the library's data is 380–780 nm at 2 nm, so every even
    /// sample here is the table's own and the odd ones (385, 395, ...) are the midpoint of
    /// their 2 nm neighbours.
    /// Its provenance is a private communication (BIBLIOGRAPHY.bib `Houston2015a`, Jim Houston
    /// to Thomas Mansencal, 2015) rather than a standard or a published measurement report,
    /// which is the weakest link in this table and the reason it is named here rather than
    /// folded into a generator.
    ///
    /// Its peak is at 468 nm — the blue spike an arc lamp has and a blackbody does not — and its
    /// 700 nm tail collapses to under 1.5% of peak, which says the measurement is through the
    /// projector's IR-cut optics rather than of a bare lamp. That is what a viewing illuminant
    /// should be.
    ///
    /// It integrates to x = 0.3151, y = 0.3325, CCT ≈ 6350 K, which is representative of the
    /// uncalibrated lamp but bluer than the 5400 K reference screen light used for release-print
    /// measurements.
    static let measuredXenonProjection: [Float] = [
        0.136746, 0.206570, 0.281575, 0.381492, 0.477762,  // 380-400 nm
        0.580290, 0.680332, 0.752829, 0.783793, 0.796124,  // 405-425 nm
        0.831295, 0.891565, 0.966010, 1.007482, 1.079627,  // 430-450 nm
        1.117596, 1.188808, 1.309845, 1.362901, 1.240829,  // 455-475 nm
        1.162528, 1.170259, 1.136912, 1.146093, 1.091440,  // 480-500 nm
        1.070819, 1.058280, 1.049140, 1.045223, 1.038052,  // 505-525 nm
        1.038052, 1.031067, 1.030798, 1.024933, 1.014342,  // 530-550 nm
        1.006031, 1.000000, 0.997845, 1.009409, 1.012829,  // 555-575 nm
        1.009534, 1.004477, 0.979938, 0.945534, 0.913741,  // 580-600 nm
        0.902674, 0.902922, 0.915710, 0.920497, 0.905554,  // 605-625 nm
        0.870881, 0.821181, 0.767668, 0.738798, 0.728746,  // 630-650 nm
        0.710694, 0.716394, 0.716332, 0.672787, 0.560642,  // 655-675 nm
        0.420808, 0.292705, 0.180933, 0.105948, 0.061306,  // 680-700 nm
        0.042653, 0.031200, 0.026257, 0.018528, 0.017583,  // 705-725 nm
        0.016041, 0.014596, 0.014301, 0.015295, 0.014873,  // 730-750 nm
        0.012305, 0.010856, 0.018298, 0.018653, 0.021065,  // 755-775 nm
        0.017534,                                          // 780 nm
    ]

    /// Reference cinema screen light: the measured xenon spectrum above after a smooth,
    /// strictly-positive two-term filtration that brings its CIE 1931 white to the model's
    /// 5400 K daylight locus. The filtration preserves the arc's narrow blue structure and
    /// projector IR-cut tail; substituting a daylight or blackbody generator would erase both
    /// and therefore erase dye metamerism that Kodak's release-print data explicitly normalizes
    /// for a xenon-arc viewing illuminant.
    ///
    /// The correction is `exp(aq + bq²)`, q = (λ − 560 nm) / 100 nm, with `a` and `b`
    /// solved on this 5 nm observer grid for the chromaticity of `daylight(kelvin: 5400)`.
    public static let xenonProjection: [Float] = {
        let a: Float = 0.13620723
        let b: Float = -0.02311008
        var values = zip(SpectralGrid.wavelengths, measuredXenonProjection).map {
            wavelength, value in
            let q = (wavelength - 560) / 100
            return value * exp(a * q + b * q * q)
        }
        let anchor = values[anchorIndex]
        for index in values.indices { values[index] /= anchor }
        return values
    }()

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
        4.2, 3.05, 1.9, 0.95, 0.0, -0.8, -1.6, -2.55,
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
        -0.5, -0.4, -0.3, -0.15, 0.0, 0.1, 0.2, 0.35,
        0.5, 1.3, 2.1, 2.65, 3.2, 3.65, 4.1, 4.4,
        4.7, 4.9, 5.1, 5.9, 6.7, 7.0, 7.3, 7.95,
        8.6, 9.2, 9.8, 10.0, 10.2, 9.25, 8.3, 8.95,
        9.6, 9.05, 8.5, 7.75, 7.0, 7.3, 7.6, 7.8,
        8.0, 7.35, 6.7, 5.95, 5.2, 6.3, 7.4, 7.1,
        6.8,
    ]
}
