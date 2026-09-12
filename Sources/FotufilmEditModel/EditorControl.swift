import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

public enum EditorControlField: String, CaseIterable, Sendable, Codable {
    case exposure, warmth, tint, highlights, shadows, localTone
    case saturation, vibrance
    case sceneLight, sceneLightKelvin

    case stock, gauge, frameCoverage
    case grain, grainMottle, mottleOverride, mottleShare, grainModel, grainAnimation, seed
    case halation, halationColour, halationSpectrum, halationModel, estimatedHalation
    case couplers, couplerReach, couplerSelf, couplerRedGreen, couplerGreenBlue
    case chromaticFringeAmount, chromaticFringeRadius
    case push, bleach, expired, shutter

    case lensFilter1, lensFilter2, lensFilter3, metering, diffusion, diffusionGrade
    case focalLength, flare, filterCoating
    case lensCorrection, lensProfile, lensAmount
    case lensDistortion, lensVignetting, lensRedCyan, lensBlueYellow

    case paper, printLight, enlarger, printCorrection, negativeViewing, gradeSpace
    case printerEnabled, printerLamp, printerExposure, printerMagenta, printerYellow
    case gradeShadowsWarmth, gradeShadowsTint, gradeShadowsLevel
    case gradeMidtonesWarmth, gradeMidtonesTint, gradeMidtonesLevel
    case gradeHighlightsWarmth, gradeHighlightsTint, gradeHighlightsLevel

    case crop, straighten, perspectiveVertical, perspectiveHorizontal
    case rotation, flip
    case selective

    case colorSpace, stage, textureStages, renderMode
}

public enum EditorControlGroup: String, CaseIterable, Sendable {
    case film, lens, light, print, frame, pipeline

    public var title: String {
        switch self {
        case .film: return "Film"
        case .lens: return "Lens"
        case .light: return "Light & Color"
        case .print: return "Print"
        case .frame: return "Frame"
        case .pipeline: return "Pipeline"
        }
    }
}

public enum EditorControlSection: String, CaseIterable, Sendable {
    case filmStock, filmGrain, filmEmulsion, filmLab
    case lensGlass, lensCorrection
    case lightExposure, lightBalance, lightColor, lightGrade
    case printPaper, printLamp
    case frameGeometry, frameLocal
    case pipeline

    public var group: EditorControlGroup {
        switch self {
        case .filmStock, .filmGrain, .filmEmulsion, .filmLab: return .film
        case .lensGlass, .lensCorrection: return .lens
        case .lightExposure, .lightBalance, .lightColor, .lightGrade: return .light
        case .printPaper, .printLamp: return .print
        case .frameGeometry, .frameLocal: return .frame
        case .pipeline: return .pipeline
        }
    }

    public var title: String {
        switch self {
        case .filmStock: return "Stock"
        case .filmGrain: return "Grain"
        case .filmEmulsion: return "Emulsion"
        case .filmLab: return "Lab"
        case .lensGlass: return "Filters"
        case .lensCorrection: return "Correction"
        case .lightExposure: return "Exposure"
        case .lightBalance: return "Balance"
        case .lightColor: return "Color"
        case .lightGrade: return "Grade"
        case .printPaper: return "Output"
        case .printLamp: return "Lamp"
        case .frameGeometry: return "Geometry"
        case .frameLocal: return "Local"
        case .pipeline: return "Pipeline"
        }
    }
}

public enum EditorControlUnit: String, Sendable, Equatable, Codable {
    case multiplier
    case stops
    case stopsFromOff
    case signed
    case percent
    case years
    case seconds
    case degrees
    case kelvin
    case opticalDensity
    case micrometers
    case millimetres
    case none

    public static let offStops = -6.0

