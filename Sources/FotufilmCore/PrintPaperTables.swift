import Foundation

/// The measurements each print medium is read through. `PrintPaper` is the
/// choice; this is what the choice resolves to.
extension PrintPaper {
    /// Viewing dye spectra normalized for flat neutral density. The digital reference uses the
    /// measured RA-4 dye basis only to retain the negative-to-positive spectral coupling; it is
    /// not presented as a measured display or a physical sheet. Negative output bypasses this
    /// positive-medium table, so its entry is only unreachable scaffolding for exhaustive access.
    var dyes: [[Float]] {
        switch self {
        case .ektacolorEdge, .screen, .negative: return SpectralGrid.paperDyes
        case .enduraPremier: return SpectralGrid.enduraPremierDyes
        case .crystalArchive: return SpectralGrid.crystalArchiveDyes
        case .vision2383: return SpectralGrid.vision2383Dyes
        case .vision2393: return SpectralGrid.vision2393Dyes
        case .eternaCP: return SpectralGrid.eternaCPDyes
        // A scan has no physical viewing dyes. The balance solve and Telecine's calibrated
        // colour-timing reference still need a neutral visual judge, so the RA-4 set stands in.
        case .labScan, .telecine: return SpectralGrid.paperDyes
        }
    }

    /// The sheet's own dye shapes at its neutral-forming amounts, before `partition` divides
    /// them by their pointwise sum. What a spectrum is composed from once a Status A reading has
    /// been unmixed; `dyes` stays the partitioned basis the neutral axis is built on.
    var analyticalDyes: [[Float]] {
        switch self {
        case .ektacolorEdge, .screen, .negative, .labScan, .telecine:
            return SpectralGrid.paperDyeAmounts
        case .enduraPremier: return SpectralGrid.enduraPremierDyeAmounts
        case .crystalArchive: return SpectralGrid.crystalArchiveDyeAmounts
        case .vision2383: return SpectralGrid.vision2383DyeAmounts
        case .vision2393: return SpectralGrid.vision2393DyeAmounts
        case .eternaCP: return SpectralGrid.eternaCPDyeAmounts
        }
    }

    /// Layer sensitivities with publication tails extended. Release prints preserve the
    /// publication's inter-layer speed scale: it determines the additive printer's beam mix.
    /// Per-layer normalization is harmless only for paths without a spectral timing solve.
    /// Screen and negative output bypass paper exposure.
    var sensitivity: [[Float]] {
        switch self {
        case .ektacolorEdge, .screen, .negative: return SpectralGrid.paperSensitivity
        case .enduraPremier: return SpectralGrid.enduraPremierSensitivity
        case .crystalArchive: return SpectralGrid.crystalArchiveSensitivity
        case .vision2383: return SpectralGrid.vision2383Sensitivity
        case .vision2393: return SpectralGrid.vision2393Sensitivity
        case .eternaCP: return SpectralGrid.eternaCPSensitivity
        case .labScan: return SpectralGrid.labScanSensitivity
        case .telecine: return SpectralGrid.telecineSensitivity
        }
    }

    /// Gross Status A setup aims, not densities above clear film. Kodak H-1-2383t and
    /// H-1-2393t, LAD sections; Fujifilm ETERNA-CP 3513DI brochure, "Aim Print Density".
    /// These instrument readings must not be replaced by three equal density values or
    /// by an RGB-neutralizing correction after development.
    var ladStatusA: SIMD3<Float>? {
        switch self {
        case .vision2383, .vision2393: return SIMD3(1.09, 1.06, 1.03)
        case .eternaCP: return SIMD3(1.10, 1.05, 1.05)
        default: return nil
        }
    }

    /// Density at which the published reciprocal-exposure sensitivity was measured.
    /// Kodak labels D = 1.0; Fuji explicitly states 1.0 above minimum density.
    func sensitivityReferenceExposures(for stock: FilmStock) -> [Float] {
        precondition(isProjected)
        return printCurves(for: stock).map {
            $0.logExposure(density: self == .eternaCP ? $0.dMin + 1 : 1)
        }
    }

    /// Fixed printer exposure-axis origins. Reflection paper is visually balanced under its
    /// reference lamp; cine film uses the published gross LAD aims. Viewing another lamp
    /// cannot move these exposures. Monochrome retains the single-record neutral convention.
    func printExposureMidpoints(for stock: FilmStock) -> [Float] {
        let curves = printCurves(for: stock)
        if let aim = ladStatusA, !stock.isMonochrome, !stock.isReversal {
            return (0..<3).map { curves[$0].logExposure(density: aim[$0]) }
        }
        let offset = acceptsViewingIlluminant && !stock.isMonochrome && !stock.isReversal
            ? SpectralRuntime.reflectionPrintDensityTrim(for: self) : .zero
        return (0..<3).map {
            curves[$0].logExposure(density: curves[$0].dMin + anchorDensity + offset[$0])
        }
    }

