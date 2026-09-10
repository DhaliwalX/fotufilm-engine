// Digitised from Kodak H-1-2383 (March 2022).

import Foundation

/// The release print, digitised from KODAK VISION Color Print Film
/// 2383, Kodak publication H-1-2383 (March 2022), on the 380...780 nm
/// grid at 5 nm steps.
///
/// Like the other release-print media, 2383 is
/// projected, so its scale runs to a D-max of 4.1 where a sheet of
/// RA-4 paper stops near 2.1, and it is what the pack's three
/// motion-picture negatives were exposed to be printed on.
enum Vision2383PrintSpectra {
    /// Diffuse spectral density of the developed cyan, magenta and
    /// yellow dyes, from the sheet's SPECTRAL DYE DENSITY CURVES.
    ///
    /// Unlike E-7020's and AF3-0250U2's, these are drawn at the
    /// amounts that form a visual neutral of density 1.0 under a
    /// xenon-arc viewing illuminant — the plot's own caption — so
    /// dividing them by their pointwise sum in
    /// `SpectralGrid.partition` is a reading rather than a
    /// convention. The sheet draws the neutral too and it was held
    /// out of the calibration: solving it for the three amounts
    /// afterwards returns 1.04, 1.05 and 1.09
    /// of them plus a base of 0.023 D, at 0.0094 D RMS and
    /// 0.0432 D at worst over 400...780 nm.
    ///
    /// Each record holds its end value outside the span the sheet
    /// draws it over, which is 350...744 nm for cyan and 350...713
    /// for the other two.
    static let dyeDensity: [[Float]] = [
        [
            0.285216, 0.29115552, 0.28943843, 0.29127742, 0.28348601, 0.26855635, 0.24977477,
            0.22467377, 0.19675809, 0.16896057, 0.14098481, 0.11733181, 0.095530467, 0.074792026,
            0.067927496, 0.054897711, 0.045792646, 0.038383586, 0.034383216, 0.031869919, 0.030213504,
            0.029555918, 0.0295756, 0.030064671, 0.022535272, 0.03199534, 0.036669666, 0.041419687,
            0.049204842, 0.058324369, 0.07138858, 0.085453163, 0.1030208, 0.12498453, 0.1495748,
            0.17784291, 0.21014077, 0.24878776, 0.288945, 0.33483311, 0.38633829, 0.43821532,
            0.49504746, 0.55538218, 0.61625855, 0.67662172, 0.73695119, 0.79493337, 0.85085582,
            0.90473803, 0.95106636, 0.99112741, 1.0226927, 1.0497904, 1.0696224, 1.0807754,
            1.0861121, 1.08421, 1.0761482, 1.0591202, 1.0358936, 1.0039058, 0.96514468,
            0.92089942, 0.8713099, 0.81755203, 0.76121879, 0.70341994, 0.6452785, 0.58816801,
            0.52927428, 0.47400401, 0.42104647, 0.37594264, 0.37594264, 0.37594264, 0.37594264,
            0.37594264, 0.37594264, 0.37594264, 0.37594264,
        ],
        [
            0.038719656, 0.038897248, 0.04307436, 0.050237023, 0.057141228, 0.064323524, 0.069527385,
            0.072845528, 0.078662227, 0.087943688, 0.093285403, 0.08381529, 0.07085062, 0.074792026,
            0.072611884, 0.087680351, 0.10748231, 0.13224707, 0.16465313, 0.20428134, 0.250322,
            0.30506715, 0.3734502, 0.43359981, 0.50571566, 0.57977716, 0.64949884, 0.70670429,
            0.75468809, 0.79821326, 0.83141925, 0.86023913, 0.87663044, 0.87468144, 0.85609611,
            0.82132882, 0.76797814, 0.69701753, 0.61717216, 0.53014142, 0.44671187, 0.37307604,
            0.30471745, 0.24843, 0.20285495, 0.16449315, 0.13424072, 0.11072251, 0.092284043,
            0.076251178, 0.064235953, 0.056378128, 0.0476718, 0.042373868, 0.024466477, 0.013658537,
            0.013658537, 0.013658537, 0.015379558, 0.017480111, 0.015872531, 0.014286415, 0.013658537,
            0.013658537, 0.020407952, 0.013658537, 0.013658537, 0.013658537, 0.013658537, 0.013658537,
            0.013658537, 0.013658537, 0.013658537, 0.013658537, 0.013658537, 0.013658537, 0.013658537,
            0.013658537, 0.013658537, 0.013658537, 0.013658537,
        ],
        [
            0.20446992, 0.23219762, 0.27430083, 0.3248248, 0.38118694, 0.4443892, 0.50886626,
            0.57633543, 0.6433059, 0.70036091, 0.75145096, 0.78357888, 0.80273514, 0.81227834,
            0.80681611, 0.79230262, 0.766534, 0.72165558, 0.66654903, 0.60120141, 0.53006635,
            0.45821325, 0.38211458, 0.324464, 0.26786784, 0.21555102, 0.17364156, 0.13906128,
            0.11116926, 0.088540727, 0.07138858, 0.059539664, 0.052195795, 0.046308672, 0.041490222,
            0.036819857, 0.032215891, 0.02938532, 0.025512579, 0.022685022, 0.020075516, 0.017911843,
            0.015826883, 0.013658537, 0.020375103, 0.013658537, 0.013658537, 0.013658537, 0.013658537,
            0.013658537, 0.013658537, 0.013658537, 0.013658537, 0.013658537, 0.024466477, 0.031571229,
            0.028528131, 0.0249283, 0.021025091, 0.017480111, 0.015872531, 0.014286415, 0.013658537,
            0.013658537, 0.020407952, 0.013658537, 0.013658537, 0.013658537, 0.013658537, 0.013658537,
            0.013658537, 0.013658537, 0.013658537, 0.013658537, 0.013658537, 0.013658537, 0.013658537,
            0.013658537, 0.013658537, 0.013658537, 0.013658537,
        ],
    ]

