import Foundation

/// A physical print material: the emulsion the developed film is exposed onto.
///
/// `PrintPaper` is the output the user chooses and the identity hosts persist. A print stock is
/// what one of those choices is made of. Scans, Digital Reference and the viewed negative are
/// outputs with no print stock behind them.
///
/// A stock states only what its datasheet measures: three characteristic curves, its dye and
/// layer-sensitivity spectra and, for release print film, its setup aims. Everything shared by
/// a family of materials — how it is exposed, viewed and timed — belongs to its `Process`.
///
/// The shipped stocks are in `PrintStockCatalogue.swift`. To add one, see docs/print-stocks.md.
public struct PrintStock: Sendable {
    /// The family of material a stock belongs to. It decides how the print is exposed, viewed
    /// and timed, and which films and gauges can print onto it.
    public enum Process: Sendable, CaseIterable {
        /// Negative-working colour paper (RA-4), viewed by reflection and balanced visually
        /// under its reference lamp.
        case photoPaper
        /// Negative-working colour print film (ECP-2), projected and timed to published gross
        /// Status A LAD aims through an additive printer.
        case releasePrintFilm
        /// Positive-working paper for slide film, viewed by reflection. More exposure makes a
        /// lighter print.
        case positivePaper

        /// Whether the finished print is a transparency projected in a dark room rather than a
        /// sheet under room light.
        public var isProjected: Bool { self == .releasePrintFilm }

        /// Whether the print is a sheet viewed by reflection: it has a border, and its visual
        /// setup is solved under the reflection reference lamp.
        public var isReflection: Bool { !isProjected }

        /// Whether the material loses density as exposure increases.
        public var isPositiveWorking: Bool { self == .positivePaper }

        /// Whether the material prints transparent positives rather than negatives.
        public var printsReversal: Bool { isPositiveWorking }

        /// Combined lens, focus and scattering blur of the printing stage, as Gaussian sigma in
        /// millimetres on the film.
        public var enlargerBlurMM: Float { isProjected ? 0.003 : 0.004 }

        /// Nominal visual mid-grey, as density above clear base. Release prints are placed at
        /// their LAD aims instead; this is their nominal reading.
        public var midDensity: Float { isProjected ? 1.0 : 0.744 }

        /// Whether layer sensitivities keep the datasheet's inter-layer speed scale. A release
        /// print's additive printer mixes its beams against that scale; reflection papers are
        /// balanced visually, so each layer is normalized on its own.
        var keepsLayerSpeedScale: Bool { isProjected }
    }

    /// The published setup of a release print: what the timing solve aims for.
    public struct ReleaseSetup: Sendable {
        /// Gross Status A setup aims, not densities above clear film. These instrument readings
        /// must not be replaced by three equal densities or by an RGB-neutralizing correction.
        public let ladStatusA: SIMD3<Float>
        /// Whether the sheet's spectral sensitivity was measured at 1.0 above minimum density
        /// rather than at a gross density of 1.0.
        public let sensitivityAboveMinimum: Bool
    }

    /// The material's dye and receiver spectra on the engine's wavelength grid.
    public struct Spectra: Sendable {
        /// The sheet's dye shapes at their neutral-forming amounts. A spectrum is composed from
        /// these once a Status A reading has been unmixed.
        let analyticalDyes: [[Float]]
        /// `analyticalDyes` divided by their pointwise sum: the basis the neutral axis is built on.
        let dyes: [[Float]]
        /// Layer sensitivities with publication tails extended.
        let sensitivity: [[Float]]

        /// Spectra as a datasheet publishes them.
        ///
        /// - Parameters:
        ///   - dyeDensity: Cyan, magenta and yellow dye density on the grid.
        ///   - neutralAmounts: The amount of each dye in a visual neutral, where the sheet plots
        ///     each record at its own peak. Pass nil when the sheet draws the dyes at the amounts
        ///     that already form a neutral.
        ///   - layerSensitivity: Red-, green- and blue-sensitive layer response on the grid.
        ///   - process: The material's family, which decides whether the layers keep the
        ///     sheet's inter-layer speed scale; see `Process.keepsLayerSpeedScale`.
        init(dyeDensity: [[Float]], neutralAmounts: [Float]? = nil,
             layerSensitivity: [[Float]], process: Process) {
            precondition(dyeDensity.count == 3 && layerSensitivity.count == 3)
            precondition((dyeDensity + layerSensitivity).allSatisfy { $0.count == SpectralGrid.count })
            let amounts = neutralAmounts.map { amounts in
                zip(dyeDensity, amounts).map { record, amount in record.map { $0 * amount } }
            } ?? dyeDensity
            let tailed = layerSensitivity.map(SpectralGrid.continuedTails)
            analyticalDyes = amounts
            dyes = SpectralGrid.partition(amounts)
            sensitivity = process.keepsLayerSpeedScale ? tailed : SpectralGrid.normalizeSensitivities(tailed)
        }
    }

    /// The manufacturer's product name.
    public let name: String
    /// One sentence on how the print looks, for menus.
    public let detail: String
    public let process: Process
    /// The red, green and blue records' characteristic curves on the printer's log-exposure
    /// axis. A sheet that publishes one curve repeats it.
    public let curves: [CharacteristicCurve]
    public let spectra: Spectra
    /// Required for, and only for, release print film.
    public let releaseSetup: ReleaseSetup?

    init(name: String, detail: String, process: Process, curves: [CharacteristicCurve],
         spectra: Spectra, releaseSetup: ReleaseSetup? = nil) {
        precondition(curves.count == 3, "\(name): a print stock develops three records")
        precondition((releaseSetup != nil) == process.isProjected,
                     "\(name): release print film, and only it, states its setup aims")
        self.name = name
        self.detail = detail
        self.process = process
        self.curves = curves
        self.spectra = spectra
        self.releaseSetup = releaseSetup
    }
}
