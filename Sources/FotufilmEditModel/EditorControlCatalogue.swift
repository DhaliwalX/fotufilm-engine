import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Editor controls in display order. Rendering and storage mappings are defined separately.
public enum EditorControlCatalogue {

    public static let all: [EditorControl] = film + light + print + frame

    // MARK: - Film

    private static let film: [EditorControl] = [
        EditorControl(
            .stock, title: "Film",
            detail: "The emulsion the photograph is exposed on",
            section: .filmStock, kind: .menu),
        EditorControl(
            .gauge, title: "Format",
            detail: "The gauge the frame is exposed on, or the film's own",
            section: .filmStock, kind: .menu),

        EditorControl(
            .grain, title: "Grain",
            detail: "How much of the stock's published granularity develops",
            section: .filmGrain,
            kind: .slider(EditorControlScale(0...2, neutral: 1,
                                             unit: .multiplier)),
            availability: .film),
        EditorControl(
            .grainMottle, title: "Mottle",
            detail: "The soft coarse clumping under the sharp grain",
            section: .filmGrain, kind: .menu, availability: .film),
        EditorControl(
            .grainModel, title: "Disc Grain",
            detail: "Resolve single grains where one covers an output pixel",
            section: .filmGrain, kind: .toggle(restingOn: false),
            availability: .film),

        EditorControl(
            .halation, title: "Halation",
            detail: "Light returned by the base, back through the emulsion",
            section: .filmEmulsion,
            // 0 EV is 1x the stock's calibrated returned-light fraction. `HalationAmount`
            // carries the travel, the admitted range and the conversion to the multiple the
            // edit stores.
            kind: .slider(EditorControlScale(HalationAmount.travel, neutral: 0,
                                             unit: .stopsFromOff,
                                             admitted: HalationAmount.admitted)),
            availability: .film),
        EditorControl(
            .halationColour, title: "Halo Colour",
            detail: "How much the ring keeps the light's own colour",
            section: .filmEmulsion,
            // The returning light re-enters the emulsion from below, so a colour film's ring
            // is red whatever the light was; this raises the dimmer records to the strongest
            // one's return, and the ring brightens toward the source's own colour. Offered on
            // colour negative, where the layered red ring is the thing being traded away.
            kind: .slider(EditorControlScale(0...1, neutral: 0,
                                             unit: .percent)),
            availability: .colourNegative),
        EditorControl(
            .halationSpectrum, title: "Return Spectrum",
            detail: "How much of each wavelength the base hands back",
            section: .filmEmulsion,
            // The stock's own return spectrum is derived, not guessed: the mask, the AH undercoat
            // and the yellow filter layer decide what colour comes back, and the sheet carries
            // that reduction. This is a gain over it, flat at rest, drawn in stops rather than in
            // multiples — a masked negative returns green some sixty times less than deep red, so
            // a multiplier's travel would be spent long before the halo changed colour. The
            // handles sit where the engine's own records read, one on each band centre.
            kind: .curve(EditorControlCurve(
                handles: HalationSpectrum.handleNM.map { Double($0) },
                domain: 380...780,
                range: Double(HalationSpectrum.travelStops.lowerBound)
                    ... Double(HalationSpectrum.travelStops.upperBound),
                neutral: Double(HalationSpectrum.neutralStops),
                unit: .stops)),
            availability: .film,
            foldsUnder: .halation),
        EditorControl(
            .couplers, title: "Couplers",
            detail: "DIR inhibition: colour separation and edge contrast",
            section: .filmEmulsion,
            kind: .slider(EditorControlScale(0...2, neutral: 1,
                                             unit: .multiplier)),
            availability: .film),
        EditorControl(
            .couplerReach, title: "Separation",
            detail: "How far the released inhibitor crosses each interlayer",
            section: .filmEmulsion,
            kind: .slider(EditorControlScale(0...3, neutral: 1,
                                             unit: .multiplier)),
            availability: .couplerGeometry),
        EditorControl(
            .couplerSelf, title: "Edge Contrast",
            detail: "The same inhibition acting within a layer, not across two",
            section: .filmEmulsion,
            kind: .slider(EditorControlScale(0...3, neutral: 1,
                                             unit: .multiplier)),
            availability: .couplerGeometry),

        EditorControl(
            .push, title: "Push",
            detail: "Measured push or pull conditions for this film and process",
            section: .filmLab,
            kind: .slider(EditorControlScale(-2...2, neutral: 0, unit: .stops,
                                             stops: [-2, 0, 1, 2])),
            availability: .measuredDevelopment),
        EditorControl(
            .bleach, title: "Bleach Bypass",
            detail: "Silver the bleach leaves in the negative",
            section: .filmLab,
            kind: .chips(EditorControlScale(0...1, neutral: 0, unit: .percent),
                         choices: [EditorControlChoice(0, "Off"),
                                   EditorControlChoice(0.5, "Half"),
                                   EditorControlChoice(1, "Full")]),
            availability: .colourNegative),
        EditorControl(
            .expired, title: "Expired",
            detail: "Years past the process-by date at room temperature",
            section: .filmLab,
            // The travel ends where the stops do: a snapped slider with track past its last stop is
            // a third of a row that does nothing.
            kind: .slider(EditorControlScale(0...20, neutral: 0, unit: .years,
                                             stops: [0, 5, 10, 20])),
            availability: .film),
        EditorControl(
            .shutter, title: "Long Exposure",
            detail: "How long the shutter was open, for the sheet's reciprocity row",
            section: .filmLab, kind: .menu,
            availability: .statedReciprocity),
    ]

