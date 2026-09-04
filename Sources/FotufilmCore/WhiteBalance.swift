import Foundation

/// Camera white balance, as a correlated colour temperature and a tint away
/// from the blackbody/daylight locus.
public struct WhiteBalance: Equatable, Codable, Sendable {
    /// Correlated colour temperature of the scene illuminant, in kelvin.
    public var kelvin: Float
    /// Displacement perpendicular to the locus in CIE 1960 uv, x10000 — so one unit is a Duv of
    /// 0.0001 and the slider's ends are +/-0.01.
    public var tint: Float

    /// D65, the renderer's working white.
    public static let neutralKelvin: Float = 6504
    public static let neutral = WhiteBalance(kelvin: neutralKelvin, tint: 0)

    /// The range the UI offers.
    public static let kelvinRange: ClosedRange<Float> = 2000...12000
    public static let tintRange: ClosedRange<Float> = -100...100

    public init(kelvin: Float = neutralKelvin, tint: Float = 0) {
        self.kelvin = kelvin
        self.tint = tint
    }

    public var isNeutral: Bool { kelvin == Self.neutralKelvin && tint == 0 }

    /// Micro-reciprocal degrees, 10^6 / K.
    public static func kelvinToMired(_ kelvin: Float) -> Float {
        1e6 / max(kelvin, 1)
    }

    public static func miredToKelvin(_ mired: Float) -> Float {
        1e6 / max(mired, 1)
    }

    /// The temperature expressed for the slider.
    public var mired: Float {
        get { Self.kelvinToMired(kelvin) }
        set { kelvin = Self.miredToKelvin(newValue) }
    }

    /// `kelvinRange` seen from the slider's end, warm on the right the way a camera shows it: low
    /// mired is cool light, high mired is warm.
    public static let miredRange: ClosedRange<Float> =
        kelvinToMired(kelvinRange.upperBound)...kelvinToMired(kelvinRange.lowerBound)

    /// Per-channel gains on scene-linear working-space RGB that carry a subject lit by this
    /// illuminant to what it would have looked like under the renderer's D65 white.
    public var gains: (r: Float, g: Float, b: Float) {
        if isNeutral { return (1, 1, 1) }
        let source = Self.chromaticity(kelvin: kelvin, tint: tint)
        let destination = Self.chromaticity(kelvin: Self.neutralKelvin, tint: 0)
        let sourceRGB = Self.workingRGB(fromXY: source)
        let destinationRGB = Self.workingRGB(fromXY: destination)
        let r = destinationRGB.x / max(sourceRGB.x, 1e-6)
        let g = destinationRGB.y / max(sourceRGB.y, 1e-6)
        let b = destinationRGB.z / max(sourceRGB.z, 1e-6)
        return (r / g, 1, b / g)
    }

    /// CIE 1931 xy of the illuminant named by a temperature and a tint.
    public static func chromaticity(kelvin: Float, tint: Float) -> SIMD2<Float> {
        let t = clamp(kelvin, 1000, 25000)
        let base = locusXY(t)
        guard tint != 0 else { return base }

        let uv = uvFromXY(base)
        let step: Float = 10
        let ahead = uvFromXY(locusXY(t + step))
        let behind = uvFromXY(locusXY(t - step))
        var tangent = ahead - behind
        let length = (tangent.x * tangent.x + tangent.y * tangent.y).squareRoot()
        guard length > 1e-9 else { return base }
        tangent /= length
        let normal = SIMD2<Float>(-tangent.y, tangent.x)
        let signed = normal.y >= 0 ? normal : -normal
        return xyFromUV(uv + signed * (tint / 10000))
    }

    /// The reference locus: a Planckian radiator up to 4000 K, the CIE daylight series from 5000 K,
    /// crossfaded in uv between.
    static func locusXY(_ kelvin: Float) -> SIMD2<Float> {
        let t = clamp(kelvin, 1000, 25000)
        if t <= 4000 { return planckianXY(t) }
        if t >= 5000 { return daylightXY(t) }
        let s = (t - 4000) / 1000
        let blend = s * s * (3 - 2 * s)
        let planckian = uvFromXY(planckianXY(t))
        let daylight = uvFromXY(daylightXY(t))
        return xyFromUV(planckian + (daylight - planckian) * blend)
    }

    /// CIE 15 daylight locus, valid 4000-25000 K.
    static func daylightXY(_ kelvin: Float) -> SIMD2<Float> {
        let t = Double(clamp(kelvin, 4000, 25000))
        let x: Double
        if t <= 7000 {
            x = 0.244063 + 0.09911e3 / t + 2.9678e6 / (t * t) - 4.6070e9 / (t * t * t)
        } else {
            x = 0.237040 + 0.24748e3 / t + 1.9018e6 / (t * t) - 2.0064e9 / (t * t * t)
        }
        let y = -3.000 * x * x + 2.870 * x - 0.275
        return SIMD2(Float(x), Float(y))
    }

    /// Planckian locus by direct integration of Planck's law against the CIE 1931 observer on the
    /// renderer's own 10 nm grid — the same tables the film model integrates everything else
    /// against, so a tungsten balance and a tungsten enlarger agree by construction.
    static func planckianXY(_ kelvin: Float) -> SIMD2<Float> {
        let spectrum = SpectralGrid.blackbody(kelvinK: kelvin)
        let xyz = SpectralGrid.xyz(spectrum: spectrum)
        let sum = xyz.x + xyz.y + xyz.z
        guard sum > 0 else { return SIMD2(0.3127, 0.3290) }
        return SIMD2(xyz.x / sum, xyz.y / sum)
    }

    /// CIE 1960 uv, the space correlated colour temperature is defined in.
    static func uvFromXY(_ xy: SIMD2<Float>) -> SIMD2<Float> {
        let denominator = -2 * xy.x + 12 * xy.y + 3
        guard abs(denominator) > 1e-9 else { return SIMD2(0, 0) }
        return SIMD2(4 * xy.x / denominator, 6 * xy.y / denominator)
    }

    static func xyFromUV(_ uv: SIMD2<Float>) -> SIMD2<Float> {
        let denominator = 2 * uv.x - 8 * uv.y + 4
        guard abs(denominator) > 1e-9 else { return SIMD2(0.3127, 0.3290) }
        return SIMD2(3 * uv.x / denominator, 2 * uv.y / denominator)
    }

    /// Working-space linear RGB of a chromaticity at unit luminance. The gains divide out in
    /// linear Rec.2020 because that is the basis the kernel applies them in.
    static func workingRGB(fromXY xy: SIMD2<Float>) -> SIMD3<Float> {
        guard xy.y > 1e-6 else { return SIMD3(1, 1, 1) }
        let xyz = SIMD3<Float>(xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y)
        return SpectralGrid.linearRec2020(fromXYZ: xyz)
    }
}