    /// Sensitivity-weighted energy needed at setup, relative to each record's published
    /// sensitivity reference. Only a common multiplier is arbitrary; record ratios are not.
    func printingAim(for stock: FilmStock) -> SIMD3<Float> {
        let midpoints = printExposureMidpoints(for: stock)
        let reference = sensitivityReferenceExposures(for: stock)
        return SIMD3((0..<3).map { pow(10, midpoints[$0] - reference[$0]) })
    }

    /// The characteristic curve the print's timing is reckoned against: the
    /// green record where the sheet publishes three, which is the record a
    /// printer times and filters to. `screen` is not a material: its
    /// `paperCurve` is the density scale a direct read is normalized onto,
    /// not a claim about paper.
    func printCurve(for stock: FilmStock) -> CharacteristicCurve {
        printCurves(for: stock)[1]
    }

    /// The characteristic curves the print's three records develop along, in
    /// the engine's red/green/blue channel order — the cyan-, magenta- and
    /// yellow-forming layers as read through red, green and blue filters. A
    /// sheet that publishes one curve develops all three records along it,
    /// which is exactly the single-curve stage this generalizes.
    func printCurves(for stock: FilmStock) -> [CharacteristicCurve] {
        guard !stock.isReversal else {
            return [stock.paperCurve, stock.paperCurve, stock.paperCurve]
        }
        // A monochrome negative prints through one exposure and the engine
        // forces its output neutral, so the model's stance is the timing
        // record — the green curve — three times. Per-record spread would be
        // unreachable in the render and only skew the analytic mirrors.
        if stock.isMonochrome {
            let timing = colourRecords(for: stock)[1]
            return [timing, timing, timing]
        }
        return colourRecords(for: stock)
    }

    private func colourRecords(for stock: FilmStock) -> [CharacteristicCurve] {
        switch self {
        case .ektacolorEdge:
            return [PrintPaper.ra4PrintCurveRed, PrintPaper.ra4PrintCurve,
                    PrintPaper.ra4PrintCurveBlue]
        case .enduraPremier:
            return [EnduraPremierPaperSpectra.redCurve,
                    EnduraPremierPaperSpectra.greenCurve,
                    EnduraPremierPaperSpectra.blueCurve]
        case .crystalArchive:
            // AF3-0250U2 provides no characteristic curve. Use the RA-4 green record for all three
            // channels rather than assigning unmeasured Kodak red/blue differences to Fuji paper.
            return [PrintPaper.ra4PrintCurve, PrintPaper.ra4PrintCurve,
                    PrintPaper.ra4PrintCurve]
        case .screen, .negative:
            return [stock.paperCurve, stock.paperCurve, stock.paperCurve]
        case .vision2383:
            return [Vision2383PrintSpectra.redCurve,
                    Vision2383PrintSpectra.greenCurve,
                    Vision2383PrintSpectra.blueCurve]
        case .vision2393:
            return [Vision2393PrintSpectra.redCurve,
                    Vision2393PrintSpectra.greenCurve,
                    Vision2393PrintSpectra.blueCurve]
        // Fujifilm draws its three records apart along the exposure axis and
        // prints no absolute exposure at all, so only their shapes are read.
        // The engine anchors each record at its own midpoint, which is what
        // makes that enough — see the extractor's note.
        case .eternaCP:
            return [EternaCPPrintSpectra.cyanCurve,
                    EternaCPPrintSpectra.magentaCurve,
                    EternaCPPrintSpectra.yellowCurve]
        case .labScan:
            return [PrintPaper.labScanCurve, PrintPaper.labScanCurve,
                    PrintPaper.labScanCurve]
        case .telecine:
            return [PrintPaper.telecineCurve, PrintPaper.telecineCurve,
                    PrintPaper.telecineCurve]
        }
    }

