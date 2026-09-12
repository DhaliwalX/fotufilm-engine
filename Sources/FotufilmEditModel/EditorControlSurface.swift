import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

public enum EditorSurface: String, CaseIterable, Sendable, Codable {
    case app, desktop, android, resolve, finalcut, web, cli

    public var title: String {
        switch self {
        case .app: return "iPhone"
        case .desktop: return "Mac and iPad"
        case .android: return "Android"
        case .resolve: return "DaVinci Resolve"
        case .finalcut: return "Final Cut Pro"
        case .web: return "Web"
        case .cli: return "Command line"
        }
    }
}

public enum EditorControlScope: Equatable, Sendable {
    case edit
    case global(settingKey: String)
    case hostOnly
}

public enum StoredEncoding: String, Sendable, Codable {
    case same
    case miredFromWarmth
    case duvFromPadTint
    case scaleFromStops

    public func stored(fromDisplayed value: Double) -> Double {
        switch self {
        case .same: return value
        case .miredFromWarmth: return WarmthAxis.mired(fromWarmth: value)
        case .duvFromPadTint: return WarmthAxis.duv(fromPadTint: value)
        case .scaleFromStops: return HalationAmount.scale(fromStops: value)
        }
    }

    public func displayed(fromStored value: Double) -> Double {
        switch self {
        case .same: return value
        case .miredFromWarmth: return WarmthAxis.warmth(fromMired: value)
        case .duvFromPadTint: return WarmthAxis.padTint(fromDuv: value)
        case .scaleFromStops: return HalationAmount.stops(fromScale: value)
        }
    }
}

public enum WarmthAxis {
    public static let neutralMired = Double(WhiteBalance.kelvinToMired(WhiteBalance.neutralKelvin))
    public static let coolMired = 1e6 / 12000.0
    public static let warmMired = 1e6 / 2500.0

    public static func warmth(fromMired mired: Double) -> Double {
        let warmth = mired >= neutralMired
            ? (mired - neutralMired) / (warmMired - neutralMired)
            : (mired - neutralMired) / (neutralMired - coolMired)
        return min(max(warmth, -1), 1)
    }

    public static func mired(fromWarmth warmth: Double) -> Double {
        warmth > 0
            ? neutralMired + warmth * (warmMired - neutralMired)
            : neutralMired + warmth * (neutralMired - coolMired)
    }

    public static func kelvin(fromWarmth warmth: Double) -> Double {
        Double(WhiteBalance.miredToKelvin(Float(mired(fromWarmth: warmth))))
    }

    public static func warmth(fromKelvin kelvin: Double) -> Double {
        warmth(fromMired: Double(WhiteBalance.kelvinToMired(Float(kelvin))))
    }

    public static func padTint(fromDuv tint: Double) -> Double {
        min(max(tint / 100, -1), 1)
    }

    public static func duv(fromPadTint value: Double) -> Double {
        value * 100
    }
}

public enum EditorControlPersistence: Equatable, Sendable {
    case key(String, StoredEncoding)
    case bespoke
    case none

    public var key: String? {
        if case .key(let key, _) = self { return key }
        return nil
    }

    public var encoding: StoredEncoding? {
        if case .key(_, let encoding) = self { return encoding }
        return nil
    }
}

public enum EditorControlValue: Equatable, Sendable {
    case number(Double)
    case optionalNumber(Double?)
    case flag(Bool)
    case curve([Double])
    case choice(Int)

    public var number: Double? {
        switch self {
        case .number(let value): return value
        case .optionalNumber(let value): return value
        case .flag(let on): return on ? 1 : 0
        case .choice(let index): return Double(index)
        case .curve: return nil
        }
    }

    public var flag: Bool? {
        switch self {
        case .flag(let on): return on
        case .number(let value): return value != 0
        case .optionalNumber(let value): return value.map { $0 != 0 }
        case .choice(let index): return index != 0
        case .curve: return nil
        }
    }

    public var choice: Int? {
        switch self {
        case .choice(let index): return index
        case .number(let value): return Int(value)
        case .optionalNumber(let value): return value.map { Int($0) }
        case .flag(let on): return on ? 1 : 0
        case .curve: return nil
        }
    }
}

public enum GradeBand: String, CaseIterable, Sendable, Codable {
    case shadows, midtones, highlights

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    public var keyPath: WritableKeyPath<ColorGrade, ColorGrade.Band> {
        switch self {
        case .shadows: return \.shadows
        case .midtones: return \.midtones
        case .highlights: return \.highlights
        }
    }
}