    public func format(_ value: Double) -> String {
        switch self {
        case .multiplier: return String(format: "%.2f×", shown(value, places: 2))
        case .stops: return String(format: "%+.1f EV", shown(value, places: 1))
        case .stopsFromOff:
            return value <= Self.offStops ? "Off" : Self.stops.format(value)
        case .signed: return String(format: "%+.2f", shown(value, places: 2))
        case .percent:
            return String(format: "%.0f%%", shown(value * 100, places: 0))
        case .years:
            return value == 0 ? "Fresh" : String(format: "%.0f yr", value)
        case .seconds:
            if value >= 1 { return String(format: "%.0f s", value) }
            return String(format: "%.2f s", shown(value, places: 2))
        case .degrees: return String(format: "%+.1f°", shown(value, places: 1))
        case .kelvin: return String(format: "%.0f K", shown(value, places: 0))
        case .opticalDensity: return String(format: "%.2f OD", shown(value, places: 2))
        case .micrometers: return String(format: "%.0f µm", shown(value, places: 0))
        case .millimetres: return String(format: "%.0f mm", shown(value, places: 0))
        case .none: return ""
        }
    }

    private func shown(_ value: Double, places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        let rounded = (value * scale).rounded() / scale
        return rounded == 0 ? 0 : rounded
    }
}

public struct EditorControlScale: Sendable, Equatable {
    public let range: ClosedRange<Double>
    public let neutral: Double
    public let unit: EditorControlUnit
    public let stops: [Double]
    public let admitted: ClosedRange<Double>

    public init(_ range: ClosedRange<Double>, neutral: Double,
                unit: EditorControlUnit, stops: [Double] = [],
                admitted: ClosedRange<Double>? = nil) {
        self.range = range
        self.neutral = neutral
        self.unit = unit
        self.stops = stops
        self.admitted = admitted ?? range
    }

    public func isMoved(_ value: Double) -> Bool {
        abs(value - neutral) > (range.upperBound - range.lowerBound) * 1e-4
    }
}

public struct EditorControlChoice: Sendable, Equatable {
    public let value: Double
    public let label: String

    public init(_ value: Double, _ label: String) {
        self.value = value
        self.label = label
    }
}

public enum EditorControlKind: Sendable, Equatable {
    case slider(EditorControlScale)
    case chips(EditorControlScale, choices: [EditorControlChoice])
    case toggle(restingOn: Bool)
    case menu(EditorMenuChoices)
    case takeover
    case curve(EditorControlCurve)

    public var scale: EditorControlScale? {
        switch self {
        case .slider(let scale): return scale
        case .chips(let scale, _): return scale
        case .toggle, .menu, .takeover, .curve: return nil
        }
    }

    public var curve: EditorControlCurve? {
        if case .curve(let curve) = self { return curve }
        return nil
    }

    public var menu: EditorMenuChoices? {
        if case .menu(let choices) = self { return choices }
        return nil
    }

    public var typeName: String {
        switch self {
        case .slider: return "slider"
        case .chips: return "chips"
        case .toggle: return "toggle"
        case .menu: return "menu"
        case .takeover: return "takeover"
        case .curve: return "curve"
        }
    }
}

public struct EditorControlCurve: Sendable, Equatable {
    public let handles: [Double]
    public let domain: ClosedRange<Double>
    public let range: ClosedRange<Double>
    public let neutral: Double
    public let unit: EditorControlUnit

    public init(handles: [Double], domain: ClosedRange<Double>,
                range: ClosedRange<Double>, neutral: Double,
                unit: EditorControlUnit) {
        self.handles = handles
        self.domain = domain
        self.range = range
        self.neutral = neutral
        self.unit = unit
    }

    public var restingValues: [Double] {
        [Double](repeating: neutral, count: handles.count)
    }

    public func isMoved(_ values: [Double]) -> Bool {
        guard values.count == handles.count else { return false }
        let slack = (range.upperBound - range.lowerBound) * 1e-4
        return values.contains { abs($0 - neutral) > slack }
    }
}

public enum EditorControlAvailability: String, Sendable, Equatable, Codable {
    case always
    case film
    case colourNegative
    case printStage
    case statedReciprocity
    case couplerGeometry
    case interlayerInhibition
    case measuredDevelopment

