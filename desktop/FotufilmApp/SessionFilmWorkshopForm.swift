import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Builds the workshop's parameter form. Values without meaningful bounds use typed fields.
extension FilmWorkshopController {

    func buildForm() {
        var built = [identitySection(), layersSection(), toneSection()]
        if draft.kind == .colorNegative { built.append(printSection()) }
        if !draft.isMonochrome { built.append(couplerSection()) }
        built.append(contentsOf: [sharpnessSection(), glowSection(),
                                  grainSection(), reciprocitySection()])
        setSections(built)
    }

    // MARK: - Row helpers

    private func slider(_ title: String, _ range: ClosedRange<Float>,
                        format: String = "%.3f",
                        scale: Float = 1, unit: String = "",
                        get: @escaping (CustomStockDraft) -> Float,
                        set: @escaping (inout CustomStockDraft, Float) -> Void)
        -> SliderRow {
        SliderRow(title, range: Double(range.lowerBound)...Double(range.upperBound),
                  display: { value in
                      String(format: format, Float(value) * scale) + unit
                  },
                  get: { [weak self] in
                      guard let self else { return 0 }
                      return Double(get(draft))
                  },
                  set: { [weak self] value in
                      self?.edit { set(&$0, Float(value)) }
                  },
                  // One history entry per slider drag, not one per pixel the thumb travels.
                  began: { [weak self] in self?.beginStroke() },
                  ended: { [weak self] in self?.endStroke() })
    }

    private func numbers(_ title: String,
                         captions: [String] = ["Red", "Green", "Blue"],
                         decimals: Int = 3,
                         get: @escaping (CustomStockDraft) -> [Float],
                         set: @escaping (inout CustomStockDraft, [Float]) -> Void)
        -> NumberFieldRow {
        NumberFieldRow(title, captions: captions, decimals: decimals,
                       get: { [weak self] in
                           guard let self else { return [0, 0, 0] }
                           return get(draft)
                       },
                       set: { [weak self] values in
                           self?.edit { set(&$0, values) }
                       })
    }

    private static let layerNames = ["Red", "Green", "Blue"]

    // MARK: - What it is

    private func identitySection() -> FormSectionView {
        let section = FormSectionView(title: "Film")
        section.add(TextFieldRow("Name", placeholder: "My Film",
                                 get: { [weak self] in self?.draft.name ?? "" },
                                 set: { [weak self] name in
                                     self?.edit { $0.name = name }
                                 }))
        section.add(TextFieldRow("Notes", placeholder: "Kodak · colour negative",
                                 get: { [weak self] in self?.draft.subtitle ?? "" },
                                 set: { [weak self] text in
                                     self?.edit { $0.subtitle = text }
                                 }))
        section.add(PopUpRow<CustomStockDraft.Kind>(
            "Kind",
            options: CustomStockDraft.Kind.allCases.map {
                (title: $0.title, value: $0)
            },
            get: { [weak self] in self?.draft.kind ?? .colorNegative },
            set: { [weak self] kind in
                // Which rows exist at all depends on this: a slide has no print stage and a
                // black-and-white film has no dye set.
                self?.edit(rebuild: true) { $0.kind = kind }
            }))

        var formats: [(title: String, value: String?)] = [("No preference", nil)]
        formats += FilmFormat.presets.map {
            (title: $0.format.name, value: Optional($0.id))
        }
        section.add(PopUpRow<String?>(
            "Shot on", options: formats,
            get: { [weak self] in self?.draft.nativeFormatID },
            set: { [weak self] id in self?.edit { $0.nativeFormatID = id } }))
        section.add(NoteRow("The format a film is normally shot on. Everything "
                            + "measured in millimetres below — grain, turbidity, "
                            + "coupler reach — is enlarged from it, so the same "
                            + "numbers look coarser on a smaller frame."))
        return section
    }

    // MARK: - The layers