public enum GradeAxis: String, CaseIterable, Sendable, Codable {
    case warmth, tint, level

    public var keyPath: WritableKeyPath<ColorGrade.Band, Float> {
        switch self {
        case .warmth: return \.balanceX
        case .tint: return \.balanceY
        case .level: return \.level
        }
    }
}

public enum EngineBinding: Equatable, Sendable {
    case exposureEV
    case warmth
    case tint
    case highlights
    case shadows
    case localTone
    case saturation
    case vibrance
    case grainScale
    case grainMottleShare
    case discGrain
    case halationStops
    case halationSourceColour
    case halationReturnRatio
    case halationReturnGain
    case couplerScale
    case couplerGapReach
    case couplerSelf
    case chromaticFringeAmount
    case chromaticFringeRadiusMicrometers
    case developmentEV
    case bleachBypass
    case expiredYears
    case shutterSeconds
    case printViewingKelvin
    case printCorrection
    case grade(GradeBand, GradeAxis)
    case gradeSpaceEncoded
    case flareScale
    case estimatedHalationProfile
    case halationModelIndex
    case negativeViewingIndex
    case frameCoverage
    case focalLengthMM
    case sceneIlluminantKelvin
    case stageIndex
    case textureStagesMask
    case seed
    case enlargerIndex
    case whiteBalanceKelvin
    case whiteBalanceDuv
    case halationScale

    public var optionNames: [String] {
        switch self {
        case .exposureEV: return ["exposureEV"]
        case .warmth, .tint: return ["whiteBalance"]
        case .highlights: return ["highlights"]
        case .shadows: return ["shadows"]
        case .localTone: return ["localTone"]
        case .saturation: return ["saturation"]
        case .vibrance: return ["vibrance"]
        case .grainScale: return ["grainScale"]
        case .grainMottleShare: return ["grainMottleShare"]
        case .discGrain: return ["grainModel"]
        case .halationStops: return ["halationScale"]
        case .halationReturnRatio: return ["halationReturnRatio"]
        case .halationSourceColour: return ["halationSourceColour"]
        case .halationReturnGain: return ["halationReturnGain"]
        case .couplerScale: return ["couplerScale"]
        case .couplerGapReach: return ["couplerGapReachScales"]
        case .couplerSelf: return ["couplerSelfScale"]
        case .chromaticFringeAmount: return ["chromaticFringeAmount"]
        case .chromaticFringeRadiusMicrometers: return ["chromaticFringeRadiusMM"]
        case .developmentEV: return ["developmentEV"]
        case .bleachBypass: return ["bleachBypass"]
        case .expiredYears: return ["expiredYears"]
        case .shutterSeconds: return ["shutterSeconds"]
        case .printViewingKelvin: return ["printViewingKelvin"]
        case .printCorrection: return ["printCorrection"]
        case .grade: return ["grade"]
        case .gradeSpaceEncoded: return ["gradeSpace"]
        case .flareScale: return ["flareScale"]
        case .estimatedHalationProfile: return ["useEstimatedHalationProfile"]
        case .halationModelIndex: return ["halationModel"]
        case .negativeViewingIndex: return ["negativeViewing"]
        case .frameCoverage: return ["frameCoverage"]
        case .focalLengthMM: return ["focalLengthMM"]
        case .sceneIlluminantKelvin: return ["sceneIlluminantKelvin"]
        case .stageIndex: return ["stage"]
        case .textureStagesMask: return ["textureStages"]
        case .seed: return ["seed"]
        case .enlargerIndex: return ["enlarger"]
        case .whiteBalanceKelvin, .whiteBalanceDuv: return ["whiteBalance"]
        case .halationScale: return ["halationScale"]
        }
    }

