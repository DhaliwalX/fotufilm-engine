import Foundation

/// Serialised form of a `FilmStock`.
public struct FilmStockDefinition: Codable, Sendable {
    /// Bumped only when an older pack would decode incorrectly rather than merely incompletely.
    public var schemaVersion: Int
    /// Lookup key, unique within a pack.
    public var id: String
    /// Human-readable name, shown in user interfaces.
    public var name: String
    /// Optional one-line description for pickers ("Kodak · colour negative").
    public var subtitle: String?
    /// The gauge this stock is known on — a `FilmFormat.presets` id, such as "super35" for a
    /// motion-picture negative or "120" for a roll film whose reputation was made in medium format.
    public var nativeFormatID: String?
    /// The illuminant the stock is balanced to record neutrally, in kelvin. Absent means the
    /// ordinary 5500 K daylight balance; tungsten stocks state 3200 K in their pack record.
    public var referenceIlluminantKelvin: Float?

    public var sensitivity: [[Float]]
    public var spectral: SpectralSpec
    public var curves: [CurveSpec]
    /// Coated capture layers beyond the dye-forming ones: records that develop and release
    /// inhibitor but form no image dye (REALA's 4th Color Layer). Optional so that every
    /// earlier pack decodes unchanged; absent is the three-layer stock it always was.
    public var donorLayers: [DonorLayerSpec]?

    public var flare: Float?
    public var emulsionDiffusionMM: [Float]?
    /// Optional second positive Gaussian and the primary scale's blend share. Absent is the
    /// original single-Gaussian MTF exactly.
    public var emulsionDiffusionSecondaryMM: [Float]?
    public var emulsionDiffusionPrimaryShare: [Float]?
    /// Optional fields default to no separation, preserving decoding of earlier packs.
    public var mtfLumaShare: Float?
    public var lumaDiffusionMM: Float?
    public var couplerInhibition: [[Float]]
    /// Per-donor Hill exponents for inhibitor release. Absent is [1, 1, 1], preserving the
    /// historical linear law for older and third-party packs.
    public var couplerReleaseGamma: [Float]? = nil
    /// Optional, and where it is present it is what the engine actually uses — `couplerInhibition`
    /// above is then the matrix this produces, written out so the file still says plainly what it
    /// renders.
    public var couplerGeometry: CouplerGeometry?
    public var couplerDiffusionMM: Float
    public var adjacencyStrength: Float?
    public var adjacencyRadiusMM: Float?

    public var grainStrength: Float
    public var grainSizeMM: Float
    public var grainLayerWeights: [Float]
    public var grainLumaCorrelation: Float?
    /// Optional pair describing the grain-size mixture; absent is the
    /// single-radius field every earlier pack rendered.
    public var grainMottleShare: Float?
    public var grainMottleSizeRatio: Float?
    /// Per-layer clump radius as a multiple of `grainSizeMM`. Absent is [1, 1, 1] — the
    /// single-radius pack, bit-identically.
    public var grainLayerSizeRatio: [Float]?
    /// Which granularity-against-density law the emulsion obeys. Absent reads it off the
    /// material: silver for a monochrome stock, the measured chromogenic negative shape for a
    /// colour negative, Selwyn for a reversal. Stated only where the material and the law
    /// cross, as they do for a chromogenic black-and-white stock.
    public var grainDensityLaw: GrainDensityLaw?
    /// `[amplitude, toeDensity, decayDensity]` of the chromogenic negative's
    /// granularity-against-density shape. Absent uses the embedding's shared default;
    /// this source repository supplies an illustrative analytic profile.
    public var grainDensityProfile: [Float]?
    /// Developed fog, in density above the base's own dye. Absent is the shared default.
    public var grainFogDensity: Float?
    public var halationStrength: [Float]
    /// Authored presentation default: the multiple of `halationStrength` a scale of 1 renders.
    /// Absent is 1 — the measured film, bit-identically, which every earlier pack rendered.
    public var halationLookScale: Float? = nil
    /// Gaussian sigma in millimeters of the support's impurity scatter, softening the halo's
    /// edges. Absent is 0 — the clean support, which every earlier pack rendered.
    public var halationHazeMM: Float? = nil
    /// Optional independently calibrated halo shape. Its absence is the exact legacy model.
    public var halationProfile: HalationProfile? = nil
    /// Optional provisional halo shape, ignored unless explicitly enabled by the renderer.
    public var estimatedHalationProfile: HalationProfile? = nil
    /// Optional spectral return matrix (receiver rows by source columns) from the stock's
    /// per-wavelength return-trip stack transmission. Only its row shapes are rendered —
    /// `halationStrength` stays the amplitude — and its absence is the legacy diagonal mix.
    public var halationReturnMatrix: [[Float]]? = nil