    /// KODAK EKTACOLOR EDGE records from E-7020 page 3, fitted by `extract_fit.py`.
    /// RMS errors are 0.0036 D green, 0.0116 D red, and 0.0067 D blue. Red and blue use the
    /// smallest gamma within 0.0005 D of the degenerate fit minimum.
    static let ra4PrintCurve = CharacteristicCurve(
        dMin: 0.051, gamma: 5.851,
        toe: -1.541, toeWidth: 0.145, shoulder: -1.182, shoulderWidth: 0.152)
    static let ra4PrintCurveRed = CharacteristicCurve(
        dMin: 0.089, gamma: 9.5,
        toe: -1.480, toeWidth: 0.142, shoulder: -1.253, shoulderWidth: 0.153)
    static let ra4PrintCurveBlue = CharacteristicCurve(
        dMin: 0.090, gamma: 8.5,
        toe: -1.479, toeWidth: 0.155, shoulder: -1.222, shoulderWidth: 0.176)

    /// Minilab inversion on the RA-4 log-exposure axis, keeping the paper's toe and shoulder
    /// positions. A digital inversion has no dye D-max and sets its own black and white points, so
    /// the range and the highlight roll-off are the scan's own, fitted against 166 same-lab
    /// daylight minilab scans: their median 0.1 percentile is 0.00202 of display white and their
    /// median 1st percentile is 0.0208 of the frame's own median, which this reproduces at
    /// 0.00241 and 0.0234 over fifteen rendered scenes.
    static let labScanCurve = CharacteristicCurve(
        dMin: 0.051, gamma: 7.5,
        toe: -1.541, toeWidth: 0.11, shoulder: -1.182, shoulderWidth: 0.152)

    /// Telecine inversion on the RA-4 log-exposure axis. Gamma is 5.7, D-max is 2.10, and the
    /// 0.12 shoulder represents film white at 86 IRE with headroom to 100 IRE. The shared
    /// mid-grey anchor takes precedence over the composite-video LAD convention of 49 IRE.
    static let telecineCurve = CharacteristicCurve(
        dMin: 0.051, gamma: 5.7,
        toe: -1.541, toeWidth: 0.16, shoulder: -1.182, shoulderWidth: 0.12)

    /// Fixed lab-scan profile solved from Portra 400. Regenerate with
    /// `FOTUFILM_STOCKS=stocks-private fotufilm --dump-labscan-reference portra400` after changing
    /// the reference stock, scan sensitivities, or balance solve. `labScanReferenceMidRatio` is
    /// log10(red/green, blue/green) at mid-grey; `labScanReferenceBalance` is the printing balance.
    static let labScanReferenceMidRatio = SIMD2<Float>(0.5609019, -0.444564)
    static let labScanReferenceBalance: [Float] = [1.0579212, 1.0, 0.880968]

    /// Maximum retained cast magnitude in log paper exposure. What a viewer sees is this offset
    /// carried through `labScanCurve`'s own slope at the mid anchor, so the ceiling has to be
    /// refitted whenever that curve is: the gamma 4.4 → 7.5 refit more than doubled that slope
    /// (1.81 → 4.00 D per decade) and left every stock scanning at up to 0.19 D off neutral.
    ///
    /// Refitted 2026-08-29 against the same-lab corpus of 163 minilab scans, on the paired
    /// engine-vs-real Δ Oklab b the original fit used. Over the four stocks that corpus can call
    /// (Ultramax, C200, Superia, CineStill 400D) the median engine/real ratio is 1.02 on the mids
    /// band and 1.00 globally; the two axes cross 1.0 together here.
    static let labScanCastCeiling: Float = 0.029
}

extension SpectralGrid {
    /// KODAK PROFESSIONAL ENDURA Premier Paper (E-4070), from Kodak publication E-4070.
    static let enduraPremierDyeAmounts: [[Float]] =
        zip(EnduraPremierPaperSpectra.dyeDensity,
            EnduraPremierPaperSpectra.neutralAmounts)
            .map { record, amount in record.map { $0 * amount } }
    static let enduraPremierDyes: [[Float]] = partition(enduraPremierDyeAmounts)
    static let enduraPremierSensitivity: [[Float]] =
        normalizeSensitivities(EnduraPremierPaperSpectra.layerSensitivity
            .map(continuedTails))

    /// Fujicolor Crystal Archive Type CA, from AF3-0250U2.
    static let crystalArchiveDyeAmounts: [[Float]] =
        zip(CrystalArchivePaperSpectra.dyeDensity,
            CrystalArchivePaperSpectra.neutralAmounts)
            .map { record, amount in record.map { $0 * amount } }
    static let crystalArchiveDyes: [[Float]] = partition(crystalArchiveDyeAmounts)
    static let crystalArchiveSensitivity: [[Float]] =
        normalizeSensitivities(CrystalArchivePaperSpectra.layerSensitivity
            .map(continuedTails))