    private func layersSection() -> FormSectionView {
        let section = FormSectionView(title: "Layers")

        // Which description of the spectra the film renders through. Generated is the published
        // lobes; drawn is control points on the engine's own grid, dye record included, which is
        // the only form a measured film can be shown and played with in.
        section.add(PopUpRow<CustomStockDraft.SpectralModelKind>(
            "Spectra",
            options: CustomStockDraft.SpectralModelKind.allCases.map {
                (title: $0.title, value: $0)
            },
            get: { [weak self] in self?.draft.spectralModel ?? .generated },
            set: { [weak self] model in
                self?.edit(rebuild: true) { draft in
                    if model == .drawn {
                        draft.adoptDrawnSpectra()
                    } else {
                        draft.spectralModel = .generated
                    }
                }
            }))

        if draft.spectralModel == .drawn {
            section.add(NoteRow("The curves above are yours: drag a handle, "
                                + "press an empty spot to add one, or carry a "
                                + "handle below the plot to take it out. The "
                                + "chips pick which curve is in hand. What the "
                                + "engine renders is the drawn curve resampled "
                                + "onto its 5 nm grid — exactly what the "
                                + "graph strokes."))
            if let lineage = draft.spectralLineage {
                section.add(NoteRow("These curves descend from \(lineage)'s "
                                    + "record. Play freely and save copies; a "
                                    + "film drawn from a library record does "
                                    + "not export."))
            }
        }

        if draft.isMonochrome {
            if draft.spectralModel == .generated {
                section.add(numbers("Panchromatic response", decimals: 2,
                                    get: { $0.monoWeights },
                                    set: { $0.monoWeights = $1 }))
                section.add(NoteRow("Drag the bands above, or type here. What one "
                                    + "emulsion makes of the three primaries: a film "
                                    + "that answers red strongly renders a red "
                                    + "filter's effect without one."))
            }
            return section
        }

        if draft.spectralModel == .generated {
            section.add(PopUpRow<CustomStockDraft.DyeSet>(
                "Dyes",
                options: CustomStockDraft.DyeSet.allCases.map {
                    (title: $0.title, value: $0)
                },
                get: { [weak self] in self?.draft.dyeSet ?? .kodakNegative },
                set: { [weak self] set in self?.edit { $0.dyeSet = set } }))
            section.add(numbers("Peak sensitivity", decimals: 0,
                                get: { $0.peaksNM }, set: { $0.peaksNM = $1 }))
            section.add(numbers("Bandwidth", decimals: 0,
                                get: { $0.widthsNM }, set: { $0.widthsNM = $1 }))
            section.add(NoteRow("Nanometres, and the same two numbers as the graph "
                                + "above: drag a crest to move a layer's peak, or "
                                + "the small ring on its shoulder to open or close "
                                + "the band it answers over."))
        }

        for layer in 0..<3 {
            section.add(numbers("\(Self.layerNames[layer]) layer sees",
                                decimals: 2,
                                get: { draft in
                                    draft.sensitivityMix.indices.contains(layer)
                                        ? draft.sensitivityMix[layer] : [0, 0, 0]
                                },
                                set: { draft, values in
                                    var mix = draft.sensitivityMix
                                    while mix.count < 3 { mix.append([0, 0, 0]) }
                                    mix[layer] = values
                                    draft.sensitivityMix = mix
                                }))
        }
        section.add(NoteRow("Crosstalk. No emulsion answers one primary and "
                            + "nothing else; the rows are normalised, so what "
                            + "matters is their proportion."))
        return section
    }

    // MARK: - Tone

    private func toneSection() -> FormSectionView {
        let section = FormSectionView(title: "Tone")
        section.add(NoteRow("Drag the curve above. These are the same six "
                            + "numbers, for when a value is known rather than "
                            + "looked for."))
        section.add(slider("Base density", 0...1.6, format: "%.2f",
                           get: { $0.baseDensity },
                           set: { $0.baseDensity = $1 }))
        section.add(slider("Contrast", 0.05...2.5, format: "%.2f",
                           get: { $0.contrast }, set: { $0.contrast = $1 }))
        section.add(slider("Toe", -4 ... -0.05, format: "%+.2f",
                           scale: 1 / logPerStop, unit: " stops",
                           get: { $0.toe }, set: { $0.toe = $1 }))
        section.add(slider("Toe softness", 0.02...2, format: "%.2f",
                           scale: 1 / logPerStop, unit: " stops",
                           get: { $0.toeWidth }, set: { $0.toeWidth = $1 }))
        section.add(slider("Shoulder", 0.2...6, format: "%+.2f",
                           scale: 1 / logPerStop, unit: " stops",
                           get: { $0.shoulder }, set: { $0.shoulder = $1 }))
        section.add(slider("Shoulder softness", 0.02...2.5, format: "%.2f",
                           scale: 1 / logPerStop, unit: " stops",
                           get: { $0.shoulderWidth },
                           set: { $0.shoulderWidth = $1 }))

        if !draft.isMonochrome {
            section.add(numbers("Contrast per layer", decimals: 3,
                                get: { $0.contrastTrim },
                                set: { $0.contrastTrim = $1 }))
        }
        if draft.kind == .colorNegative {
            section.add(numbers("Mask density", decimals: 3,
                                get: { $0.maskOffsets },
                                set: { $0.maskOffsets = $1 }))
            section.add(NoteRow("The orange mask, as density added over the red "
                                + "layer's base. It is a correction printed into "
                                + "the negative, which is why the negative looks "
                                + "orange and the print does not."))
        }
        return section
    }

    // MARK: - The print

