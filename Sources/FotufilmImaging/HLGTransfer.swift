import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Reading a 10-bit HLG capture back into the light that made it.
public enum HLGTransfer {
    /// Rec.2020 linear to Display P3 linear, both D65.
    public static let rec2020ToDisplayP3: [Float] =
        rowMajor(ColorScience.linearRec2020ToDisplayP3)

    /// The way back, for writing a print into an HLG track.
    public static let displayP3ToRec2020: [Float] =
        rowMajor(ColorScience.linearDisplayP3ToRec2020)

    /// Both of the above are taken from `ColorScience` rather than restated as digits. The hand
    /// copies they replace were rounded to six places and had drifted: neither one's rows summed
    /// to 1, so D65 white did not survive the delivery matrix it was written through.
    private static func rowMajor(
        _ transform: (SIMD3<Float>) -> SIMD3<Float>
    ) -> [Float] {
        let r = transform(SIMD3(1, 0, 0))
        let g = transform(SIMD3(0, 1, 0))
        let b = transform(SIMD3(0, 0, 1))
        return [r.x, g.x, b.x,
                r.y, g.y, b.y,
                r.z, g.z, b.z]
    }

    /// Display P3's linear-light contribution to D65 luminance.
    public static let displayP3Luminance = SIMD3<Float>(
        0.2289746, 0.6917385, 0.0792869)

    /// Applies the output shoulder without changing an RGB value's hue.
    public static func hdrShoulderPreservingHue(_ value: SIMD3<Float>)
        -> SIMD3<Float> {
        PrintEncoding.hdrShoulderPreservingHue(value)
    }

    /// Maps scene-linear Rec.2020 into the nonnegative Display-P3 cube while
    /// preserving luminance and the colour's direction from neutral. A delivery-boundary
    /// tool: ingest no longer uses it — the engine accepts out-of-P3 components and
    /// gamut-handles at its own Rec.2020 seam.
    public static func mapRec2020ToDisplayP3(
        _ rgb: SIMD3<Float>, ceiling: Float = PrintEncoding.hdrHeadroom
    ) -> SIMD3<Float> {
        let m = rec2020ToDisplayP3
        let raw = SIMD3<Float>(
            m[0] * rgb.x + m[1] * rgb.y + m[2] * rgb.z,
            m[3] * rgb.x + m[4] * rgb.y + m[5] * rgb.z,
            m[6] * rgb.x + m[7] * rgb.y + m[8] * rgb.z)
        let luminance = max(raw.x * displayP3Luminance.x
            + raw.y * displayP3Luminance.y
            + raw.z * displayP3Luminance.z, 0)
        guard luminance > 1e-8 else { return .zero }

        var saturation: Float = 1
        for component in [raw.x, raw.y, raw.z] {
            if component < 0 {
                saturation = min(saturation,
                                 luminance / (luminance - component))
            } else if component > ceiling, luminance < ceiling {
                saturation = min(saturation,
                                 (ceiling - luminance)
                                    / (component - luminance))
            }
        }
        let neutral = SIMD3<Float>(repeating: luminance)
        let mapped = neutral + (raw - neutral) * max(saturation, 0)
        return SIMD3<Float>(max(mapped.x, 0), max(mapped.y, 0),
                            max(mapped.z, 0))
    }

    /// One display-linear P3 print pixel to HLG-encoded BT.2020 RGB.
    static func encodeRGB(r: Float, g: Float, b: Float)
        -> (r: Float, g: Float, b: Float) {
        let rolled = PrintEncoding.hdrShoulderPreservingHue(SIMD3(r, g, b))
        let m = displayP3ToRec2020
        let wide = (
            max(m[0] * rolled.x + m[1] * rolled.y + m[2] * rolled.z, 0),
            max(m[3] * rolled.x + m[4] * rolled.y + m[5] * rolled.z, 0),
            max(m[6] * rolled.x + m[7] * rolled.y + m[8] * rolled.z, 0))
        let open = opticalToOpen(r: wide.0, g: wide.1, b: wide.2)
        let headroom = PrintEncoding.hdrHeadroom
        return (r: PrintEncoding.encodeHLG(open.r / headroom),
                g: PrintEncoding.encodeHLG(open.g / headroom),
                b: PrintEncoding.encodeHLG(open.b / headroom))
    }