    public func admits(stock: FilmStock?) -> Bool {
        switch self {
        case .always:
            return true
        case .film:
            return stock != nil
        case .colourNegative:
            guard let stock else { return false }
            return !stock.isMonochrome && !stock.isReversal
        case .printStage:
            guard let stock else { return false }
            return !stock.isReversal
        case .statedReciprocity:
            guard let stated = stock?.reciprocityFailure else { return false }
            return stated.lostStopsPerDecade > 0
        case .couplerGeometry:
            return stock?.couplerGeometry != nil
        case .interlayerInhibition:
            guard let stock, !stock.isMonochrome else { return false }
            return stock.couplerInhibition.enumerated().contains { receiver, row in
                row.enumerated().contains { donor, value in receiver != donor && value != 0 }
            }
        case .measuredDevelopment:
            return stock?.hasMeasuredDevelopmentResponse == true
        }
    }

    public var capabilityBit: Int32? {
        switch self {
        case .colourNegative: return 1
        case .couplerGeometry: return 2
        case .statedReciprocity: return 4
        default: return nil
        }
    }
}

public struct EditorControl: Sendable, Equatable, Identifiable {
    public var id: EditorControlField { field }
    public let field: EditorControlField
    public let title: String
    public let detail: String
    public let section: EditorControlSection
    public let kind: EditorControlKind
    public let availability: EditorControlAvailability
    public let foldsUnder: EditorControlField?
    public let scope: EditorControlScope
    public let persistence: EditorControlPersistence
    public let binding: EngineBinding?
    public let drives: [String]
    public let surfaces: Set<EditorSurface>
    public let omitted: [EditorSurface: String]
    public let host: HostParameter?
    public let web: WebBinding?
    public let commandLine: CommandLineFlag?
    public let documentation: String?

    public init(_ field: EditorControlField, title: String, detail: String,
                section: EditorControlSection, kind: EditorControlKind,
                availability: EditorControlAvailability = .always,
                foldsUnder: EditorControlField? = nil,
                scope: EditorControlScope = .edit,
                persistence: EditorControlPersistence? = nil,
                binding: EngineBinding? = nil,
                drives: [String] = [],
                surfaces: Set<EditorSurface> = [.app, .desktop, .android],
                omitted: [EditorSurface: String] = [:],
                host: HostParameter? = nil,
                web: WebBinding? = nil,
                commandLine: CommandLineFlag? = nil,
                documentation: String? = nil) {
        self.field = field
        self.title = title
        self.detail = detail
        self.section = section
        self.kind = kind
        self.availability = availability
        self.foldsUnder = foldsUnder
        self.scope = scope
        self.persistence = persistence ?? Self.defaultPersistence(field, kind: kind, scope: scope)
        self.binding = binding
        self.drives = drives
        self.surfaces = surfaces
        self.omitted = omitted
        self.host = host
        self.web = web
        self.commandLine = commandLine
        self.documentation = documentation
    }

    private static func defaultPersistence(_ field: EditorControlField, kind: EditorControlKind,
                                           scope: EditorControlScope) -> EditorControlPersistence {
        guard case .edit = scope else { return .none }
        switch kind {
        case .slider, .chips, .toggle, .curve: return .key(field.rawValue, .same)
        case .menu, .takeover: return .bespoke
        }
    }

    public var group: EditorControlGroup { section.group }

    public func offered(on surface: EditorSurface) -> Bool { surfaces.contains(surface) }

    public var restingValue: EditorControlValue? {
        switch kind {
        case .slider(let scale), .chips(let scale, _): return .number(scale.neutral)
        case .toggle(let restingOn): return .flag(restingOn)
        case .curve(let curve): return .curve(curve.restingValues)
        case .menu, .takeover: return nil
        }
    }

    public var storedNeutral: Double? {
        guard let neutral = kind.scale?.neutral, let encoding = persistence.encoding else { return nil }
        return encoding.stored(fromDisplayed: neutral)
    }
}