    private func printSection() -> FormSectionView {
        let section = FormSectionView(title: "Print")
        section.add(slider("Paper contrast", 0.5...8, format: "%.2f",
                           get: { $0.paperContrast },
                           set: { $0.paperContrast = $1 }))
        section.add(slider("Paper base", 0...0.6, format: "%.3f",
                           get: { $0.paperDMin }, set: { $0.paperDMin = $1 }))
        section.add(slider("Paper toe", -2 ... -0.05, format: "%.2f",
                           get: { $0.paperToe }, set: { $0.paperToe = $1 }))
        section.add(slider("Paper toe softness", 0.02...1, format: "%.3f",
                           get: { $0.paperToeWidth },
                           set: { $0.paperToeWidth = $1 }))
        section.add(slider("Paper shoulder", 0.05...2, format: "%.2f",
                           get: { $0.paperShoulder },
                           set: { $0.paperShoulder = $1 }))
        section.add(slider("Paper shoulder softness", 0.02...1, format: "%.3f",
                           get: { $0.paperShoulderWidth },
                           set: { $0.paperShoulderWidth = $1 }))
        section.add(slider("Mid grey prints at", 0.2...1.4, format: "%.3f",
                           get: { $0.paperMidDensity },
                           set: { $0.paperMidDensity = $1 }))
        section.add(ToggleRow("Reflection print",
                              get: { [weak self] in
                                  self?.draft.isReflectionPrint ?? false
                              },
                              set: { [weak self] on in
                                  self?.edit { $0.isReflectionPrint = on }
                              }))
        section.add(NoteRow("A print on paper reaches the D-max a reflective "
                            + "surface can and no further. A transparency, lit "
                            + "from behind, goes darker than any paper."))
        return section
    }

    // MARK: - What the layers do to one another

    private func couplerSection() -> FormSectionView {
        let section = FormSectionView(title: "Colour Interaction")
        section.add(slider("Coupler release", 0...1.5, format: "%.2f",
                           get: { $0.couplerStrength },
                           set: { $0.couplerStrength = $1 }))
        section.add(numbers("Release per layer", decimals: 2,
                            get: { $0.couplerReleaseRatios },
                            set: { $0.couplerReleaseRatios = $1 }))
        section.add(slider("Red–green barrier", 0...1, format: "%.3f",
                           get: { $0.couplerTransmissionRedGreen },
                           set: { $0.couplerTransmissionRedGreen = $1 }))
        section.add(slider("Green–blue barrier", 0...1, format: "%.3f",
                           get: { $0.couplerTransmissionGreenBlue },
                           set: { $0.couplerTransmissionGreenBlue = $1 }))
        section.add(NoteRow("A layer developing hard releases inhibitor that "
                            + "suppresses its neighbours. The barriers are the "
                            + "coated interlayers: 1 lets everything through, 0 "
                            + "seals the layers apart. Watch the hue sweep — the "
                            + "grey wedge is the control and should stay put."))
        section.add(slider("Coupler reach", 0...0.4, format: "%.3f", unit: " mm",
                           get: { $0.couplerDiffusionMM },
                           set: { $0.couplerDiffusionMM = $1 }))
        section.add(slider("Edge effect", 0...1, format: "%.3f",
                           get: { $0.adjacencyStrength },
                           set: { $0.adjacencyStrength = $1 }))
        section.add(slider("Edge effect reach", 0...0.2, format: "%.3f",
                           unit: " mm",
                           get: { $0.adjacencyRadiusMM },
                           set: { $0.adjacencyRadiusMM = $1 }))
        section.add(NoteRow("The border in the middle of the chart is where the "
                            + "edge effect shows: exhausted developer drifting "
                            + "across a boundary lightens one side of it and "
                            + "darkens the other."))
        return section
    }

    // MARK: - Sharpness

    private func sharpnessSection() -> FormSectionView {
        let section = FormSectionView(title: "Sharpness")
        section.add(slider("Turbidity", 0...0.03, format: "%.4f", unit: " mm",
                           get: { $0.softness }, set: { $0.softness = $1 }))
        section.add(numbers("Turbidity per layer", decimals: 2,
                            get: { $0.softnessRatios },
                            set: { $0.softnessRatios = $1 }))
        section.add(slider("Measured on luminance", 0...1, format: "%.2f",
                           get: { $0.mtfLumaShare },
                           set: { $0.mtfLumaShare = $1 }))
        section.add(NoteRow("Light scatters sideways inside the emulsion before "
                            + "it is recorded. The blue layer is on top and sees "
                            + "the sharpest image; the red layer is under "
                            + "everything. The bar patterns are where this shows."))
        return section
    }

    // MARK: - Glow

