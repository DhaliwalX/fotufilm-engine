import Foundation

/// The print stocks the engine ships.
///
/// Each descriptor reads its datasheet values from the generated `…Spectra` file named in it.
/// Those files are written by the calibration extractors and must not be edited by hand; this
/// file holds everything that is not generated. See docs/print-stocks.md.
extension PrintStock {
    /// KODAK EKTACOLOR EDGE Paper (E-7020), measured. Its spectra also stand in wherever an
    /// output needs a neutral visual judge but has no dyes of its own.
    static let ektacolorEdge = PrintStock(
        name: "Kodak Ektacolor Edge Paper",
        detail: "Kodak photo paper with a slightly warm color balance.",
        process: .photoPaper,
        curves: [EktacolorEdgeCurves.red, EktacolorEdgeCurves.green, EktacolorEdgeCurves.blue],
        spectra: Spectra(dyeDensity: PrintPaperSpectra.dyeDensity,
                         neutralAmounts: PrintPaperSpectra.neutralAmounts,
                         layerSensitivity: PrintPaperSpectra.layerSensitivity,
                         process: .photoPaper))

    /// KODAK PROFESSIONAL ENDURA Premier Paper (E-4070), measured.
    static let enduraPremier = PrintStock(
        name: "Kodak Professional Endura Premier Paper",
        detail: "Kodak photo paper with saturated colors and deep blacks.",
        process: .photoPaper,
        curves: [EnduraPremierPaperSpectra.redCurve, EnduraPremierPaperSpectra.greenCurve,
                 EnduraPremierPaperSpectra.blueCurve],
        spectra: Spectra(dyeDensity: EnduraPremierPaperSpectra.dyeDensity,
                         neutralAmounts: EnduraPremierPaperSpectra.neutralAmounts,
                         layerSensitivity: EnduraPremierPaperSpectra.layerSensitivity,
                         process: .photoPaper))

    /// Fujicolor Crystal Archive Type CA (AF3-0250U2), measured.
    ///
    /// AF3-0250U2 provides no characteristic curve. All three records use the Ektacolor Edge
    /// green record rather than assigning unmeasured Kodak red/blue differences to Fuji paper.
    static let crystalArchive = PrintStock(
        name: "Fujicolor Crystal Archive Paper Type CA",
        detail: "Fujifilm photo paper with a cooler color balance than Ektacolor Edge.",
        process: .photoPaper,
        curves: Array(repeating: EktacolorEdgeCurves.green, count: 3),
        spectra: Spectra(dyeDensity: CrystalArchivePaperSpectra.dyeDensity,
                         neutralAmounts: CrystalArchivePaperSpectra.neutralAmounts,
                         layerSensitivity: CrystalArchivePaperSpectra.layerSensitivity,
                         process: .photoPaper))

    /// KODAK VISION Color Print Film 2383 (H-1-2383), measured. Setup aims from the sheet's
    /// LAD section; sensitivity measured at a gross density of 1.0.
    static let vision2383 = PrintStock(
        name: "Kodak Vision Color Print Film 2383",
        detail: "Kodak cinema print film with stronger contrast than photo paper.",
        process: .releasePrintFilm,
        curves: [Vision2383PrintSpectra.redCurve, Vision2383PrintSpectra.greenCurve,
                 Vision2383PrintSpectra.blueCurve],
        spectra: Spectra(dyeDensity: Vision2383PrintSpectra.dyeDensity,
                         layerSensitivity: Vision2383PrintSpectra.layerSensitivity,
                         process: .releasePrintFilm),
        releaseSetup: ReleaseSetup(ladStatusA: SIMD3(1.09, 1.06, 1.03),
                                   sensitivityAboveMinimum: false))

    /// KODAK VISION Premier Color Print Film 2393 (H-1-2393t), measured. Setup aims from the
    /// sheet's LAD section; sensitivity measured at a gross density of 1.0.
    ///
    /// Its dyes are partitioned without a `neutralAmounts` multiply for the same reason 2383's
    /// are: the sheet draws them at the amounts that already make a neutral, and solving its
    /// printed neutral for those amounts returns 1.00, 1.00 and 1.07 of them.
    static let vision2393 = PrintStock(
        name: "Kodak Vision Premier Color Print Film 2393",
        detail: "Kodak cinema print film with deeper blacks and stronger color than 2383, but less shadow detail.",
        process: .releasePrintFilm,
        curves: [Vision2393PrintSpectra.redCurve, Vision2393PrintSpectra.greenCurve,
                 Vision2393PrintSpectra.blueCurve],
        spectra: Spectra(dyeDensity: Vision2393PrintSpectra.dyeDensity,
                         layerSensitivity: Vision2393PrintSpectra.layerSensitivity,
                         process: .releasePrintFilm),
        releaseSetup: ReleaseSetup(ladStatusA: SIMD3(1.09, 1.06, 1.03),
                                   sensitivityAboveMinimum: false))

