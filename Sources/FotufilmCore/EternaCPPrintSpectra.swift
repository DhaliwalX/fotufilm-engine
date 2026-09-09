// Digitised from the manufacturer's published spectral-density and sensitivity plots.

import Foundation

/// Fujifilm's release print, read from the ETERNA-CP 3513DI brochure
/// on the 380...780 nm grid at 5 nm steps.
///
/// The only print medium here from a manufacturer other than Kodak,
/// and the one the pack's four Fujifilm motion-picture negatives were
/// actually made to be printed onto. Its dye set is its own: the cyan
/// runs materially heavier than either Kodak print's, which is most of
/// why a Fujifilm positive does not look like a Kodak one.
enum EternaCPPrintSpectra {
    /// Diffuse spectral density of the developed cyan, magenta and
    /// yellow dyes, from the brochure's spectral density curves.
    ///
    /// The held-out Gray is inconsistent with an additive dye-plus-base model:
    /// an unconstrained fit gives amounts 1.03/0.99/0.95 and an intercept of
    /// -0.092 D (0.0174 D RMS, 0.0591 D worst over 400...700 nm).
    /// That intercept is not a physical base and is never added by the renderer.
    /// A shared base counted in each trace is one possible explanation, but the
    /// brochure gives neither a base spectrum nor the Gray's normalization.
    /// Preserve the published traces pending independent evidence; partitioning
    /// or retiming them does not validate their neutral spectral shape.
    ///
    /// Drawn over 400...700 nm only, so each record holds its end
    /// value outside that. What that costs is measured rather than
    /// assumed: holding Kodak 2393's own dye set from 700 nm, whose
    /// real tail is known, moves the printed colour by 1.2e-5,
    /// because the observer and the projection lamp have both gone
    /// to nothing out there.
    static let dyeDensity: [[Float]] = [
        [
            0.38909341, 0.38909341, 0.38909341, 0.38909341, 0.38827872, 0.35786332, 0.33176979,
            0.30980555, 0.29247891, 0.2746029, 0.25430122, 0.23321942, 0.21248548, 0.19289838,
            0.17503944, 0.1593448, 0.14613167, 0.13564853, 0.12770013, 0.12149776, 0.11669148,
            0.11311306, 0.11070619, 0.1094484, 0.10934123, 0.11044327, 0.1127871, 0.11645796,
            0.12157075, 0.12823816, 0.1366208, 0.14693978, 0.15945733, 0.17449629, 0.19256076,
            0.21426495, 0.2405429, 0.27260975, 0.31027185, 0.3525622, 0.39879562, 0.44841205,
            0.50094182, 0.55598888, 0.61318378, 0.67218369, 0.73265908, 0.79426778, 0.85660654,
            0.91917643, 0.98126399, 1.0416924, 1.0980143, 1.1441844, 1.1784553, 1.2026085,
            1.2175172, 1.2235398, 1.2206244, 1.2082568, 1.1854446, 1.1504054, 1.1030949,
            1.0516744, 0.99984432, 0.99984432, 0.99984432, 0.99984432, 0.99984432, 0.99984432,
            0.99984432, 0.99984432, 0.99984432, 0.99984432, 0.99984432, 0.99984432, 0.99984432,
            0.99984432, 0.99984432, 0.99984432, 0.99984432,
        ],
        [
            0.20858974, 0.20858974, 0.20858974, 0.20858974, 0.20841208, 0.19100119, 0.18310618,
            0.18309512, 0.18980327, 0.19729358, 0.19858542, 0.19671379, 0.19175312, 0.18061048,
            0.17267847, 0.17453976, 0.18295724, 0.19770189, 0.21937887, 0.24932437, 0.28602601,
            0.32079376, 0.36950311, 0.43253729, 0.50074954, 0.55512483, 0.59553255, 0.6453897,
            0.71240978, 0.78757165, 0.84005763, 0.87740031, 0.90709742, 0.9252089, 0.92639178,
            0.90448613, 0.85395707, 0.78440408, 0.71599639, 0.64814779, 0.58040785, 0.51241356,
            0.44367018, 0.37297397, 0.30283706, 0.25592314, 0.22384169, 0.19958711, 0.18010872,
            0.16383729, 0.14990377, 0.13776701, 0.12701869, 0.11742666, 0.1088019, 0.1009872,
            0.093854325, 0.08735236, 0.081378544, 0.075879065, 0.070808274, 0.066125193, 0.06179299,
            0.057778508, 0.054276557, 0.054276557, 0.054276557, 0.054276557, 0.054276557, 0.054276557,
            0.054276557, 0.054276557, 0.054276557, 0.054276557, 0.054276557, 0.054276557, 0.054276557,
            0.054276557, 0.054276557, 0.054276557, 0.054276557,
        ],
        [
            0.5042033, 0.5042033, 0.5042033, 0.5042033, 0.50424354, 0.52045821, 0.56147547,
            0.62371784, 0.69051184, 0.74223786, 0.7884319, 0.83226178, 0.86933874, 0.89253631,
            0.9061653, 0.91011524, 0.90285695, 0.88135578, 0.83986777, 0.78256332, 0.72059344,
            0.65533276, 0.58777144, 0.51873914, 0.44906585, 0.3797841, 0.31676714, 0.2715842,
            0.23610336, 0.20670741, 0.18169108, 0.1601201, 0.14139938, 0.1251181, 0.1109812,
            0.098763237, 0.088306572, 0.07947289, 0.072150062, 0.066235923, 0.061661338, 0.058367524,
            0.056297255, 0.055392023, 0.055620032, 0.056956464, 0.059231019, 0.061433732, 0.063390826,
            0.065143958, 0.066709217, 0.068091071, 0.069285521, 0.070279977, 0.07105863, 0.071595404,
            0.071851548, 0.07177639, 0.071292384, 0.070277491, 0.06852656, 0.067014652, 0.067014652,
            0.067014652, 0.067014652, 0.067014652, 0.067014652, 0.067014652, 0.067014652, 0.067014652,
            0.067014652, 0.067014652, 0.067014652, 0.067014652, 0.067014652, 0.067014652, 0.067014652,
            0.067014652, 0.067014652, 0.067014652, 0.067014652,
        ],
    ]

