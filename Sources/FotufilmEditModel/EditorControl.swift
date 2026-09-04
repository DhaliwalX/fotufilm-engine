import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Stable identifiers for editor controls. Multiple controls may map to one stored model value.
public enum EditorControlField: String, CaseIterable, Sendable, Codable {
    // The light the film was given.
    case exposure, warmth, tint, highlights, shadows, localTone
    case saturation, vibrance

    // The emulsion, and what the lab was told to do with it.
    case stock, gauge
    case grain, grainMottle, grainModel, halation, halationColour
    case halationSpectrum
    case couplers, couplerReach, couplerSelf
    case push, bleach, expired, shutter

    // The print, and the grade laid over it.
    case paper, printLight, printCorrection, gradeSpace
    case gradeShadowsWarmth, gradeShadowsTint, gradeShadowsLevel
    case gradeMidtonesWarmth, gradeMidtonesTint, gradeMidtonesLevel
    case gradeHighlightsWarmth, gradeHighlightsTint, gradeHighlightsLevel

    // The frame itself.
    case crop, straighten, perspectiveVertical, perspectiveHorizontal
    case rotation, flip
    case lensCorrection, lensProfile, lensAmount
    case selective
}

/// Top-level editor groups in display order.
public enum EditorControlGroup: String, CaseIterable, Sendable {
    case film, lens, light, print, frame

    public var title: String {
        switch self {
        case .film: return "Film"
        case .lens: return "Lens"
        case .light: return "Light & Color"
        case .print: return "Print"
        case .frame: return "Frame"
        }
    }
}

/// A run of controls under one heading in the panel. Declaration order is panel order, and the
/// groups are contiguous within it, so each circle can scroll to a section by its first row.
public enum EditorControlSection: String, CaseIterable, Sendable {
    case filmStock, filmGrain, filmEmulsion, filmLab
    case lensCorrection
    case lightExposure, lightBalance, lightColor, lightGrade
    case printPaper
    case frameGeometry, frameLocal

    public var group: EditorControlGroup {
        switch self {
        case .filmStock, .filmGrain, .filmEmulsion, .filmLab: return .film
        case .lensCorrection: return .lens
        case .lightExposure, .lightBalance, .lightColor, .lightGrade: return .light
        case .printPaper: return .print
        case .frameGeometry, .frameLocal: return .frame
        }
    }

    public var title: String {
        switch self {
        case .filmStock: return "Stock"
        case .filmGrain: return "Grain"
        case .filmEmulsion: return "Emulsion"
        case .filmLab: return "Lab"
        case .lensCorrection: return "Correction"
        case .lightExposure: return "Exposure"
        case .lightBalance: return "Balance"
        case .lightColor: return "Color"
        case .lightGrade: return "Grade"
        case .printPaper: return "Output"
        case .frameGeometry: return "Geometry"
        case .frameLocal: return "Local"
        }
    }
}

/// Display units for editor values.
public enum EditorControlUnit: String, Sendable, Equatable {
    /// A multiple of what the stock itself does: `1.00×` leaves the emulsion alone.
    case multiplier
    /// Stops, signed, as an exposure or development instruction is written.
    case stops
    /// Stops on a fader: the same signed reading, except that the bottom of the track is off
    /// rather than a very small amount, and reports it.
    case stopsFromOff
    /// A signed amount with no unit of its own — the shaping controls' -1…1.
    case signed
    case percent
    case years
    case seconds
    case degrees
    case kelvin
    /// A choice, a switch, or a surface of its own: nothing to format.
    case none

    /// Where a `stopsFromOff` track stops counting stops and turns the stage off — a fader's −∞
    /// mark, at a definite place so the row, its scale and the edit's storage all agree where it
    /// is. A scale drawn in this unit must start here, which `EditorControlCatalogueTests` holds
    /// it to.
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
        case .none: return ""
        }
    }

    /// The value as the row will print it, with a zero that appears as zero.
    ///
    /// The axes are round trips through the units the engine works in — tint
    /// goes to a duv and back, warmth to a mired — so a control sitting exactly
    /// at neutral comes back as a hair under it. `String(format:)` keeps that
    /// hair's sign, and the row reads `−0.00`, which says the photographer has
    /// tinted the picture when they have not. Rounding to the places the row
    /// actually shows, before the sign is written, is the whole fix.
    private func shown(_ value: Double, places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        let rounded = (value * scale).rounded() / scale
        // `-0.0 == 0` is true, so this also turns a negative zero positive.
        return rounded == 0 ? 0 : rounded
    }
}

/// A numeric control's travel and the value it rests at.
///
/// `neutral` is where the control is *not an edit* — the well the slider snaps into and the value a
/// reset returns it to. It is not always the middle: print correction rests at 0.05, and every
/// multiplier rests at 1.
public struct EditorControlScale: Sendable, Equatable {
    public let range: ClosedRange<Double>
    public let neutral: Double
    public let unit: EditorControlUnit
    /// The values a snapped control may take, in order, or empty where the travel is continuous.
    ///
    /// The lab's order form is written in whole stops and whole years: +1.7 is not something a lab
    /// can be asked for, so the row that asks does not offer it. A row with stops is drawn as a
    /// slider that lands on them, which says the same discrete choice in the same shape as every
    /// other row rather than in a run of chips of its own.
    public let stops: [Double]
    /// The values the control admits without destroying them, where that is wider than the drawn
    /// travel. A value can arrive from outside the slider — a replayed recipe, a capture dump, a
    /// project graded in the Resolve plugin, whose halation admits typed values past its own
    /// visible track — and a control that clamps such a value to its travel silently rewrites the
    /// edit. The slider pins its knob at the end of `range`; the value itself survives inside
    /// `admitted`. For most controls the two are the same range.
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

