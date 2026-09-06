import Foundation
import XCTest
@testable import FotufilmCore

final class BrowserColorControlTests: XCTestCase {
    struct Fixture: Decodable {
        struct Balance: Decodable { let temperature: Float; let tint: Float; let gains: [Float] }
        struct Grade: Decodable { let controls: [String: Float]; let packed: [Float] }
        let balances: [Balance]
        let grade: Grade
    }

    func testBrowserWhiteBalanceAndGradeMatchNative() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("web/test/editor/color-fixtures.json")))
        // Swift uses Float; the browser uses Double. Extreme tint can produce
        // large gains, so allow two parts per million there.
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
        for (actual, expected) in zip(grade.packed, fixture.grade.packed) {
            XCTAssertEqual(actual, expected, accuracy: 0.000001)
        }
    }
}
