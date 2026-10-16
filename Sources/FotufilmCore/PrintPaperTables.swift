import Foundation

/// The measurements each print medium is read through. `PrintPaper` is the
/// choice; this is what the choice resolves to.
extension PrintPaper {
    /// Viewing dye spectra normalized for flat neutral density. The digital reference uses the
    /// measured RA-4 dye basis only to retain the negative-to-positive spectral coupling; it is
    /// not presented as a measured display or a physical sheet. Negative output bypasses this
    /// positive-medium table, so its entry is only unreachable scaffolding for exhaustive access.
    /// A scan has no physical viewing dyes. The balance solve and Telecine's calibrated
    /// colour-timing reference still need a neutral visual judge, so the RA-4 set stands in.
    var dyes: [[Float]] { printStock?.spectra.dyes ?? SpectralGrid.paperDyes }

    /// The sheet's own dye shapes at their neutral-forming amounts, before `partition` divides
    /// them by their pointwise sum. What a spectrum is composed from once a Status A reading has
    /// been unmixed; `dyes` stays the partitioned basis the neutral axis is built on.
    var analyticalDyes: [[Float]] {
        printStock?.spectra.analyticalDyes ?? SpectralGrid.paperDyeAmounts
    }

    /// Layer sensitivities with publication tails extended. Release prints preserve the
    /// publication's inter-layer speed scale: it determines the additive printer's beam mix.
    /// Per-layer normalization is harmless only for paths without a spectral timing solve.
    /// Digital Reference reads through its receiver bands; viewed negatives bypass this stage.
    var sensitivity: [[Float]] { sensitivity(bands: .paper) }

    /// The layer sensitivities, with Digital Reference reading through `bands`.
    func sensitivity(bands: ReceiverBands) -> [[Float]] {
        switch route {
        case .print(let stock): return stock.spectra.sensitivity
        case .screen: return bands.sensitivity
        case .negative: return SpectralGrid.paperSensitivity
        case .labScan: return SpectralGrid.labScanSensitivity
        case .telecine: return SpectralGrid.telecineSensitivity
        }
    }

    /// Gross Status A setup aims, not densities above clear film. Kodak H-1-2383t, H-1-2393t
    /// and H-1-5386, LAD sections; Fujifilm ETERNA-CP 3513DI brochure and KB-0707E, "Aim Print
    /// Density"; Agfa CP30 Technical Data, "Laboratory aimdensity values".
    /// These instrument readings must not be replaced by three equal density values or
    /// by an RGB-neutralizing correction after development.
    var ladStatusA: SIMD3<Float>? { printStock?.releaseSetup?.ladStatusA }

    /// Density at which the published reciprocal-exposure sensitivity was measured.
    /// Kodak labels D = 1.0; Fuji explicitly states 1.0 above minimum density.
    func sensitivityReferenceExposures(for stock: FilmStock) -> [Float] {
        precondition(isProjected)
        return printCurves(for: stock).map {
            $0.logExposure(density: printStock?.releaseSetup?.sensitivityAboveMinimum == true
                ? $0.dMin + 1 : 1)
        }
    }