    // MARK: - Light

    private static let light: [EditorControl] = [
        EditorControl(
            .lensCorrection, title: "Lens Correction",
            detail: "Correct the lens the photograph was taken with",
            section: .lensCorrection, kind: .toggle(restingOn: false)),
        EditorControl(
            .lensProfile, title: "Lens",
            detail: "The profile to correct against, or the matched one",
            section: .lensCorrection, kind: .menu),
        EditorControl(
            .lensAmount, title: "Amount",
            detail: "How much of the matched profile to apply",
            section: .lensCorrection,
            kind: .slider(EditorControlScale(0...1, neutral: 1,
                                             unit: .percent))),

        EditorControl(
            .exposure, title: "Exposure",
            detail: "Exposure compensation, in stops",
            section: .lightExposure,
            kind: .slider(EditorControlScale(-2...2, neutral: 0,
                                             unit: .stops))),
        EditorControl(
            .highlights, title: "Highlights",
            detail: "Scene-referred shaping above mid-grey, before the film",
            section: .lightExposure,
            kind: .slider(EditorControlScale(-1...1, neutral: 0,
                                             unit: .signed))),
        EditorControl(
            .shadows, title: "Shadows",
            detail: "The same shaping below mid-grey",
            section: .lightExposure,
            kind: .slider(EditorControlScale(-1...1, neutral: 0,
                                             unit: .signed))),
        EditorControl(
            .localTone, title: "Regional",
            detail: "Key the two shapings above to each pixel's surroundings",
            section: .lightExposure, kind: .toggle(restingOn: true)),

        EditorControl(
            .warmth, title: "Warmth",
            detail: "The illuminant the scene is declared to have been lit by",
            section: .lightBalance,
            kind: .slider(EditorControlScale(-1...1, neutral: 0,
                                             unit: .signed))),
        EditorControl(
            .tint, title: "Tint",
            detail: "Green and magenta off the daylight locus",
            section: .lightBalance,
            kind: .slider(EditorControlScale(-1...1, neutral: 0,
                                             unit: .signed))),

        EditorControl(
            .saturation, title: "Saturation",
            detail: "Chroma about each pixel's own luminance",
            section: .lightColor,
            kind: .slider(EditorControlScale(0...2, neutral: 1,
                                             unit: .multiplier))),
        EditorControl(
            .vibrance, title: "Vibrance",
            detail: "Chroma weighted toward the least colourful pixels",
            section: .lightColor,
            kind: .slider(EditorControlScale(-1...1, neutral: 0,
                                             unit: .signed))),

        // Grade follows the other colour decisions in the editor even though the engine applies
        // it after the print. Grouping by intent avoids another bottom-row destination.
        EditorControl(
            .gradeSpace, title: "Encoded Grade",
            detail: "Correct the encoded signal rather than the light itself",
            section: .lightGrade, kind: .toggle(restingOn: false)),
    ] + gradeBands

    // MARK: - Print

    private static let print: [EditorControl] = [
        EditorControl(
            .paper, title: "Output Medium",
            detail: "Choose where the finished image will live",
            section: .printPaper, kind: .menu, availability: .printStage),
        EditorControl(
            .printLight, title: "Viewing Illuminant",
            detail: "Choose the light used to judge a physical print",
            section: .printPaper, kind: .menu, availability: .printStage),
        EditorControl(
            .printCorrection, title: "Channel Contrast Match",
            detail: "Balance how the film's colour layers print together",
            section: .printPaper,
            kind: .slider(EditorControlScale(0...1, neutral: 0.05,
                                             unit: .percent)),
            availability: .printStage),

    ]