    /// Relative sensitivity of the cyan-, magenta- and
    /// yellow-forming layers, from the sheet's SPECTRAL SENSITIVITY
    /// CURVES, raised out of the publication's log scale. Zero
    /// outside each record's printed span — 588...722, 448...579 and
    /// 372...495 nm — which is where `SpectralGrid.continuedTails`
    /// takes over. Those ends are where each record plunges off the
    /// bottom of a four-decade axis, so what is continued past them
    /// is a thousandth of a peak either way.
    static let layerSensitivity: [[Float]] = [
        [
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0.0041385393, 0.0044599654, 0.0051289328, 0.0061705435, 0.0076044565, 0.0092316126,
            0.01148714, 0.013690888, 0.015173941, 0.016521972, 0.017001399, 0.01776166, 0.019073026,
            0.02209281, 0.027965637, 0.036833213, 0.047169426, 0.059018511, 0.072048137, 0.079975617,
            0.082378355, 0.07309468, 0.057437967, 0.039191023, 0.025510729, 0.013780514, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0,
        ],
        [
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0.014680803, 0.021577635, 0.024820525, 0.029384824, 0.035244481, 0.041171782, 0.048674593,
            0.06008911, 0.075336881, 0.087433095, 0.10059697, 0.11154005, 0.11793613, 0.11918321,
            0.12199177, 0.12777691, 0.14521213, 0.18068102, 0.25491065, 0.45502644, 0.59370318,
            0.41377323, 0.18903926, 0.11403305, 0.057739112, 0.032060261, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0,
        ],
        [
            0.77357844, 0.66381691, 0.55627485, 0.48192392, 0.4451041, 0.4685868, 0.51472401,
            0.60492227, 0.73061296, 0.92057797, 1.1699458, 1.3285137, 1.4993288, 1.808395,
            2.2763311, 2.9964221, 3.7731951, 4.1670163, 3.9046888, 2.4671817, 1.2165559,
            0.82470132, 0.44680432, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0,
        ],
    ]

    /// Red Status A record from H-1-2383 (March 2022), PDF p. 4.
    /// Softplus fit: RMS 0.0159 D, worst 0.0479 D. The red and blue
    /// fits reach the gamma bound of 8; these are shape fits, not measured gammas.
    /// Each record is timed at the medium's LAD anchor on its own exposure axis.
    static let redCurve = CharacteristicCurve(
        dMin: 0.075077462, gamma: 8, toe: 1.0037479, toeWidth: 0.18808844, shoulder: 1.5102138, shoulderWidth: 0.19810258)

    /// Green Status A record from H-1-2383 (March 2022), PDF p. 4.
    /// Softplus fit: RMS 0.0180 D, worst 0.0607 D. The red and blue
    /// fits reach the gamma bound of 8; these are shape fits, not measured gammas.
    /// Each record is timed at the medium's LAD anchor on its own exposure axis.
    static let greenCurve = CharacteristicCurve(
        dMin: 0.059956807, gamma: 6.4092376, toe: 0.65255915, toeWidth: 0.21583477, shoulder: 1.2849948, shoulderWidth: 0.20276041)

    /// Blue Status A record from H-1-2383 (March 2022), PDF p. 4.
    /// Softplus fit: RMS 0.0175 D, worst 0.0429 D. The red and blue
    /// fits reach the gamma bound of 8; these are shape fits, not measured gammas.
    /// Each record is timed at the medium's LAD anchor on its own exposure axis.
    static let blueCurve = CharacteristicCurve(
        dMin: 0.1145942, gamma: 8, toe: 0.42881204, toeWidth: 0.21798468, shoulder: 0.92582811, shoulderWidth: 0.17628637)

}
