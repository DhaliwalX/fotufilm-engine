import Foundation

/// Lab Scan's finish: the colour and tone a minilab scanner's processing gives a frame after it
/// has set it up, fitted to the median measured difference between such scans and neutral scans of
/// the same negatives, once each frame's own density and colour are matched. The scanner prints
/// its scan rather than measuring it: a deeper black under faintly lifted upper tones; records
/// whose contrasts do not quite match, which leaves near-neutral shadows and lower mid-tones a cool
/// cyan-blue; and colour corrections that turn foliage toward teal and mute it, turn cyans and
/// blues toward cyan, and turn reds and oranges slightly toward yellow.
///
/// It is applied to the characterized scan, so it is baked into the medium's output table: no
/// kernel runs it and every renderer shares it.
public enum LabScanFinish {
    /// Lift of the upper tones at their peak, in cube-root luminance; zero at mid-grey and white.
    static let highlightLift: Float = 0.006
    /// Pull on the deepest tones at black, in cube-root luminance.
    static let blackPull: Float = 0.019
    /// The records' crossover on near-neutral colours, in Oklab a/b per unit of Oklab lightness,
    /// so a deep shadow takes it in proportion: a cyan-blue cast below the upper tones, neither at
    /// the black floor nor through the upper tones, which the scans leave neutral.
    static let shadowCast = SIMD2<Float>(-0.045, -0.033)
    /// Oklab chroma relative to lightness over which the crossover fades out: a coloured patch,
    /// however dark, keeps its own colour.
    static let castSaturation: Float = 0.1

    /// A hue-selective correction: a chroma gain and a hue turn in degrees, both fading over a
    /// Gaussian window of `width` degrees about `hue` on the Oklab hue circle.
    struct HueCorrection {
        let hue: Float
        let width: Float
        let chroma: Float
        let turn: Float
    }

    /// The corrections were measured in 30° hue sectors and kept only where the measurements
    /// agree, so there are three broad windows, none narrower than the sectors resolve. They keep
    /// the hue map smooth: neighbouring hues are drawn apart or together by at most a fifth, so a
    /// colour whose hue drifts with its exposure turns steadily rather than in a step.
    static let corrections: [HueCorrection] = [
        HueCorrection(hue: 45, width: 35, chroma: 0.97, turn: 2.3),   // reds, oranges, skin
        HueCorrection(hue: 135, width: 35, chroma: 0.89, turn: 5.5),  // foliage toward teal, muted
        HueCorrection(hue: 240, width: 35, chroma: 1.05, turn: -6.4), // cyans and blues toward cyan
    ]

    /// Oklab chroma over which the corrections fade out. They were measured on colours of
    /// moderate chroma, and the measured turn falls away toward saturated colours, which the scans
    /// hold few of: a saturated yellow keeps its hue rather than turning green. The fade is wide
    /// enough that a colour moving out in chroma turns aside by at most a fifth of its move.
    static let correctionFade: ClosedRange<Float> = 0.08...0.20

    /// The finished colour of a scan pixel, linear Display P3 in and out, `strength` of the way
    /// from the neutral scan. A monochrome scan takes the gradation alone and stays neutral.
    /// `floor` is the scan's no-light luminance, the black the machine times neutral.
    public static func apply(_ colour: SIMD3<Float>, strength: Float = 1,
                             chromatic: Bool = true, floor: Float = 0) -> SIMD3<Float> {
        let strength = strength.isFinite ? min(max(strength, 0), 1) : 1
        guard strength > 0 else { return colour }
        let toned = graded(colour, strength: strength)
        guard chromatic else { return toned }
        var lab = oklab(ColorScience.linearDisplayP3ToSRGB(toned))
        let l = lab.x

        // The crossover, on near-neutral colours: cyan-blue shadows and lower mid-tones. It comes
        // in over a stop from half a stop above the floor, so the black itself, and the output
        // table's cell above it, stay neutral.
        let weights = ColorScience.displayP3LuminanceWeights
        let level = weights.0 * colour.x + weights.1 * colour.y + weights.2 * colour.z
        let onset = floor > 0 ? clamp(log2(max(level, 1e-12) / floor) - 0.5, 0, 1) : 1
        let shadow = clamp((0.70 - l) / 0.40, 0, 1) * clamp((l - 0.04) / 0.16, 0, 1) * onset
        let saturation = (lab.y * lab.y + lab.z * lab.z).squareRoot() / max(l, 1e-3)
        let neutral = l * exp(-saturation / castSaturation)
        let cast = strength * neutral * shadow * shadowCast
        lab.y += cast.x
        lab.z += cast.y

        // The hue corrections, faded out in the deepest shadows, toward white, which a scanner
        // keeps clean, and over saturated colours.
        var chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        var hue = atan2(lab.z, lab.y) * 180 / .pi
        var gain: Float = 1
        var turn: Float = 0
        for correction in corrections {
            var distance = (hue - correction.hue).truncatingRemainder(dividingBy: 360)
            if distance > 180 { distance -= 360 }
            if distance < -180 { distance += 360 }
            let weight = exp(-0.5 * (distance / correction.width) * (distance / correction.width))
            gain *= 1 + strength * (correction.chroma - 1) * weight
            turn += strength * correction.turn * weight
        }
        let saturated = clamp((chroma - correctionFade.lowerBound)
            / (correctionFade.upperBound - correctionFade.lowerBound), 0, 1)
        let fade = clamp(l / 0.25, 0, 1) * clamp((1 - l) / 0.08, 0, 1)
            * (1 - saturated * saturated * (3 - 2 * saturated))
        chroma *= 1 + (gain - 1) * fade
        hue += turn * fade
        let radians = hue * .pi / 180
        lab.y = chroma * cos(radians)
        lab.z = chroma * sin(radians)
        return ColorScience.linearSRGBToDisplayP3(linear(fromOklab: lab))
    }

    /// The gradation alone: luminance re-placed on a steeper print-like curve, hue untouched.
    static func graded(_ colour: SIMD3<Float>, strength: Float = 1) -> SIMD3<Float> {
        let weights = ColorScience.displayP3LuminanceWeights
        let luminance = weights.0 * colour.x + weights.1 * colour.y + weights.2 * colour.z
        guard luminance > 1e-6 else { return colour }
        let level = cbrt(luminance)
        let upper = clamp((level - 0.55) / 0.45, 0, 1)
        let lifted = level + strength * (highlightLift * sin(.pi * upper)
            - blackPull * clamp(1 - level / 0.35, 0, 1))
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

    static func linear(fromOklab lab: SIMD3<Float>) -> SIMD3<Float> {
        let l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let (l3, m3, s3) = (l * l * l, m * m * m, s * s * s)
        return SIMD3(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
                     -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
                     -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
    }
}