    /// The three-way corrector, laid out band by band rather than page by page: in a panel the bands
    /// read as one run of nine rows, which is what a colourist's corrector is.
    private static let gradeBands: [EditorControl] = [
        ("Shadows", EditorControlField.gradeShadowsWarmth,
         EditorControlField.gradeShadowsTint, EditorControlField.gradeShadowsLevel),
        ("Midtones", .gradeMidtonesWarmth, .gradeMidtonesTint,
         .gradeMidtonesLevel),
        ("Highlights", .gradeHighlightsWarmth, .gradeHighlightsTint,
         .gradeHighlightsLevel),
    ].flatMap { band -> [EditorControl] in
        let (name, warmth, tint, level) = band
        let signed = EditorControlScale(-1...1, neutral: 0, unit: .signed)
        return [
            EditorControl(warmth, title: "\(name) Warmth",
                          detail: "Cool to warm, in the \(name.lowercased())",
                          section: .lightGrade, kind: .slider(signed)),
            EditorControl(tint, title: "\(name) Tint",
                          detail: "Magenta to green, in the \(name.lowercased())",
                          section: .lightGrade, kind: .slider(signed)),
            EditorControl(level, title: "\(name) Level",
                          detail: "How far the \(name.lowercased()) are carried",
                          section: .lightGrade, kind: .slider(signed)),
        ]
    }

    // MARK: - Frame

    private static let frame: [EditorControl] = [
        EditorControl(
            .crop, title: "Crop",
            detail: "The part of the frame the print is made from",
            section: .frameGeometry, kind: .takeover),
        EditorControl(
            .straighten, title: "Straighten",
            detail: "Rotation off level, in degrees",
            section: .frameGeometry,
            kind: .slider(EditorControlScale(-15...15, neutral: 0,
                                             unit: .degrees))),
        EditorControl(
            .perspectiveVertical, title: "Vertical",
            detail: "Keystone about the horizontal axis",
            section: .frameGeometry,
            kind: .slider(EditorControlScale(-15...15, neutral: 0,
                                             unit: .degrees))),
        EditorControl(
            .perspectiveHorizontal, title: "Horizontal",
            detail: "Keystone about the vertical axis",
            section: .frameGeometry,
            kind: .slider(EditorControlScale(-15...15, neutral: 0,
                                             unit: .degrees))),
        EditorControl(
            .rotation, title: "Rotate",
            detail: "Quarter turns clockwise",
            section: .frameGeometry, kind: .menu),
        EditorControl(
            .flip, title: "Flip",
            detail: "Mirror the frame left to right",
            section: .frameGeometry, kind: .toggle(restingOn: false)),

        EditorControl(
            .selective, title: "Selective",
            detail: "The same light and colour controls, over part of the frame",
            section: .frameLocal, kind: .takeover),
    ]

    // MARK: - What is not here yet

    /// Controls intentionally omitted from the editor, with a reason. Tests require every field to
    /// appear in either `all` or `pending`.
    public static let pending: [EditorControlField: String] = [:]
}

public extension EditorControlCatalogue {
    /// The catalogue as the loaded film can take it — the panel's actual rows.
    static func controls(for stock: FilmStock?) -> [EditorControl] {
        all.compactMap { control in
            guard control.availability.admits(stock: stock) else { return nil }
            guard control.field == .push, let stock else { return control }

            // Development conditions belong to the stock, not the catalogue. Build this row from
            // its exact measurements so a future profile with a different set cannot expose a
            // condition the engine would have to interpolate or reject.
            let stops = ([Float(0)] + stock.supportedDevelopmentStops)
                .sorted()
                .map { Double($0) }
            guard let lower = stops.first, let upper = stops.last else { return nil }
            return EditorControl(
                control.field, title: control.title, detail: control.detail,
                section: control.section,
                kind: .slider(EditorControlScale(
                    lower...upper, neutral: 0, unit: .stops, stops: stops)),
                availability: control.availability, foldsUnder: control.foldsUnder)
        }
    }

    /// The rows under one section, in panel order.
    static func controls(in section: EditorControlSection,
                         for stock: FilmStock?) -> [EditorControl] {
        controls(for: stock).filter { $0.section == section }
    }

    static func control(_ field: EditorControlField) -> EditorControl? {
        all.first { $0.field == field }
    }
}

/// Classifies how each `FotufilmEngine.Options` field is supplied by the editor.
/// Tests require every new option to be classified here.
public enum EngineOptionCoverage: Sendable, Equatable {
    /// Controls on the photograph's own edit drive it.
    case control([EditorControlField])
    /// The engine reads it, but from something the editor works out rather than from a control.
    case derived(String)
    /// An app-wide setting drives it, so it is the same for every photograph and does not travel
    /// with the edit.
    case globalSetting(String)
    /// Nothing in the app drives it at all.
    case unexposed(String)
}