    /// Fixed printer exposure-axis origins. Reflection paper is visually balanced under its
    /// reference lamp; cine film uses the published gross LAD aims. Viewing another lamp
    /// cannot move these exposures. Monochrome retains the single-record neutral convention.
    func printExposureMidpoints(for stock: FilmStock,
                                digitalReference: DigitalReferenceStyle = .default) -> [Float] {
        let curves = printCurves(for: stock, digitalReference: digitalReference)
        if let aim = ladStatusA, !stock.isMonochrome, !stock.isReversal {
            return (0..<3).map { curves[$0].logExposure(density: aim[$0]) }
        }
        let offset = acceptsViewingIlluminant && !stock.isMonochrome
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
    /// printer times and filters to. `screen` is not a material: its colour-negative receiver
    /// has one fixed tone curve, independent of the film profile, and its graded styles a
    /// straight line the output table grades.
    func printCurve(for stock: FilmStock,
                    digitalReference: DigitalReferenceStyle = .default) -> CharacteristicCurve {
        printCurves(for: stock, digitalReference: digitalReference)[1]
    }

    /// The characteristic curves the print's three records develop along, in
    /// the engine's red/green/blue channel order — the cyan-, magenta- and
    /// yellow-forming layers as read through red, green and blue filters. A
    /// sheet that publishes one curve develops all three records along it,
    /// which is exactly the single-curve stage this generalizes.
    func printCurves(for stock: FilmStock,
                     digitalReference: DigitalReferenceStyle = .default) -> [CharacteristicCurve] {
        if levelsPositive(for: stock, digitalReference: digitalReference) {
            let curve = DigitalReferenceReceiver.positiveCurve
            return [curve, curve, curve]
        }
        guard !viewsFilmDirectly(for: stock) else {
            return [stock.paperCurve, stock.paperCurve, stock.paperCurve]
        }
        // A monochrome negative prints through one exposure and the engine
        // forces its output neutral, so the model's stance is the timing
        // record — the green curve — three times. Per-record spread would be
        // unreachable in the render and only skew the analytic mirrors.
        if stock.isMonochrome {
            let timing = colourRecords(for: stock, digitalReference: digitalReference)[1]
            return [timing, timing, timing]
        }
        return colourRecords(for: stock, digitalReference: digitalReference)
    }

    private func colourRecords(for stock: FilmStock,
                               digitalReference: DigitalReferenceStyle) -> [CharacteristicCurve] {
        switch route {
        case .print(let printStock):
            return printStock.curves
        case .screen:
            let curve = DigitalReferenceReceiver.curve(for: digitalReference, stock: stock)
            return [curve, curve, curve]
        case .negative:
            return [stock.paperCurve, stock.paperCurve, stock.paperCurve]
        case .labScan:
            return [PrintPaper.labScanCurve, PrintPaper.labScanCurve,
                    PrintPaper.labScanCurve]
        case .telecine:
            return [PrintPaper.telecineCurve, PrintPaper.telecineCurve,
                    PrintPaper.telecineCurve]
        }
    }

    /// Editable scan tone scale, independent of a paper's limited density range. Equal toe and
    /// shoulder widths keep their softplus difference positive instead of crossing below D-min
    /// and clipping bright scene detail. The broad transitions retain separation for 16-bit
    /// delivery; 3.6 D is the receiver's asymptotic range, not a measured scanner specification.
    static let labScanCurve = CharacteristicCurve(
        dMin: 0, gamma: 3,
        toe: -1, toeWidth: 0.3, shoulder: 0.2, shoulderWidth: 0.3)

    /// Telecine inversion on the RA-4 log-exposure axis. Gamma is 5.7, D-max is 2.10, and the
    /// 0.12 shoulder represents film white at 86 IRE with headroom to 100 IRE. The shared
    /// mid-grey anchor takes precedence over the composite-video LAD convention of 49 IRE.
    static let telecineCurve = CharacteristicCurve(
        dMin: 0.051, gamma: 5.7,
        toe: -1.541, toeWidth: 0.16, shoulder: -1.182, shoulderWidth: 0.12)

    /// Fixed lab-scan profile solved from Portra 400. Regenerate with
    /// `fotufilm --dump-labscan-reference portra400` after changing
    /// the reference stock, scan sensitivities, or balance solve. `labScanReferenceMidRatio` is
    /// log10(red/green, blue/green) at mid-grey; `labScanReferenceBalance` is the printing balance.
    static let labScanReferenceMidRatio = SIMD2<Float>(0.5609019, -0.444564)
    static let labScanReferenceBalance: [Float] = [1.0579212, 1.0, 0.880968]

    /// Maximum retained reference-profile cast in log receiver exposure. The softer scan curve
    /// carries this exposure difference with its own slope; it is not a finished minilab grade.
    static let labScanCastCeiling: Float = 0.029
}

extension SpectralGrid {
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
