import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// What an authored stock can be made of: the `color` and `monochrome` generators, or spectral
/// curves drawn by hand as control points and resampled onto the engine's 41-band grid. A drawn
/// film whose curves descend from a measured record carries that record's lineage, and the export
/// gate reads it — playing with a library film's curves is free, passing them on is not.
struct CustomStockDraft: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case colorNegative, colorReversal, monochrome
        var id: String { rawValue }

        var title: String {
            switch self {
            case .colorNegative: return "Color Negative"
            case .colorReversal: return "Slide"
            case .monochrome: return "Black and white"
            }
        }
    }

    /// A generated stock picks one of the engine's published dye sets; it
    /// does not describe its own dyes.
    enum DyeSet: String, Codable, CaseIterable, Identifiable {
        case kodakNegative, fujiNegative, motionNegative, kodachrome
        var id: String { rawValue }

        var title: String {
            switch self {
            case .kodakNegative: return "Warm negative"
            case .fujiNegative: return "Cool negative"
            case .motionNegative: return "Motion picture"
            case .kodachrome: return "Vintage reversal"
            }
        }

        var family: FilmDyeFamily {
            switch self {
            case .kodakNegative: return .kodakNegative
            case .fujiNegative: return .fujiNegative
            case .motionNegative: return .motionNegative
            case .kodachrome: return .kodachrome
            }
        }

        /// `nil` for `.monochrome`, which this list does not offer.
        init?(family: FilmDyeFamily) {
            guard let match = DyeSet.allCases.first(where: { $0.family == family })
            else { return nil }
            self = match
        }
    }

    /// Which description of the spectra the film renders through.
    enum SpectralModelKind: String, Codable, CaseIterable, Identifiable {
        /// The published generators: three lobes and a named dye set.
        case generated
        /// Hand-placed control points, resampled onto the engine's own grid.
        case drawn
        var id: String { rawValue }

        var title: String {
            switch self {
            case .generated: return "Simple lobes"
            case .drawn: return "Drawn curves"
            }
        }
    }

    var name: String = "My Film"
    var subtitle: String = ""
    var kind: Kind = .colorNegative
    var dyeSet: DyeSet = .kodakNegative
    var nativeFormatID: String? = nil

    /// Layer peak sensitivities in nanometres, R/G/B.
    var peaksNM: [Float] = [650, 550, 450]
    var widthsNM: [Float] = [58, 46, 42]
    var monoWeights: [Float] = [0.32, 0.48, 0.20]

    var spectralModel: SpectralModelKind = .generated
    /// Drawn sensitivity, one row per layer — R/G/B for a colour film, a single row for a
    /// panchromatic one. Rows live on their own peak of 1; the engine renormalises at use.
    var sensitivityPoints: [[SpectralControlPoint]] = []
    /// Drawn dye shares, C/M/Y, colour films only. The rows are renormalised on the way out so
    /// the three sum to one at every wavelength, which is the form the engine consumes.
    var dyePoints: [[SpectralControlPoint]] = []
    /// The loaded id of the stock the drawn record descends from, if it descends from one.
    var spectralLineage: String? = nil

    var baseDensity: Float = 0.2
    var contrast: Float = 0.6
    /// Per-layer, R/G/B.
    var contrastTrim: [Float] = [1, 1, 1]
    var toe: Float = -1.2
    var toeWidth: Float = 0.24
    var shoulder: Float = 4.2
    var shoulderWidth: Float = 1.2

    /// The orange mask a colour negative carries, as density added to green and blue over the base.
    /// Zero on every other kind, and on a negative that is meant to scan as though unmasked.
    var maskOffsets: [Float] = [0, 0.42, 0.66]

    /// How each layer answers the three primaries — the crosstalk a real emulsion cannot avoid.
    /// Rows are the layers, columns R/G/B; the engine normalises each row.
    var sensitivityMix: [[Float]] = [[0.92, 0.08, 0], [0.2, 0.73, 0.07], [0, 0.02, 0.98]]

    var grainStrength: Float = 0.012
    var grainSizeMM: Float = 0.005
    var grainLumaCorrelation: Float = 0
    /// Per-layer, R/G/B.
    var grainLayerWeights: [Float] = [0.7, 1.0, 1.35]
    /// Per-layer grain size, as a multiple of `grainSizeMM`.
    var grainLayerSizeRatio: [Float] = [1, 1, 1]
    /// How much of the grain is the slow, wide mottle rather than the fine structure, and how much
    /// wider that mottle is.
    var grainMottleShare: Float = 0
    var grainMottleSizeRatio: Float = 3
    /// The density the grain is still visible down at — base fog, which never has none.
    var grainFogDensity: Float = FilmStock.defaultGrainFogDensity
    /// How the noise grows with density. Left to the film's own kind unless stated.
    var grainDensityLaw: GrainLaw = .followsKind
    /// Fitted chromogenic-negative density response. The Workshop does not expose these
    /// calibration coefficients, but it must retain them when an installed stock is copied.
    /// `nil` keeps older saved drafts decodable and selects the shared family fit.
    var grainDensityProfile: [Float]? = nil

    /// Red, and the ratios green and blue follow at. Halation is longer-wavelength light coming
    /// back off the base, so red leads by construction, but by how much is the film's own.
    var halation: Float = 0.05
    var halationRatios: [Float] = [1, 0.4, 0.16]
    /// Light scattered inside the camera and the emulsion before any of it is recorded: the floor
    /// under a black, and the reason a real film has no true zero.
    var flare: Float = 0.008
    /// Emulsion turbidity, one sigma in mm.
    var softness: Float = 0.004
    /// Per-layer turbidity, as a multiple of `softness`. The blue-sensitive layer is on top and
    /// sees the sharpest image; the red layer is under everything.
    var softnessRatios: [Float] = [1, 0.75, 0.6]
    /// How much of the sharpness loss is luminance rather than per-layer — a film whose MTF is
    /// measured on a grey wedge rather than reconstructed from three colour records.
    var mtfLumaShare: Float = 0

    /// DIR coupler activity.
    var couplerStrength: Float = 0.7
    /// What each coated interlayer lets through, as a fraction: the red–green scavenger interlayer
    /// and the green–blue yellow filter layer. 1 is no barrier at all, 0 seals the layers apart.
    /// The defaults are the example negative's.
    var couplerTransmissionRedGreen: Float = 0.275
    var couplerTransmissionGreenBlue: Float = 0.341
    var couplerDiffusionMM: Float = 0.08
    /// What each layer releases, relative to the red layer's `couplerStrength`.
    var couplerReleaseRatios: [Float] = [1, 0.91, 0.68]
    var adjacencyStrength: Float = 0.12
    var adjacencyRadiusMM: Float = 0.03

    /// Only a colour negative has a print stage.
    var paperContrast: Float = 2.6
    var paperDMin: Float = 0.07
    var paperToe: Float = -0.52
    var paperToeWidth: Float = 0.16
    var paperShoulder: Float = 0.42
    var paperShoulderWidth: Float = 0.14
    /// Where a mid grey lands on the print, which is what the whole print stage is anchored on.
    var paperMidDensity: Float = 0.744
    /// A print on paper rather than a transparency: it has a D-max a reflective surface can reach
    /// and no more, and it is judged in a room rather than on a light box.
    var isReflectionPrint: Bool = false

    /// A long exposure loses speed, and the sheet says by how much. Off unless the author states
    /// it, because a film with no measured row should not be given an invented one.
    var reciprocityEnabled: Bool = false
    var reciprocityThresholdSeconds: Float = 1
    var reciprocityLostStopsPerDecade: Float = 0.5
    /// The last exposure the correction is stated through, past which it holds. Zero for a rule
    /// left open-ended.
    var reciprocityStatedThroughSeconds: Float = 0

    /// How grain grows with density.
    enum GrainLaw: String, Codable, CaseIterable, Identifiable {
        /// Silver for black and white, the measured dye-cloud shape for a colour negative, and
        /// Selwyn's dye-cloud law for a reversal.
        case followsKind, dyeCloud, dyeCloudSelwyn, silver
        var id: String { rawValue }

        var title: String {
            switch self {
            case .followsKind: return "Follows the film"
            case .dyeCloud: return "Dye cloud"
            case .dyeCloudSelwyn: return "Dye cloud (Selwyn)"
            case .silver: return "Silver"
            }
        }

        var law: GrainDensityLaw? {
            switch self {
            case .followsKind: return nil
            case .dyeCloud: return .dyeCloud
            case .dyeCloudSelwyn: return .dyeCloudSelwyn
            case .silver: return .silver
            }
        }

        init(_ law: GrainDensityLaw?) {
            switch law {
            case .none: self = .followsKind
            case .some(.dyeCloud): self = .dyeCloud
            case .some(.dyeCloudSelwyn): self = .dyeCloudSelwyn
            case .some(.silver): self = .silver
            }
        }
    }

    var isMonochrome: Bool { kind == .monochrome }
    var isReversal: Bool { kind == .colorReversal }

    static func suggestedID(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let slug = name.lowercased().unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .split(separator: "-").joined(separator: "-")
        let trimmed = String(slug.prefix(48))
        return trimmed.isEmpty ? "my-film" : trimmed
    }

    /// A film is stored as the schema, not as the draft.
    ///
    /// - Parameter lineage: the loaded id this definition was opened from, for a film that is
    ///   being studied rather than one of the user's own. The definition's stored lineage stands
    ///   where none is given.
    static func recovered(from definition: FilmStockDefinition,
                          lineage: String? = nil) -> CustomStockDraft {
        var draft = CustomStockDraft()
        draft.name = definition.name
        draft.subtitle = definition.subtitle ?? ""
        draft.nativeFormatID = definition.nativeFormatID
        draft.kind = definition.isMonochrome == true
            ? .monochrome
            : (definition.isReversal == true ? .colorReversal : .colorNegative)
        draft.spectralLineage = lineage ?? definition.spectralLineage

        switch definition.spectral {
        case let .color(peaksNM, widthsNM, dyeFamily):
            draft.peaksNM = peaksNM
            if let widthsNM { draft.widthsNM = widthsNM }
            draft.dyeSet = DyeSet(family: dyeFamily) ?? .kodakNegative
        case let .monochrome(rgbWeights):
            draft.monoWeights = rgbWeights
        case let .samples(layerSensitivity, imageDyeDensity):
            // Preserve every sampled row so measured spectra are not reduced to fitted lobes.
            draft.spectralModel = .drawn
            draft.sensitivityPoints = Self.seededSensitivity(
                layerSensitivity, monochrome: draft.isMonochrome)
            draft.dyePoints = draft.isMonochrome
                ? []
                : imageDyeDensity.map { SpectralCurve.controlPoints(from: $0) }
        case let .measured(layerSensitivity, dyeFamily):
            draft.spectralModel = .drawn
            draft.sensitivityPoints = Self.seededSensitivity(
                layerSensitivity, monochrome: draft.isMonochrome)
            draft.dyeSet = DyeSet(family: dyeFamily) ?? .kodakNegative
            draft.dyePoints = draft.isMonochrome
                ? []
                : SpectralGrid.familyDyeDensities(dyeFamily)
                    .map { SpectralCurve.controlPoints(from: $0) }
        }

        if let first = definition.curves.first {
            draft.baseDensity = first.dMin
            draft.contrast = first.gamma
            draft.toe = first.toe
            draft.toeWidth = first.toeWidth
            draft.shoulder = first.shoulder
            draft.shoulderWidth = first.shoulderWidth
            if first.gamma > 0 {
                draft.contrastTrim = definition.curves.map { $0.gamma / first.gamma }
            }
            // The mask is whatever each layer's base is over the red layer's, which is how it was
            // written on the way out and the only place it is recorded.
            draft.maskOffsets = definition.curves.map { $0.dMin - first.dMin }
        }
        draft.sensitivityMix = definition.sensitivity
        draft.paperContrast = definition.paperCurve.gamma
        draft.paperDMin = definition.paperCurve.dMin
        draft.paperToe = definition.paperCurve.toe
        draft.paperToeWidth = definition.paperCurve.toeWidth
        draft.paperShoulder = definition.paperCurve.shoulder
        draft.paperShoulderWidth = definition.paperCurve.shoulderWidth
        draft.paperMidDensity = definition.paperMidDensity ?? draft.paperMidDensity
        draft.isReflectionPrint = definition.isReflectionPrint ?? false

        draft.grainStrength = definition.grainStrength
        draft.grainSizeMM = definition.grainSizeMM
        draft.grainLayerWeights = definition.grainLayerWeights
        draft.grainLumaCorrelation = definition.grainLumaCorrelation ?? 0
        draft.grainLayerSizeRatio = definition.grainLayerSizeRatio ?? draft.grainLayerSizeRatio
        draft.grainMottleShare = definition.grainMottleShare ?? 0
        draft.grainMottleSizeRatio =
            definition.grainMottleSizeRatio ?? draft.grainMottleSizeRatio
        draft.grainFogDensity = definition.grainFogDensity ?? draft.grainFogDensity
        draft.grainDensityLaw = GrainLaw(definition.grainDensityLaw)
        draft.grainDensityProfile = definition.grainDensityProfile

        draft.halation = definition.halationStrength.first ?? draft.halation
        if let lead = definition.halationStrength.first, lead > 0 {
            draft.halationRatios = definition.halationStrength.map { $0 / lead }
        }
        draft.flare = definition.flare ?? draft.flare
        draft.softness = definition.emulsionDiffusionMM?.first ?? draft.softness
        if let diffusion = definition.emulsionDiffusionMM, let lead = diffusion.first,
           lead > 0 {
            draft.softnessRatios = diffusion.map { $0 / lead }
        }
        draft.mtfLumaShare = definition.mtfLumaShare ?? 0

        if let geometry = definition.couplerGeometry {
            draft.couplerStrength = geometry.release.first ?? draft.couplerStrength
            draft.couplerTransmissionRedGreen =
                geometry.interlayerTransmission.first ?? draft.couplerTransmissionRedGreen
            draft.couplerTransmissionGreenBlue =
                geometry.interlayerTransmission.last ?? draft.couplerTransmissionGreenBlue
            if let lead = geometry.release.first, lead > 0 {
                draft.couplerReleaseRatios = geometry.release.map { $0 / lead }
            }
        } else {
            draft.couplerStrength = 0
        }
        draft.couplerDiffusionMM = definition.couplerDiffusionMM
        draft.adjacencyStrength = definition.adjacencyStrength ?? 0
        draft.adjacencyRadiusMM = definition.adjacencyRadiusMM ?? 0

        if let reciprocity = definition.reciprocityFailure {
            draft.reciprocityEnabled = true
            draft.reciprocityThresholdSeconds = reciprocity.thresholdSeconds
            draft.reciprocityLostStopsPerDecade = reciprocity.lostStopsPerDecade
            draft.reciprocityStatedThroughSeconds =
                reciprocity.statedThroughSeconds ?? 0
        }
        return draft
    }

    func definition(id: String) -> FilmStockDefinition {
        let spectral = spectralSpec

        // Only a colour negative carries a mask; a slide and a black-and-white film have one base
        // under all three records, whatever the mask row has been left set to.
        let mask: [Float] = kind == .colorNegative ? padded(maskOffsets, 0) : [0, 0, 0]
        let trim = padded(contrastTrim, 1)
        let curves = (0..<3).map { layer in
            FilmStockDefinition.CurveSpec(CharacteristicCurve(
                dMin: baseDensity + mask[layer],
                gamma: contrast * trim[layer],
                toe: toe, toeWidth: max(toeWidth, 0.01),
                shoulder: max(shoulder, toe + 0.05),
                shoulderWidth: max(shoulderWidth, 0.01)))
        }

        let release = padded(couplerReleaseRatios, 1)
        let geometry: CouplerGeometry? = couplerStrength > 0 && !isMonochrome
            ? CouplerGeometry(interlayerTransmission: [couplerTransmissionRedGreen,
                                                       couplerTransmissionGreenBlue],
                              release: release.map { couplerStrength * $0 })
            : nil

        let paper = FilmStockDefinition.CurveSpec(CharacteristicCurve(
            dMin: paperDMin, gamma: paperContrast,
            toe: paperToe, toeWidth: max(paperToeWidth, 0.01),
            shoulder: max(paperShoulder, paperToe + 0.05),
            shoulderWidth: max(paperShoulderWidth, 0.01)))

        let sensitivity: [[Float]] = isMonochrome
            ? [monoWeights, monoWeights, monoWeights]
            : sensitivityMix

        let turbidity = padded(softnessRatios, 1).map { softness * $0 }
        let glow = padded(halationRatios, 0).map { halation * $0 }
        let reciprocity: ReciprocityFailure? = reciprocityEnabled
            ? ReciprocityFailure(
                thresholdSeconds: max(reciprocityThresholdSeconds, 0.001),
                lostStopsPerDecade: reciprocityLostStopsPerDecade,
                statedThroughSeconds: reciprocityStatedThroughSeconds > 0
                    ? reciprocityStatedThroughSeconds : nil)
            : nil

        var definition = FilmStockDefinition(
            id: id,
            stock: FilmStock(
                name: name,
                sensitivity: sensitivity,
                spectralProfile: spectral.profile,
                curves: curves.map(\.curve),
                flare: flare,
                emulsionDiffusionMM: turbidity,
                mtfLumaShare: mtfLumaShare,
                couplerInhibition: geometry?.matrix() ?? [[0, 0, 0], [0, 0, 0], [0, 0, 0]],
                couplerGeometry: geometry,
                couplerDiffusionMM: couplerDiffusionMM,
                adjacencyStrength: adjacencyStrength,
                adjacencyRadiusMM: adjacencyRadiusMM,
                grainStrength: grainStrength,
                grainSizeMM: grainSizeMM,
                grainLayerWeights: isMonochrome ? [1, 1, 1] : grainLayerWeights,
                grainLumaCorrelation: isMonochrome ? 1 : grainLumaCorrelation,
                grainMottleShare: grainMottleShare,
                grainMottleSizeRatio: grainMottleSizeRatio,
                grainLayerSizeRatio: padded(grainLayerSizeRatio, 1),
                grainDensityLaw: grainDensityLaw.law,
                grainDensityProfile: grainDensityProfile,
                grainFogDensity: grainFogDensity,
                halationStrength: glow,
                paperCurve: paper.curve,
                paperMidDensity: paperMidDensity,
                reciprocityFailure: reciprocity,
                isMonochrome: isMonochrome,
                isReversal: isReversal,
                isReflectionPrint: isReflectionPrint),
            subtitle: subtitle.isEmpty ? nil : subtitle,
            nativeFormatID: nativeFormatID)

        definition.spectral = spectral
        definition.spectralLineage = spectralModel == .drawn ? spectralLineage : nil
        return definition
    }

    // MARK: - Drawn spectra

    /// The spectral description the film renders through, whichever model is up.
    var spectralSpec: FilmStockDefinition.SpectralSpec {
        guard spectralModel == .drawn else {
            return isMonochrome
                ? .monochrome(rgbWeights: monoWeights)
                : .color(peaksNM: peaksNM, widthsNM: widthsNM,
                         dyeFamily: dyeSet.family)
        }
        let rows = drawnSensitivityPoints().map(SpectralCurve.resampled)
        let sensitivity = isMonochrome ? [rows[0], rows[0], rows[0]] : rows
        let dyes = isMonochrome
            ? SpectralGrid.familyDyeDensities(.monochrome)
            : SpectralGrid.partitionedDyes(
                drawnDyePoints().map(SpectralCurve.resampled))
        return .samples(layerSensitivity: sensitivity, imageDyeDensity: dyes)
    }

    /// The drawn sensitivity rows, healed to the kind's shape: three for a colour film, one for a
    /// panchromatic one. A shape that no longer fits — the kind changed under the model — or a row
    /// down to a single handle is baked fresh from the generators, so there is always a curve.
    func drawnSensitivityPoints() -> [[SpectralControlPoint]] {
        let expected = isMonochrome ? 1 : 3
        var rows = sensitivityPoints.count == expected
            ? sensitivityPoints : bakedSensitivityPoints()
        for index in rows.indices where rows[index].count < 2 {
            rows[index] = bakedSensitivityPoints()[index]
        }
        return rows
    }

    /// The drawn dye rows, healed the same way. Meaningless for a panchromatic film, whose silver
    /// is spectrally flat by construction.
    func drawnDyePoints() -> [[SpectralControlPoint]] {
        var rows = dyePoints.count == 3 ? dyePoints : bakedDyePoints()
        for index in rows.indices where rows[index].count < 2 {
            rows[index] = bakedDyePoints()[index]
        }
        return rows
    }

    /// The generated model as handles — where drawing starts when there is nothing measured to
    /// start from.
    func bakedSensitivityPoints() -> [[SpectralControlPoint]] {
        if isMonochrome {
            let centres = FilmSpectralProfile.monochromeBandsNM.centres
            let widths = FilmSpectralProfile.monochromeBandsNM.widths
            let weights = padded(monoWeights, 0.33)
            var row = SpectralGrid.wavelengths.map { nm -> Float in
                (0..<3).reduce(Float(0)) { sum, band in
                    let x = (nm - centres[band]) / max(widths[band], 1)
                    return sum + weights[band] * exp(-0.5 * x * x)
                }
            }
            let peak = max(row.max() ?? 1, 1e-6)
            row = row.map { $0 / peak }
            return [SpectralCurve.controlPoints(from: row)]
        }
        let peaks = padded(peaksNM, 550)
        let widths = padded(widthsNM, 46)
        return (0..<3).map { layer in
            SpectralCurve.controlPoints(
                from: SpectralGrid.wavelengths.map {
                    FilmSpectralProfile.colorLayerSensitivity(
                        layer: layer, peakNM: peaks[layer],
                        widthNM: widths[layer], atNM: $0)
                })
        }
    }

    func bakedDyePoints() -> [[SpectralControlPoint]] {
        SpectralGrid.familyDyeDensities(dyeSet.family)
            .map { SpectralCurve.controlPoints(from: $0) }
    }

    /// Puts the draft into drawn mode, baking handles for whatever has none yet.
    mutating func adoptDrawnSpectra() {
        sensitivityPoints = drawnSensitivityPoints()
        if !isMonochrome { dyePoints = drawnDyePoints() }
        spectralModel = .drawn
    }

    private static func seededSensitivity(_ rows: [[Float]],
                                          monochrome: Bool) -> [[SpectralControlPoint]] {
        let kept = monochrome ? [rows.first ?? []] : rows
        return kept.map { row in
            guard row.count == SpectralGrid.count else { return [] }
            let peak = max(row.max() ?? 0, 1e-12)
            return SpectralCurve.controlPoints(from: row.map { $0 / peak })
        }
    }

    private func padded(_ values: [Float], _ fill: Float) -> [Float] {
        (0..<3).map { values.indices.contains($0) ? values[$0] : fill }
    }
}