    public func apply(_ value: EditorControlValue, to options: inout FotufilmEngine.Options) {
        switch self {
        case .exposureEV:
            if let number = value.number { options.exposureEV = Float(number) }
        case .warmth:
            if let number = value.number {
                options.whiteBalance.kelvin = Float(WarmthAxis.kelvin(fromWarmth: number))
            }
        case .tint:
            if let number = value.number {
                options.whiteBalance.tint = Float(WarmthAxis.duv(fromPadTint: number))
            }
        case .highlights:
            if let number = value.number { options.highlights = Float(number) }
        case .shadows:
            if let number = value.number { options.shadows = Float(number) }
        case .localTone:
            if let flag = value.flag { options.localTone = flag }
        case .saturation:
            if let number = value.number { options.saturation = Float(number) }
        case .vibrance:
            if let number = value.number { options.vibrance = Float(number) }
        case .grainScale:
            if let number = value.number { options.grainScale = Float(number) }
        case .grainMottleShare:
            options.grainMottleShare = value.number.map(Float.init)
        case .discGrain:
            if let flag = value.flag { options.grainModel = flag ? .discs : .clumpField }
        case .halationStops:
            if let number = value.number {
                options.halationScale = Float(HalationAmount.scale(fromStops: number))
            }
        case .halationReturnRatio:
            options.halationReturnRatio = value.number.map(Float.init)
        case .halationSourceColour:
            if let number = value.number { options.halationSourceColour = Float(number) }
        case .halationReturnGain:
            if case .curve(let handles) = value {
                options.halationReturnGain = HalationSpectrum.resampled(handles.map(Float.init))
            }
        case .couplerScale:
            if let number = value.number { options.couplerScale = Float(number) }
        case .couplerGapReach:
            if let number = value.number {
                options.couplerGapReachScales = [Float(number), Float(number)]
            }
        case .couplerSelf:
            if let number = value.number { options.couplerSelfScale = Float(number) }
        case .chromaticFringeAmount:
            if let number = value.number { options.chromaticFringeAmount = Float(number) }
        case .chromaticFringeRadiusMicrometers:
            if let number = value.number { options.chromaticFringeRadiusMM = Float(number / 1000) }
        case .developmentEV:
            if let number = value.number { options.developmentEV = Float(number) }
        case .bleachBypass:
            if let number = value.number { options.bleachBypass = Float(number) }
        case .expiredYears:
            if let number = value.number { options.expiredYears = Float(number) }
        case .shutterSeconds:
            options.shutterSeconds = value.number.flatMap { $0 > 0 ? Float($0) : nil }
        case .printViewingKelvin:
            options.printViewingKelvin = value.number.flatMap { $0 > 0 ? Float($0) : nil }
        case .printCorrection:
            if let number = value.number { options.printCorrection = Float(number) }
        case .grade(let band, let axis):
            if let number = value.number {
                options.grade[keyPath: band.keyPath][keyPath: axis.keyPath] = Float(number)
            }
        case .gradeSpaceEncoded:
            if let flag = value.flag { options.gradeSpace = flag ? .encoded : .linear }
        case .flareScale:
            if let number = value.number { options.flareScale = Float(number) }
        case .estimatedHalationProfile:
            if let flag = value.flag { options.useEstimatedHalationProfile = flag }
        case .halationModelIndex:
            if let index = value.choice { options.halationModel = index == 1 ? .layered : .legacy }
        case .negativeViewingIndex:
            if let index = value.choice, NegativeViewing.allCases.indices.contains(index) {
                options.negativeViewing = NegativeViewing.allCases[index]
            }
        case .frameCoverage:
            if let number = value.number { options.frameCoverage = Float(number) }
        case .focalLengthMM:
            options.focalLengthMM = value.number.flatMap { $0 > 0 ? Float($0) : nil }
        case .sceneIlluminantKelvin:
            options.sceneIlluminantKelvin = value.number.flatMap {
                $0.isFinite && (1000...25000).contains($0) ? Float($0) : nil
            }
            // Selecting a temperature or Stock Native replaces the entire source choice.
            // A previous capture xy or measured spectrum must not silently override it.
            options.sceneIlluminantChromaticity = nil
            options.sceneIlluminantSpectrum = []
        case .stageIndex:
            if let index = value.choice, let stage = PipelineStage(ordinal: Int32(index)) {
                options.stage = stage
            }
        case .textureStagesMask:
            if let mask = value.choice {
                options.textureStages = TextureStages(rawValue: Int32(mask) & TextureStages.all.rawValue)
            }
        case .seed:
            if let number = value.number { options.seed = UInt64(max(0, number)) }
        case .enlargerIndex:
            if let index = value.choice, Enlarger.allCases.indices.contains(index) {
                options.enlarger = Enlarger.allCases[index]
            }
        case .whiteBalanceKelvin:
            if let number = value.number { options.whiteBalance.kelvin = Float(number) }
        case .whiteBalanceDuv:
            if let number = value.number { options.whiteBalance.tint = Float(number) }
        case .halationScale:
            if let number = value.number { options.halationScale = Float(number) }
        }
    }
}

public struct EditorMenuChoice: Equatable, Sendable {
    public let value: Double?
    public let label: String
    public let detail: String
    public let id: String