    /// Whether a value is far enough from rest to call the control moved. Floating point arrives
    /// here from a drag, so exact equality would badge a control the user only brushed.
    public func isMoved(_ value: Double) -> Bool {
        abs(value - neutral) > (range.upperBound - range.lowerBound) * 1e-4
    }
}

/// One named stop on a control that has them — the lab's order form, where `+2` is a thing you ask
/// for and `+1.7` is not.
public struct EditorControlChoice: Sendable, Equatable {
    public let value: Double
    public let label: String

    public init(_ value: Double, _ label: String) {
        self.value = value
        self.label = label
    }
}

/// What a row is, once the panel has to draw it.
public enum EditorControlKind: Sendable, Equatable {
    /// A number on a continuous track.
    case slider(EditorControlScale)
    /// A number with named stops, and the same continuous track behind them.
    case chips(EditorControlScale, choices: [EditorControlChoice])
    /// A switch, and the position it rests in.
    case toggle(restingOn: Bool)
    /// A named choice rather than a number: the film, the gauge, the paper, the grain model.
    case menu
    /// A row that opens a surface of its own rather than editing in place.
    case takeover
    /// A curve drawn against wavelength: a ladder of handles, each moved up and down its own
    /// track, with the shape between them the engine's own interpolation.
    case curve(EditorControlCurve)

    /// The travel, where the row has one.
    public var scale: EditorControlScale? {
        switch self {
        case .slider(let scale): return scale
        case .chips(let scale, _): return scale
        case .toggle, .menu, .takeover, .curve: return nil
        }
    }

    /// The drawn curve, where the row is one.
    public var curve: EditorControlCurve? {
        if case .curve(let curve) = self { return curve }
        return nil
    }
}

/// A curve a photographer draws rather than a number they set.
///
/// The handles are fixed and the values are not: what is being said is "more here, less there"
/// against an axis the film already has an opinion about, so the axis is the catalogue's and only
/// the heights are the photographer's. That is also what makes the row resettable and badgeable
/// like every other — `neutral` is a flat curve, and a flat curve is not an edit.
public struct EditorControlCurve: Sendable, Equatable {
    /// Where the handles sit on the axis, ascending, in the axis's own unit.
    public let handles: [Double]
    /// The axis the handles sit on, for the graph to label itself by.
    public let domain: ClosedRange<Double>
    /// Handle value range and the neutral value within that range.
    public let range: ClosedRange<Double>
    public let neutral: Double
    /// Display unit for handle values.
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

    /// The curve at rest — what a reset puts back and what a fresh edit starts from.
    public var restingValues: [Double] {
        [Double](repeating: neutral, count: handles.count)
    }

    /// Whether these heights say anything the flat curve does not. The tolerance is the sliders':
    /// a handle a finger only brushed is not an edit.
    public func isMoved(_ values: [Double]) -> Bool {
        guard values.count == handles.count else { return false }
        let slack = (range.upperBound - range.lowerBound) * 1e-4
        return values.contains { abs($0 - neutral) > slack }
    }
}

/// Stock capabilities required for a control to be shown.
public enum EditorControlAvailability: String, Sendable, Equatable {
    /// Everything scene-referred, which applies with or without an emulsion.
    case always
    /// Needs a film loaded at all — absent in Normal, where there is no emulsion by choice.
    case film
    /// Bleach bypass: a monochrome image *is* its silver, and a reversal's bleach is part of making
    /// the positive, so only a colour negative can skip it.
    case colourNegative
    /// Reaches a print stage. A reversal stock is a direct positive and never meets paper.
    case printStage
    /// The stock's own sheet publishes a long-exposure correction row with a rate to it. A sheet
    /// that states only a hold states that the law holds, and no control should suggest otherwise.
    case statedReciprocity
    /// The stock carries a layer model the reach and the diagonal can be scaled against. A pack
    /// that ships a fixed inhibition matrix instead has no geometry to scale, and the engine reads
    /// neither scale there — which is the same fact `CouplerDemoPanel` already says in words.
    case couplerGeometry
    /// The stock pack carries complete measured curves for at least one non-reference development
    /// condition. A reference curve alone cannot define push or pull.
    case measuredDevelopment

    /// `stock` is the film this edit really develops on, or nil in Normal and where no pack is
    /// installed — `EditState.hasFilm ? EditState.stock : nil`.
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
        case .measuredDevelopment:
            return stock?.hasMeasuredDevelopmentResponse == true
        }
    }
}

/// Metadata used to render, badge, and reset an editor control.
public struct EditorControl: Sendable, Equatable, Identifiable {
    public var id: EditorControlField { field }
    public let field: EditorControlField
    public let title: String
    /// The line under the title: what moving it does, in the photographer's terms rather than the
    /// engine's.
    public let detail: String
    public let section: EditorControlSection
    public let kind: EditorControlKind
    public let availability: EditorControlAvailability
    /// Owner row for an expandable control. Owner and child must share a section, with the child
    /// listed after its owner.
    public let foldsUnder: EditorControlField?

    public init(_ field: EditorControlField, title: String, detail: String,
                section: EditorControlSection, kind: EditorControlKind,
                availability: EditorControlAvailability = .always,
                foldsUnder: EditorControlField? = nil) {
        self.field = field
        self.title = title
        self.detail = detail
        self.section = section
        self.kind = kind
        self.availability = availability
        self.foldsUnder = foldsUnder
    }

    public var group: EditorControlGroup { section.group }
}
