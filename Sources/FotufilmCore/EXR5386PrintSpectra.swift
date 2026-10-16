// Spectral curves digitized from the manufacturer's published data sheet.

import Foundation

/// The EXR-era release print, read from EASTMAN EXR Color Print Film
/// 5386, Kodak publication H-1-5386 (February 1999), on the 380...780 nm
/// grid at 5 nm steps.
///
/// The print 2383 replaced. Every plot on the sheet's page 3 is vector
/// artwork, so the numbers below are the publisher's own polylines with
/// no tracing step between the drawing and the table.
enum EXR5386PrintSpectra {
    /// Diffuse spectral density of the developed cyan, magenta and
    /// yellow dyes, from the sheet's SPECTRAL-DYE-DENSITY CURVES.
    ///
    /// Drawn, like 2383's, at the amounts that form the visual neutral the
    /// sheet draws beside them, so `SpectralGrid.partition` reads them rather
    /// than imposing a convention. That neutral was held out of the
    /// calibration: solving it afterwards returns
    /// 1.00, 1.01 and 0.99 of the three plus -0.005 D, at
    /// 0.0056 D RMS and 0.0179 D at worst over 400...698 nm.
    ///
    /// The plot's density ticks are placed by hand, up to 3 pt from even
    /// spacing, so its axis is the least-squares line through all four.
    /// It reads the yellow tail down to -0.0017 D, inside that line's
    /// own error, and the table floors it at zero.
    /// Drawn over 400...698 nm; each record holds its end value outside that.
    /// Continuing 2383's tails past 700 nm instead moves a Status A red reading
    /// by at most 0.002 D at 3 D: 0.07% of that band lies beyond 700 nm.
    static let dyeDensity: [[Float]] = [
        [
            0.31044844, 0.31044844, 0.31044844, 0.31044844, 0.30824761, 0.28228098, 0.25617375,
            0.22994363, 0.20359865, 0.17729679, 0.15143699, 0.12665583, 0.10395802, 0.084068607,
            0.067051257, 0.052906798, 0.041461987, 0.032960932, 0.028152778, 0.02637935, 0.027012107,
            0.029020725, 0.032166787, 0.036359396, 0.041600363, 0.048210231, 0.056251532, 0.065972204,
            0.077453388, 0.09101676, 0.10689634, 0.12540475, 0.14690631, 0.17162773, 0.19972744,
            0.23141814, 0.26671444, 0.30586123, 0.34920749, 0.39709166, 0.44987153, 0.50749821,
            0.56930881, 0.63454528, 0.70224901, 0.77148664, 0.84059766, 0.90802582, 0.97213051,
            1.0314919, 1.0851529, 1.1320149, 1.1711823, 1.2015372, 1.222611, 1.2347528,
            1.2392079, 1.2356052, 1.2235019, 1.2023483, 1.1729712, 1.1374029, 1.0960623,
            1.0508107, 1.0193087, 1.0193087, 1.0193087, 1.0193087, 1.0193087, 1.0193087,
            1.0193087, 1.0193087, 1.0193087, 1.0193087, 1.0193087, 1.0193087, 1.0193087,
            1.0193087, 1.0193087, 1.0193087, 1.0193087,
        ],
        [
            0.084440056, 0.084440056, 0.084440056, 0.084440056, 0.085055008, 0.092310581, 0.098857728,
            0.10455899, 0.1091954, 0.1126026, 0.11467924, 0.11524504, 0.11532325, 0.11597861,
            0.11943556, 0.12995974, 0.15117161, 0.18061138, 0.21648879, 0.25831833, 0.30623701,
            0.36066409, 0.42039558, 0.48373778, 0.54904474, 0.61476272, 0.67922856, 0.74081968,
            0.79788863, 0.84849538, 0.88979659, 0.91887877, 0.93288109, 0.92987339, 0.90998044,
            0.87367437, 0.82147126, 0.75524667, 0.67941716, 0.59883068, 0.51833487, 0.44174278,
            0.37083837, 0.30704337, 0.25183316, 0.20581554, 0.16805902, 0.13747394, 0.11293411,
            0.093406229, 0.07799855, 0.065917381, 0.056355259, 0.048750788, 0.042410103, 0.036902967,
            0.031834664, 0.026913283, 0.022390102, 0.018268333, 0.014673112, 0.011419859, 0.0085905242,
            0.0059896364, 0.0042852836, 0.0042852836, 0.0042852836, 0.0042852836, 0.0042852836, 0.0042852836,
            0.0042852836, 0.0042852836, 0.0042852836, 0.0042852836, 0.0042852836, 0.0042852836, 0.0042852836,
            0.0042852836, 0.0042852836, 0.0042852836, 0.0042852836,
        ],
        [
            0.46454175, 0.46454175, 0.46454175, 0.46454175, 0.46988732, 0.53295749, 0.59367546,
            0.65175695, 0.70639722, 0.75655671, 0.80139832, 0.83886261, 0.86890627, 0.88769645,
            0.89040869, 0.87892136, 0.84890974, 0.80462974, 0.7523371, 0.69535936, 0.63391384,
            0.56503476, 0.49077153, 0.41886804, 0.35267961, 0.29250328, 0.23825385, 0.18984255,
            0.14769145, 0.11242371, 0.083560512, 0.060556335, 0.042770098, 0.029595998, 0.02019235,
            0.01366373, 0.0091930647, 0.0060638285, 0.0038951375, 0.0024310342, 0.0013436397, 0.00041931953,
            0, 0, 0, 0, 0, 0, 0,
            5.7699351e-05, 0.001080384, 0.0021720167, 0.0032176329, 0.0042286538, 0.0053582364, 0.0066711591,
            0.0083369909, 0.010319587, 0.012394422, 0.014338762, 0.016174346, 0.017922238, 0.019472976,
            0.020874205, 0.021785529, 0.021785529, 0.021785529, 0.021785529, 0.021785529, 0.021785529,
            0.021785529, 0.021785529, 0.021785529, 0.021785529, 0.021785529, 0.021785529, 0.021785529,
            0.021785529, 0.021785529, 0.021785529, 0.021785529,
        ],
    ]

