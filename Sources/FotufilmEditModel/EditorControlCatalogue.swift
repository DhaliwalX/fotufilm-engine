import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

public enum EditorControlCatalogue {

    public static let all: [EditorControl] = film + light + print + frame + pipeline

    // Browser media transport and delivery controls do not occupy film-engine
    // slots. Export their labels with the shared catalogue, separately from
    // parameters that cross the WASM / plugin bridge.
    public static let webVideoLabels: [String: String] = [
        "play": "Play", "pause": "Pause", "position": "Video position",
        "encoding": "Input color space", "trimStart": "Trim in", "trimEnd": "Trim out",
        "audio": "Include audio", "export": "Export video", "quality": "Video quality",
        "medium": "Medium", "high": "High", "veryHigh": "Very high",
        "mp4": "MP4 · H.264", "webm": "WebM · VP9", "dismiss": "Dismiss",
    ]

    public static let auxiliaries: [HostAuxiliary] = [
        HostAuxiliary(ofxName: "status", fxplugID: 37, group: nil, label: "Status",
                      kind: .label(text: "", hint: nil), surfaces: [.finalcut], order: 0),
        HostAuxiliary(ofxName: "colorSpaceStatus", group: .input, label: "Decoded Input",
                      hint: "The input encoding Fotufilm will decode. Host means Resolve supplied an "
                          + "exact OFX colour-space tag. Assumed means Resolve supplied Raw or no tag; "
                          + "select Timeline Color Space explicitly if that assumption does not match "
                          + "the image arriving at this node.",
                      kind: .label(text: "Not yet examined", hint: nil), surfaces: [.resolve], order: 20),
        HostAuxiliary(ofxName: "resolvedFormat", group: .film, label: "Resolved Format",
                      kind: .label(text: "Not yet examined", hint: nil), surfaces: [.resolve], order: 25),
        HostAuxiliary(ofxName: "stockID", fxplugID: 27, group: nil, label: "id",
                      kind: .hiddenString, order: 910),
        HostAuxiliary(ofxName: "formatID", fxplugID: 28, group: nil, label: "id",
                      kind: .hiddenString, order: 920),
        HostAuxiliary(ofxName: "paperID", fxplugID: 29, group: nil, label: "id",
                      kind: .hiddenString, order: 930),
        HostAuxiliary(ofxName: "stageID", fxplugID: 26, group: nil, label: "id",
                      kind: .hiddenString, order: 900),
        HostAuxiliary(ofxName: "lensFilter1ID", fxplugID: 81, group: nil, label: "id",
                      kind: .hiddenString, order: 940),
        HostAuxiliary(ofxName: "lensFilter2ID", fxplugID: 82, group: nil, label: "id",
                      kind: .hiddenString, order: 950),
        HostAuxiliary(ofxName: "lensFilter3ID", fxplugID: 83, group: nil, label: "id",
                      kind: .hiddenString, order: 960),
        HostAuxiliary(ofxName: "diffusionID", fxplugID: 84, group: nil, label: "id",
                      kind: .hiddenString, order: 970),
        HostAuxiliary(ofxName: "inspectorShape", fxplugID: 92, group: nil, label: "Inspector Shape",
                      kind: .hiddenString, surfaces: [.finalcut], order: 980),
        HostAuxiliary(ofxName: "pushCondition", group: .lab, label: "Push / Pull",
                      hint: "Measured development conditions for this stock. The saved stop value is "
                          + "preserved when the menu is rebuilt. Pair a push with the intended camera exposure.",
                      kind: .choice(["Reference · 0 stops"], value: 0, persistent: false),
                      surfaces: [.resolve], order: 15),
        HostAuxiliary(ofxName: "developmentStatus", group: .lab, label: "Measured Conditions",
                      kind: .label(text: "Not yet examined", hint: nil), surfaces: [.resolve], order: 16),
        HostAuxiliary(ofxName: "newSeed", group: .grainAdvanced, label: "New Seed",
                      hint: "Choose a different deterministic grain field. Included in Undo with Grain Seed.",
                      kind: .pushButton, surfaces: [.resolve], order: 30),
        HostAuxiliary(ofxName: "grainStatus", group: .grainAdvanced, label: "Grain Status",
                      kind: .label(text: "Not yet examined", hint: nil), surfaces: [.resolve], order: 40),
        HostAuxiliary(ofxName: "resolvedPaper", group: .output, label: "Resolved Medium",
                      kind: .label(text: "Not yet examined", hint: nil), surfaces: [.resolve], order: 15),
        HostAuxiliary(ofxName: "stageStatus", group: .stage, label: " ",
                      kind: .label(text: "Stage: Full — scene in, finished output out", hint: nil),
                      surfaces: [.resolve], order: 20),
        HostAuxiliary(ofxName: "textureStages", fxplugID: 40, group: .stage, label: "Texture Stages",
                      hint: "Whether Texture Only carries this stage. Ignored by every other stage, "
                          + "where the strength controls below select what runs.",
                      kind: .textureToggles, order: 30),
        HostAuxiliary(ofxName: "renderStatus", group: .render, label: "Effective Renderer",
                      kind: .label(text: "Not yet examined", hint: nil), surfaces: [.resolve], order: 20),
    ]

    public static let hostGroupOrder: [HostGroup] = [
        .input, .film, .exposure, .sceneLight, .lens, .lensAdvanced, .lab, .grain, .grainAdvanced,
        .halation, .halationSpectrum, .coupler, .couplerAdvanced, .output, .stage, .render,
    ]

    public static let retiredFxplugIDs: [Int] = [33]
    public static let fxplugTextureStageIDs: ClosedRange<Int> = 40...71
    public static let bridgeSlotCount = 53

    static let hostOnly: [EditorSurface: String] = [
        .app: "a plugin host's own setting, with no meaning on a photograph",
        .desktop: "a plugin host's own setting, with no meaning on a photograph",
        .android: "a plugin host's own setting, with no meaning on a photograph",
        .web: "the demo renders one still through a sealed pack",
        .cli: "the command line renders the full pipeline end to end",
    ]

    static let hostsOwnIt: [EditorSurface: String] = [
        .resolve: "the host owns the frame's geometry and its colour corrector",
        .finalcut: "the host owns the frame's geometry and its colour corrector",
        .web: "the demo shows one still without a frame tool",
        .cli: "the command line renders the whole frame as given",
    ]

    static let webBaked: String = "reshapes the sealed pack rather than a configuration slot"
    static let noCurveFlag: String = "no flag carries a curve"
    static let filmModelSetting: String = "Film Model settings choose it for every photograph"

    private static let signed = EditorControlScale(-1...1, neutral: 0, unit: .signed)
    private static let percent = EditorControlScale(0...1, neutral: 0, unit: .percent)

    private static let printLights: [EditorMenuChoice] = [
        EditorMenuChoice(nil, "Medium Reference · Auto",
                         detail: "D50 for photo paper, calibrated 5400 K xenon for a release print",
                         id: "reference"),
        EditorMenuChoice(5003, "Proofing Booth · D50", detail: "Standard neutral light for judging prints",
                         id: "d50"),
        EditorMenuChoice(2856, "Tungsten · 2856 K", detail: "A warm indoor lamp", id: "tungsten"),
        EditorMenuChoice(6504, "Daylight · D65", detail: "Cooler daylight", id: "d65"),
    ]

    public static let mottleShares: [EditorMenuChoice] = [
        EditorMenuChoice(nil, "Film’s Own", detail: "Use the film’s default amount", id: "film"),
        EditorMenuChoice(0, "None", detail: "No added coarse clusters", id: "none"),
        EditorMenuChoice(0.2, "Light · 20%", detail: "A small amount of coarse grain",
                         id: "light"),
        EditorMenuChoice(0.45, "Moderate · 45%", detail: "Similar amounts of fine and coarse grain",
                         id: "moderate"),
        EditorMenuChoice(0.7, "Heavy · 70%", detail: "Mostly coarse grain",
                         id: "heavy"),
        EditorMenuChoice(0.9, "Maximum · 90%", detail: "Maximum coarse grain", id: "maximum"),
    ]

    public static let shutterLadder: [Double] = [1, 2, 4, 8, 15, 30, 60, 120, 240, 480]

    public static func shutterTimes(for stock: FilmStock?) -> [Double] {
        guard let stated = stock?.reciprocityFailure, stated.lostStopsPerDecade > 0 else { return [] }
        let past = shutterLadder.filter { $0 > Double(stated.thresholdSeconds) }
        guard let end = stated.statedThroughSeconds.map(Double.init),
              let last = past.firstIndex(where: { $0 >= end })
        else { return past }
        return Array(past.prefix(through: last))
    }

    public static func shutterName(_ seconds: Double) -> String {
        guard seconds >= 60 else { return String(format: "%.0f s", seconds) }
        let minutes = seconds / 60
        return minutes == minutes.rounded()
            ? "\(Int(minutes)) min" : String(format: "%.1f min", minutes)
    }

    public static func viewingLights(for paper: PrintPaper) -> [EditorMenuChoice] {
        if !paper.acceptsViewingIlluminant {
            return [EditorMenuChoice(nil, "Display White · D65",
                                     detail: "The display's fixed white point; no viewing lamp is added",
                                     id: "reference")]
        }
        if paper.isProjected {
            return [
                EditorMenuChoice(nil, "Reference Projector · Xenon 5400 K",
                                 detail: "How a cinema release print is intended to look on screen",
                                 id: "reference"),
                EditorMenuChoice(6504, "Light Table · D65", detail: "See the film directly under cool daylight",
                                 id: "d65"),
                EditorMenuChoice(5003, "Proofing Booth · D50",
                                 detail: "Inspect the film under standard print-viewing light", id: "d50"),
                EditorMenuChoice(2856, "Tungsten · 2856 K", detail: "See the print under a warm indoor lamp",
                                 id: "tungsten"),
            ]
        }
        return [
            EditorMenuChoice(nil, "Reference Booth · D50", detail: "Standard neutral light for judging photo prints",
                             id: "reference"),
            EditorMenuChoice(6504, "Daylight · D65", detail: "See the print in cooler daylight", id: "d65"),
            EditorMenuChoice(2856, "Tungsten · 2856 K", detail: "See the print under a warm indoor lamp",
                             id: "tungsten"),
        ]
    }

    public static let rotations: [EditorMenuChoice] = [
        EditorMenuChoice(0, "Upright", id: "0"),
        EditorMenuChoice(1, "90°", id: "90"),
        EditorMenuChoice(2, "180°", id: "180"),
        EditorMenuChoice(3, "270°", id: "270"),
    ]

