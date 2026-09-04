import CoreGraphics

/// The selection: a colour, a light or a subject the finger picked out of the photograph, and the
/// edit developed wherever the picture matches it.
struct SelectiveState: Equatable {
    /// Defines whether a sample selects by chroma, luminance, or detected subject.
    enum MaskKind: Equatable {
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
    /// Where the subject's rim sits against the detector's: negative eats
    /// into the selection, positive spreads it out.
    var subjectEdge = 0.0
    /// How soft that rim is.
    var subjectFeather = 0.35
    /// The selection's own develop, seeded from the photograph's edit the first time the surface
    /// comes up so it opens changing nothing.
    var edit = EditState()
    var seeded = false
}