    private func glowSection() -> FormSectionView {
        let section = FormSectionView(title: "Highlight Glow")
        section.add(slider("Halation", 0...0.4, format: "%.3f",
                           get: { $0.halation }, set: { $0.halation = $1 }))
        if !draft.isMonochrome {
            section.add(numbers("Halation per layer", decimals: 2,
                                get: { $0.halationRatios },
                                set: { $0.halationRatios = $1 }))
        }
        section.add(slider("Flare", 0...0.05, format: "%.4f",
                           get: { $0.flare }, set: { $0.flare = $1 }))
        section.add(NoteRow("Halation is light that went through the emulsion, "
                            + "bounced off the base and came back — red first, "
                            + "which is why it glows warm. Flare is the light "
                            + "that never made it to a sharp image at all, and "
                            + "is the floor under the chart's black surround."))
        return section
    }

    // MARK: - Grain

    private func grainSection() -> FormSectionView {
        let section = FormSectionView(title: "Grain")
        section.add(slider("Strength", 0...0.06, format: "%.4f",
                           get: { $0.grainStrength },
                           set: { $0.grainStrength = $1 }))
        section.add(slider("Size", 0.001...0.02, format: "%.4f", unit: " mm",
                           get: { $0.grainSizeMM },
                           set: { $0.grainSizeMM = $1 }))
        if !draft.isMonochrome {
            section.add(numbers("Strength per layer", decimals: 2,
                                get: { $0.grainLayerWeights },
                                set: { $0.grainLayerWeights = $1 }))
            section.add(numbers("Size per layer", decimals: 2,
                                get: { $0.grainLayerSizeRatio },
                                set: { $0.grainLayerSizeRatio = $1 }))
            section.add(slider("Grain shared between layers", 0...1,
                               format: "%.2f",
                               get: { $0.grainLumaCorrelation },
                               set: { $0.grainLumaCorrelation = $1 }))
        }
        section.add(slider("Mottle", 0...1, format: "%.2f",
                           get: { $0.grainMottleShare },
                           set: { $0.grainMottleShare = $1 }))
        section.add(slider("Mottle size", 1...8, format: "%.1f×",
                           get: { $0.grainMottleSizeRatio },
                           set: { $0.grainMottleSizeRatio = $1 }))
        section.add(slider("Fog", 0...0.5, format: "%.3f",
                           get: { $0.grainFogDensity },
                           set: { $0.grainFogDensity = $1 }))
        section.add(PopUpRow<CustomStockDraft.GrainLaw>(
            "Grows as",
            options: CustomStockDraft.GrainLaw.allCases.map {
                (title: $0.title, value: $0)
            },
            get: { [weak self] in self?.draft.grainDensityLaw ?? .followsKind },
            set: { [weak self] law in
                self?.edit { $0.grainDensityLaw = law }
            }))
        section.add(NoteRow("Dye clouds are not opaque, so their densities add. "
                            + "Silver grains are, so what adds is covered area — "
                            + "the same noise at low density, steepening as the "
                            + "grains begin to hide one another. The flat grey "
                            + "field is where to look."))
        return section
    }

    // MARK: - Reciprocity

    private func reciprocitySection() -> FormSectionView {
        let section = FormSectionView(title: "Long Exposures")
        section.add(ToggleRow("Reciprocity failure",
                              get: { [weak self] in
                                  self?.draft.reciprocityEnabled ?? false
                              },
                              set: { [weak self] on in
                                  self?.edit(rebuild: true) {
                                      $0.reciprocityEnabled = on
                                  }
                              }))
        if draft.reciprocityEnabled {
            section.add(slider("Holds through", 0.1...60, format: "%.1f s",
                               get: { $0.reciprocityThresholdSeconds },
                               set: { $0.reciprocityThresholdSeconds = $1 }))
            section.add(slider("Stops lost per decade", 0...3, format: "%.2f",
                               get: { $0.reciprocityLostStopsPerDecade },
                               set: { $0.reciprocityLostStopsPerDecade = $1 }))
            section.add(numbers("Stated through", captions: [], decimals: 0,
                                get: { [$0.reciprocityStatedThroughSeconds] },
                                set: {
                                    $0.reciprocityStatedThroughSeconds =
                                        $1.first ?? 0
                                }))
            section.add(NoteRow("Seconds. Past the last exposure the sheet states "
                                + "a correction for, the correction holds at what "
                                + "it said there — the fit describes a published "
                                + "row, and the row ends. Zero leaves it open."))
        } else {
            section.add(NoteRow("A film left open for minutes loses speed, and "
                                + "the manufacturer's sheet says by how much. Off "
                                + "unless you have that row: a film with no "
                                + "measurement should not be given an invented one."))
        }
        return section
    }

    private var logPerStop: Float { 0.30103 }
}
