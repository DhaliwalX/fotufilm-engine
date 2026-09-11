import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class SourceIlluminantTests: XCTestCase {
    func testStockNativeIsDefaultAndPresetsKeepTheirHostIndices() {
        XCTAssertEqual(EditorControlCatalogue.sourceLights.map(\.value),
                       [0, 6504, 5500, 3200, 2856, nil])
        XCTAssertEqual(EditorControlCatalogue.sourceLights.first?.label, "Stock Native")
        XCTAssertNil(EditorControlCatalogue.sourceLightKelvin(selection: 0, custom: 4500))
        for (index, expected) in [(1, 6504), (2, 5500), (3, 3200), (4, 2856)] {
            XCTAssertEqual(EditorControlCatalogue.sourceLightKelvin(selection: index, custom: 4500),
                           Float(expected))
        }
    }

    func testCustomLightIsIndependentOfPresetsAndBounded() {
        for value: Double in [1000, 2856, 5000, 25000] {
            XCTAssertEqual(EditorControlCatalogue.sourceLightKelvin(selection: 5, custom: value),
                           Float(value))
        }
        for invalid: Double in [0, 999, 25001, .nan, .infinity] {
            XCTAssertNil(EditorControlCatalogue.sourceLightKelvin(selection: 5, custom: invalid))
        }
        XCTAssertNil(EditorControlCatalogue.sourceLightKelvin(selection: 99, custom: 5000))
    }

    func testChangingSourceClearsPreviousXYAndSpectrum() {
        var options = FotufilmEngine.Options()
        for value: Double in [5500, 0] {
            options.sceneIlluminantChromaticity = SIMD2(0.35, 0.36)
            options.sceneIlluminantSpectrum = Array(repeating: 1, count: 81)
            EngineBinding.sceneIlluminantKelvin.apply(.number(value), to: &options)
            XCTAssertNil(options.sceneIlluminantChromaticity)
            XCTAssertTrue(options.sceneIlluminantSpectrum.isEmpty)
            XCTAssertEqual(options.sceneIlluminantKelvin, value == 0 ? nil : Float(value))
        }
    }

    func testSourceControlsReachNativeEditorsAndHosts() throws {
        for field: EditorControlField in [.sceneLight, .sceneLightKelvin] {
            let control = try XCTUnwrap(EditorControlCatalogue.control(field))
            for surface: EditorSurface in [.app, .desktop, .resolve, .finalcut] {
                XCTAssertTrue(control.offered(on: surface), "\(field), \(surface)")
            }
            XCTAssertTrue(control.drives.contains("sceneIlluminantKelvin"))
        }
        XCTAssertEqual(EditorControlCatalogue.control(.sceneLightKelvin)?.commandLine?.flag,
                       "--scene-kelvin")
    }
}