    /// One display-linear P3 print pixel to HLG-encoded Y′CbCr, each in its normalised range: luma
    /// 0…1, chroma ±0.5.
    public static func encode(r: Float, g: Float, b: Float)
        -> (y: Float, u: Float, v: Float) {
        let signal = encodeRGB(r: r, g: g, b: b)
        let y = 0.2627 * signal.r + 0.6780 * signal.g + 0.0593 * signal.b
        return (y: y,
                u: (signal.b - y) / 1.8814,
                v: (signal.r - y) / 1.4746)
    }

    /// Four display-linear P3 print pixels reduced to one 4:2:0 chroma sample.
    public static func encode420(
        topLeft: SIMD3<Float>, topRight: SIMD3<Float>,
        bottomLeft: SIMD3<Float>, bottomRight: SIMD3<Float>
    ) -> (luma: SIMD4<Float>, u: Float, v: Float) {
        let a = encode(r: topLeft.x, g: topLeft.y, b: topLeft.z)
        let b = encode(r: topRight.x, g: topRight.y, b: topRight.z)
        let c = encode(r: bottomLeft.x, g: bottomLeft.y, b: bottomLeft.z)
        let d = encode(r: bottomRight.x, g: bottomRight.y, b: bottomRight.z)
        return (
            luma: SIMD4(a.y, b.y, c.y, d.y),
            u: (a.u + b.u + c.u + d.u) * 0.25,
            v: (a.v + b.v + c.v + d.v) * 0.25)
    }

    /// BT.2100's HLG system gamma.
    public static let systemGamma: Float = 1.2

    /// The opto-optical transfer function, normalised so diffuse white is 1.0 and therefore fixed:
    /// `Y^(γ-1)` applied to all three channels, which leaves chromaticity exactly where it was and
    /// moves only the tone.
    public static func openToOptical(r: Float, g: Float, b: Float)
        -> (r: Float, g: Float, b: Float) {
        let y = 0.2627 * r + 0.6780 * g + 0.0593 * b
        guard y > 1e-6 else { return (0, 0, 0) }
        let scale = pow(y, systemGamma - 1)
        return (r * scale, g * scale, b * scale)
    }

    /// The inverse, for writing a display-referred print back out as HLG.
    public static func opticalToOpen(r: Float, g: Float, b: Float)
        -> (r: Float, g: Float, b: Float) {
        let y = 0.2627 * r + 0.6780 * g + 0.0593 * b
        guard y > 1e-6 else { return (0, 0, 0) }
        let scale = pow(y, (1 - systemGamma) / systemGamma)
        return (r * scale, g * scale, b * scale)
    }

    /// The video feed's exposure brought to the photo pipeline's.
    public static let videoExposureTrim: Float = 0.92

    /// A developed Display-P3 print prepared for an extended-linear Metal layer, whose contract is
    /// fixed by the colour space alone: 1.0 is SDR reference white, values above it are EDR
    /// headroom, and nothing else is implied.
    ///
    /// No preview in this repository draws through it yet — the playback surfaces publish an SDR
    /// print — so its only caller is the test that pins the mapping. It is kept public and tested
    /// because it states the display side of the same ceiling `PrintEncoding.hdrDisplayCeiling`
    /// fixes for the file side, and a preview that goes EDR needs exactly this and not a second
    /// derivation of it.
    public static func previewDisplayLight(
        r: Float, g: Float, b: Float, ceiling: Float
    ) -> (r: Float, g: Float, b: Float) {
        let bounded = min(max(ceiling, 1), PrintEncoding.hdrDisplayCeiling)
        let rolled = PrintEncoding.hdrShoulderPreservingHue(
            SIMD3(r, g, b), ceiling: bounded)
        return (rolled.x, rolled.y, rolled.z)
    }

    /// One 10-bit video-range Y′CbCr sample to scene-linear light, with diffuse white at 1.0.
    /// HLG's container primaries are BT.2020 — the engine's own working space — so an HLG
    /// capture decodes into it with no matrix at all: the source's whole gamut arrives intact
    /// by identity.
    public static func decode(luma: Float, cb: Float, cr: Float) -> (Float, Float, Float) {
        let y = (luma - 64) / 876
        let u = (cb - 512) / 896
        let v = (cr - 512) / 896
        let signal = (r: min(max(y + 1.4746 * v, 0), 1),
                      g: min(max(y - 0.164553 * u - 0.571353 * v, 0), 1),
                      b: min(max(y + 1.8814 * u, 0), 1))
        let headroom = PrintEncoding.hdrHeadroom
        return (PrintEncoding.hlgSceneLight(at: signal.r) * headroom,
                PrintEncoding.hlgSceneLight(at: signal.g) * headroom,
                PrintEncoding.hlgSceneLight(at: signal.b) * headroom)
    }
}
