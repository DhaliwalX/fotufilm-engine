import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// One tile of the print deck's frame strip: the photograph finished in one border, from none
/// through the physical film and paper constructions to the posting canvases. The strip offers
/// every frame; one the loaded film or medium cannot take develops as the bare photograph and
/// says why in its detail.
struct FrameChoice: Identifiable, Hashable, StripChoice {
    let frame: PrintFrame

    var id: String { frame.rawValue }
    var name: String { frame.name }

    /// Every frame, in the order the menu lists them.
    static let strip: [FrameChoice] = PrintFrame.allCases.map(FrameChoice.init)

    /// The run is keyed on everything but the frame, so choosing one keeps the other tiles' prints.
    static func aside(_ grade: EditState) -> EditState {
        var slice = grade
        slice.printFrame = .none
        return slice
    }

    func develop(_ grade: inout EditState) {
        grade.printFrame = frame
    }
}
