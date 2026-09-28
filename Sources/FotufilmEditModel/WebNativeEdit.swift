import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// What the web editor asks a native host to develop (`web/src/backend/macos/session.js`): the
/// saved edit, and the film settings the editor has already resolved against the stock.
///
/// The film settings are read exactly as a browser profile request reads them. The light and
/// colour sliders, which the browser engine writes into its own configuration, become the catalogue
/// controls they stand for, so a native host develops the edit through `EditDocument` like every
/// other surface.
public struct WebNativeEdit: Decodable {
    /// The film settings: `profileRequest` in the render request.
    public struct Settings: Decodable {
        public var controls: [String: WebProfileRequest.Value]?
        public var format: String?
        public var medium: String?
        public var filters: [String]?
        public var filterMetering: String?
        public var sceneKelvin: Float?
    }

    /// The parts of the saved edit that are not film settings.
    public struct Edit: Decodable {
        public var stock: String?
        public var params: [String: Double]?
        public var gradeSpace: Bool?
        public var localTone: Bool?
        /// New Grain Pattern: 0 keeps the film's own pattern.
        public var seed: UInt32?
        /// Legacy or Layered Transport, which the editor keeps beside the film settings.
        public var halationModel: String?
        /// How a still's dynamic range is read (`FilmSourceInterpretation`); the host decodes the
        /// photograph to match before it develops.
        public var sourceInterpretation: String?
    }

    public var edit: Edit
    public var profileRequest: Settings
    /// How much of the frame's short edge the edit's geometry keeps, measured by the host that
    /// cut the scene: a crop is an enlargement, as the Mac app develops it. Nil is the whole frame.
    public var frameCoverage: Float?

    private enum CodingKeys: String, CodingKey { case edit, profileRequest }

    /// Whether the edit reads a processed photograph as Standard Range: tone-mapped to SDR before
    /// the film is exposed, where Automatic and Full Range keep the decoded highlight range.
    public var readsStandardRange: Bool { edit.sourceInterpretation == "standardRange" }

    /// Web slider keys and the controls they stand for, with the web's unit converted to the
    /// catalogue's. Temperature and tint use the conversions the plug-ins' Kelvin and Δuv
    /// parameters use; everything else is already in catalogue units.
    static let sliders: [(key: String, field: EditorControlField, canonical: (Double) -> Double)] = [
        ("ev", .exposure, { $0 }),
        ("highlights", .highlights, { $0 }),
        ("shadows", .shadows, { $0 }),
        ("temperature", .warmth, WarmthAxis.warmth(fromKelvin:)),
        ("tint", .tint, WarmthAxis.padTint(fromDuv:)),
        ("saturation", .saturation, { $0 }),
        ("vibrance", .vibrance, { $0 }),
        ("grain", .grain, { $0 }),
        ("cameraPreflash", .cameraPreflash, { $0 }),
        ("gradeShadowsWarmth", .gradeShadowsWarmth, { $0 }),
        ("gradeShadowsTint", .gradeShadowsTint, { $0 }),
        ("gradeShadowsLevel", .gradeShadowsLevel, { $0 }),
        ("gradeMidtonesWarmth", .gradeMidtonesWarmth, { $0 }),
        ("gradeMidtonesTint", .gradeMidtonesTint, { $0 }),
        ("gradeMidtonesLevel", .gradeMidtonesLevel, { $0 }),
        ("gradeHighlightsWarmth", .gradeHighlightsWarmth, { $0 }),
        ("gradeHighlightsTint", .gradeHighlightsTint, { $0 }),
        ("gradeHighlightsLevel", .gradeHighlightsLevel, { $0 }),
    ]

    /// The edit as one document. A medium the editor leaves unstated is the one an editor's edit
    /// starts on, Digital Reference, which the host's film library names as each film's default
    /// (`WebStockCatalogue.entries`) — not the engine's physically matched print.
    public var document: EditDocument {
        let settings = profileRequest
        var document = EditDocument(webControls: settings.controls ?? [:], format: settings.format,
                                    medium: settings.medium ?? PrintPaper.editorDefault.id,
                                    filters: settings.filters,
                                    filterMetering: settings.filterMetering,
                                    sceneKelvin: settings.sceneKelvin)
        for (key, field, canonical) in Self.sliders {
            guard let value = edit.params?[key] else { continue }
            document[field] = .number(canonical(value))
        }
        if let gradeSpace = edit.gradeSpace { document[.gradeSpace] = .flag(gradeSpace) }
        if let localTone = edit.localTone { document[.localTone] = .flag(localTone) }
        if let halationModel = edit.halationModel { document[.halationModel] = .choice(halationModel) }
        return document
    }

    /// The engine options for this edit on a film: the document's, with New Grain Pattern's seed
    /// added to the film's own as the browser engine adds it (0 keeps the film's pattern).
    public func options(for stock: FilmStock, nativeFormatID: String? = nil) throws
        -> FotufilmEngine.Options {
        var options = try document.options(for: stock, nativeFormatID: nativeFormatID)
        if let seed = edit.seed, seed != 0 { options.seed &+= UInt64(seed) }
        if let frameCoverage { options.frameCoverage = frameCoverage }
        return options
    }
}

extension EditDocument {
    /// A browser profile request's controls, with its top-level choices as the controls they
    /// stand for. Unknown control names are left out; the request rejects them before this.
    public init(webControls controls: [String: WebProfileRequest.Value], format: String?,
                medium: String?, filters: [String]?, filterMetering: String?,
                sceneKelvin: Float?) {
        self.init()
        for (name, input) in controls {
            guard let field = EditorControlField(rawValue: name) else { continue }
            switch input {
            case .number(let number): self[field] = .number(number)
            case .flag(let flag): self[field] = .flag(flag)
            case .choice(let id): self[field] = .choice(id)
            case .curve(let points): self[field] = .curve(points)
            }
        }
        if let format { self[.gauge] = .choice(format) }
        if let medium { self[.paper] = .choice(medium) }
        if let filters { self[.lensFilterStack] = .choices(filters) }
        if let filterMetering { self[.metering] = .choice(filterMetering) }
        if let sceneKelvin {
            self[.sceneLight] = .choice("custom")
            self[.sceneLightKelvin] = .number(Double(sceneKelvin))
        }
    }
}
