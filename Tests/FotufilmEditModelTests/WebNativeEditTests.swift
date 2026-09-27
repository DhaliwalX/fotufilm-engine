import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class WebNativeEditTests: XCTestCase {
    private func stock() throws -> FilmStock {
        try XCTUnwrap(FilmStock.presets["gold200"], "stock gold200 is not installed")
    }

    /// The request the web editor's native backend sends, trimmed to what develops the image.
    private func request(params: [String: Double] = [:], controls: String = "{}",
                         extra: String = "") throws -> WebNativeEdit {
        let params = String(data: try JSONEncoder().encode(params), encoding: .utf8)!
        let json = """
        {"edit": {"stock": "gold200", "params": \(params), "gradeSpace": false,
                  "localTone": true, "crop": [[0, 0], [1, 0], [1, 1], [0, 1]]},
         "profileRequest": {"controls": \(controls)\(extra)}}
        """
        return try JSONDecoder().decode(WebNativeEdit.self, from: Data(json.utf8))
    }

    func testRestingEditDevelopsAtRest() throws {
        // The web editor's defaults, every slider at its resting value.
        let edit = try request(params: [
            "ev": 0, "highlights": 0, "shadows": 0, "temperature": 6504, "tint": 0,
            "saturation": 1, "vibrance": 0, "grain": 1, "cameraPreflash": 0,
            "sceneLightKelvin": 6504, "gradeShadowsWarmth": 0, "gradeMidtonesLevel": 0,
        ], controls: #"{"digitalReference": "auto-levels"}"#)
        let rest = try EditDocument().options(for: try stock())
        let options = try edit.document.options(for: try stock())
        XCTAssertEqual(options.exposureEV, rest.exposureEV)
        XCTAssertEqual(options.whiteBalance.kelvin, rest.whiteBalance.kelvin, accuracy: 1)
        XCTAssertEqual(options.whiteBalance.tint, rest.whiteBalance.tint, accuracy: 1e-6)
        XCTAssertEqual(options.saturation, rest.saturation)
        XCTAssertEqual(options.grainScale, rest.grainScale)
    }

    func testSlidersBecomeTheirCatalogueControls() throws {
        let edit = try request(params: [
            "ev": 0.5, "highlights": -0.3, "shadows": 0.2, "temperature": 3200, "tint": 20,
            "saturation": 1.2, "vibrance": 0.1, "grain": 0.5, "cameraPreflash": 0.01,
        ])
        let options = try edit.document.options(for: try stock())
        XCTAssertEqual(options.exposureEV, 0.5)
        XCTAssertEqual(options.highlights, -0.3, accuracy: 1e-6)
        XCTAssertEqual(options.shadows, 0.2, accuracy: 1e-6)
        // Temperature is the plug-ins' Kelvin parameter: relative scene light, not an RGB gain.
        XCTAssertEqual(options.whiteBalance.kelvin, 3200, accuracy: 1)
        XCTAssertEqual(options.whiteBalance.tint, 20, accuracy: 1e-3)
        XCTAssertEqual(options.saturation, 1.2, accuracy: 1e-6)
        XCTAssertEqual(options.vibrance, 0.1, accuracy: 1e-6)
        XCTAssertEqual(options.grainScale, 0.5, accuracy: 1e-6)
        XCTAssertEqual(options.cameraPreflash, 0.01, accuracy: 1e-6)
    }

    func testGradeAndToneFlags() throws {
        let graded = try request(params: ["gradeHighlightsWarmth": 0.4, "gradeShadowsLevel": -0.2])
        let options = try graded.document.options(for: try stock())
        XCTAssertNotEqual(options.grade, .neutral)
        var flags = try request()
        flags.edit.gradeSpace = true
        flags.edit.localTone = false
        let flagged = try flags.document.options(for: try stock())
        XCTAssertFalse(flagged.localTone)
        XCTAssertNotEqual(flagged.gradeSpace, try EditDocument().options(for: try stock()).gradeSpace)
    }

    func testNewGrainPatternReseedsTheGrain() throws {
        let rest = try request().options(for: try stock())
        var film = try request()
        film.edit.seed = 0
        XCTAssertEqual(try film.options(for: try stock()).seed, rest.seed)
        film.edit.seed = 123_456
        XCTAssertEqual(try film.options(for: try stock()).seed, rest.seed &+ 123_456)
    }

    func testFilmSettingsAreReadAsAProfileRequestReadsThem() throws {
        let edit = try request(controls: #"{"push": 0}"#,
                               extra: #", "format": "35mm", "sceneKelvin": 3200"#)
        XCTAssertEqual(edit.document[.push], .number(0))
        XCTAssertEqual(edit.document[.gauge], .choice("35mm"))
        XCTAssertEqual(try edit.document.options(for: try stock()).sceneIlluminantKelvin, 3200)
    }

    func testOutOfRangeSliderIsRefused() throws {
        XCTAssertThrowsError(try request(params: ["ev": 40]).document.options(for: try stock()))
    }
}