    public var paperCurve: CurveSpec
    public var paperMidDensity: Float?
    /// Where this emulsion leaves the reciprocity law, when its datasheet publishes a
    /// long-exposure table. Absent keeps the classic one-stop-per-decade rule, which is
    /// what every earlier pack rendered.
    public var reciprocityFailure: ReciprocityFailure?
    /// Measured non-reference development conditions. Absent means push/pull is unavailable; the
    /// engine does not manufacture a response from the reference curve.
    public var development: DevelopmentSpec? = nil
    public var isMonochrome: Bool?
    public var isReversal: Bool?
    /// A worked example of the pack format rather than a film anyone shot.
    public var isExample: Bool?
    /// A direct positive that is the print — an integral instant sheet.
    public var isReflectionPrint: Bool?
    /// The id of the finished positive this emulsion was designed to be printed onto — a
    /// `PrintPaper` raw value such as `"vision-2383"`. Absent means the stock states no
    /// preference and takes the engine's default sheet.
    public var nativePrintMedium: String?
    /// The loaded id of the stock whose sampled spectral record this definition's curves descend
    /// from, where they descend from one at all. The export gate follows it: a record that could
    /// not leave directly does not leave by being redrawn first.
    public var spectralLineage: String?

    public struct CurveSpec: Codable, Sendable {
        public var dMin: Float
        public var gamma: Float
        public var toe: Float
        public var toeWidth: Float
        public var shoulder: Float
        public var shoulderWidth: Float
        /// A second coated speed group. Absent preserves the original six-parameter curve.
        public var secondary: ComponentSpec?

        public struct ComponentSpec: Codable, Sendable {
            public var gamma: Float
            public var toe: Float
            public var toeWidth: Float
            public var shoulder: Float
            public var shoulderWidth: Float

            public init(_ component: CharacteristicCurveComponent) {
                gamma = component.gamma
                toe = component.toe
                toeWidth = component.toeWidth
                shoulder = component.shoulder
                shoulderWidth = component.shoulderWidth
            }

            public var component: CharacteristicCurveComponent {
                CharacteristicCurveComponent(
                    gamma: gamma, toe: toe, toeWidth: toeWidth,
                    shoulder: shoulder, shoulderWidth: shoulderWidth)
            }
        }

        public init(_ curve: CharacteristicCurve) {
            dMin = curve.dMin
            gamma = curve.gamma
            toe = curve.toe
            toeWidth = curve.toeWidth
            shoulder = curve.shoulder
            shoulderWidth = curve.shoulderWidth
            secondary = curve.secondary.map(ComponentSpec.init)
        }

        public var curve: CharacteristicCurve {
            CharacteristicCurve(dMin: dMin, gamma: gamma, toe: toe,
                                toeWidth: toeWidth, shoulder: shoulder,
                                shoulderWidth: shoulderWidth,
                                secondary: secondary?.component)
        }
    }

    /// Serialised form of a `DonorCaptureLayer`.
    public struct DonorLayerSpec: Codable, Sendable {
        /// The record's name as the publication prints it ("CL").
        public var name: String
        /// Spectral sensitivity on `SpectralGrid`, in the same linear units as the
        /// dye-forming records in `spectral`.
        public var sensitivity: [Float]
        /// The donor's own development curve.
        public var curve: CurveSpec
        /// Inhibitor released into each dye-forming layer per unit of donor activation,
        /// R, G, B record order, log-exposure units.
        public var inhibition: [Float]
        /// Hill exponent for inhibitor release. Absent is the historical linear law.
        public var releaseGamma: Float? = nil
        /// Centre depth below the emulsion surface in micrometres, descriptive.
        public var depthUM: Float?

        public init(_ layer: DonorCaptureLayer) {
            name = layer.name
            sensitivity = layer.sensitivity
            curve = CurveSpec(layer.curve)
            inhibition = layer.inhibition
            releaseGamma = layer.releaseGamma
            depthUM = layer.depthUM
        }

        public var layer: DonorCaptureLayer {
            DonorCaptureLayer(name: name, sensitivity: sensitivity,
                              curve: curve.curve, inhibition: inhibition,
                              releaseGamma: releaseGamma ?? 1,
                              depthUM: depthUM)
        }
    }

    public struct DevelopmentSpec: Codable, Sendable {
        public var developer: String
        public var dilution: String?
        public var temperatureC: Float
        public var agitation: String
        public var source: String
        public var sourcePage: Int
        public var conditions: [ConditionSpec]