    /// Spectral sensitivity of the cyan-, magenta- and
    /// yellow-forming layers — the brochure's R, G and B curves,
    /// which label the light each layer answers to where Kodak's
    /// sheets label the dye each forms — as linear sensitivity.
    ///
    /// Drawn over 360...780 nm, so unlike the dye set above this one
    /// spans the model's grid and holds nothing. Zero outside the
    /// span each record is drawn over.
    static let layerSensitivity: [[Float]] = [
        [
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 1.7187516, 1.9825475, 2.2262697, 2.4277008, 2.6048788,
            2.8573054, 3.3611583, 3.9462098, 4.635106, 5.5487638, 6.0235852, 6.1250736,
            5.9578631, 5.4747089, 4.5949344, 3.6782694, 2.8234904, 2.0248756, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0,
        ],
        [
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 6.713306, 7.4854211,
            8.546088, 10.162873, 12.323462, 14.932466, 17.335084, 18.379695, 18.462198,
            18.560045, 19.110417, 22.887523, 29.699579, 44.683525, 60.557166, 72.172608,
            47.672436, 17.98121, 6.4796888, 2.3013397, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0,
        ],
        [
            0, 53.769614, 41.293117, 30.730699, 25.408749, 24.588815, 25.892115,
            29.469579, 35.385778, 43.099929, 53.023995, 65.918896, 80.878816, 89.7924,
            105.13354, 141.98206, 211.02939, 342.79383, 536.36737, 480.33726, 227.08042,
            84.050453, 25.853149, 10.046329, 4.4680099, 2.30223, 0, 0,
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

    /// The cyan record of the brochure's characteristic
    /// curves, fitted to the engine's softplus H&D family at RMS 0.0068 D
    /// (worst 0.0222 D), reaching 3.893 D.
    ///
    /// Its position along the exposure axis carries no meaning:
    /// the sheet holds its three records apart so they can be
    /// read, and prints no absolute exposure anywhere. The engine
    /// anchors each record at its own midpoint, which absorbs that
    /// exactly — what is calibrated here is the shape and the
    /// scale, and both are the sheet's own.
    static let cyanCurve = CharacteristicCurve(
        dMin: 0.0790849, gamma: 8.26487, toe: 3.33869, toeWidth: 0.209914, shoulder: 3.80009, shoulderWidth: 0.137617)

    /// The magenta record of the brochure's characteristic
    /// curves, fitted to the engine's softplus H&D family at RMS 0.0089 D
    /// (worst 0.0232 D), reaching 4.189 D.
    ///
    /// Its position along the exposure axis carries no meaning:
    /// the sheet holds its three records apart so they can be
    /// read, and prints no absolute exposure anywhere. The engine
    /// anchors each record at its own midpoint, which absorbs that
    /// exactly — what is calibrated here is the shape and the
    /// scale, and both are the sheet's own.
    static let magentaCurve = CharacteristicCurve(
        dMin: 0.0875284, gamma: 4.64109, toe: 2.03554, toeWidth: 0.226543, shoulder: 2.91917, shoulderWidth: 0.140043)

    /// The yellow record of the brochure's characteristic
    /// curves, fitted to the engine's softplus H&D family at RMS 0.0162 D
    /// (worst 0.0414 D), reaching 3.930 D.
    ///
    /// Its position along the exposure axis carries no meaning:
    /// the sheet holds its three records apart so they can be
    /// read, and prints no absolute exposure anywhere. The engine
    /// anchors each record at its own midpoint, which absorbs that
    /// exactly — what is calibrated here is the shape and the
    /// scale, and both are the sheet's own.
    static let yellowCurve = CharacteristicCurve(
        dMin: 0.135715, gamma: 7.96541, toe: 1.42302, toeWidth: 0.27466, shoulder: 1.88654, shoulderWidth: 0.0956655)
}