public extension EngineOptionCoverage {
    /// Keyed by the option's own property name, so the test can walk `FotufilmEngine.Options` and
    /// find each one.
    static let byOptionName: [String: EngineOptionCoverage] = [
        "exposureEV": .control([.exposure]),
        "sceneHeadroom": .derived(
            "the source interpretation the overflow menu sets, against the source's declared range"),
        "whiteBalance": .control([.warmth, .tint]),
        "highlights": .control([.highlights]),
        "shadows": .control([.shadows]),
        "localTone": .control([.localTone]),
        "saturation": .control([.saturation]),
        "vibrance": .control([.vibrance]),
        "grainScale": .control([.grain]),
        "grainMottleShare": .control([.grainMottle]),
        "grainMottleSizeRatio": .derived(
            "how coarse the mottle is, as a multiple of the emulsion's own clump. The Mottle "
            + "control sets how much of the grain goes into that population; how far it is "
            + "spread is the road's, because it is a question about the delivery lattice "
            + "rather than about the look — a still keeps the sheet's crystal-distribution "
            + "figure, and a clip's roads complete an explicit share with the coarser "
            + "delivery ratio (`FotufilmEngine.Options.completeDeliveryMottle`) that lands in "
            + "the band a video frame and its encoder can hold"),
        "grainModel": .control([.grainModel]),
        "halationScale": .control([.halation]),
        "halationSourceColour": .control([.halationColour]),
        "halationReturnGain": .control([.halationSpectrum]),
        "halationHazeMM": .unexposed(
            "the support's impurity scatter is the stock's own figure, stated per sheet; "
            + "the CLI exposes an override for calibration experiments, and a slider here "
            + "would be a physics field pretending to be a look"),
        "useEstimatedHalationProfile": .globalSetting(
            "Advanced Film Model settings enables provisional spatial profiles globally"),
        "flareScale": .unexposed(
            "the stage models the taking lens's veiling glare, and every picture this app "
            + "develops is a photograph whose light already went through one — turning it on "
            + "here would veil the shadows a second time. The CLI and the Resolve plugin "
            + "expose it, because those can be handed a render that has met no glass"),
        "couplerScale": .control([.couplers]),
        "couplerRangeScale": .unexposed(
            "the app sets the per-gap reaches instead, so the engine never reads this one"),
        "couplerGapReachScales": .control([.couplerReach]),
        "couplerSelfScale": .control([.couplerSelf]),
        "expiredYears": .control([.expired]),
        "shutterSeconds": .control([.shutter]),
        "developmentEV": .control([.push]),
        "bleachBypass": .control([.bleach]),
        "printCorrection": .control([.printCorrection]),
        "paper": .control([.paper]),
        "printViewingKelvin": .control([.printLight]),
        "grade": .control([.gradeShadowsWarmth, .gradeShadowsTint,
                           .gradeShadowsLevel, .gradeMidtonesWarmth,
                           .gradeMidtonesTint, .gradeMidtonesLevel,
                           .gradeHighlightsWarmth, .gradeHighlightsTint,
                           .gradeHighlightsLevel]),
        "gradeSpace": .control([.gradeSpace]),
        "format": .control([.gauge]),
        "frameCoverage": .derived("the crop"),
        "seed": .derived("the grain reroll"),
        "negativeViewing": .globalSetting(
            "Settings chooses the lightbox or scanner reading used by negative output and preview"),
        "sceneIlluminantKelvin": .derived("capture metadata"),
        "sceneIlluminantSpectrum": .derived(
            "capture metadata when a source supplies a measured illuminant spectrum; its CCT "
            + "is the fallback when only a correlated temperature is available"),
        "stage": .unexposed(
            "which span of the pipeline a render performs is a node-graph question, and the "
            + "app renders one photograph end to end; the Resolve plugin is where it is offered"),
        "textureStages": .unexposed(
            "read only by the texture span, which the app has no way of asking for"),
        "lensFilters": .derived(
            "the Lens deck's own page, which holds an ordered stack rather than a row: a filter "
            + "is a sequence a photographer adds to and reorders, and no single control in this "
            + "catalogue has that shape"),
        "diffusionFilter": .derived(
            "the same page — a mist is fitted alongside the absorbing filters and sits in the "
            + "same sequence, so one list offers both"),
        "focalLengthMM": .derived("capture metadata"),
    ]
}