        public struct ConditionSpec: Codable, Sendable {
            public var stops: Float
            public var label: String
            public var timeMinutes: Float
            public var exposureIndex: Float?
            public var curves: [CurveSpec]
            public var donorCurves: [CurveSpec]?
            public var grainStrength: Float?
            public var grainSizeMM: Float?
            public var grainLayerWeights: [Float]?
            public var grainFogDensity: Float?
            public var adjacencyStrength: Float?

            public init(_ condition: FilmDevelopmentCondition) {
                stops = condition.stops
                label = condition.label
                timeMinutes = condition.timeMinutes
                exposureIndex = condition.exposureIndex
                curves = condition.curves.map(CurveSpec.init)
                donorCurves = condition.donorCurves.isEmpty
                    ? nil : condition.donorCurves.map(CurveSpec.init)
                grainStrength = condition.grainStrength
                grainSizeMM = condition.grainSizeMM
                grainLayerWeights = condition.grainLayerWeights
                grainFogDensity = condition.grainFogDensity
                adjacencyStrength = condition.adjacencyStrength
            }

            public var condition: FilmDevelopmentCondition {
                FilmDevelopmentCondition(
                    stops: stops, label: label, timeMinutes: timeMinutes,
                    exposureIndex: exposureIndex, curves: curves.map(\.curve),
                    donorCurves: donorCurves?.map(\.curve) ?? [],
                    grainStrength: grainStrength, grainSizeMM: grainSizeMM,
                    grainLayerWeights: grainLayerWeights,
                    grainFogDensity: grainFogDensity,
                    adjacencyStrength: adjacencyStrength)
            }
        }

        public init(_ profile: FilmDevelopmentProfile) {
            developer = profile.developer
            dilution = profile.dilution
            temperatureC = profile.temperatureC
            agitation = profile.agitation
            source = profile.source
            sourcePage = profile.sourcePage
            conditions = profile.conditions.map(ConditionSpec.init)
        }

        public var profile: FilmDevelopmentProfile {
            FilmDevelopmentProfile(
                developer: developer, dilution: dilution,
                temperatureC: temperatureC, agitation: agitation,
                source: source, sourcePage: sourcePage,
                conditions: conditions.map(\.condition))
        }
    }

    /// How a pack describes the stock's wavelength-domain behaviour. `samples` is the exact form:
    /// `SpectralGrid.count` values per layer on the 380...780 nm grid, which is what a pack calibrated from measured
    /// data will carry.
    public enum SpectralSpec: Codable, Sendable {
        /// Fully specified: sensitivity and image-dye density per layer, already on `SpectralGrid`.
        case samples(layerSensitivity: [[Float]], imageDyeDensity: [[Float]])
        /// Measured layer sensitivities, with image dyes taken from a process family.
        case measured(layerSensitivity: [[Float]], dyeFamily: FilmDyeFamily)
        /// Generated asymmetric-Gaussian layers from peak wavelengths.
        case color(peaksNM: [Float], widthsNM: [Float]?, dyeFamily: FilmDyeFamily)
        /// Panchromatic response built from broad RGB bands.
        case monochrome(rgbWeights: [Float])

        private enum CodingKeys: String, CodingKey {
            case kind, layerSensitivity, imageDyeDensity, dyeFamily
            case peaksNM, widthsNM, rgbWeights
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "samples":
                self = .samples(
                    layerSensitivity: try container.decode([[Float]].self, forKey: .layerSensitivity),
                    imageDyeDensity: try container.decode([[Float]].self, forKey: .imageDyeDensity))
            case "measured":
                self = .measured(
                    layerSensitivity: try container.decode([[Float]].self, forKey: .layerSensitivity),
                    dyeFamily: try container.decode(FilmDyeFamily.self, forKey: .dyeFamily))
            case "color":
                self = .color(
                    peaksNM: try container.decode([Float].self, forKey: .peaksNM),
                    widthsNM: try container.decodeIfPresent([Float].self, forKey: .widthsNM),
                    dyeFamily: try container.decode(FilmDyeFamily.self, forKey: .dyeFamily))
            case "monochrome":
                self = .monochrome(
                    rgbWeights: try container.decode([Float].self, forKey: .rgbWeights))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: container,
                    debugDescription: "unknown spectral kind '\(kind)'; expected "
                        + "samples, measured, color or monochrome")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .samples(layerSensitivity, imageDyeDensity):
                try container.encode("samples", forKey: .kind)
                try container.encode(layerSensitivity, forKey: .layerSensitivity)
                try container.encode(imageDyeDensity, forKey: .imageDyeDensity)
            case let .measured(layerSensitivity, dyeFamily):
                try container.encode("measured", forKey: .kind)
                try container.encode(layerSensitivity, forKey: .layerSensitivity)
                try container.encode(dyeFamily, forKey: .dyeFamily)
            case let .color(peaksNM, widthsNM, dyeFamily):
                try container.encode("color", forKey: .kind)
                try container.encode(peaksNM, forKey: .peaksNM)
                try container.encodeIfPresent(widthsNM, forKey: .widthsNM)
                try container.encode(dyeFamily, forKey: .dyeFamily)
            case let .monochrome(rgbWeights):
                try container.encode("monochrome", forKey: .kind)
                try container.encode(rgbWeights, forKey: .rgbWeights)
            }
        }

        public var profile: FilmSpectralProfile {
            switch self {
            case let .samples(layerSensitivity, imageDyeDensity):
                return FilmSpectralProfile(layerSensitivity: layerSensitivity,
                                           imageDyeDensity: imageDyeDensity)
            case let .measured(layerSensitivity, dyeFamily):
                return .measured(layerSensitivity: layerSensitivity, dyeFamily: dyeFamily)
            case let .color(peaksNM, widthsNM, dyeFamily):
                if let widthsNM {
                    return .color(peaksNM: peaksNM, widthsNM: widthsNM, dyeFamily: dyeFamily)
                }
                return .color(peaksNM: peaksNM, dyeFamily: dyeFamily)
            case let .monochrome(rgbWeights):
                return .monochrome(rgbWeights: rgbWeights)
            }
        }
    }
}

