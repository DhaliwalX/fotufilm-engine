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
enum HalationReturnEditCheck {
    static func main() throws {
        for id in ["cinestill800t", "cinestill400d"] {
            let oldJSON = Data("{\"stockID\":\"\(id)\",\"halation\":1}".utf8)
            var edit = try JSONDecoder().decode(EditState.self, from: oldJSON)
            precondition(edit.halationReturnRatio == nil)
            precondition(abs(edit.value(of: .halationReturn)! - 0.12) < 1e-7)
            precondition(!edit.isMoved(.halationReturn))
            precondition(edit.options.halationReturnRatio == nil)

            edit.setValue(0.24, of: .halationReturn)
            let restored = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(edit))
            precondition(restored == edit)
            precondition(restored.isMoved(.halationReturn))
            precondition(restored.options.halationReturnRatio == 0.24)

            edit.stockID = "gold200"
            precondition(edit.value(of: .halationReturn) == 0.24)
            edit.reset(.halationReturn)
            precondition(edit.halationReturnRatio == nil)
            precondition(edit.value(of: .halationReturn) == Double(edit.stock!.halationStrength[0]))

            edit.setValue(0, of: .halationReturn)
            let off = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(edit))
            precondition(off.options.halationReturnRatio == 0)
            edit.stockID = StockPreset.noFilmID
            precondition(edit.options.halationReturnRatio == nil)
            edit.setValue(0.12, of: .halationReturn)
            precondition(edit.options.halationReturnRatio == nil)
        }
        do {
            _ = try JSONDecoder().decode(EditState.self, from: Data("{\"halationReturnRatio\":1.1}".utf8))
            preconditionFailure("invalid persisted ratio was accepted")
        } catch { }
        print("Halation Return edit checks passed: defaults, persistence, stock changes, reset, off and Normal.")
    }
}
