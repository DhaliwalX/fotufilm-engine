import Foundation

/// sRGB transfer functions (IEC 61966-2-1).
public enum ColorScience {
    /// Linear-light sRGB into the working space: an ingest conversion for material that
    /// arrives tagged sRGB. Rows sum to exactly 1, so sRGB white is working white.
    public static func linearSRGBToRec2020(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            0.627403896 * rgb.x + 0.329283038 * rgb.y + 0.043313066 * rgb.z,
            0.069097289 * rgb.x + 0.919540395 * rgb.y + 0.011362316 * rgb.z,
            0.016391439 * rgb.x + 0.088013308 * rgb.y + 0.895595253 * rgb.z)
    }

    /// Linear-light sRGB to linear Display P3, for material whose definition is a P3 colour
    /// (patch nominals, delivery-side tooling) rather than for the scene path.
    public static func linearSRGBToDisplayP3(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            0.822461969 * rgb.x + 0.177538031 * rgb.y,
            0.033194199 * rgb.x + 0.966805801 * rgb.y,
            0.017082631 * rgb.x + 0.072397441 * rgb.y + 0.910519929 * rgb.z)
    }

    /// Linear Display P3 to linear-light sRGB. Values outside 0...1 are retained for the caller to
    /// gamut-map or clip at the delivery boundary.
    public static func linearDisplayP3ToSRGB(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            1.22494018 * rgb.x - 0.224940176 * rgb.y,
           -0.042056955 * rgb.x + 1.04205695 * rgb.y,
           -0.019637555 * rgb.x - 0.078636046 * rgb.y + 1.09827360 * rgb.z)
    }

    /// Linear Display P3 into the working space: the ingest conversion for P3-tagged sources
    /// (Apple video buffers, P3-defined patch nominals). The engine works in linear Rec.2020,
    /// whose primaries sit on the spectral locus and whose cube contains every P3 colour. More
    /// saturated spectral lights reach the wider exposure-table domain later. Rows sum to exactly
    /// 1: P3 white is working white.
    public static func linearDisplayP3ToRec2020(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            0.753833034 * rgb.x + 0.198597369 * rgb.y + 0.047569597 * rgb.z,
            0.045743849 * rgb.x + 0.941777220 * rgb.y + 0.012478931 * rgb.z,
           -0.001210340 * rgb.x + 0.017601717 * rgb.y + 0.983608623 * rgb.z)
    }

    /// The way out, for the compact 3x3 sensitivity fallback and for tooling that reports
    /// working-space colours in display terms. Delivery itself does not pass through here:
    /// the print tables integrate their dyes straight to the delivery basis.
    public static func linearRec2020ToDisplayP3(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            1.343578253 * rgb.x - 0.282179671 * rgb.y - 0.061398582 * rgb.z,
           -0.065297453 * rgb.x + 1.075787916 * rgb.y - 0.010490463 * rgb.z,
            0.002821787 * rgb.x - 0.019598495 * rgb.y + 1.016776707 * rgb.z)
    }

    /// Linear Rec.2020 into the exposure table's own basis: the ACES AP0 primaries about the
    /// engine's D65 working white. Rec.2020's primaries sit on the spectral locus, but the
    /// locus bulges outward between them, so every monochromatic light but three wavelengths
    /// falls outside its cube. AP0's triangle encloses the whole locus, so the table has cells
    /// of its own for every real light, and the recovery's boundary moves out to where physical
    /// light actually ends. Rows sum to exactly 1: the neutral axis is the same line in both
    /// bases, so a walk toward it means the same thing on either side of the seam. The kernels
    /// apply this per pixel; it must match `kRec2020ToExposureDomain` in FotufilmHalideShared.h
    /// and the handwritten Metal shaders digit for digit.
    public static func linearRec2020ToExposureDomain(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            0.670231843 * rgb.x + 0.152168745 * rgb.y + 0.177599412 * rgb.z,
            0.044501114 * rgb.x + 0.854482372 * rgb.y + 0.101016514 * rgb.z,
            0.025777047 * rgb.y + 0.974222953 * rgb.z)
    }

    /// The way back, for the table builder and the inverse solves, which reach the reflectance
    /// model and the display seams through Rec.2020. Rows sum to exactly 1.
    public static func linearExposureDomainToRec2020(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            1.509371119 * rgb.x - 0.261310044 * rgb.y - 0.248061075 * rgb.z,
           -0.078854123 * rgb.x + 1.187622946 * rgb.y - 0.108768823 * rgb.z,
            0.002086408 * rgb.x - 0.031423416 * rgb.y + 1.029337008 * rgb.z)
    }

    /// CIE Y of the exposure-domain components: the Y row of AP0's RGB-to-XYZ matrix. The blue
    /// weight is negative because that corner of the triangle lies below the purple line, where
    /// there is no light; a domain colour with non-positive luminance is darkness.
    public static let exposureDomainLuminanceWeights: (Float, Float, Float) =
        (0.343172898, 0.734696400, -0.077869298)

    @inlinable
    public static func srgbToLinear(_ v: Float) -> Float {
        if v <= 0.04045 { return v / 12.92 }
        return pow((v + 0.055) / 1.055, 2.4)
    }

    @inlinable
    public static func linearToSrgb(_ v: Float) -> Float {
        let c = clamp(v, 0, 1)
        if c <= 0.0031308 { return c * 12.92 }
        return 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// The sRGB transfer's slope where it reaches white, which is what continues it above white.
    public static let srgbSlopeAtWhite: Float = 1.055 / 2.4

    /// The signal a grading suite's three-way corrector works on, and its exact inverse.
    ///
    /// Over 0…1 this is sRGB, so the three-way lands where a colourist expects. Outside it the curve
    /// is continued by its own end slopes rather than clamped, which keeps the pair a true bijection
    /// over the whole range: a neutral grade has to stay a neutral grade, and light above display
    /// white has to survive to meet the shoulder that rolls it.
    @inlinable
    public static func gradingEncode(_ linear: Float) -> Float {
        if linear <= 0.0031308 { return linear * 12.92 }
        if linear >= 1 { return 1 + (linear - 1) * srgbSlopeAtWhite }
        return 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    @inlinable
    public static func gradingDecode(_ coded: Float) -> Float {
        if coded <= 0.04045 { return coded / 12.92 }
        if coded >= 1 { return 1 + (coded - 1) / srgbSlopeAtWhite }
        return pow((coded + 0.055) / 1.055, 2.4)
    }

    @inlinable
    public static func displayShoulder(_ x: Float, knee: Float = 0.9) -> Float {
        highlightShoulder(x, ceiling: 1, knee: knee)
    }

    /// The same shoulder against an arbitrary ceiling, which is what an HDR print needs: a
    /// rational soft clip that leaves everything below the knee alone, meets it with slope 1, and
    /// approaches `ceiling` without reaching it. The single definition of the curve — SDR is this
    /// with `ceiling` at 1, and `PrintEncoding` and `FilmOutputConversion` both come here rather
    /// than restating it, because two spellings of a shoulder are two different pictures.
    @inlinable
    public static func highlightShoulder(
        _ x: Float, ceiling: Float, knee: Float = 0.9
    ) -> Float {
        let knee = min(max(knee, 0), ceiling)
        guard x > knee else { return x }
        let over = x - knee, room = ceiling - knee
        guard room > 0 else { return ceiling }
        return knee + room * over / (over + room)
    }

    /// CIE Y weights for one linear working-space RGB triple — row two of the BT.2020 RGB to
    /// XYZ matrix, because linear Rec.2020 is the scene basis the renderer works in. Must match
    /// `kLuma{R,G,B}` in FotufilmHalideShared.h (and FotufilmMetalGrain.mm) digit for digit — the
    /// Swift reference path mirrors those kernels value for value.
    public static let luminanceWeights: (Float, Float, Float) = (0.2627002, 0.6779981, 0.0593017)

    /// CIE Y weights for the print side's Display P3 basis — row two of the P3 to XYZ matrix.
    /// The finished print is integrated and output in P3, so anything weighing *developed*
    /// colour (reversal balance, the neutral tone scale, print measurement) meters with these.
    public static let displayP3LuminanceWeights: (Float, Float, Float) =
        (0.2289746, 0.6917385, 0.0792869)
}

/// Material-aware SDR delivery. Reversal has no print-paper stage to absorb its long physical
/// shoulder, so its output roll-off begins earlier and uses more of the SDR interval instead of
/// bunching distinct highlight exposures immediately below code white.
public enum FilmSDRDelivery {
    public static let standardShoulderKnee: Float = 0.9
    public static let reversalShoulderKnee: Float = 0.7

    @inlinable
    public static func shoulderKnee(isReversal: Bool) -> Float {
        isReversal ? reversalShoulderKnee : standardShoulderKnee
    }
}