    /// FUJIFILM ETERNA-CP Color Positive Film 3513DI, measured. Setup aims from the brochure's
    /// "Aim Print Density"; Fuji states its sensitivity at 1.0 above minimum density.
    ///
    /// Fujifilm draws its three records apart along the exposure axis and prints no absolute
    /// exposure at all, so only their shapes are read. The engine anchors each record at its
    /// own midpoint, which is what makes that enough — see the extractor's note. The dye traces
    /// are kept as published: the held-out Gray requires a negative residual intercept, which is
    /// unresolved source inconsistency, not evidence of a physical neutral-forming dye ratio.
    static let eternaCP = PrintStock(
        name: "Fujifilm ETERNA-CP Color Positive Film 3513DI",
        detail: "Fujifilm cinema print film with a cooler color balance and softer contrast than Kodak print films.",
        process: .releasePrintFilm,
        curves: [EternaCPPrintSpectra.cyanCurve, EternaCPPrintSpectra.magentaCurve,
                 EternaCPPrintSpectra.yellowCurve],
        spectra: Spectra(dyeDensity: EternaCPPrintSpectra.dyeDensity,
                         layerSensitivity: EternaCPPrintSpectra.layerSensitivity,
                         process: .releasePrintFilm),
        releaseSetup: ReleaseSetup(ladStatusA: SIMD3(1.10, 1.05, 1.05),
                                   sensitivityAboveMinimum: true))

    /// Ilfochrome Classic CPS.1K (Cibachrome), normal contrast. See `IlfochromeCurves`.
    static let ilfochromeCPS1K = PrintStock(
        name: "Ilfochrome Classic CPS.1K (Cibachrome)",
        detail: "Normal-contrast positive paper for slide film. Approximate color response; more paper exposure lightens the print.",
        process: .positivePaper,
        curves: Array(repeating: IlfochromeCurves.normal, count: 3),
        spectra: PrintStock.ektacolorEdge.spectra)

    /// Ilfochrome Classic CLM.1K (Cibachrome), medium contrast. See `IlfochromeCurves`.
    static let ilfochromeCLM1K = PrintStock(
        name: "Ilfochrome Classic CLM.1K (Cibachrome)",
        detail: "Medium-contrast positive paper for slide film, softer than CPS.1K. Approximate color response.",
        process: .positivePaper,
        curves: Array(repeating: IlfochromeCurves.medium, count: 3),
        spectra: PrintStock.ektacolorEdge.spectra)
}

/// KODAK EKTACOLOR EDGE records from E-7020 page 3, fitted by `extract_fit.py`, each named
/// by the label printed beside its end: green is the top curve at log E 0, blue the bottom.
/// RMS errors are 0.0129 D green, 0.0116 D red, and 0.0036 D blue. Green's worst, 0.077 D,
/// is past log E -0.4, where the sheet keeps rising to 2.37 D and one shoulder levels at
/// 2.30. Red and green use the smallest gamma within 0.0005 D of the degenerate fit minimum.
enum EktacolorEdgeCurves {
    static let green = CharacteristicCurve(
        dMin: 0.094, gamma: 8.5,
        toe: -1.493, toeWidth: 0.154, shoulder: -1.234, shoulderWidth: 0.184)
    static let red = CharacteristicCurve(
        dMin: 0.089, gamma: 9.5,
        toe: -1.480, toeWidth: 0.142, shoulder: -1.253, shoulderWidth: 0.153)
    static let blue = CharacteristicCurve(
        dMin: 0.051, gamma: 5.851,
        toe: -1.541, toeWidth: 0.145, shoulder: -1.182, shoulderWidth: 0.152)
}

/// Ilford TDS 307US (August 2003), p. 1: CPS.1K has visual density range 2.0
/// and mid-tone contrast 1.40; CLM.1K has 2.05 and 1.15. The sheet does not
/// publish channel curves, dye spectra or layer sensitivities. Use equal records,
/// a soft toe/shoulder approximation and explicitly provisional RA-4 receiver spectra.
/// No claim is made to measured Ilfochrome color or a separate Cibachrome emulsion.
/// https://www.bonavolta.ch/hobby/files/Ilfochrome_CPS_CLM_E.pdf
enum IlfochromeCurves {
    static let normal = curve(range: 2.0, contrast: 1.40)
    static let medium = curve(range: 2.05, contrast: 1.15)

    private static func curve(range: Float, contrast: Float) -> CharacteristicCurve {
        // A symmetric soft toe/shoulder with width 10% of their separation. Correct the
        // asymptotic gamma so the actual center slope equals the published mid-tone value.
        let gamma = contrast / tanh(Float(2.5))
        let span = range / gamma
        return CharacteristicCurve(dMin: 0, gamma: gamma,
            toe: -span / 2, toeWidth: span / 10,
            shoulder: span / 2, shoulderWidth: span / 10)
    }
}
