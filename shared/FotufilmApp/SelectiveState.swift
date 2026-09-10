import CoreGraphics
import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The selection: a colour, a light or a subject the finger picked out of the photograph, and the
/// edit developed wherever the picture matches it.
struct SelectiveState: Equatable, Codable {
    /// Defines whether a sample selects by chroma, luminance, or detected subject.
    enum MaskKind: String, Codable {
        case color, light, subject
    }

    var kind = MaskKind.color
    /// Where the finger sampled, in unit image coordinates, origin top left.
    var samplePoint: CGPoint?
    /// The sampled colour, display-referred, averaged over a small patch so a
    /// single noisy pixel cannot own the selection.
    var sampleRed = 0.0
    var sampleGreen = 0.0
    var sampleBlue = 0.0
    /// How far from the sample the selection reaches.
    var range = 0.25
    /// How much of that reach is falloff rather than full selection.
    var softness = 0.5
    /// Selected detected subject, or nil to include all detected subjects.
    var subjectInstance: Int?
    /// PNG mask in the original photograph's upright coordinates, before lens correction or crop.
    var subjectMask: Data?
    /// Where the subject's rim sits against the detector's: negative eats
    /// into the selection, positive spreads it out.
    var subjectEdge = 0.0
    /// How soft that rim is.
    var subjectFeather = 0.35
    /// The selection's own develop, seeded from the photograph's edit the first time the surface
    /// comes up so it opens changing nothing.
    var edit = SelectiveDevelop(EditState())
    var seeded = false

    init() {}

    init(base: EditState) {
        self = base.selective ?? SelectiveState()
        if !seeded {
            edit = SelectiveDevelop(base)
            seeded = true
        }
    }

    var hasSelection: Bool {
        kind == .subject ? subjectMask != nil : samplePoint != nil
    }

    var saved: SelectiveState? { hasSelection ? self : nil }
}

/// Only local light and color controls belong to a selection. Film, crop, lens and output
/// settings always come from the current photograph, including after reopening an edit.
struct SelectiveDevelop: Equatable, Codable {
    var exposure: Double
    var temperatureMired: Double
    var tint: Double
    var highlights: Double
    var shadows: Double
    var localTone: Bool
    var saturation: Double
    var vibrance: Double
    var grade: ColorGrade
    var encodedGrade: Bool

    init(_ state: EditState) {
        exposure = state.exposure
        temperatureMired = state.temperatureMired
        tint = state.tint
        highlights = state.highlights
        shadows = state.shadows
        localTone = state.localTone
        saturation = state.saturation
        vibrance = state.vibrance
        grade = state.grade
        encodedGrade = state.encodedGrade
    }

    func applying(to base: EditState) -> EditState {
        var state = base
        state.selective = nil
        state.exposure = exposure
        state.temperatureMired = temperatureMired
        state.tint = tint
        state.highlights = highlights
        state.shadows = shadows
        state.localTone = localTone
        state.saturation = saturation
        state.vibrance = vibrance
        state.grade = grade
        state.encodedGrade = encodedGrade
        return state
    }
}