public extension FilmStockDefinition {
    static let currentSchemaVersion = 1

    /// Materialise the definition into a renderable stock. `FilmStock.init` re-normalises the RGB
    /// matrix and validates layer counts, so a malformed pack fails here rather than part-way
    /// through a render.
    var stock: FilmStock {
        FilmStock(
            name: name,
            sensitivity: sensitivity,
            referenceIlluminantKelvin: referenceIlluminantKelvin ?? 5500,
            spectralProfile: spectral.profile,
            curves: curves.map(\.curve),
            donorLayers: donorLayers?.map(\.layer) ?? [],
            flare: flare ?? 0.008,
            emulsionDiffusionMM: emulsionDiffusionMM ?? [0, 0, 0],
            emulsionDiffusionSecondaryMM: emulsionDiffusionSecondaryMM ?? [0, 0, 0],
            emulsionDiffusionPrimaryShare: emulsionDiffusionPrimaryShare ?? [1, 1, 1],
            mtfLumaShare: mtfLumaShare ?? 0,
            lumaDiffusionMM: lumaDiffusionMM,
            couplerInhibition: couplerInhibition,
            couplerReleaseGamma: couplerReleaseGamma ?? [1, 1, 1],
            couplerGeometry: couplerGeometry,
            couplerDiffusionMM: couplerDiffusionMM,
            adjacencyStrength: adjacencyStrength ?? 0,
            adjacencyRadiusMM: adjacencyRadiusMM ?? 0,
            grainStrength: grainStrength,
            grainSizeMM: grainSizeMM,
            grainLayerWeights: grainLayerWeights,
            grainLumaCorrelation: grainLumaCorrelation ?? 0,
            grainMottleShare: grainMottleShare ?? 0,
            grainMottleSizeRatio: grainMottleSizeRatio ?? 3,
            grainLayerSizeRatio: grainLayerSizeRatio ?? [1, 1, 1],
            grainDensityLaw: grainDensityLaw,
            grainDensityProfile: grainDensityProfile,
            grainFogDensity: grainFogDensity ?? FilmStock.defaultGrainFogDensity,
            halationStrength: halationStrength,
            halationLookScale: halationLookScale ?? 1,
            halationHazeMM: halationHazeMM ?? 0,
            halationProfile: halationProfile,
            estimatedHalationProfile: estimatedHalationProfile,
            halationReturnMatrix: halationReturnMatrix,
            paperCurve: paperCurve.curve,
            paperMidDensity: paperMidDensity ?? 0.744,
            reciprocityFailure: reciprocityFailure,
            developmentProfile: development?.profile,
            isMonochrome: isMonochrome ?? false,
            isReversal: isReversal ?? false,
            isReflectionPrint: isReflectionPrint ?? false,
            nativePrintMedium: nativePrintMedium.flatMap(PrintPaper.preset(id:)))
    }

