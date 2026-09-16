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
    static let storedNegativeViewing = NegativeViewing.scanner
}

@main
@MainActor
enum PrintFrameEditCheck {
    static func main() throws {
        let legacy = try JSONDecoder().decode(EditState.self, from: Data("{}".utf8))
        precondition(legacy.printFrame == .none)
        precondition(legacy.digitalReference == .autoLevels)
        for style in DigitalReferenceStyle.allCases {
            var edit = legacy
            edit.digitalReference = style
            let restored = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(edit))
            precondition(restored == edit)
            precondition(restored.options.digitalReference == style)
            precondition(edit.isMoved(.digitalReference) == (style != .default))
            edit.reset(.digitalReference)
            precondition(edit.digitalReference == .default)
        }
        for (value, expected) in [("film-35", PrintFrame.film), ("instant", .film),
                                  ("baryta", .paper), ("cotton", .paper), ("contact", .paper)] {
            let saved = Data("{\"printFrame\":\"\(value)\"}".utf8)
            let restored = try JSONDecoder().decode(EditState.self, from: saved)
            precondition(restored.printFrame == expected)
        }
        var film = legacy
        film.stockID = "hp5plus400"
        film.printFrame = .film
        film.chosenFormatID = nil
        precondition(film.frameConfiguration.geometry == FilmBorderGeometry.preset("35mm"))
        film.chosenFormatID = "4x5"
        precondition(film.frameConfiguration.sheetNotches?.notches.count == 3)
        film.paper = .enduraPremier
        film.paperFollowsStock = false
        film.printLightKelvin = 2856
        precondition(film.filmFrameNegative == .lightBox)
        let negative = film.frameRenderState
        precondition(negative.resolvedPaper == .negative)
        precondition(negative.options.negativeViewing == .lightBox)
        precondition(!negative.supportsHDROutput)
        precondition(film.paper == .enduraPremier)
        precondition(film.frameRenderState.frameRenderState == negative)
        for stockID in ["portra400", "hp5plus400"] {
            film.stockID = stockID
            let stock = film.stock!
            let clearFilm = SpectralRuntime.negativeViewing(for: stock, look: .lightBox).sample(.zero)
            let border = film.frameConfiguration.baseRGB
            for channel in 0..<3 { precondition(abs(clearFilm[channel] - border[channel]) < 0.00001) }
            let denseFilm = SpectralRuntime.negativeViewing(for: stock, look: .lightBox).sample(SIMD3(repeating: 1))
            precondition(denseFilm.x < clearFilm.x && denseFilm.y < clearFilm.y && denseFilm.z < clearFilm.z)
        }
        for frame in [PrintFrame.none, .paper, .emulsion] {
            film.printFrame = frame
            precondition(film.filmFrameNegative == nil)
            precondition(film.frameRenderState == film)
            precondition(film.frameRenderState.resolvedPaper == .enduraPremier)
        }
        for stockID in ["ektachromee100", "instaxmini", "original", "missing-stock"] {
            film.stockID = stockID
            film.chosenFormatID = nil
            film.printFrame = .film
            precondition(film.filmFrameNegative == nil)
            precondition(film.frameRenderState == film)
        }
        var positive = legacy
        positive.stockID = "provia100f"
        positive.paper = .ilfochromeCLM1K
        positive.paperFollowsStock = false
        precondition(positive.resolvedPaper == .ilfochromeCLM1K)
        precondition(!positive.supportsHDROutput)
        let restoredPositive = try JSONDecoder().decode(EditState.self,
            from: JSONEncoder().encode(positive))
        precondition(restoredPositive == positive)
        positive.printFrame = .paper
        precondition(positive.frameConfiguration.frame == .paper)
        precondition(positive.frameRenderState.resolvedPaper == .ilfochromeCLM1K)
        positive.printFrame = .film
        precondition(positive.frameRenderState.resolvedPaper == .screen)
        precondition(positive.paper == .ilfochromeCLM1K)
        precondition(positive.frameRenderState.frameRenderState == positive.frameRenderState)
        film.stockID = "hp5plus400"
        film.chosenFormatID = "unknown"
        precondition(film.filmFrameNegative == nil)
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
        session.edit.printFrame = .film
        precondition(session.canUndo)
        session.undo()
        precondition(session.edit.printFrame == .none)
        session.redo()
        precondition(session.edit.printFrame == .film)
        let checkpoint = session.historyCheckpoint()
        session.edit.printFrame = .paper
        session.restoreHistoryCheckpoint(checkpoint)
        precondition(session.edit.printFrame == .film)
        print("Print frame edit checks passed: negative delivery, matching rebate, retained paper, direct positives, persistence, reset, undo, redo, and cancel.")
    }
}