    public init(_ value: Double?, _ label: String, detail: String = "", id: String? = nil) {
        self.value = value
        self.label = label
        self.detail = detail
        self.id = id ?? EditorMenuChoice.slug(label)
    }

    static func slug(_ label: String) -> String {
        let lowered = label.lowercased()
        var out = ""
        var pendingDash = false
        for scalar in lowered.unicodeScalars {
            if scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar)) {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out
    }
}

public enum EditorDynamicMenu: String, CaseIterable, Sendable, Codable {
    case stocks, gauges, papers, lensProfiles, lensFilters, meterings
    case diffusionFamilies, diffusionGrades, negativeViewings, stages, textureStages
    case shutterTimes, viewingLights, colourSpaces, pushConditions
}

public enum EditorMenuChoices: Equatable, Sendable {
    case fixed([EditorMenuChoice])
    case dynamic(EditorDynamicMenu)

    public var fixedChoices: [EditorMenuChoice]? {
        if case .fixed(let choices) = self { return choices }
        return nil
    }

    public var dynamicMenu: EditorDynamicMenu? {
        if case .dynamic(let menu) = self { return menu }
        return nil
    }
}

public enum HostGroup: String, CaseIterable, Sendable, Codable {
    case input, film, exposure, sceneLight, lens, lensAdvanced, lab
    case grain, grainAdvanced, halation, halationSpectrum, coupler, couplerAdvanced
    case output, stage, render

    public var ofxName: String {
        switch self {
        case .input: return "inputGroup"
        case .film: return "filmGroup"
        case .exposure: return "exposureGroup"
        case .sceneLight: return "sceneLightGroup"
        case .lens: return "lensGroup"
        case .lensAdvanced: return "lensAdvancedGroup"
        case .lab: return "labGroup"
        case .grain: return "filmResponseGroup"
        case .grainAdvanced: return "grainAdvancedGroup"
        case .halation: return "halationGroup"
        case .halationSpectrum: return "halationSpectrumGroup"
        case .coupler: return "couplerGroup"
        case .couplerAdvanced: return "couplerAdvancedGroup"
        case .output: return "outputGroup"
        case .stage: return "stageGroup"
        case .render: return "renderGroup"
        }
    }

    public var label: String {
        switch self {
        case .input: return "Input"
        case .film: return "Film"
        case .exposure: return "Light & Colour"
        case .sceneLight: return "Spectral Scene Light"
        case .lens: return "Lens & Filters"
        case .lensAdvanced: return "Advanced"
        case .lab: return "Development"
        case .grain: return "Grain"
        case .grainAdvanced: return "Advanced"
        case .halation: return "Halation"
        case .halationSpectrum: return "Return Spectrum"
        case .coupler: return "Colour Separation"
        case .couplerAdvanced: return "Interlayer Reach"
        case .output: return "Output"
        case .stage: return "Pipeline"
        case .render: return "Rendering"
        }
    }

    public var parent: HostGroup? {
        switch self {
        case .sceneLight: return .exposure
        case .lensAdvanced: return .lens
        case .grainAdvanced: return .grain
        case .halationSpectrum: return .halation
        case .couplerAdvanced: return .coupler
        case .render: return .stage
        default: return nil
        }
    }

    public var opensExpanded: Bool {
        switch self {
        case .input, .film, .output: return true
        default: return false
        }
    }

    public var fxplugID: Int? {
        switch self {
        case .input: return 85
        case .film: return 31
        case .exposure: return 32
        case .lens: return 72
        case .lab: return 35
        case .grain: return 34
        case .halation: return 86
        case .coupler: return 87
        case .output: return 36
        case .stage: return 30
        default: return nil
        }
    }

    public var fxplugCollapsed: Bool {
        switch self {
        case .lens, .lab, .stage: return true
        default: return false
        }
    }

    public var topLevel: HostGroup { parent?.topLevel ?? self }
}

public enum BridgeEncoding: String, Sendable, Codable {
    case identity
    case kelvinFromWarmth
    case duvFromPadTint
    case multipleFromStops
    case minusOne
    case indexPlusOne

    public func bridge(fromCanonical value: Double) -> Double {
        switch self {
        case .identity: return value
        case .kelvinFromWarmth: return WarmthAxis.kelvin(fromWarmth: value)
        case .duvFromPadTint: return WarmthAxis.duv(fromPadTint: value)
        case .multipleFromStops: return HalationAmount.scale(fromStops: value)
        case .minusOne: return value - 1
        case .indexPlusOne: return value + 1
        }
    }