    private static let film: [EditorControl] = [
        EditorControl(
            .stock, title: "Film",
            detail: "Choose the film used to render the photo.",
            section: .filmStock, kind: .menu(.dynamic(.stocks)),
            drives: [],
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .web, .cli],
            host: HostParameter(
                slot: nil, ofxName: "stock", fxplugID: 2, group: .film, label: "Stock",
                hint: "The emulsion. Each is a measured stock: its own spectral sensitivity, "
                    + "characteristic curves, couplers, halation and granularity.",
                kind: .choice(.dynamic(.stocks), value: 0), order: 10),
            commandLine: CommandLineFlag("--stock", placeholder: "<name>",
                                         help: "Film stock (default: first installed). See --list-stocks",
                                         generic: false),
            documentation: "Selects the emulsion. Normal preserves the source frame without film transformation."),
        EditorControl(
            .gauge, title: "Format",
            detail: "Set the film frame size, which affects visible grain and halation.",
            section: .filmStock, kind: .menu(.dynamic(.gauges)),
            drives: ["format"],
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: "a pack is sealed for one gauge"],
            host: HostParameter(
                slot: nil, ofxName: "format", fxplugID: 3, group: .film, label: "Film Format",
                hint: "The gauge the frame is exposed on. The image height maps onto the gauge's frame "
                    + "height, so a smaller format is enlarged more and shows coarser grain, wider "
                    + "halation and stronger adjacency — the same emulsion at a different "
                    + "magnification. Match Film takes the gauge the chosen stock is known on.",
                kind: .choice(.dynamic(.gauges), value: -1), order: 20),
            commandLine: CommandLineFlag("--format", placeholder: "<name>",
                                         help: "Film gauge (default: the gauge the stock is known on). "
                                             + "\"sensor\" cuts the film to the frame the input file says "
                                             + "its camera exposed. See --list-formats",
                                         generic: false),
            documentation: "Sets physical negative dimensions. Smaller formats increase grain enlargement and spatial halation reach."),
        EditorControl(
            .frameCoverage, title: "Frame Coverage",
            detail: "Short edge of the film frame retained after the host's crop",
            section: .filmStock,
            kind: .slider(EditorControlScale(0.05...1, neutral: 1, unit: .percent)),
            scope: .hostOnly,
            binding: .frameCoverage,
            surfaces: [.resolve],
            omitted: [
                .app: "the crop tool removes pixels; coverage stands in for a crop the host owns",
                .desktop: "the crop tool removes pixels; coverage stands in for a crop the host owns",
                .android: "the crop tool removes pixels; coverage stands in for a crop the host owns",
                .finalcut: "Final Cut crops before the effect runs; not yet offered there",
                .web: webBaked,
                .cli: "the command line renders the whole frame as given",
            ],
            host: HostParameter(
                slot: 42, slotSymbol: "FRAME_COVERAGE", ofxName: "frameCoverage", group: .film,
                label: "Film Frame Coverage (%)",
                hint: "Short edge of the film frame retained after cropping. 100 uses the full frame; "
                    + "50 enlarges half the frame. Changes grain, halation and other spatial scales, "
                    + "without cropping pixels. Account for any upstream resize yourself.",
                kind: .double(min: 5, max: 100, value: 100), paramScale: 0.01, paramOffset: -1,
                bridge: .minusOne, clamp: 0.05...1, order: 30)),

        EditorControl(
            .grain, title: "Grain",
            detail: "Adjust grain strength relative to the selected film.",
            section: .filmGrain,
            kind: .slider(EditorControlScale(0...2, neutral: 1, unit: .multiplier)),
            availability: .film,
            binding: .grainScale,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .web, .cli],
            host: HostParameter(
                slot: 7, slotSymbol: "GRAIN_SCALE", ofxName: "grain", fxplugID: 14, group: .grain,
                label: "Grain", hint: "Multiplier on the stock's measured granularity. 0 disables it.",
                kind: .double(min: 0, max: 2, value: 1), clamp: 0...Double.greatestFiniteMagnitude, order: 10),
            web: .grainScale,
            commandLine: CommandLineFlag("--grain", placeholder: "<scale>",
                                         help: "Grain multiplier, 0 disables (default: 1)"),
            documentation: "Scales calibrated silver or dye-cloud grain variance. Black-and-white films use continuous silver texture so individual samples do not appear as dots."),
        EditorControl(
            .grainMottle, title: "Mottle",
            detail: "Add larger, softer clusters to the grain pattern.",
            section: .filmGrain, kind: .menu(.fixed(mottleShares)), availability: .film,
            persistence: .bespoke,
            binding: .grainMottleShare,
            surfaces: [.app, .desktop, .android, .cli],
            omitted: [
                .resolve: "offered as Mottle and Mottle Amount",
                .finalcut: "not yet offered; the share is a Full-stage control",
                .web: webBaked,
            ],
            commandLine: CommandLineFlag("--mottle", placeholder: "<share>",
                                         help: "Grain-size mixture override, 0-0.9 (default: the stock's "
                                             + "own, usually 0): the variance share of the published "
                                             + "granularity carried by a coarse second clump field — the "
                                             + "soft mottle under the sharp grain. The RMS anchor holds "
                                             + "whatever the split",
                                         generic: false),
            documentation: "Modulates low-frequency grain clump covariance."),
        EditorControl(
            .mottleOverride, title: "Mottle",
            detail: "Use the film’s default grain clumping or choose an amount.",
            section: .filmGrain,
            kind: .menu(.fixed([EditorMenuChoice(0, "Stock Default", id: "stock"),
                                EditorMenuChoice(1, "Custom", id: "custom")])),
            scope: .hostOnly,
            surfaces: [.resolve],
            omitted: hostOnly.merging([.finalcut: "not yet offered; the share is a Full-stage control"]) { $1 },
            host: HostParameter(
                slot: 29, slotSymbol: "MOTTLE_OVERRIDE", ofxName: "mottleOverride", group: .grain,
                label: "Mottle",
                hint: "Use the stock's coarse grain mixture, or set a custom share. Full mode only.",
                kind: .choice(.fixed([EditorMenuChoice(0, "Stock Default", id: "stock"),
                                      EditorMenuChoice(1, "Custom", id: "custom")]), value: 0),
                order: 20)),
        EditorControl(
            .mottleShare, title: "Mottle Amount",
            detail: "Set how much of the grain pattern comes from larger clusters.",
            section: .filmGrain,
            kind: .slider(EditorControlScale(0...0.9, neutral: 0, unit: .percent)),
            scope: .hostOnly,
            drives: ["grainMottleShare"],
            surfaces: [.resolve],
            omitted: hostOnly.merging([.finalcut: "not yet offered; the share is a Full-stage control"]) { $1 },
            host: HostParameter(
                slot: 30, slotSymbol: "MOTTLE_SHARE", ofxName: "mottleShare", group: .grain,
                label: "Mottle Amount (%)",
                hint: "Share of grain variance carried by coarse clumping. Total calibrated "
                    + "granularity is preserved. Custom mottle uses the engine's video delivery size.",
                kind: .double(min: 0, max: 90, value: 0), paramScale: 0.01, clamp: 0...0.9, order: 30)),
        EditorControl(
            .grainAnimation, title: "Grain Animation",
            detail: "Choose whether the grain pattern changes between video frames.",
            section: .filmGrain,
            kind: .menu(.fixed([EditorMenuChoice(0, "Timeline", id: "timeline"),
                                EditorMenuChoice(1, "Frozen", id: "frozen")])),
            scope: .hostOnly,
            surfaces: [.resolve],
            omitted: hostOnly.merging([.finalcut: "not yet offered; the grain follows the timeline"]) { $1 },
            host: HostParameter(
                slot: 46, slotSymbol: "GRAIN_FROZEN", ofxName: "grainAnimation", group: .grain,
                label: "Grain Animation",
                hint: "Timeline changes grain each frame. Frozen uses the same field at every time; "
                    + "the texture still responds to changes in the image.",
                kind: .choice(.fixed([EditorMenuChoice(0, "Timeline", id: "timeline"),
                                      EditorMenuChoice(1, "Frozen", id: "frozen")]), value: 0),
                order: 40)),
        EditorControl(
            .grainModel, title: "Disc Grain",
            detail: "Draw individual grains when they are large enough to be visible.",
            section: .filmGrain, kind: .toggle(restingOn: false), availability: .film,
            persistence: .key("discGrain", .same),
            binding: .discGrain,
            surfaces: [.app, .desktop, .android, .resolve, .cli],
            omitted: [.finalcut: "not yet offered; discs need Reference rendering",
                      .web: webBaked],
            host: HostParameter(
                slot: 43, slotSymbol: "GRAIN_MODEL", ofxName: "grainModel", group: .grainAdvanced,
                label: "Grain Model",
                hint: "Disc grain is available on silver-image stocks and requires Reference rendering, "
                    + "selected automatically. Subpixel grain uses the clump field; coarse mottle is "
                    + "suppressed where discs render.",
                kind: .choice(.fixed([EditorMenuChoice(0, "Clump Field", id: "clump"),
                                      EditorMenuChoice(1, "Discs", id: "discs")]), value: 0),
                order: 10),
            commandLine: CommandLineFlag("--grain-model", placeholder: "<m>",
                                         help: "clump (default) or discs. `discs` lays Boolean discs at "
                                             + "the film's clump radius, scaled onto its published "
                                             + "granularity, instead of a blurred clump field: the texture "
                                             + "survives enlargement, saturates where discs overlap, and "
                                             + "only differs once a disc covers a pixel. Costs about 5x "
                                             + "the pixels and a one-off minute of pipeline build",
                                         generic: false),
            documentation: "Enables discrete tabular grain disc rendering where emulsion grain clumps resolve at output pixels."),
        EditorControl(
            .seed, title: "Grain Seed",
            detail: "Choose a grain pattern. The same seed and frame produce the same pattern.",
            section: .filmGrain, kind: .takeover, availability: .film,
            persistence: .bespoke,
            binding: .seed,
            surfaces: [.resolve, .finalcut, .cli],
            omitted: [
                .app: "rerolled with New Grain Pattern",
                .desktop: "rerolled with New Grain Pattern",
                .android: "rerolled with New Grain Pattern",
                .web: webBaked,
            ],
            host: HostParameter(
                slot: nil, ofxName: "seed", fxplugID: 21, group: .grainAdvanced, label: "Grain Seed",
                hint: "Same seed and same frame give the same grain. Grain also advances with the "
                    + "timeline, so a still frame is still, and a moving one is not.",
                kind: .integer(min: 0, max: Int(Int32.max), value: 0x46494C4D), animates: false,
                order: 20),
            commandLine: CommandLineFlag("--seed", placeholder: "<n>",
                                         help: "Grain random seed (default: fixed)", generic: false)),

        EditorControl(
            .halationModel, title: "Halation Model",
            detail: "Choose how light is scattered and reflected within the film.",
            section: .filmEmulsion,
            kind: .menu(.fixed([EditorMenuChoice(0, "Legacy", detail: "Original film halation", id: "legacy"),
                                EditorMenuChoice(1, "Layered Transport", detail: "Illustrative film stack",
                                                 id: "layered")])),
            scope: .global(settingKey: "fotufilm.halation-model"),
            binding: .halationModelIndex,
            surfaces: [.resolve, .finalcut, .web, .cli],
            omitted: [.app: filmModelSetting, .desktop: filmModelSetting, .android: filmModelSetting],
            host: HostParameter(
                slot: 49, slotSymbol: "HALATION_MODEL", ofxName: "halationModel", fxplugID: 88,
                group: .halation, label: "Halation Model",
                hint: "Legacy or layered optical transport. Unmeasured stacks use an illustrative construction.",
                kind: .choice(.fixed([EditorMenuChoice(0, "Legacy", id: "legacy"),
                                      EditorMenuChoice(1, "Layered Transport", id: "layered")]), value: 0),
                order: 10),
            commandLine: CommandLineFlag("--halation-model", placeholder: "<legacy|layered>",
                                         help: "Halation model (default: legacy)")),
        EditorControl(
            .halation, title: "Halation",
            detail: "Adjust the glow around bright areas caused by light reflecting inside the film.",
            section: .filmEmulsion,
            kind: .slider(EditorControlScale(HalationAmount.travel, neutral: 0,
                                             unit: .stopsFromOff,
                                             admitted: HalationAmount.admitted)),
            availability: .film,
            persistence: .key("halation", .scaleFromStops),
            binding: .halationStops,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: webBaked],
            host: HostParameter(
                slot: 8, slotSymbol: "HALATION_SCALE", ofxName: "halation", fxplugID: 15, group: .halation,
                label: "Halation",
                hint: "Multiplier on the fraction of light the base returns. On the legacy model it "
                    + "scales the light going down rather than the finished halo, so raising it widens "
                    + "the halo as well as brightening it — the way a thinner antihalation layer would. "
                    + "With Estimated Halation Shape on, the film's geometry is pinned and this scales "
                    + "the amount alone. 1 is the stock's authored look — the sheet's look scale times "
                    + "the measured film, whose calibrated returns sit at the patent-floor absorber "
                    + "densities and are all but invisible on their own. The measured film survives at "
                    + "1 over the look scale (0.025 on a rem-jet stock). Typing past the slider reaches 100.",
                kind: .double(min: 0, max: 10, value: 1, hardMax: 100), bridge: .multipleFromStops,
                binding: .halationScale, clamp: 0...Double.greatestFiniteMagnitude, order: 20),
            commandLine: CommandLineFlag("--halation", placeholder: "<scale>",
                                         help: "Halation multiplier, 0 disables (default: 1)"),
            documentation: "Controls back-surface reflection and scatter around high-contrast exposure boundaries."),
        EditorControl(
            .estimatedHalation, title: "Estimated Halation Shape",
            detail: "Use an estimated halo shape when the film has no measured shape.",
            section: .filmEmulsion, kind: .toggle(restingOn: false),
            scope: .global(settingKey: "fotufilm.estimated-halation"),
            binding: .estimatedHalationProfile,
            surfaces: [.resolve, .finalcut, .cli],
            omitted: [.app: filmModelSetting, .desktop: filmModelSetting, .android: filmModelSetting,
                      .web: webBaked],
            host: HostParameter(
                slot: 19, slotSymbol: "ESTIMATED_HALATION", ofxName: "estimatedHalation", fxplugID: 16,
                group: .halation, label: "Estimated Halation Shape",
                hint: "Renders halation through the stock's provisional annular profile — the reflex "
                    + "ring at the base's critical angle — where no independently calibrated profile "
                    + "exists. Off is the legacy Gaussian model and the render every existing project "
                    + "made; the annular road costs roughly half again as much frame time.",
                kind: .boolean(value: false), order: 30),
            commandLine: CommandLineFlag("--estimated-halation", placeholder: "",
                                         help: "Use provisional spatial profiles where a stock has no "
                                             + "independently calibrated profile (default: off)")),
        EditorControl(
            .halationColour, title: "Halo Colour",
            detail: "Control how much the halo keeps the color of the light source.",
            section: .filmEmulsion,
            kind: .slider(EditorControlScale(0...1, neutral: 0, unit: .percent)),
            availability: .colourNegative,
            binding: .halationSourceColour,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: webBaked],
            host: HostParameter(
                slot: 20, slotSymbol: "HALATION_COLOUR", ofxName: "halationColour", fxplugID: 17,
                group: .halation, label: "Halo Colour",
                hint: "How much the halo keeps the source's own colour instead of the film's layered "
                    + "red. The returning light re-enters the emulsion from below, so a colour film's "
                    + "ring is red whatever the light was; raising this lifts the dimmer records to the "
                    + "strongest record's return, and the ring brightens toward the light's colour. 0 is the film.",
                kind: .double(min: 0, max: 1, value: 0), clamp: 0...1, order: 40),
            commandLine: CommandLineFlag("--halation-colour", placeholder: "<f>",
                                         help: "How much the halo keeps the source's own colour instead "
                                             + "of the stock's layered red, 0-1 (default: 0). The dimmer "
                                             + "records are raised to the strongest record's return, so "
                                             + "the ring brightens toward the light's colour"),
            documentation: "Shifts negative halation toward source light spectrum."),
        EditorControl(
            .halationSpectrum, title: "Return Spectrum",
            detail: "Adjust which colors the film base reflects back into the image.",
            section: .filmEmulsion,
            kind: .curve(EditorControlCurve(
                handles: HalationSpectrum.handleNM.map { Double($0) },
                domain: 380...780,
                range: Double(HalationSpectrum.travelStops.lowerBound)
                    ... Double(HalationSpectrum.travelStops.upperBound),
                neutral: Double(HalationSpectrum.neutralStops),
                unit: .stops)),
            availability: .film,
            foldsUnder: .halation,
            binding: .halationReturnGain,
            surfaces: [.app, .desktop, .resolve],
            omitted: [
                .android: "the Android panel draws no curve rows yet",
                .finalcut: "not yet offered; seven sliders would need seven ids",
                .web: webBaked,
                .cli: noCurveFlag,
            ],
            host: HostParameter(
                slot: 34, slotSymbol: "HALATION_400", ofxName: "halation", group: .halationSpectrum,
                label: "nm (stops)",
                hint: "Gain over the stock's halation return spectrum. 0 preserves the stock; positive "
                    + "values strengthen this band. Does not create return in an absent band.",
                kind: .double(min: -6, max: 6, value: 0), order: 10),
            documentation: "Selects base reflectance spectral weighting."),
        EditorControl(
            .couplers, title: "Couplers",
            detail: "Adjust how development affects color separation and edge contrast.",
            section: .filmEmulsion,
            kind: .slider(EditorControlScale(0...2, neutral: 1, unit: .multiplier)),
            availability: .film,
            binding: .couplerScale,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: webBaked],
            host: HostParameter(
                slot: 9, slotSymbol: "COUPLER_SCALE", ofxName: "couplers", fxplugID: 19, group: .coupler,
                label: "DIR Couplers",
                hint: "Multiplier on inter-image inhibition, the mechanism behind the stock's colour "
                    + "separation and its Mackie lines. 0 disables it.",
                kind: .double(min: 0, max: 2, value: 1), clamp: 0...Double.greatestFiniteMagnitude, order: 10),
            commandLine: CommandLineFlag("--couplers", placeholder: "<scale>",
                                         help: "DIR + adjacency strength; 1 calibrated, overdrive compressed (default: 1)"),
            documentation: "Controls development inhibitor release chemistry for interlayer color separation and edge contrast."),
        EditorControl(
            .couplerReach, title: "Separation",
            detail: "Adjust how strongly neighboring film layers affect each other during development.",
            section: .filmEmulsion,
            kind: .slider(EditorControlScale(0...3, neutral: 1, unit: .multiplier)),
            availability: .couplerGeometry,
            persistence: .bespoke,
            binding: .couplerGapReach,
            surfaces: [.app, .desktop, .android, .resolve, .cli],
            omitted: [.finalcut: "not yet offered; needs the coupler-geometry gate",
                      .web: webBaked],
            host: HostParameter(
                slot: 31, slotSymbol: "COUPLER_REACH", ofxName: "couplerReach", group: .coupler,
                label: "Separation",
                hint: "Interlayer inhibitor reach. 1 preserves the stock; 0 seals the layers off.",
                kind: .double(min: 0, max: 3, value: 1), paramOffset: -1, bridge: .minusOne,
                clamp: 0...3, order: 20),
            commandLine: CommandLineFlag("--coupler-reach", placeholder: "<scale>",
                                         help: "Interlayer inhibitor reach as a multiple of the stock's "
                                             + "own geometry, 0-3 (default: 1)"),
            documentation: "Scales how far the released inhibitor crosses each interlayer."),
        EditorControl(
            .couplerSelf, title: "Edge Contrast",
            detail: "Adjust the local contrast around edges created during development.",
            section: .filmEmulsion,
            kind: .slider(EditorControlScale(0...3, neutral: 1, unit: .multiplier)),
            availability: .couplerGeometry,
            binding: .couplerSelf,
            surfaces: [.app, .desktop, .android, .resolve, .cli],
            omitted: [.finalcut: "not yet offered; needs the coupler-geometry gate",
                      .web: webBaked],
            host: HostParameter(
                slot: 32, slotSymbol: "COUPLER_SELF", ofxName: "couplerSelf", group: .coupler,
                label: "Edge Contrast",
                hint: "Within-layer inhibition. 1 preserves the stock's retained self-inhibition.",
                kind: .double(min: 0, max: 3, value: 1), paramOffset: -1, bridge: .minusOne,
                clamp: 0...3, order: 30),
            commandLine: CommandLineFlag("--coupler-self", placeholder: "<scale>",
                                         help: "Within-layer inhibition as a multiple of the stock's "
                                             + "own, 0-3 (default: 1)"),
            documentation: "Scales inhibition acting within a layer rather than across two."),
        EditorControl(
            .couplerRedGreen, title: "Red–Green Reach",
            detail: "Adjust the separation between the red and green layers.",
            section: .filmEmulsion,
            kind: .slider(EditorControlScale(0...3, neutral: 1, unit: .multiplier)),
            availability: .couplerGeometry,
            scope: .hostOnly,
            surfaces: [.resolve],
            omitted: hostOnly.merging([.finalcut: "not yet offered; needs the coupler-geometry gate"]) { $1 },
            host: HostParameter(
                slot: 47, slotSymbol: "COUPLER_RED_GREEN", ofxName: "couplerRedGreen", group: .couplerAdvanced,
                label: "Red–Green Reach",
                hint: "Additional multiplier on Separation for the red–green interlayer.",
                kind: .double(min: 0, max: 3, value: 1), paramOffset: -1, bridge: .minusOne,
                clamp: 0...3, order: 10)),
        EditorControl(
            .couplerGreenBlue, title: "Green–Blue Reach",
            detail: "Adjust the separation between the green and blue layers.",
            section: .filmEmulsion,
            kind: .slider(EditorControlScale(0...3, neutral: 1, unit: .multiplier)),
            availability: .couplerGeometry,
            scope: .hostOnly,
            surfaces: [.resolve],
            omitted: hostOnly.merging([.finalcut: "not yet offered; needs the coupler-geometry gate"]) { $1 },
            host: HostParameter(
                slot: 48, slotSymbol: "COUPLER_GREEN_BLUE", ofxName: "couplerGreenBlue", group: .couplerAdvanced,
                label: "Green–Blue Reach",
                hint: "Additional multiplier on Separation for the green–blue interlayer.",
                kind: .double(min: 0, max: 3, value: 1), paramOffset: -1, bridge: .minusOne,
                clamp: 0...3, order: 20)),
        EditorControl(
            .chromaticFringeAmount, title: "Fringe Amount",
            detail: "Add a broader color effect around edges.",
            section: .filmEmulsion,
            kind: .slider(EditorControlScale(0...1, neutral: 0, unit: .percent)),
            availability: .interlayerInhibition,
            binding: .chromaticFringeAmount,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: webBaked],
            host: HostParameter(
                slot: 50, slotSymbol: "FRINGE_AMOUNT", ofxName: "fringeAmount", fxplugID: 89,
                group: .coupler, label: "Fringe Amount",
                hint: "Broad inter-layer transport fraction, 0-1. 0 keeps the stock's own transport.",
                kind: .double(min: 0, max: 1, value: 0), zeroLeavesEngineDefault: true, order: 40),
            commandLine: CommandLineFlag("--fringe-amount", placeholder: "<f>",
                                         help: "Broad inter-layer transport fraction, 0-1 (default: stock, normally 0)",
                                         range: 0...1),
            documentation: "Spreads a share of inter-layer inhibition farther around colour boundaries."),
        EditorControl(
            .chromaticFringeRadius, title: "Fringe Radius",
            detail: "Set the width of the color fringe. Requires Fringe Amount above zero.",
            section: .filmEmulsion,
            kind: .slider(EditorControlScale(20...300, neutral: 100, unit: .micrometers)),
            availability: .interlayerInhibition,
            foldsUnder: .chromaticFringeAmount,
            binding: .chromaticFringeRadiusMicrometers,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: webBaked],
            host: HostParameter(
                slot: 51, slotSymbol: "FRINGE_RADIUS", ofxName: "fringeRadius", fxplugID: 90,
                group: .coupler, label: "Fringe Radius (µm)",
                hint: "Broad transport Gaussian sigma on the film, 20-300 micrometers. Read only "
                    + "while Fringe Amount is above zero; 0 keeps the stock's own radius.",
                kind: .double(min: 0, max: 300, value: 0, delta: 1), zeroLeavesEngineDefault: true,
                order: 50),
            commandLine: CommandLineFlag("--fringe-radius", placeholder: "<um>",
                                         help: "Broad transport Gaussian sigma on the film, 0-2000 micrometers "
                                             + "(default: stock, normally 100; must exceed the stock's core radius)",
                                         range: 0...2000),
            documentation: "Sets the broad spread on the film in micrometres."),

        EditorControl(
            .push, title: "Push",
            detail: "Choose a measured push or pull development setting for this film.",
            section: .filmLab,
            kind: .slider(EditorControlScale(-2...2, neutral: 0, unit: .stops,
                                             stops: [-2, 0, 1, 2])),
            availability: .measuredDevelopment,
            binding: .developmentEV,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: webBaked],
            host: HostParameter(
                slot: 12, slotSymbol: "PUSH_PULL", ofxName: "push", fxplugID: 22, group: .lab,
                label: "Push / Pull",
                hint: "Measured push or pull conditions for this film's stated developer, dilution, "
                    + "temperature and agitation. The control is disabled when the stock pack has no "
                    + "measured response.",
                kind: .double(min: -2, max: 2, value: 0), animates: false, secret: true, order: 10),
            commandLine: CommandLineFlag("--push", placeholder: "<stops>",
                                         help: "Push (positive) or pull (negative) development, in stops "
                                             + "(default: 0). Must name an exact condition measured for "
                                             + "this stock's stated developer, dilution, temperature and "
                                             + "agitation; stocks or stop values without measurements are "
                                             + "rejected. Pair a push with its exposure change via --ev",
                                         generic: false),
            documentation: "Adjusts chemical development timing using measured push/pull sensitometry curves."),
        EditorControl(
            .bleach, title: "Bleach Bypass",
            detail: "Leave silver in the negative to increase contrast and reduce color saturation.",
            section: .filmLab,
            kind: .chips(EditorControlScale(0...1, neutral: 0, unit: .percent),
                         choices: [EditorControlChoice(0, "Off"),
                                   EditorControlChoice(0.5, "Half"),
                                   EditorControlChoice(1, "Full")]),
            availability: .colourNegative,
            binding: .bleachBypass,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: webBaked],
            host: HostParameter(
                slot: 13, slotSymbol: "BLEACH_BYPASS", ofxName: "bleachBypass", fxplugID: 23, group: .lab,
                label: "Bleach Bypass",
                hint: "How much of the developed silver the bleach leaves in the negative. The "
                    + "retained silver is a black-and-white image over the colour one: contrast up, "
                    + "chroma down, together.",
                kind: .double(min: 0, max: 1, value: 0), clamp: 0...1, order: 20),
            commandLine: CommandLineFlag("--bleach-bypass", placeholder: "<f>",
                                         help: "Fraction of the developed silver the bleach leaves in the "
                                             + "negative, 0-1 (default: 0). The print re-times on the "
                                             + "denser mid-grey, so what changes is contrast and chroma. "
                                             + "Colour negative only"),
            documentation: "Retains metallic silver in color negative processing, increasing contrast and lowering dye saturation."),
        EditorControl(
            .expired, title: "Expired",
            detail: "Simulate film stored at room temperature past its expiry date, in years.",
            section: .filmLab,
            kind: .slider(EditorControlScale(0...20, neutral: 0, unit: .years,
                                             stops: [0, 5, 10, 20], admitted: 0...30)),
            availability: .film,
            persistence: .key("expiredYears", .same),
            binding: .expiredYears,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: webBaked],
            host: HostParameter(
                slot: 14, slotSymbol: "EXPIRED_YEARS", ofxName: "expired", fxplugID: 24, group: .lab,
                label: "Film Age (years)",
                hint: "Years the roll sat past its process-by date. Speed falls a stop a decade with "
                    + "the blue-sensitive layer going first, base fog rises, and grain rises with the "
                    + "fog — the muddy, crossed toe of an old roll.",
                kind: .double(min: 0, max: 30, value: 0, delta: 0.1), clamp: 0...Double.greatestFiniteMagnitude, order: 30),
            commandLine: CommandLineFlag("--expired", placeholder: "<years>",
                                         help: "Years past the process-by date at room temperature "
                                             + "(default: 0). One stop per decade slower, blue layer "
                                             + "first; base fog and grain rise with it. Add the stop the "
                                             + "lab rule asks for with --ev to keep the mids"),
            documentation: "Simulates room-temperature aging: speed loss, baseline fog density, increased grain, and layer sensitivity drift."),
        EditorControl(
            .shutter, title: "Long Exposure",
            detail: "Set exposure time to apply the film’s measured long-exposure correction.",
            section: .filmLab, kind: .menu(.dynamic(.shutterTimes)),
            availability: .statedReciprocity,
            persistence: .bespoke,
            binding: .shutterSeconds,
            surfaces: [.app, .desktop, .android, .resolve, .cli],
            omitted: [.finalcut: "not yet offered; needs the reciprocity gate", .web: webBaked],
            host: HostParameter(
                slot: 44, slotSymbol: "SHUTTER_SECONDS", ofxName: "shutterSeconds", group: .lab,
                label: "Long Exposure (s)",
                hint: "Exposure duration for the stock's measured reciprocity response. 0 disables "
                    + "the override. Corrections stop at the last measured duration; no motion blur "
                    + "is added. Use the same value in paired Negative Only and Print Only nodes.",
                kind: .double(min: 0, max: 3600, value: 0, delta: 1), order: 40),
            commandLine: CommandLineFlag("--shutter", placeholder: "<secs>",
                                         help: "Exposure time in seconds (default: instantaneous). When "
                                             + "the stock's datasheet publishes a long-exposure table the "
                                             + "emulsion leaves the reciprocity law as that table states, "
                                             + "frozen past the table's last row; a sheet that states no "
                                             + "table holds the law. The print re-times the mid; shadows "
                                             + "slide into the toe and any unequal failure casts the ends"),
            documentation: "Evaluates the emulsion's measured reciprocity failure characteristics under low-intensity long exposures."),
    ]

    private static let light: [EditorControl] = [
        EditorControl(
            .lensFilter1, title: "Filter 1",
            detail: "Add a lens filter that changes the amount or color of incoming light.",
            section: .lensGlass, kind: .menu(.dynamic(.lensFilters)),
            persistence: .bespoke,
            drives: ["lensFilters"],
            surfaces: [.resolve, .finalcut, .cli],
            omitted: [.app: "the Lens deck's filter page holds an ordered stack",
                      .desktop: "the Lens panel's filter list holds an ordered stack",
                      .android: "no lens filters on Android yet",
                      .web: webBaked],
            host: HostParameter(
                slot: 21, slotSymbol: "LENS_FILTER_1", ofxName: "lensFilter1", fxplugID: 73, group: .lens,
                label: "Filter 1",
                hint: "An absorbing filter on the front of the lens. It is integrated spectrally against "
                    + "the chosen film's own three layer sensitivities, which is why the same filter is a "
                    + "different filter on a different stock — an 85B is a correction on tungsten film "
                    + "and a heavy warm cast on daylight film. It also adds the veiling glare of two more "
                    + "air-glass faces, whatever the Veiling Glare slider says — and that added glare is "
                    + "why this control is live only on the Full stage: no kernel this build carries can "
                    + "measure it in a span that ends at the developed negative.",
                kind: .choice(.dynamic(.lensFilters), value: 0), composed: true, order: 10),
            commandLine: CommandLineFlag("--filter", placeholder: "<ids>",
                                         help: "Absorbing filters on the front of the lens, comma separated "
                                             + "and applied in order: w85b, w80a, w25, nd09, cc20m and the "
                                             + "rest of the Wratten catalogue. Integrated spectrally "
                                             + "against the stock's own layer sensitivities, so the same "
                                             + "filter is a different filter on a different film",
                                         generic: false)),
        EditorControl(
            .lensFilter2, title: "Filter 2",
            detail: "Add a second lens filter.",
            section: .lensGlass, kind: .menu(.dynamic(.lensFilters)),
            persistence: .bespoke,
            drives: ["lensFilters"],
            surfaces: [.resolve, .finalcut],
            omitted: [.app: "the Lens deck's filter page holds an ordered stack",
                      .desktop: "the Lens panel's filter list holds an ordered stack",
                      .android: "no lens filters on Android yet",
                      .web: webBaked,
                      .cli: "--filter takes the whole stack"],
            host: HostParameter(
                slot: 22, slotSymbol: "LENS_FILTER_2", ofxName: "lensFilter2", fxplugID: 74, group: .lens,
                label: "Filter 2",
                hint: "A second filter, behind the first. They stack in the order given: their "
                    + "transmittances multiply, and the gap between them makes a ghost of its own.",
                kind: .choice(.dynamic(.lensFilters), value: 0), composed: true, order: 20)),
        EditorControl(
            .lensFilter3, title: "Filter 3",
            detail: "Add a third lens filter.",
            section: .lensGlass, kind: .menu(.dynamic(.lensFilters)),
            persistence: .bespoke,
            drives: ["lensFilters"],
            surfaces: [.resolve, .finalcut],
            omitted: [.app: "the Lens deck's filter page holds an ordered stack",
                      .desktop: "the Lens panel's filter list holds an ordered stack",
                      .android: "no lens filters on Android yet",
                      .web: webBaked,
                      .cli: "--filter takes the whole stack"],
            host: HostParameter(
                slot: 23, slotSymbol: "LENS_FILTER_3", ofxName: "lensFilter3", fxplugID: 75, group: .lens,
                label: "Filter 3", hint: "A third filter, behind the second.",
                kind: .choice(.dynamic(.lensFilters), value: 0), composed: true, order: 30)),
        EditorControl(
            .metering, title: "Metering",
            detail: "Choose how exposure compensates for light lost through the filters.",
            section: .lensGlass, kind: .menu(.dynamic(.meterings)),
            persistence: .bespoke,
            drives: ["lensFilters"],
            surfaces: [.resolve, .finalcut, .cli],
            omitted: [.app: "chosen on the Lens deck's filter page",
                      .desktop: "chosen on the Lens panel's filter list",
                      .android: "no lens filters on Android yet",
                      .web: webBaked],
            host: HostParameter(
                slot: 24, slotSymbol: "LENS_METERING", ofxName: "metering", fxplugID: 76, group: .lens,
                label: "Metering",
                hint: "How the exposure was set with those filters fitted. Metered through is the "
                    + "camera's own photopic cell reading the light that got past the glass, and is "
                    + "the default; it can underexpose behind a narrow filter, because the meter does "
                    + "not use the film's sensitivity. Filter factor is the published compensation, "
                    + "worked out against the emulsion, which restores the luminance record without "
                    + "cancelling the colour change. None is a fixed manual exposure, so the light "
                    + "the filter took lands on the film as underexposure. Ignored with no filter "
                    + "fitted, and live only on the Full stage, which is the only span a filter is live in.",
                kind: .choice(.dynamic(.meterings), value: 1), paramOffset: 1, bridge: .indexPlusOne,
                order: 40),
            commandLine: CommandLineFlag("--metering", placeholder: "<m>",
                                         help: "How the exposure was set behind the filter: ttl (default, "
                                             + "the camera's own photopic cell), factor (the published "
                                             + "filter factor, worked out against the emulsion) or none "
                                             + "(a fixed manual exposure, so the light loss lands on the film)",
                                         generic: false)),
        EditorControl(
            .diffusion, title: "Diffusion",
            detail: "Add a filter that softens detail and spreads bright highlights.",
            section: .lensGlass, kind: .menu(.dynamic(.diffusionFamilies)),
            persistence: .bespoke,
            drives: ["diffusionFilter"],
            surfaces: [.resolve, .finalcut, .cli],
            omitted: [.app: "fitted on the Lens deck's filter page",
                      .desktop: "fitted on the Lens panel's filter list",
                      .android: "no lens filters on Android yet",
                      .web: webBaked],
            host: HostParameter(
                slot: 25, slotSymbol: "DIFFUSION_FAMILY", ofxName: "diffusion", fxplugID: 77, group: .lens,
                label: "Diffusion",
                hint: "A diffusion filter on the front of the lens. A share of the light meets a "
                    + "particle and leaves in a new direction, and the lens images it somewhere else "
                    + "on the frame; the share that missed every particle is untouched, which is why "
                    + "a diffused picture keeps its edges instead of going soft. The black families "
                    + "carry absorbing particles: the blacks still lift and the highlights bloom much less.",
                kind: .choice(.dynamic(.diffusionFamilies), value: 0), composed: true, order: 50),
            commandLine: CommandLineFlag("--diffusion", placeholder: "<f>",
                                         help: "A diffusion filter: promist, blackpromist, glimmerglass, "
                                             + "blackglimmerglass, fog, blackfog. A share of the light "
                                             + "meets a particle and is scattered or absorbed; the share "
                                             + "that missed every particle stays sharp",
                                         generic: false)),
        EditorControl(
            .diffusionGrade, title: "Diffusion Grade",
            detail: "Set the diffusion filter strength using its marked grade.",
            section: .lensGlass, kind: .menu(.dynamic(.diffusionGrades)),
            persistence: .bespoke,
            drives: ["diffusionFilter"],
            surfaces: [.resolve, .finalcut, .cli],
            omitted: [.app: "fitted on the Lens deck's filter page",
                      .desktop: "fitted on the Lens panel's filter list",
                      .android: "no lens filters on Android yet",
                      .web: webBaked],
            host: HostParameter(
                slot: 26, slotSymbol: "DIFFUSION_GRADE", ofxName: "diffusionGrade", fxplugID: 78,
                group: .lens, label: "Diffusion Grade",
                hint: "The particle loading a product line's 1/8, 1/4, 1/2, 1 and 2 name: one "
                    + "formulation more heavily loaded, so the grade moves how much light takes part "
                    + "and never how far it goes. Ignored with no diffusion filter fitted.",
                kind: .choice(.dynamic(.diffusionGrades), value: 1), order: 60),
            commandLine: CommandLineFlag("--diffusion-grade", placeholder: "<g>",
                                         help: "1/8, 1/4, 1/2, 1 or 2 (default: 1/4)", generic: false)),
        EditorControl(
            .focalLength, title: "Focal Length",
            detail: "Set the lens focal length used to calculate the diffusion effect.",
            section: .lensGlass,
            kind: .slider(EditorControlScale(0...300, neutral: 0, unit: .millimetres)),
            scope: .hostOnly,
            binding: .focalLengthMM,
            surfaces: [.resolve, .finalcut, .cli],
            omitted: [.app: "read from the capture metadata",
                      .desktop: "read from the capture metadata",
                      .android: "read from the capture metadata",
                      .web: webBaked],
            host: HostParameter(
                slot: 27, slotSymbol: "FOCAL_LENGTH", ofxName: "focalLength", fxplugID: 79, group: .lens,
                label: "Focal Length",
                hint: "The taking lens's focal length in millimetres, read only by the diffusion "
                    + "filter: a ray deviated by an angle ahead of the lens lands focal length times "
                    + "that angle off its unscattered position, so the same filter glows bigger on a "
                    + "longer lens, exactly as it does in the world. 0 — the default — is the gauge's "
                    + "own normal lens, which is what the grade numbering on a filter's ring is "
                    + "calibrated around.",
                kind: .double(min: 0, max: 300, value: 0, delta: 1), order: 70),
            commandLine: CommandLineFlag("--focal", placeholder: "<mm>",
                                         help: "Lens focal length. Read by the diffusion filter, whose "
                                             + "halo is focal length times scattering angle — the reason "
                                             + "the same filter glows bigger on a longer lens. Default: "
                                             + "the gauge's own normal lens")),
        EditorControl(
            .flare, title: "Veiling Glare",
            detail: "Adjust scattered lens light that lifts dark areas and reduces contrast.",
            section: .lensGlass,
            kind: .slider(EditorControlScale(0...2, neutral: 0, unit: .multiplier)),
            scope: .hostOnly,
            binding: .flareScale,
            surfaces: [.resolve, .finalcut, .cli],
            omitted: [.app: "every photograph the app develops already carries its own lens's glare",
                      .desktop: "every photograph the app develops already carries its own lens's glare",
                      .android: "every photograph the app develops already carries its own lens's glare",
                      .web: webBaked],
            host: HostParameter(
                slot: 18, slotSymbol: "FLARE_SCALE", ofxName: "flare", fxplugID: 18, group: .lens,
                label: "Veiling Glare",
                hint: "Veiling glare from the taking lens, as a multiplier on the stock's figure. It "
                    + "defaults to 0 because a photographed clip already carries the glare of the lens "
                    + "that shot it, and this stage would veil the shadows a second time. Raise it for "
                    + "light that has met no glass — a render or a synthetic chart — or to stand in "
                    + "for glass worse than the camera's.",
                kind: .double(min: 0, max: 2, value: 0), clamp: 0...Double.greatestFiniteMagnitude, order: 80),
            commandLine: CommandLineFlag("--flare", placeholder: "<scale>",
                                         help: "Taking-lens veiling glare, 1 enables (default: 0 — a "
                                             + "photographed source already carries its own lens's glare)")),
        EditorControl(
            .filterCoating, title: "Filter Coating",
            detail: "Choose the coating used on the fitted lens filters.",
            section: .lensGlass,
            kind: .menu(.fixed([EditorMenuChoice(0, "Multi-coated", id: "multiCoated"),
                                EditorMenuChoice(1, "Single-coated", id: "singleLayer"),
                                EditorMenuChoice(2, "Uncoated", id: "uncoated")])),
            scope: .hostOnly,
            surfaces: [.resolve, .cli],
            omitted: [.app: "the Lens deck's filters are multi-coated",
                      .desktop: "the Lens panel's filters are multi-coated",
                      .android: "no lens filters on Android yet",
                      .finalcut: "not yet offered; the filters are multi-coated",
                      .web: webBaked],
            host: HostParameter(
                slot: 41, slotSymbol: "FILTER_COATING", ofxName: "filterCoating", group: .lensAdvanced,
                label: "Filter Coating",
                hint: "Coating on every fitted absorbing and diffusion filter. Changes transmission "
                    + "and added glare. Multicoated preserves the existing filter look.",
                kind: .choice(.fixed([EditorMenuChoice(0, "Multi-coated", id: "multiCoated"),
                                      EditorMenuChoice(1, "Single-coated", id: "singleLayer"),
                                      EditorMenuChoice(2, "Uncoated", id: "uncoated")]), value: 0),
                order: 10),
            commandLine: CommandLineFlag("--filter-coating", placeholder: "<c>",
                                         help: "uncoated, singleLayer or multiCoated (default). Sets "
                                             + "what each face reflects, and so what the filter costs in "
                                             + "light and adds in veiling glare",
                                         generic: false)),

        EditorControl(
            .lensCorrection, title: "Lens Correction",
            detail: "Correct lens distortion, dark corners, and color fringing.",
            section: .lensCorrection, kind: .toggle(restingOn: false),
            persistence: .key("lensCorrectionEnabled", .same),
            surfaces: [.app, .desktop],
            omitted: hostsOwnIt.merging([.android: "no lens correction on Android yet"]) { $1 },
            documentation: "Enables the matched lens profile or the calibrated camera profile."),
        EditorControl(
            .lensProfile, title: "Lens",
            detail: "Choose a lens profile or use the match from the photo’s metadata.",
            section: .lensCorrection, kind: .menu(.dynamic(.lensProfiles)),
            surfaces: [.app, .desktop],
            omitted: hostsOwnIt.merging([.android: "no lens correction on Android yet"]) { $1 },
            documentation: "Identifies the matched lens model."),
        EditorControl(
            .lensAmount, title: "Amount",
            detail: "Adjust the strength of the lens correction.",
            section: .lensCorrection,
            kind: .slider(EditorControlScale(0...1, neutral: 1, unit: .percent)),
            persistence: .key("lensProfileAmount", .same),
            surfaces: [.app, .desktop],
            omitted: hostsOwnIt.merging([.android: "no lens correction on Android yet"]) { $1 },
            documentation: "Sets overall correction intensity."),
        EditorControl(
            .lensDistortion, title: "Distortion",
            detail: "Adjust curved edges: negative values add barrel distortion; positive values add pincushion distortion.",
            section: .lensCorrection, kind: .slider(signed),
            persistence: .bespoke,
            surfaces: [.app, .desktop],
            omitted: hostsOwnIt.merging([.android: "no lens correction on Android yet"]) { $1 },
            documentation: "Corrects or introduces radial barrel and pincushion distortion."),
        EditorControl(
            .lensVignetting, title: "Vignetting",
            detail: "Darken the corners with negative values or brighten them with positive values.",
            section: .lensCorrection, kind: .slider(signed),
            persistence: .bespoke,
            surfaces: [.app, .desktop],
            omitted: hostsOwnIt.merging([.android: "no lens correction on Android yet"]) { $1 },
            documentation: "Compensates for peripheral illumination falloff."),
        EditorControl(
            .lensRedCyan, title: "Red / Cyan",
            detail: "Correct red and cyan fringes around edges.",
            section: .lensCorrection, kind: .slider(signed),
            persistence: .bespoke,
            surfaces: [.app, .desktop],
            omitted: hostsOwnIt.merging([.android: "no lens correction on Android yet"]) { $1 },
            documentation: "Corrects lateral chromatic aberration by scaling the red channel radially."),
        EditorControl(
            .lensBlueYellow, title: "Blue / Yellow",
            detail: "Correct blue and yellow fringes around edges.",
            section: .lensCorrection, kind: .slider(signed),
            persistence: .bespoke,
            surfaces: [.app, .desktop],
            omitted: hostsOwnIt.merging([.android: "no lens correction on Android yet"]) { $1 },
            documentation: "Corrects lateral chromatic aberration by scaling the blue channel radially."),

        EditorControl(
            .exposure, title: "Exposure",
            detail: "Brighten or darken the light reaching the film, measured in stops.",
            section: .lightExposure,
            kind: .slider(EditorControlScale(-2...2, neutral: 0, unit: .stops, admitted: -5...5)),
            binding: .exposureEV,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .web, .cli],
            host: HostParameter(
                slot: 0, slotSymbol: "EXPOSURE_EV", ofxName: "exposure", fxplugID: 6, group: .exposure,
                label: "Exposure", hint: "Camera exposure, in stops.",
                kind: .double(min: -5, max: 5, value: 0), order: 10),
            web: .configSlot("FOTUFILM_CONFIG_EXPOSURE_GAIN", transform: .exp2),
            commandLine: CommandLineFlag("--ev", placeholder: "<stops>",
                                         help: "Exposure compensation in stops (default: 0)"),
            documentation: "Adjusts exposure in stops (EV) before film simulation."),
        EditorControl(
            .highlights, title: "Highlights",
            detail: "Adjust bright areas before the film response is applied.",
            section: .lightExposure, kind: .slider(signed),
            binding: .highlights,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .web, .cli],
            host: HostParameter(
                slot: 3, slotSymbol: "HIGHLIGHTS", ofxName: "highlights", fxplugID: 9, group: .exposure,
                label: "Highlights",
                hint: "Scene-referred highlight recovery, applied before the film model. Keyed to each "
                    + "pixel's regional brightness, so pulling a sky down moves the sky as one piece.",
                kind: .double(min: -1, max: 1, value: 0), clamp: -1...1, order: 40),
            web: .configSlot("FOTUFILM_CONFIG_HIGHLIGHTS", transform: .identity),
            commandLine: CommandLineFlag("--highlights", placeholder: "<n>",
                                         help: "Scene-referred shaping above mid-grey, -1...1 (default: 0)"),
            documentation: "Scales scene radiance above 18% neutral gray."),
        EditorControl(
            .shadows, title: "Shadows",
            detail: "Adjust dark areas before the film response is applied.",
            section: .lightExposure, kind: .slider(signed),
            binding: .shadows,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .web, .cli],
            host: HostParameter(
                slot: 4, slotSymbol: "SHADOWS", ofxName: "shadows", fxplugID: 10, group: .exposure,
                label: "Shadows", hint: "The same shift, fading in below mid-grey.",
                kind: .double(min: -1, max: 1, value: 0), clamp: -1...1, order: 50),
            web: .configSlot("FOTUFILM_CONFIG_SHADOWS", transform: .identity),
            commandLine: CommandLineFlag("--shadows", placeholder: "<n>",
                                         help: "The same shaping below mid-grey, -1...1 (default: 0)"),
            documentation: "Scales scene radiance below 18% neutral gray."),
        EditorControl(
            .localTone, title: "Regional",
            detail: "Make highlight and shadow adjustments respond to nearby brightness.",
            section: .lightExposure, kind: .toggle(restingOn: true),
            binding: .localTone,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: "the regional base is measured from the image, which the pack cannot carry"],
            host: HostParameter(
                slot: 11, slotSymbol: "LOCAL_TONE", ofxName: "localTone", fxplugID: 11, group: .exposure,
                label: "Regional Tone Mask",
                hint: "Off, the highlight and shadow shifts key to each pixel's own luminance instead "
                    + "of to the region it sits in. Identical output when both rest at zero.",
                kind: .boolean(value: true), order: 60),
            commandLine: CommandLineFlag("--local-tone", placeholder: "<0|1>",
                                         help: "Regional highlight/shadow keying (default: 1)"),
            documentation: "Applies spatially aware contrast compression across adjacent luminance zones."),

        EditorControl(
            .warmth, title: "Warmth",
            detail: "Set the color temperature of the scene lighting.",
            section: .lightBalance, kind: .slider(signed),
            persistence: .key("temperatureMired", .miredFromWarmth),
            binding: .warmth,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: "the demo bakes the scene light into the pack"],
            host: HostParameter(
                slot: 1, slotSymbol: "TEMPERATURE", ofxName: "temperature", fxplugID: 7, group: .exposure,
                label: "Temperature (K)",
                hint: "Spectral scene temperature. Lower Kelvin adds warm light. Relative in mired "
                    + "to Scene Illuminant when a base lamp is selected; 6504 leaves that lamp unchanged.",
                kind: .double(min: 2000, max: 12000, value: 6504, delta: 10), bridge: .kelvinFromWarmth,
                binding: .whiteBalanceKelvin, clamp: 2000...12000, order: 20),
            commandLine: CommandLineFlag("--wb", placeholder: "<kelvin>",
                                         help: "Scene illuminant, 2000-12000 K. Unset, an already "
                                             + "white-balanced file is lit at the stock's own balance, "
                                             + "so a neutral renders neutral. On camera raw this is "
                                             + "relative to the file's as-shot light; 6504 preserves "
                                             + "the capture illuminant",
                                         generic: false),
            documentation: "Changes scene-light temperature; RAW edits are relative to the capture illuminant."),
        EditorControl(
            .tint, title: "Tint",
            detail: "Shift the color balance between green and magenta.",
            section: .lightBalance, kind: .slider(signed),
            persistence: .key("tint", .duvFromPadTint),
            binding: .tint,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: "the demo bakes the scene light into the pack"],
            host: HostParameter(
                slot: 2, slotSymbol: "TINT", ofxName: "tint", fxplugID: 8, group: .exposure,
                label: "Tint", hint: "Green/magenta balance of the illuminant.",
                kind: .double(min: -100, max: 100, value: 0, delta: 0.5), bridge: .duvFromPadTint,
                binding: .whiteBalanceDuv, clamp: -100...100, order: 30),
            commandLine: CommandLineFlag("--tint", placeholder: "<n>",
                                         help: "Green/magenta off the locus, -100...100 (default: 0)",
                                         generic: false),
            documentation: "Changes the scene spectrum toward green or magenta, perpendicular to the blended blackbody/daylight locus."),
        EditorControl(
            .sceneLight, title: "Scene Illuminant",
            detail: "Choose the scene light source. Temperature and Tint refine its color.",
            section: .lightBalance,
            kind: .menu(.fixed([
                EditorMenuChoice(0, "Unspecified · D65", id: "unspecified"),
                EditorMenuChoice(6504, "Daylight · D65", id: "d65"),
                EditorMenuChoice(5500, "Daylight · 5500 K", id: "daylight5500"),
                EditorMenuChoice(3200, "Tungsten · 3200 K", id: "tungsten3200"),
                EditorMenuChoice(2856, "Incandescent · 2856 K", id: "incandescent"),
                EditorMenuChoice(nil, "Custom", id: "custom"),
            ])),
            scope: .hostOnly,
            drives: ["sceneIlluminantKelvin"],
            surfaces: [.resolve],
            omitted: [.app: "read from the capture metadata", .desktop: "read from the capture metadata",
                      .android: "read from the capture metadata",
                      .finalcut: "not yet offered; the clip's light is taken as D65",
                      .web: webBaked, .cli: "--wb states the scene light directly"],
            host: HostParameter(
                slot: 33, slotSymbol: "SCENE_ILLUMINANT", ofxName: "sceneLight", group: .sceneLight,
                label: "Scene Illuminant",
                hint: "Capture light presented to the film; Temperature and Tint adjust this spectrum. "
                    + "Unspecified light assumes D65. Custom sources use a daylight or Planckian "
                    + "spectrum, not a measured LED spectrum.",
                kind: .choice(.fixed([
                    EditorMenuChoice(0, "Unspecified · D65", id: "unspecified"),
                    EditorMenuChoice(6504, "Daylight · D65", id: "d65"),
                    EditorMenuChoice(5500, "Daylight · 5500 K", id: "daylight5500"),
                    EditorMenuChoice(3200, "Tungsten · 3200 K", id: "tungsten3200"),
                    EditorMenuChoice(2856, "Incandescent · 2856 K", id: "incandescent"),
                    EditorMenuChoice(nil, "Custom", id: "custom"),
                ]), value: 0), composed: true, order: 10)),
        EditorControl(
            .sceneLightKelvin, title: "Scene Illuminant (K)",
            detail: "Define a custom scene light source before Temperature and Tint adjustments.",
            section: .lightBalance,
            kind: .slider(EditorControlScale(2000...12000, neutral: 6504, unit: .kelvin)),
            scope: .hostOnly,
            drives: ["sceneIlluminantKelvin"],
            surfaces: [.resolve],
            omitted: [.app: "read from the capture metadata", .desktop: "read from the capture metadata",
                      .android: "read from the capture metadata",
                      .finalcut: "not yet offered; the clip's light is taken as D65",
                      .web: webBaked, .cli: "--wb states the scene light directly"],
            host: HostParameter(
                slot: nil, ofxName: "sceneLightKelvin", group: .sceneLight, label: "Scene Illuminant (K)",
                hint: "Custom capture light before the Temperature and Tint edits.",
                kind: .double(min: 2000, max: 12000, value: 6504, delta: 10), composed: true, order: 20)),

        EditorControl(
            .saturation, title: "Saturation",
            detail: "Adjust color intensity while preserving brightness.",
            section: .lightColor,
            kind: .slider(EditorControlScale(0...2, neutral: 1, unit: .multiplier)),
            binding: .saturation,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .web, .cli],
            host: HostParameter(
                slot: 5, slotSymbol: "SATURATION", ofxName: "saturation", fxplugID: 12, group: .exposure,
                label: "Saturation",
                hint: "Chroma multiplier applied to the scene before the film responds. 1 leaves it untouched.",
                kind: .double(min: 0, max: 2, value: 1), clamp: 0...Double.greatestFiniteMagnitude, order: 70),
            web: .configSlot("FOTUFILM_CONFIG_SATURATION", transform: .identity),
            commandLine: CommandLineFlag("--saturation", placeholder: "<scale>",
                                         help: "Chroma multiplier before the film responds (default: 1)"),
            documentation: "Scales radial chroma across all hues uniformly."),
        EditorControl(
            .vibrance, title: "Vibrance",
            detail: "Adjust color intensity, with more effect on muted colors.",
            section: .lightColor, kind: .slider(signed),
            binding: .vibrance,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .web, .cli],
            host: HostParameter(
                slot: 6, slotSymbol: "VIBRANCE", ofxName: "vibrance", fxplugID: 13, group: .exposure,
                label: "Vibrance",
                hint: "Chroma boost weighted toward the least colourful pixels; already-vivid colours are left alone.",
                kind: .double(min: -1, max: 1, value: 0), clamp: -1...1, order: 80),
            web: .configSlot("FOTUFILM_CONFIG_VIBRANCE", transform: .identity),
            commandLine: CommandLineFlag("--vibrance", placeholder: "<n>",
                                         help: "Chroma boost weighted toward the least colourful pixels, -1...1 (default: 0)"),
            documentation: "Scales chroma non-linearly, prioritizing muted tones."),

        EditorControl(
            .gradeSpace, title: "Encoded Grade",
            detail: "Apply the grade to encoded color values instead of linear light. This changes how the grade responds.",
            section: .lightGrade, kind: .toggle(restingOn: false),
            persistence: .key("encodedGrade", .same),
            binding: .gradeSpaceEncoded,
            surfaces: [.app, .desktop, .android],
            omitted: hostsOwnIt,
            documentation: "Grades the sRGB-encoded signal, where a grading suite's corrector works, instead of display-linear light."),
    ] + gradeBands

    private static let print: [EditorControl] = [
        EditorControl(
            .paper, title: "Output Medium",
            detail: "Choose how the film is printed, scanned, or viewed.",
            section: .printPaper, kind: .menu(.dynamic(.papers)), availability: .printStage,
            drives: ["paper"],
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: webBaked],
            host: HostParameter(
                slot: nil, ofxName: "paper", fxplugID: 4, group: .output, label: "Output Medium",
                hint: "Choose where the finished image lives. Match Film uses RA-4 paper for a still "
                    + "negative, the stock's native release print for a motion negative, and the "
                    + "direct positive for reversal film. Digital Reference is the HDR path; paper, "
                    + "projection, Lab Scan, Telecine and Negative are SDR. Negative is available "
                    + "only for negative film.",
                kind: .choice(.dynamic(.papers), value: -1), order: 10),
            commandLine: CommandLineFlag("--paper", placeholder: "<name>",
                                         help: "Output medium: ektacolor-edge (default), endura-premier, "
                                             + "crystal-archive, vision-2383, vision-2393, eterna-cp, "
                                             + "lab-scan, telecine, screen or negative. Photo and "
                                             + "projection variants are digitised from the manufacturers' "
                                             + "published datasheets. Reversal stocks use screen "
                                             + "regardless of the requested medium.",
                                         generic: false),
            documentation: "Selects the print paper, projection print, scan, display reference or the negative itself."),
        EditorControl(
            .printLight, title: "Viewing Illuminant",
            detail: "Choose the light used to view the print.",
            section: .printPaper, kind: .menu(.dynamic(.viewingLights)), availability: .printStage,
            persistence: .bespoke,
            binding: .printViewingKelvin,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: webBaked],
            host: HostParameter(
                slot: 15, slotSymbol: "PRINT_LIGHT", ofxName: "printLight", fxplugID: 25, group: .output,
                label: "Viewing Illuminant",
                hint: "Choose the light used to judge a physical print. Medium Reference means D50 "
                    + "for photo paper or calibrated 5400 K xenon for a projected release print. "
                    + "Digital Reference, Lab Scan, Telecine and Negative ignore this control.",
                kind: .choice(.fixed(printLights), value: 0), order: 20),
            commandLine: CommandLineFlag("--print-light", placeholder: "<k>",
                                         help: "Colour temperature the finished print is viewed under, in "
                                             + "kelvin: daylight series from 4000 K up (5003 = D50 proof "
                                             + "light), Planckian below (2856 = tungsten). Greys hold — "
                                             + "the read adapts to the light — and the paper dyes' "
                                             + "metamerism moves. Default: D50 for paper, calibrated "
                                             + "5400 K xenon for cinema print, fixed D65 for screen",
                                         generic: false),
            documentation: "Sets the lamp a physical print is judged under; digital media ignore it."),
        EditorControl(
            .enlarger, title: "Enlarger",
            detail: "Choose the enlarger lighting used to make the print.",
            section: .printPaper,
            kind: .menu(.fixed([
                EditorMenuChoice(0, "Diffuser",
                                 detail: "Soft, even light, as in a color enlarger or minilab.", id: "diffuser"),
                EditorMenuChoice(1, "Condenser",
                                 detail: "Focused light for stronger contrast and more visible grain and dust in black-and-white prints.", id: "condenser"),
            ])),
            availability: .printStage,
            persistence: .bespoke,
            binding: .enlargerIndex,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: webBaked],
            host: HostParameter(
                slot: 52, slotSymbol: "ENLARGER", ofxName: "enlarger", fxplugID: 91, group: .output,
                label: "Enlarger",
                hint: "The lamp house a reflection print is enlarged under. Diffuser is the sheets' "
                    + "own diffuse read and changes nothing; Condenser prints a silver negative harder "
                    + "through the Callier effect. Read only where the medium is an enlarged reflection print.",
                kind: .choice(.fixed([EditorMenuChoice(0, "Diffuser", id: "diffuser"),
                                      EditorMenuChoice(1, "Condenser", id: "condenser")]), value: 0),
                order: 25),
            commandLine: CommandLineFlag("--enlarger", placeholder: "<head>",
                                         help: "Lamp house over the negative: diffuser (default, the "
                                             + "diffuse density the sheets are measured in) or condenser "
                                             + "(collimated light: the Callier effect reads a silver "
                                             + "negative's densities ~1.4x higher, a dye negative's ~1.05x, "
                                             + "re-timed through mid-grey, so the print gains contrast). "
                                             + "--bleach-bypass leaves retained silver, which scatters "
                                             + "like a silver negative and takes the silver figure. "
                                             + "Only an enlarged reflection print has one"),
            documentation: "Chooses a diffuser or condenser head for an enlarged reflection print."),
        EditorControl(
            .printCorrection, title: "Channel Contrast Match",
            detail: "Adjust the color balance of the print.",
            section: .printPaper,
            kind: .slider(EditorControlScale(0...1, neutral: 0.05, unit: .percent)),
            availability: .printStage,
            binding: .printCorrection,
            surfaces: [.app, .desktop, .android, .resolve, .finalcut, .cli],
            omitted: [.web: webBaked],
            host: HostParameter(
                slot: 10, slotSymbol: "PRINT_CORRECTION", ofxName: "printCorrection", fxplugID: 20,
                group: .output, label: "Channel Contrast Match",
                hint: "Balances how the film's colour layers print together. The medium's own "
                    + "calibration is already applied; raise this only for a more neutral crossover.",
                kind: .double(min: 0, max: 1, value: 0.05), clamp: 0...Double.greatestFiniteMagnitude, order: 30),
            commandLine: CommandLineFlag("--print-correction", placeholder: "<f>",
                                         help: "How far the film's colour layers are balanced to print "
                                             + "together, 0-1 (default: 0.05)"),
            documentation: "Balances how the film's colour layers print together on the chosen medium."),
        EditorControl(
            .negativeViewing, title: "Negative Viewing",
            detail: "Choose how negative output is displayed.",
            section: .printPaper, kind: .menu(.dynamic(.negativeViewings)),
            scope: .global(settingKey: "fotufilm.negative-viewing"),
            binding: .negativeViewingIndex,
            surfaces: [.resolve, .finalcut, .cli],
            omitted: [.app: "Settings chooses the lightbox or scanner reading",
                      .desktop: "Settings chooses the lightbox or scanner reading",
                      .android: "Settings chooses the lightbox or scanner reading",
                      .web: webBaked],
            host: HostParameter(
                slot: 28, slotSymbol: "NEGATIVE_VIEWING", ofxName: "negativeViewing", fxplugID: 80,
                group: .output, label: "Negative Viewing",
                hint: "How the developed negative is read when Output Medium is Negative. Light Box "
                    + "sets the lamp so the clear film base sits just under white and keeps its "
                    + "orange. Scanner divides by the film base, so the base reads white. Other "
                    + "output media ignore this control.",
                kind: .choice(.dynamic(.negativeViewings), value: 0), paramOffset: 1,
                bridge: .indexPlusOne, order: 40),
            commandLine: CommandLineFlag("--negative", placeholder: "<how>",
                                         help: "Show the developed negative instead of the print it would "
                                             + "make: 'lightbox' keeps the base its own orange, 'scanner' "
                                             + "divides the base out. Ignored by a reversal stock, which "
                                             + "has no negative",
                                         generic: false)),
    ]

    private static let gradeBands: [EditorControl] = GradeBand.allCases.flatMap { band -> [EditorControl] in
        let name = band.title
        let fields: (EditorControlField, EditorControlField, EditorControlField)
        switch band {
        case .shadows: fields = (.gradeShadowsWarmth, .gradeShadowsTint, .gradeShadowsLevel)
        case .midtones: fields = (.gradeMidtonesWarmth, .gradeMidtonesTint, .gradeMidtonesLevel)
        case .highlights: fields = (.gradeHighlightsWarmth, .gradeHighlightsTint, .gradeHighlightsLevel)
        }
        return [
            EditorControl(fields.0, title: "\(name) Warmth",
                          detail: "Cool to warm, in the \(name.lowercased())",
                          section: .lightGrade, kind: .slider(signed),
                          persistence: .bespoke, binding: .grade(band, .warmth),
                          omitted: hostsOwnIt),
            EditorControl(fields.1, title: "\(name) Tint",
                          detail: "Magenta to green, in the \(name.lowercased())",
                          section: .lightGrade, kind: .slider(signed),
                          persistence: .bespoke, binding: .grade(band, .tint),
                          omitted: hostsOwnIt),
            EditorControl(fields.2, title: "\(name) Level",
                          detail: "Adjust the brightness of the \(name.lowercased()).",
                          section: .lightGrade, kind: .slider(signed),
                          persistence: .bespoke, binding: .grade(band, .level),
                          omitted: hostsOwnIt),
        ]
    }

    private static let frame: [EditorControl] = [
        EditorControl(
            .crop, title: "Crop",
            detail: "Choose the area of the photo to keep.",
            section: .frameGeometry, kind: .takeover,
            omitted: hostsOwnIt,
            documentation: "Chooses the part of the frame the print is made from."),
        EditorControl(
            .straighten, title: "Straighten",
            detail: "Rotate the photo to level the horizon, in degrees.",
            section: .frameGeometry,
            kind: .slider(EditorControlScale(-15...15, neutral: 0, unit: .degrees)),
            omitted: hostsOwnIt,
            documentation: "Rotates the frame off level by up to fifteen degrees."),
        EditorControl(
            .perspectiveVertical, title: "Vertical",
            detail: "Correct perspective when the camera was tilted up or down.",
            section: .frameGeometry,
            kind: .slider(EditorControlScale(-15...15, neutral: 0, unit: .degrees)),
            persistence: .key("perspectiveV", .same),
            surfaces: [.app, .desktop],
            omitted: hostsOwnIt.merging([.android: "the Android crop has no keystone yet"]) { $1 },
            documentation: "Tilts the picture plane about the horizontal axis."),
        EditorControl(
            .perspectiveHorizontal, title: "Horizontal",
            detail: "Correct perspective when the camera faced the subject at an angle.",
            section: .frameGeometry,
            kind: .slider(EditorControlScale(-15...15, neutral: 0, unit: .degrees)),
            persistence: .key("perspectiveH", .same),
            surfaces: [.app, .desktop],
            omitted: hostsOwnIt.merging([.android: "the Android crop has no keystone yet"]) { $1 },
            documentation: "Tilts the picture plane about the vertical axis."),
        EditorControl(
            .rotation, title: "Rotate",
            detail: "Rotate the photo 90 degrees clockwise.",
            section: .frameGeometry, kind: .menu(.fixed(rotations)),
            omitted: hostsOwnIt,
            documentation: "Turns the frame in quarter turns."),
        EditorControl(
            .flip, title: "Flip",
            detail: "Flip the photo horizontally.",
            section: .frameGeometry, kind: .toggle(restingOn: false),
            persistence: .key("flipH", .same),
            omitted: hostsOwnIt,
            documentation: "Mirrors the frame left to right."),
        EditorControl(
            .selective, title: "Selective",
            detail: "Adjust light and color in a selected part of the photo.",
            section: .frameLocal, kind: .takeover,
            persistence: .bespoke,
            surfaces: [.app, .desktop],
            omitted: hostsOwnIt.merging([.android: "no selective edits on Android yet"]) { $1 },
            documentation: "Develops a colour, a light or a subject differently from the rest of the frame."),
    ]

    private static let pipeline: [EditorControl] = [
        EditorControl(
            .colorSpace, title: "Timeline Color Space",
            detail: "What this node is being handed",
            section: .pipeline, kind: .menu(.dynamic(.colourSpaces)),
            scope: .hostOnly,
            surfaces: [.resolve, .finalcut],
            omitted: hostOnly,
            host: HostParameter(
                slot: nil, ofxName: "colorSpace", fxplugID: 5, group: .input, label: "Timeline Color Space",
                hint: "What this node is being handed — the one control that is not taste. The film "
                    + "model is scene-referred in linear Rec.2020: mid-grey at 0.18, specular "
                    + "highlights above 1.0. The input is decoded to that and the result encoded back, "
                    + "so a wrong setting shows the emulsion the wrong light and lands the "
                    + "characteristic curves whole stops off. Auto reads the space the host tags the "
                    + "clip with, where the host says. A display-referred space (Rec.709, sRGB) clips "
                    + "at diffuse white, leaving halation nothing bright to scatter; a wide-gamut log "
                    + "or linear timeline keeps the highlights the model was built for.",
                kind: .choice(.dynamic(.colourSpaces), value: 7), order: 10)),
        EditorControl(
            .stage, title: "Stage",
            detail: "Which span of the pipeline this node performs",
            section: .pipeline, kind: .menu(.dynamic(.stages)),
            scope: .hostOnly,
            binding: .stageIndex,
            surfaces: [.resolve, .finalcut],
            omitted: hostOnly,
            host: HostParameter(
                slot: 16, slotSymbol: "STAGE", ofxName: "stage", fxplugID: 1, group: .stage, label: "Stage",
                hint: "Which span of the pipeline this node performs. Full is the whole thing and is "
                    + "what every other setting here describes. Negative Only stops at the developed "
                    + "negative and writes its per-layer densities — data, not a picture — and Print "
                    + "Only takes exactly that back and finishes it on the selected medium, so the two "
                    + "in series reproduce Full. Texture Only lays the film's spatial character over "
                    + "the frame it is handed and leaves its colour alone.\n\nA Negative Only node must "
                    + "feed a Print Only node directly, with the same stock and lab settings and nothing "
                    + "in between: the densities are not colour and anything that grades, resamples or "
                    + "transforms them is not editing a picture.",
                kind: .choice(.dynamic(.stages), value: 0), composed: true, order: 10)),
        EditorControl(
            .textureStages, title: "Texture Stages",
            detail: "Which spatial stages the texture span lays over the frame",
            section: .pipeline, kind: .menu(.dynamic(.textureStages)),
            scope: .hostOnly,
            binding: .textureStagesMask,
            surfaces: [.resolve, .finalcut],
            omitted: hostOnly,
            host: HostParameter(
                slot: 17, slotSymbol: "TEXTURE_STAGES", ofxName: "textureSelection", group: .stage,
                label: "Texture Stages",
                hint: "Whether Texture Only carries this stage. Ignored by every other stage, where "
                    + "the strength controls below select what runs.",
                kind: .choice(.dynamic(.textureStages), value: 0), composed: true, order: 30)),
        EditorControl(
            .renderMode, title: "Render Mode",
            detail: "Default preserves the launch-time renderer setting",
            section: .pipeline,
            kind: .menu(.fixed([EditorMenuChoice(0, "Default", id: "default"),
                                EditorMenuChoice(1, "Realtime", id: "realtime"),
                                EditorMenuChoice(2, "Reference", id: "reference")])),
            scope: .hostOnly,
            surfaces: [.resolve],
            omitted: hostOnly.merging([.finalcut: "Final Cut decides the renderer from its own quality hint"]) { $1 },
            host: HostParameter(
                slot: 45, slotSymbol: "RENDER_MODE", ofxName: "renderMode", group: .render, label: "Render Mode",
                hint: "Default preserves the launch-time renderer setting. Realtime and Reference "
                    + "override it for this node, for both preview and delivery. Disc grain uses Reference.",
                kind: .choice(.fixed([EditorMenuChoice(0, "Default", id: "default"),
                                      EditorMenuChoice(1, "Realtime", id: "realtime"),
                                      EditorMenuChoice(2, "Reference", id: "reference")]), value: 0),
                order: 10)),
    ]

    public static let pending: [EditorControlField: String] = [:]
}