    /// Capture a stock in its exact rendered form.
    init(id: String, stock: FilmStock, subtitle: String? = nil,
         nativeFormatID: String? = nil) {
        self.schemaVersion = FilmStockDefinition.currentSchemaVersion
        self.id = id
        self.name = stock.name
        self.subtitle = subtitle
        self.nativeFormatID = nativeFormatID
        self.referenceIlluminantKelvin = stock.referenceIlluminantKelvin
        self.sensitivity = stock.sensitivity
        self.spectral = .samples(
            layerSensitivity: stock.spectralProfile.layerSensitivity,
            imageDyeDensity: stock.spectralProfile.imageDyeDensity)
        self.curves = stock.curves.map(CurveSpec.init)
        self.donorLayers = stock.donorLayers.isEmpty
            ? nil : stock.donorLayers.map(DonorLayerSpec.init)
        self.flare = stock.flare
        self.emulsionDiffusionMM = stock.emulsionDiffusionMM
        self.emulsionDiffusionSecondaryMM = stock.emulsionDiffusionSecondaryMM
        self.emulsionDiffusionPrimaryShare = stock.emulsionDiffusionPrimaryShare
        self.mtfLumaShare = stock.mtfLumaShare
        self.lumaDiffusionMM = stock.lumaDiffusionMM
        self.couplerInhibition = stock.couplerInhibition
        self.couplerReleaseGamma = stock.couplerReleaseGamma
        self.couplerGeometry = stock.couplerGeometry
        self.couplerDiffusionMM = stock.couplerDiffusionMM
        self.adjacencyStrength = stock.adjacencyStrength
        self.adjacencyRadiusMM = stock.adjacencyRadiusMM
        self.grainStrength = stock.grainStrength
        self.grainSizeMM = stock.grainSizeMM
        self.grainLayerWeights = stock.grainLayerWeights
        self.grainLumaCorrelation = stock.grainLumaCorrelation
        self.grainMottleShare = stock.grainMottleShare
        self.grainMottleSizeRatio = stock.grainMottleSizeRatio
        self.grainLayerSizeRatio = stock.grainLayerSizeRatio
        self.grainDensityLaw = stock.grainDensityLaw
        self.grainDensityProfile = stock.grainDensityProfile
        self.grainFogDensity = stock.grainFogDensity
        self.halationStrength = stock.halationStrength
        self.halationLookScale = stock.halationLookScale
        self.halationHazeMM = stock.halationHazeMM
        self.halationProfile = stock.halationProfile
        self.estimatedHalationProfile = stock.estimatedHalationProfile
        self.halationReturnMatrix = stock.halationReturnMatrix
        self.paperCurve = CurveSpec(stock.paperCurve)
        self.paperMidDensity = stock.paperMidDensity
        self.reciprocityFailure = stock.reciprocityFailure
        self.development = stock.developmentProfile.map(DevelopmentSpec.init)
        self.isMonochrome = stock.isMonochrome
        self.isReversal = stock.isReversal
        self.isReflectionPrint = stock.isReflectionPrint
        self.nativePrintMedium = stock.nativePrintMedium?.id
        self.spectralLineage = nil
    }
}

/// Assigned by the loader from where the bytes were read, never decoded from the file: a pack
/// cannot describe itself into a category, which is the only reason the export gate below means
/// anything.
public enum FilmStockOrigin: Sendable, Equatable {
    /// Plain JSON on the search path, including `FOTUFILM_STOCKS`.
    case installed
    /// A sealed pack from inside the application bundle.
    case vault
    /// A sealed pack that arrived from another user.
    case community(packID: String)
    /// A sealed pack authored on this device.
    case local(packID: String)

    public var isShareable: Bool {
        switch self {
        case .community, .local: return true
        case .installed, .vault: return false
        }
    }

    public var packID: String? {
        switch self {
        case let .community(packID), let .local(packID): return packID
        case .installed, .vault: return nil
        }
    }
}

/// A loaded set of stock definitions, keyed by id.
public struct FilmStockPack: Sendable {
    public var stocks: [String: FilmStockDefinition]
    /// Keyed like `stocks`.
    public var origins: [String: FilmStockOrigin]
    /// What each custom pack's manifest called itself, which is not recoverable from a stock.
    public var packNames: [String: String]
    public var sources: [URL]
    /// Packs found and skipped.
    public var warnings: [String]

    public init(stocks: [String: FilmStockDefinition] = [:],
                origins: [String: FilmStockOrigin] = [:],
                packNames: [String: String] = [:],
                sources: [URL] = [],
                warnings: [String] = []) {
        self.stocks = stocks
        self.origins = origins
        self.packNames = packNames
        self.sources = sources
        self.warnings = warnings
    }

    public enum LoadError: Error, CustomStringConvertible {
        case unreadable(URL, underlying: Error)
        case malformed(URL, underlying: Error)
        /// A pack that opened but is not allowed to be where it was found.
        case refused(URL, reason: String)

