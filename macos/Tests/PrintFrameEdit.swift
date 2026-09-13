import Foundation
import FotufilmCore
import FotufilmEditModel

// Only process settings are isolated. EditState, its Codable implementation, control access,
// film choices and the engine below are the production code.
enum AppSettings {
    static let storedStockID: String? = nil
    static let storedCameraStockID: String? = nil
    static let storedFormatID: String? = nil
    static let storedGradeSpace = ColorGrade.Space.linear
    static let storedDiscGrainEnabled = false
    static let storedCouplerBarrierRedGreen = 1.0
    static let storedCouplerBarrierGreenBlue = 1.0
    static let storedCouplerSelf = 1.0
    static let storedHalationModel = HalationModel.legacy
    static let storedEstimatedHalationEnabled = false
    static let storedNegativeViewing = NegativeViewing.lightBox
}

@main
@MainActor
enum PrintFrameEditCheck {
    static func main() throws {
        let legacy = try JSONDecoder().decode(EditState.self, from: Data("{}".utf8))
        precondition(legacy.printFrame == .none)
        for frame in PrintFrame.allCases {
            var edit = legacy
            edit.printFrame = frame
            let saved = try JSONEncoder().encode(edit)
            let restored = try JSONDecoder().decode(EditState.self, from: saved)
            precondition(restored == edit)
            precondition(restored.isMoved(.printFrame) == (frame != .none))
            edit.reset(.printFrame)
            precondition(edit.printFrame == .none)
        }
        do {
            _ = try JSONDecoder().decode(EditState.self,
                from: Data("{\"printFrame\":\"unknown\"}".utf8))
            preconditionFailure("invalid frame was accepted")
        } catch { }
        let session = EditSession()
        session.edit.printFrame = .film35
        precondition(session.canUndo)
        session.undo()
        precondition(session.edit.printFrame == .none)
        session.redo()
        precondition(session.edit.printFrame == .film35)
        let checkpoint = session.historyCheckpoint()
        session.edit.printFrame = .cotton
        session.restoreHistoryCheckpoint(checkpoint)
        precondition(session.edit.printFrame == .film35)
        print("Print frame edit checks passed: legacy edits, persistence, invalid data, reset, undo, redo, and cancel.")
    }
}
