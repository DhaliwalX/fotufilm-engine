import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class EditDocumentTests: XCTestCase {
    private func stock() throws -> FilmStock {
        try XCTUnwrap(FilmStock.presets["gold200"], "stock gold200 is not installed")
    }

    func testJSONRoundTripKeepsEveryValueKind() throws {
        let document = EditDocument([
            .exposure: .number(0.8), .localTone: .flag(false), .sceneLight: .choice("tungsten3200"),
            .lensFilterStack: .choices(["none"]), .halationSpectrum: .curve([0, 0.2, 0.3, 0, -0.2, 0.5, 1]),
        ])
        let decoded = try JSONDecoder().decode(EditDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded, document)
    }

    func testNewsprintPaperColorSurvivesSaveLoadAndRejectsInvalidColors() throws {
        let document = EditDocument([.paper: .choice("newsprint-color"), .paperColor: .choice("#D6C2A0")])
        let decoded = try JSONDecoder().decode(EditDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(try decoded.options(for: stock()).newsprintPaperColor?.hex, "#d6c2a0")
        XCTAssertNil(try EditDocument().options(for: stock()).newsprintPaperColor)
        for value in [EditDocument.Value.choice("#fff"), .choice("white"), .number(1)] {
            XCTAssertThrowsError(try EditDocument([.paperColor: value]).options(for: stock()))
        }
    }

    func testUnknownFieldIsRefused() {
        XCTAssertThrowsError(try JSONDecoder().decode(EditDocument.self, from: Data(#"{"nope": 1}"#.utf8)))
    }

    func testEmptyDocumentRendersAtRest() throws {
        let options = try EditDocument().options(for: try stock())
        XCTAssertEqual(options.exposureEV, 0)
        XCTAssertNil(options.sceneIlluminantKelvin)
        XCTAssertNil(options.printer)
    }

    func testSourceLightChoiceAndCustomKelvin() throws {
        let stock = try stock()
        XCTAssertEqual(try EditDocument([.sceneLight: .choice("tungsten3200")])
            .options(for: stock).sceneIlluminantKelvin, 3200)
        XCTAssertEqual(try EditDocument([.sceneLight: .choice("custom"), .sceneLightKelvin: .number(4960)])
            .options(for: stock).sceneIlluminantKelvin, 4960)
        // The custom temperature only acts when Custom is chosen.
        XCTAssertNil(try EditDocument([.sceneLightKelvin: .number(4960)])
            .options(for: stock).sceneIlluminantKelvin)
        XCTAssertThrowsError(try EditDocument([.sceneLight: .choice("candle")]).options(for: stock))
    }

    func testValuesOutsideTheCatalogueRangeAreRefused() throws {
        XCTAssertThrowsError(try EditDocument([.exposure: .number(99)]).options(for: try stock()))
        XCTAssertThrowsError(try EditDocument([.exposure: .flag(true)]).options(for: try stock()))
    }
}