        public var description: String {
            switch self {
            case let .unreadable(url, error):
                return "could not read stock \(url.lastPathComponent): \(error)"
            case let .malformed(url, error):
                return "invalid stock \(url.lastPathComponent): \(error)"
            case let .refused(url, reason):
                return "refused \(url.lastPathComponent): \(reason)"
            }
        }
    }

    /// Directories searched for `*.json` stock definitions, nearest last so
    /// that a later directory overrides an earlier one on id collision.
    public static var searchPaths: [URL] {
        var paths: [URL] = []
        #if SWIFT_PACKAGE
        if let bundled = Bundle.module.url(forResource: "Stocks", withExtension: nil) {
            paths.append(bundled)
        }
        #endif
        if let bundled = Bundle.main.url(forResource: "Stocks", withExtension: nil) {
            paths.append(bundled)
        }
        paths.append(URL(fileURLWithPath: "Stocks", isDirectory: true))
        if let configured = ProcessInfo.processInfo.environment["FOTUFILM_STOCKS"] {
            paths.append(contentsOf: configured.split(separator: ":")
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: String($0), isDirectory: true) })
        }
        return paths
    }

    /// Read every `*.json` in `directory`.
    public static func load(directory: URL) throws -> [String: FilmStockDefinition] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [:] }

        let entries: [URL]
        do {
            entries = try manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        } catch {
            throw LoadError.unreadable(directory, underlying: error)
        }

        let decoder = JSONDecoder()
        var stocks: [String: FilmStockDefinition] = [:]
        for url in entries.sorted(by: { $0.path < $1.path })
        where url.pathExtension.lowercased() == "json" {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw LoadError.unreadable(url, underlying: error)
            }
            do {
                let definition = try decoder.decode(FilmStockDefinition.self, from: data)
                    .validated()
                stocks[definition.id] = definition
            } catch {
                throw LoadError.malformed(url, underlying: error)
            }
        }
        return stocks
    }

    public static let sealedPathExtension = "fotufilmpack"

    /// The custom packs, set by the application because where they live is
    /// not the engine's business.
    public static var installedSealedPackURLs: [URL] {
        get { installedSealedStorage.withLock { $0 } }
        set { installedSealedStorage.withLock { $0 = newValue } }
    }

    /// Sealed-pack URLs supplied by plugin bundles, where `Bundle.main` refers to the host.
    /// Set only by the bundle that owns the files.
    public static var embeddedSealedPackURLs: [URL] {
        get { embeddedSealedStorage.withLock { $0 } }
        set { embeddedSealedStorage.withLock { $0 = newValue } }
    }

    /// The only place a `vault` pack is accepted, so a file dropped into the custom store cannot
    /// claim to be part of the build.
    public static var bundledSealedPackURLs: [URL] {
        var urls: [URL] = []
        // `paths(forResourcesOfType:inDirectory:)` rather than `urls(forResourcesWithExtension:)`:
        // the URL-returning call is typed `[URL]?` by Darwin Foundation but `[NSURL]?` by
        // swift-corelibs-foundation, so it does not compile off Apple platforms. The path-returning
        // call is `[String]` on both.
        #if SWIFT_PACKAGE
        urls += Bundle.module.paths(forResourcesOfType: sealedPathExtension, inDirectory: nil)
            .map { URL(fileURLWithPath: $0) }
        #endif
        urls += Bundle.main.paths(forResourcesOfType: sealedPathExtension, inDirectory: nil)
            .map { URL(fileURLWithPath: $0) }
        urls += embeddedSealedPackURLs
        return urls
    }

    /// `trustedVault` is true only for files inside the application bundle.
    public static func load(sealed url: URL, trustedVault: Bool)
        throws -> (stocks: [String: FilmStockDefinition],
                   origins: [String: FilmStockOrigin],
                   packName: String) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= FilmPackContainer.fileLimit else {
            throw LoadError.malformed(url, underlying: FilmPackContainer.Failure.truncated)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.unreadable(url, underlying: error)
        }

        let head = try FilmPackContainer.peek(data)
        if head.kind == .vault && !trustedVault {
            throw LoadError.refused(url, reason:
                "a vault pack outside the application bundle")
        }
        if head.kind != .vault && trustedVault {
            throw LoadError.refused(url, reason:
                "a \(head.kind) pack shipped as part of the build")
        }

        let manifest: FilmPackManifest
        do {
            manifest = try FilmPackContainer.open(data).manifest
        } catch {
            throw LoadError.malformed(url, underlying: error)
        }

        var stocks: [String: FilmStockDefinition] = [:]
        var origins: [String: FilmStockOrigin] = [:]
        let origin: FilmStockOrigin
        switch head.kind {
        case .vault: origin = .vault
        case .community: origin = .community(packID: manifest.packID)
        case .local: origin = .local(packID: manifest.packID)
        }

        for definition in manifest.stocks {
            if head.kind != .vault {
                do {
                    try definition.validate()
                } catch {
                    throw LoadError.malformed(url, underlying: error)
                }
            }
            let key = head.kind == .vault
                ? definition.id
                : "\(manifest.packID).\(definition.id)"
            stocks[key] = definition
            origins[key] = origin
        }
        return (stocks, origins, manifest.name)
    }

    /// Custom packs first, plain JSON, then the bundle's vault last, so nothing a user installs can
    /// stand in front of a shipped stock.
    public static func load(paths: [URL] = FilmStockPack.searchPaths,
                            sealed: [URL] = FilmStockPack.installedSealedPackURLs,
                            bundled: [URL] = FilmStockPack.bundledSealedPackURLs)
        throws -> FilmStockPack {
        var pack = FilmStockPack()

        for url in sealed.sorted(by: { $0.path < $1.path }) {
            do {
                let (stocks, origins, packName) = try load(sealed: url,
                                                           trustedVault: false)
                guard !stocks.isEmpty else { continue }
                pack.stocks.merge(stocks) { _, newer in newer }
                pack.origins.merge(origins) { _, newer in newer }
                for origin in origins.values {
                    if let packID = origin.packID { pack.packNames[packID] = packName }
                }
                pack.sources.append(url)
            } catch {
                pack.warnings.append("\(error)")
            }
        }

        for directory in paths {
            let found = try load(directory: directory)
            guard !found.isEmpty else { continue }
            pack.stocks.merge(found) { _, newer in newer }
            for id in found.keys { pack.origins[id] = .installed }
            pack.sources.append(directory)
        }

        for url in bundled.sorted(by: { $0.path < $1.path }) {
            let (stocks, origins, _) = try load(sealed: url, trustedVault: true)
            guard !stocks.isEmpty else { continue }
            pack.stocks.merge(stocks) { _, newer in newer }
            pack.origins.merge(origins) { _, newer in newer }
            pack.sources.append(url)
        }

        return pack
    }

    /// The process-wide pack.
    public static var shared: FilmStockPack {
        if let loaded = sharedStorage.withLock({ $0 }) { return loaded }
        let pack: FilmStockPack
        do {
            pack = try load()
            loadErrorStorage.withLock { $0 = nil }
        } catch {
            loadErrorStorage.withLock { $0 = error }
            pack = FilmStockPack()
        }
        sharedStorage.withLock { $0 = pack }
        return pack
    }

    @discardableResult
    public static func reload() -> FilmStockPack {
        sharedStorage.withLock { $0 = nil }
        generationStorage.withLock { $0 += 1 }
        return shared
    }

    public static var generation: Int { generationStorage.withLock { $0 } }

    public static var loadError: Error? { loadErrorStorage.withLock { $0 } }

    private static let sharedStorage = Mutex<FilmStockPack?>(nil)
    private static let loadErrorStorage = Mutex<Error?>(nil)
    private static let generationStorage = Mutex<Int>(0)
    private static let installedSealedStorage = Mutex<[URL]>([])
    private static let embeddedSealedStorage = Mutex<[URL]>([])
}