public extension EditorControlCatalogue {
    static func controls(for stock: FilmStock?, on surface: EditorSurface = .app) -> [EditorControl] {
        all.compactMap { control in
            guard control.offered(on: surface) else { return nil }
            guard control.availability.admits(stock: stock) else { return nil }
            guard control.field == .push, let stock else { return control }
            let stops = ([Float(0)] + stock.supportedDevelopmentStops)
                .sorted()
                .map { Double($0) }
            guard let lower = stops.first, let upper = stops.last else { return nil }
            return EditorControl(
                control.field, title: control.title, detail: control.detail,
                section: control.section,
                kind: .slider(EditorControlScale(
                    lower...upper, neutral: 0, unit: .stops, stops: stops)),
                availability: control.availability, foldsUnder: control.foldsUnder,
                scope: control.scope, persistence: control.persistence, binding: control.binding,
                drives: control.drives, surfaces: control.surfaces, omitted: control.omitted,
                host: control.host, web: control.web, commandLine: control.commandLine,
                documentation: control.documentation)
        }
    }

    static func controls(in section: EditorControlSection,
                         for stock: FilmStock?, on surface: EditorSurface = .app) -> [EditorControl] {
        controls(for: stock, on: surface).filter { $0.section == section }
    }

    static func control(_ field: EditorControlField) -> EditorControl? {
        all.first { $0.field == field }
    }