    /// Relative sensitivity of the cyan-, magenta- and yellow-forming
    /// layers, from the sheet's SPECTRAL-SENSITIVITY CURVES (density 1.0,
    /// ECP-2B), raised out of the publication's log scale.
    ///
    /// The sheet also draws the cyan- and magenta-forming layers' response
    /// in the blue. Each layer keeps only the lobe it is in the film to
    /// record, bounded by the trough that separates it from that response:
    /// 529...731, 439...591 and 400...501 nm. Zero outside those,
    /// where `SpectralGrid.continuedTails` takes over.
    static let layerSensitivity: [[Float]] = [
        [
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0.0010929769, 0.0013151437, 0.0015373105, 0.0017594773, 0.0019816441,
            0.0023102508, 0.0026792109, 0.0030481709, 0.003417131, 0.0039879646, 0.0045911934, 0.0055694236,
            0.0066097536, 0.0076788034, 0.0087527577, 0.010857354, 0.013142619, 0.015304224, 0.017443501,
            0.019933035, 0.022489149, 0.025383218, 0.028343351, 0.031596735, 0.034909038, 0.039276158,
            0.043860239, 0.052848714, 0.062767492, 0.074630886, 0.086925985, 0.088162214, 0.083984516,
            0.077839395, 0.063213336, 0.050560171, 0.038065696, 0.028455621, 0.019490772, 0.013585559,
            0.0089247603, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0,
        ],
        [
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0.022277352, 0.024054218,
            0.028192113, 0.034144833, 0.041886245, 0.0514275, 0.062489189, 0.07452077, 0.088036026,
            0.10397081, 0.12162908, 0.13905324, 0.15601424, 0.17345509, 0.19023858, 0.204324,
            0.2144738, 0.22055989, 0.22499253, 0.23154155, 0.2434372, 0.26313605, 0.28573738,
            0.29902642, 0.27996683, 0.21551311, 0.1316596, 0.066733634, 0.030396475, 0.012989221,
            0.0053999653, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0,
        ],
        [
            0, 0, 0, 0, 0, 1.0346166, 1.104708,
            1.237224, 1.4600746, 1.7704615, 2.133889, 2.4786825, 2.8305641, 3.2904388,
            3.9979726, 5.0790681, 6.0594545, 5.9725518, 4.5700304, 2.5955476, 1.0648056,
            0.37293673, 0.11123058, 0.038263545, 0.014123049, 0, 0, 0,
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

    /// The red record of the sheet's CHARACTERISTIC CURVES (tungsten 1/100 s, ECP-2B,
    /// Status A), fitted to the engine's softplus H&D family at RMS 0.0060 D (worst 0.0144 D)
    /// from the 0.040 D foot the sheet draws, reaching 3.846 D.
    static let redCurve = CharacteristicCurve(
        dMin: 0.0399614, gamma: 14.8, toe: 0.863502, toeWidth: 0.215382, shoulder: 1.12064, shoulderWidth: 0.216755)

    /// The green record of the sheet's CHARACTERISTIC CURVES (tungsten 1/100 s, ECP-2B,
    /// Status A), fitted to the engine's softplus H&D family at RMS 0.0076 D (worst 0.0182 D)
    /// from the 0.040 D foot the sheet draws, reaching 3.888 D.
    static let greenCurve = CharacteristicCurve(
        dMin: 0.0399614, gamma: 4.75, toe: 0.569059, toeWidth: 0.200119, shoulder: 1.37924, shoulderWidth: 0.189159)

    /// The blue record of the sheet's CHARACTERISTIC CURVES (tungsten 1/100 s, ECP-2B,
    /// Status A), fitted to the engine's softplus H&D family at RMS 0.0087 D (worst 0.0222 D)
    /// from the 0.120 D foot the sheet draws, reaching 3.981 D.
    static let blueCurve = CharacteristicCurve(
        dMin: 0.119958, gamma: 4.4, toe: 0.569546, toeWidth: 0.192864, shoulder: 1.44707, shoulderWidth: 0.161191)
}
