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
    static let storedCouplerBarrierRedGreen = 1.0
    static let storedCouplerBarrierGreenBlue = 1.0
    static let storedCouplerSelf = 1.0
    static let storedHalationModel = HalationModel.legacy
    static let storedGrainModel = GrainModel.clumpField
    static let storedEstimatedHalationEnabled = false
}

@main
enum ScreenCMYEditCheck {
    static func main() throws {
        var edit = EditState()
        edit.stockID = "gold200"
        edit.paper = .screen
        edit.paperFollowsStock = false
        let fields: [EditorControlField] = [.screenCyan, .screenMagenta, .screenYellow]
        let values = [0.25, -0.15, 0.1]
        precondition(edit.options.screenCMY == .zero)
        for (field, value) in zip(fields, values) { edit.setValue(value, of: field) }
        let restored = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(edit))
        precondition(restored == edit)
        precondition(restored.options.screenCMY == SIMD3(0.25, -0.15, 0.1))
        for field in fields { precondition(restored.isMoved(field)) }
        edit.paper = .ektacolorEdge
        let onPaper = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(edit))
        precondition(onPaper.options.screenCMY == restored.options.screenCMY)
        edit.paper = .screen
        for field in fields { edit.reset(field) }
        precondition(edit.options.screenCMY == .zero)
        precondition(fields.allSatisfy { !edit.isMoved($0) })
        let clean = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(edit))
        precondition(clean.options.screenCMY == .zero)
        print("CMY edit checks passed: defaults, engine binding, persistence, medium changes and reset.")
    }
}