    static func offered(on surface: EditorSurface) -> [EditorControl] {
        all.filter { $0.offered(on: surface) }
    }

    static var bridgeSlots: [(slot: Int, symbol: String, control: EditorControl)] {
        all.flatMap { control -> [(Int, String, EditorControl)] in
            guard let host = control.host, let slot = host.slot, let symbol = host.slotSymbol else { return [] }
            if let curve = control.kind.curve {
                return curve.handles.enumerated().map { index, nm in
                    (slot + index, symbol.replacingOccurrences(of: "\(Int(curve.handles[0]))", with: "\(Int(nm))"),
                     control)
                }
            }
            return [(slot, symbol, control)]
        }.sorted { $0.0 < $1.0 }
    }

    static func hostParameters(on surface: EditorSurface) -> [(control: EditorControl, host: HostParameter)] {
        offered(on: surface).compactMap { control in
            guard let host = control.host else { return nil }
            if surface == .finalcut, host.fxplugID == nil { return nil }
            return (control, host)
        }
    }
}

public enum EngineOptionCoverage: Sendable, Equatable {
    case control([EditorControlField])
    case derived(String)
    case globalSetting(String)
    case unexposed(String)
}

public extension EngineOptionCoverage {
    static let unbound: [String: EngineOptionCoverage] = [
        "sceneHeadroom": .derived(
            "the source interpretation the overflow menu sets, against the source's declared range"),
        "grainMottleSizeRatio": .derived(
            "how coarse the mottle is, as a multiple of the emulsion's own clump; a still keeps the "
            + "sheet's figure and a clip's roads complete an explicit share with the coarser delivery ratio"),
        "adjacencyModel": .unexposed(
            "Experimental transport selection is available through the library, CLI, and stock pack."),
        "layeredTransport": .unexposed(
            "Explicit optical construction override; apps select the model in Film Model settings."),
        "transportBackend": .unexposed(
            "Selects CPU or Metal JIT transport convolution in the checked planar API."),
        "halationHazeMM": .unexposed(
            "the support's impurity scatter is the stock's own figure, stated per sheet; the CLI "
            + "exposes an override for calibration experiments"),
        "couplerRangeScale": .unexposed(
            "the app sets the per-gap reaches instead; the Resolve bridge derives it from Separation"),
        "sceneIlluminantChromaticity": .derived("capture chromaticity"),
        "sceneIlluminantSpectrum": .derived(
            "capture metadata when a source supplies a measured illuminant spectrum; its CCT "
            + "is the fallback when only a correlated temperature is available"),
    ]

    static var byOptionName: [String: EngineOptionCoverage] {
        var map = unbound
        var driven: [String: [EditorControlField]] = [:]
        for control in EditorControlCatalogue.all {
            let names = (control.binding?.optionNames ?? []) + control.drives
            for name in names { driven[name, default: []].append(control.field) }
        }
        for (name, fields) in driven { map[name] = .control(fields) }
        return map
    }
}
