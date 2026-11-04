import Foundation
import XCTest
@testable import FotufilmCore

final class BrowserColorControlTests: XCTestCase {
    struct Fixture: Decodable {
        struct Balance: Decodable { let temperature: Float; let tint: Float; let gains: [Float] }
        struct Grade: Decodable { let controls: [String: Float]; let packed: [Float] }
        /// The same grade with output levels, in each grading space (`gradeSpace` true is
        /// encoded).
        struct LevelledGrade: Decodable {
            struct Controls: Decodable {
                let blackPoint: Float
                let whitePoint: Float
                let gradeSpace: Bool?
            }
            let controls: Controls
            let packed: [Float]
        }
        let balances: [Balance]
        let grade: Grade
        let levelledGrades: [LevelledGrade]
    }

    func testBrowserWhiteBalanceAndGradeMatchNative() throws {
        // A package may reach this Tests directory through a symbolic link.
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("web/test/editor/color-fixtures.json")))
        // The browser rounds spectral and white-balance operations to Float.
        // Allow small platform math differences, including two ppm for large gains.
        for balance in fixture.balances {
            let native = WhiteBalance(kelvin: balance.temperature, tint: balance.tint).gains
            for (actual, expected) in zip([native.r, native.g, native.b], balance.gains) {
                XCTAssertEqual(actual, expected, accuracy: max(0.0003, abs(expected) * 0.000002),
                               "\(balance.temperature) K, tint \(balance.tint)")
            }
        }
        func band(_ name: String) -> ColorGrade.Band {
            ColorGrade.Band(balanceX: fixture.grade.controls["grade\(name)Warmth"]!,
                            balanceY: fixture.grade.controls["grade\(name)Tint"]!,
                            level: fixture.grade.controls["grade\(name)Level"]!)
        }
        let grade = ColorGrade(shadows: band("Shadows"), midtones: band("Midtones"),
                               highlights: band("Highlights"))
        for (actual, expected) in zip(grade.packed(in: .linear), fixture.grade.packed) {
            XCTAssertEqual(actual, expected, accuracy: 0.000001)
        }
        XCTAssertEqual(fixture.levelledGrades.count, 2)
        for levelled in fixture.levelledGrades {
            var withLevels = grade
            withLevels.blackPoint = levelled.controls.blackPoint
            withLevels.whitePoint = levelled.controls.whitePoint
            let space: ColorGrade.Space = levelled.controls.gradeSpace == true ? .encoded : .linear
            for (actual, expected) in zip(withLevels.packed(in: space), levelled.packed) {
                XCTAssertEqual(actual, expected, accuracy: 0.000002, "\(space)")
            }
        }
    }
}