    /// KODAK VISION Color Print Film 2383, from H-1-2383.
    static let vision2383DyeAmounts: [[Float]] = Vision2383PrintSpectra.dyeDensity
    static let vision2383Dyes: [[Float]] = partition(vision2383DyeAmounts)
    static let vision2383Sensitivity: [[Float]] =
        Vision2383PrintSpectra.layerSensitivity.map(continuedTails)

    /// KODAK VISION Premier Color Print Film 2393, from its own curve sheets.
    /// Partitioned without a `neutralAmounts` multiply for the same reason
    /// 2383 is: the sheet draws these dyes at the amounts that already make a
    /// neutral, and solving its printed neutral for those amounts returns
    /// 1.00, 1.00 and 1.07 of them.
    static let vision2393DyeAmounts: [[Float]] = Vision2393PrintSpectra.dyeDensity
    static let vision2393Dyes: [[Float]] = partition(vision2393DyeAmounts)
    static let vision2393Sensitivity: [[Float]] =
        Vision2393PrintSpectra.layerSensitivity.map(continuedTails)

    /// FUJIFILM ETERNA-CP 3513DI, preserving the brochure's published dye traces.
    /// Its held-out Gray requires a negative residual intercept; this is unresolved
    /// source inconsistency, not evidence of a physical neutral-forming dye ratio.
    static let eternaCPDyeAmounts: [[Float]] = EternaCPPrintSpectra.dyeDensity
    static let eternaCPDyes: [[Float]] = partition(eternaCPDyeAmounts)
    static let eternaCPSensitivity: [[Float]] =
        EternaCPPrintSpectra.layerSensitivity.map(continuedTails)

    /// Minilab scanner sensitivity as LED emission bands at 630, 545, and 465 nm. Red and blue use
    /// community-measured SP3000 lamp values; 545 nm green sits at the top of the 535-545 nm range
    /// a spectrometer survey of lab scanners reports. The widths are the emitter chemistry's, not
    /// one shared figure: AlInGaP red and InGaN blue run near 20 and 22 nm FWHM, while InGaN green
    /// is the broad one at about 33 nm. A single 33 nm width for all three made the scan couple its
    /// records more than RA-4 paper does, which is the opposite of why labs read film this way.
    static let labScanSensitivity: [[Float]] = normalizeSensitivities(
        zip([Float(630), 545, 465], [Float(8.5), 14, 9.5]).map { center, sigma in
            wavelengths.map { w in exp(-0.5 * pow((w - center) / sigma, 2)) }
        })

    /// Peak-normalized pre-calibration Telecine receiver sensitivity from SMPTE RP 180-1999
    /// Table 1, published at 10 nm, carried onto the 5 nm grid linearly and zero outside its support. Bands peak at 670, 530, and 430 nm
    /// with 35–40 nm passbands; the finished transfer characterizes their coupling before output.
    static let telecineSensitivity: [[Float]] = normalizeSensitivities([
        // R: 610-720 nm
        [Float](repeating: 0, count: 45)
            + [
               0.0005, 0.0010, 0.0094, 0.0177, 0.0545, 0.0913, 0.1568,
               0.2223, 0.3570, 0.4917, 0.6592, 0.8267, 0.9133, 1.0000,
               0.8969, 0.7937, 0.6212, 0.4487, 0.3197, 0.1907, 0.1330,
               0.0752, 0.0425, 0.0097, 0.0049]
            + [Float](repeating: 0, count: 11),
        // G: 470-590 nm
        [Float](repeating: 0, count: 17)
            + [
               0.0003, 0.0005, 0.0008, 0.0012, 0.0030, 0.0049, 0.0208,
               0.0366, 0.1540, 0.2714, 0.4933, 0.7152, 0.8576, 1.0000,
               0.9389, 0.8779, 0.6682, 0.4584, 0.2950, 0.1317, 0.0698,
               0.0079, 0.0052, 0.0025, 0.0019, 0.0013, 0.0006]
            + [Float](repeating: 0, count: 37),
        // B: 380-490 nm
        [
               0.0052, 0.0340, 0.0628, 0.1160, 0.1692, 0.2917, 0.4141,
               0.5883, 0.7625, 0.8812, 1.0000, 0.9377, 0.8754, 0.7133,
               0.5512, 0.4066, 0.2619, 0.1847, 0.1075, 0.0668, 0.0262,
               0.0140, 0.0018, 0.0009]
            + [Float](repeating: 0, count: 57),
    ])
}
