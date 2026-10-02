import Foundation

/// Lab Scan's finish: the colour and tone a minilab scanner's processing gives a frame after it
/// has set it up, measured as the difference between such a scan and a neutral scan of the same
/// negative. The scanner prints its scan rather than measuring it: a steeper gradation with
/// bright, open highlights and a deeper black; records whose contrasts do not quite match, which
/// cools the shadows against neutral highlights; a saturation matrix; and colour corrections that
/// turn foliage toward teal and violet toward blue, hold back pure reds and enrich yellows,
/// oranges and blues.
///
/// It is applied to the characterized scan, so it is baked into the medium's output table: no
/// kernel runs it and every renderer shares it.
public enum LabScanFinish {
    /// Lift of the upper tones at their peak, in cube-root luminance; zero at mid-grey and white.
    static let highlightLift: Float = 0.04
    /// Pull on the deepest tones at black, in cube-root luminance.
    static let blackPull: Float = 0.012
    /// Shadow and mid-tone cooling from the records' crossover, in Oklab a/b.
    static let shadowCool: Float = 0.010
    /// Highlight warmth from the same crossover, in Oklab b.
    static let highlightWarmth: Float = 0.005
    /// Overall chroma gain of the saturation matrix.
    static let saturation: Float = 0.06

    /// A hue-selective correction: a chroma gain and a hue turn in degrees, both fading over a
    /// Gaussian window of `width` degrees about `hue` on the Oklab hue circle.
    struct HueCorrection {
        let hue: Float
        let width: Float
        let chroma: Float
        let turn: Float
    }

    static let corrections: [HueCorrection] = [
        HueCorrection(hue: 25, width: 15, chroma: 0.90, turn: 0),     // pure reds
        HueCorrection(hue: 70, width: 25, chroma: 1.10, turn: 0),     // oranges, skin
        HueCorrection(hue: 105, width: 20, chroma: 1.10, turn: 0),    // yellows
        HueCorrection(hue: 145, width: 25, chroma: 0.92, turn: 12),   // foliage toward teal
        HueCorrection(hue: 245, width: 30, chroma: 1.10, turn: 0),    // blues, sky
        HueCorrection(hue: 310, width: 25, chroma: 1, turn: -15),     // violet toward blue
    ]

    /// The finished colour of a scan pixel, linear Display P3 in and out. A monochrome scan takes
    /// the gradation alone and stays neutral.
    public static func apply(_ colour: SIMD3<Float>, chromatic: Bool = true) -> SIMD3<Float> {
        let toned = graded(colour)
        guard chromatic else { return toned }
        var lab = oklab(ColorScience.linearDisplayP3ToSRGB(toned))
        let l = lab.x

        // The crossover: cooler shadows and mid-tones, faintly warm highlights, neither at the
        // black floor nor at white.
        let shadow = clamp((0.75 - l) / 0.45, 0, 1) * clamp((l - 0.04) / 0.16, 0, 1)
        let high = clamp((l - 0.75) / 0.15, 0, 1) * clamp((1 - l) / 0.08, 0, 1)
        lab.y += -shadowCool * shadow + 0.5 * highlightWarmth * high
        lab.z += -0.6 * shadowCool * shadow + highlightWarmth * high

        // Saturation and the hue corrections, faded out in the deepest shadows and toward white,
        // which a scanner keeps clean.
        var chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        var hue = atan2(lab.z, lab.y) * 180 / .pi
        var gain = 1 + saturation
        var turn: Float = 0
        for correction in corrections {
            var distance = (hue - correction.hue).truncatingRemainder(dividingBy: 360)
            if distance > 180 { distance -= 360 }
            if distance < -180 { distance += 360 }
            let weight = exp(-0.5 * (distance / correction.width) * (distance / correction.width))
            gain *= 1 + (correction.chroma - 1) * weight
            turn += correction.turn * weight
        }
        let fade = clamp(l / 0.25, 0, 1) * clamp((1 - l) / 0.08, 0, 1)
        chroma *= 1 + (gain - 1) * fade
        hue += turn * fade
        let radians = hue * .pi / 180
        lab.y = chroma * cos(radians)
        lab.z = chroma * sin(radians)
        return ColorScience.linearSRGBToDisplayP3(linear(fromOklab: lab))
    }

    /// The gradation alone: luminance re-placed on a steeper print-like curve, hue untouched.
    static func graded(_ colour: SIMD3<Float>) -> SIMD3<Float> {
        let weights = ColorScience.displayP3LuminanceWeights
        let luminance = weights.0 * colour.x + weights.1 * colour.y + weights.2 * colour.z
        guard luminance > 1e-6 else { return colour }
        let level = cbrt(luminance)
        let upper = clamp((level - 0.55) / 0.45, 0, 1)
        let lifted = level + highlightLift * sin(.pi * upper)
            - blackPull * clamp(1 - level / 0.35, 0, 1)
        let target = max(lifted, 0)
        return colour * (target * target * target / luminance)
    }

    // Oklab (Ottosson 2020) on linear sRGB components; the cube root is signed so colours outside
    // the sRGB cube pass through and back unchanged.
    static func oklab(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let l = cbrt(0.4122214708 * rgb.x + 0.5363325363 * rgb.y + 0.0514459929 * rgb.z)
        let m = cbrt(0.2119034982 * rgb.x + 0.6806995451 * rgb.y + 0.1073969566 * rgb.z)
        let s = cbrt(0.0883024619 * rgb.x + 0.2817188376 * rgb.y + 0.6299787005 * rgb.z)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private static func linear(fromOklab lab: SIMD3<Float>) -> SIMD3<Float> {
        let l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let (l3, m3, s3) = (l * l * l, m * m * m, s * s * s)
        return SIMD3(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
                     -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
                     -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076724896 * s3)
    }
}