public extension FilmStockPack {
    enum ExportRefusal: Error, CustomStringConvertible {
        case notShareable(id: String, origin: FilmStockOrigin)
        /// The stock itself is the user's, but its curves were taken from a record that is not.
        case lineageNotShareable(id: String, source: String)
        case unknownStock(id: String)
        case empty
        case noCommunityKey
        /// No key to keep the user's own films with — the keychain would not give one up.
        case noLocalKey

        public var description: String {
            switch self {
            case let .notShareable(id, origin):
                switch origin {
                case .vault:
                    return "\(id) is one of the films this app ships with, and those "
                        + "are not exportable"
                case .installed:
                    return "\(id) came from an installed pack rather than from you, "
                        + "so it is not yours to share from here"
                case .community, .local:
                    return "\(id) cannot be shared"
                }
            case let .lineageNotShareable(id, source):
                return "\(id) carries curves taken from \(source), which is not "
                    + "yours to share, so a film drawn from them stays too"
            case let .unknownStock(id):
                return "no stock called \(id) is loaded"
            case .empty:
                return "a pack needs at least one stock"
            case .noCommunityKey:
                return "this build cannot seal a shareable pack"
            case .noLocalKey:
                return "this device would not give up the key your films are "
                    + "kept with, so there is nowhere safe to put this one"
            }
        }
    }