    public func canonical(fromBridge value: Double) -> Double {
        switch self {
        case .identity: return value
        case .kelvinFromWarmth: return WarmthAxis.warmth(fromKelvin: value)
        case .duvFromPadTint: return WarmthAxis.padTint(fromDuv: value)
        case .multipleFromStops: return HalationAmount.stops(fromScale: value)
        case .minusOne: return value + 1
        case .indexPlusOne: return value - 1
        }
    }
}

public enum HostParameterKind: Equatable, Sendable {
    case double(min: Double, max: Double, value: Double, hardMax: Double? = nil, delta: Double = 0.01)
    case integer(min: Int, max: Int, value: Int)
    case boolean(value: Bool)
    case choice(EditorMenuChoices, value: Int)

    public var typeName: String {
        switch self {
        case .double: return "double"
        case .integer: return "integer"
        case .boolean: return "boolean"
        case .choice: return "choice"
        }
    }
}

public struct HostParameter: Equatable, Sendable {
    public let slot: Int?
    public let slotSymbol: String?
    public let ofxName: String
    public let fxplugID: Int?
    public let group: HostGroup
    public let label: String
    public let hint: String
    public let kind: HostParameterKind
    public let paramScale: Double
    public let paramOffset: Double
    public let bridge: BridgeEncoding
    public let binding: EngineBinding?
    public let clamp: ClosedRange<Double>?
    public let zeroLeavesEngineDefault: Bool
    public let composed: Bool
    public let animates: Bool
    public let secret: Bool
    public let order: Int

    public init(slot: Int?, slotSymbol: String? = nil, ofxName: String, fxplugID: Int? = nil,
                group: HostGroup, label: String, hint: String, kind: HostParameterKind,
                paramScale: Double = 1, paramOffset: Double = 0,
                bridge: BridgeEncoding = .identity, binding: EngineBinding? = nil,
                clamp: ClosedRange<Double>? = nil, zeroLeavesEngineDefault: Bool = false,
                composed: Bool = false, animates: Bool = true, secret: Bool = false, order: Int) {
        self.slot = slot
        self.slotSymbol = slotSymbol
        self.ofxName = ofxName
        self.fxplugID = fxplugID
        self.group = group
        self.label = label
        self.hint = hint
        self.kind = kind
        self.paramScale = paramScale
        self.paramOffset = paramOffset
        self.bridge = bridge
        self.binding = binding
        self.clamp = clamp
        self.zeroLeavesEngineDefault = zeroLeavesEngineDefault
        self.composed = composed
        self.animates = animates
        self.secret = secret
        self.order = order
    }

    public var fxplugSymbol: String? {
        fxplugID.map { _ in "kFotufilmParam_" + ofxName.prefix(1).uppercased() + ofxName.dropFirst() }
    }
}

public enum HostAuxiliaryKind: Equatable, Sendable {
    case label(text: String, hint: String?)
    case hiddenString
    case pushButton
    case choice([String], value: Int, persistent: Bool)
    case textureToggles
}

public struct HostAuxiliary: Equatable, Sendable {
    public let ofxName: String
    public let fxplugID: Int?
    public let group: HostGroup?
    public let label: String
    public let hint: String?
    public let kind: HostAuxiliaryKind
    public let surfaces: Set<EditorSurface>
    public let order: Int

    public init(ofxName: String, fxplugID: Int? = nil, group: HostGroup?, label: String,
                hint: String? = nil, kind: HostAuxiliaryKind,
                surfaces: Set<EditorSurface> = [.resolve, .finalcut], order: Int) {
        self.ofxName = ofxName
        self.fxplugID = fxplugID
        self.group = group
        self.label = label
        self.hint = hint
        self.kind = kind
        self.surfaces = surfaces
        self.order = order
    }

    public var fxplugSymbol: String? {
        fxplugID.map { _ in "kFotufilmParam_" + ofxName.prefix(1).uppercased() + ofxName.dropFirst() }
    }
}

public enum WebBinding: Equatable, Sendable {
    case configSlot(String, transform: WebTransform)
    case grainScale
}

public enum WebTransform: String, Sendable, Codable {
    case identity
    case exp2
}

public struct CommandLineFlag: Equatable, Sendable {
    public let flag: String
    public let placeholder: String
    public let help: String
    public let generic: Bool
    public let range: ClosedRange<Double>?

    public init(_ flag: String, placeholder: String, help: String, generic: Bool = true,
                range: ClosedRange<Double>? = nil) {
        self.flag = flag
        self.placeholder = placeholder
        self.help = help
        self.generic = generic
        self.range = range
    }
}