    /// The single door out.
    static func sealForSharing(stockIDs: [String],
                               packID: String,
                               name: String,
                               author: String? = nil,
                               notes: String? = nil,
                               pack: FilmStockPack = .shared,
                               keyring: FilmPackKeyring = .shared) throws -> Data {
        guard !stockIDs.isEmpty else { throw ExportRefusal.empty }
        guard let (key, keyID) = keyring.newest(kind: .community) else {
            throw ExportRefusal.noCommunityKey
        }

        var definitions: [FilmStockDefinition] = []
        for id in stockIDs {
            guard let definition = pack.stocks[id] else {
                throw ExportRefusal.unknownStock(id: id)
            }
            let origin = pack.origins[id] ?? .installed
            guard origin.isShareable else {
                throw ExportRefusal.notShareable(id: id, origin: origin)
            }
            // Export requires every referenced spectral-lineage source to remain loaded and
            // shareable.
            if let lineage = definition.spectralLineage {
                guard pack.origins[lineage]?.isShareable == true else {
                    throw ExportRefusal.lineageNotShareable(id: id, source: lineage)
                }
            }
            var copy = definition
            copy.id = origin.packID.map { qualifier in
                id.hasPrefix(qualifier + ".")
                    ? String(id.dropFirst(qualifier.count + 1)) : id
            } ?? id
            try copy.validate()
            definitions.append(copy)
        }

        let manifest = FilmPackManifest(packID: packID, name: name, author: author,
                                        notes: notes, stocks: definitions)
        return try FilmPackContainer.seal(manifest, kind: .community,
                                          keyID: keyID, key: key)
    }

    /// How the custom store keeps a user's own work at rest.
    static func sealForThisDevice(_ definitions: [FilmStockDefinition],
                                  packID: String,
                                  name: String,
                                  keyring: FilmPackKeyring = .shared) throws -> Data {
        guard !definitions.isEmpty else { throw ExportRefusal.empty }
        guard let (key, keyID) = keyring.newest(kind: .local) else {
            throw ExportRefusal.noLocalKey
        }
        for definition in definitions { try definition.validate() }
        let manifest = FilmPackManifest(packID: packID, name: name,
                                        stocks: definitions)
        return try FilmPackContainer.seal(manifest, kind: .local,
                                          keyID: keyID, key: key)
    }
}

/// Minimal lock; `FilmStockPack.shared` needs one mutable slot and the
/// package targets platforms predating `Synchronization.Mutex`.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

public extension FilmStock {
    /// Every stock available from the loaded packs, keyed by id.
    static var presets: [String: FilmStock] {
        FilmStockPack.shared.stocks.mapValues(\.stock)
    }

    /// Definitions for the loaded stocks, including presentation metadata
    /// that `FilmStock` itself does not carry (id, subtitle).
    static var presetDefinitions: [String: FilmStockDefinition] {
        FilmStockPack.shared.stocks
    }

    /// The films to offer a user, in a stable display order: the pack's own ordering is by id.
    static var presetIDs: [String] {
        let installed = allPresetIDs.filter {
            FilmStockPack.shared.stocks[$0]?.isExample != true
        }
        return installed.isEmpty ? allPresetIDs : installed
    }

    /// Every id the packs carry, examples included — for tooling that is
    /// enumerating the pack rather than offering a choice.
    static var allPresetIDs: [String] {
        FilmStockPack.shared.stocks.keys.sorted()
    }

    /// Where a stock came from. `nil` for an id no pack carries.
    static func origin(of id: String) -> FilmStockOrigin? {
        FilmStockPack.shared.origins[id]
    }

    /// What a share button may offer.
    static var shareablePresetIDs: [String] {
        FilmStockPack.shared.origins
            .filter { $0.value.isShareable }
            .keys.sorted()
    }

    /// Custom packs, in the order they should be listed: pack id to the stocks it carries.
    static var customPacks: [(packID: String, stockIDs: [String])] {
        var byPack: [String: [String]] = [:]
        for (id, origin) in FilmStockPack.shared.origins {
            guard let packID = origin.packID else { continue }
            byPack[packID, default: []].append(id)
        }
        return byPack.map { ($0.key, $0.value.sorted()) }
            .sorted { $0.packID < $1.packID }
    }

    /// A stock decoded from one pack entry's JSON.
    static func decoded(fromPackJSON json: String) throws -> FilmStock {
        guard let data = json.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "pack text is not UTF-8"))
        }
        return try JSONDecoder().decode(FilmStockDefinition.self, from: data)
            .validated().stock
    }

    /// Look up a stock by id.
    static func named(_ id: String) -> FilmStock? {
        FilmStockPack.shared.stocks[id]?.stock
    }

    /// A stock to start from when the caller has no preference — the first id in display order.
    static var `default`: FilmStock? {
        presetIDs.first.flatMap(named)
    }
}
