import XCTest
@testable import FotufilmCore

final class SensitivityFloorTests: XCTestCase {
    private func definition(_ id: String) throws -> FilmStockDefinition {
        try XCTUnwrap(FilmStockPack.shared.stocks[id], "\(id) is not installed")
    }

    func testAbsentFloorIsThePublishedRecord() throws {
        var definition = try definition("provia100f")
        definition.sensitivityFloor = nil
        let data = try JSONEncoder().encode(definition)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sensitivityFloor"))
        guard case let .samples(published, _) = definition.spectral else {
            return XCTFail("provia100f carries sampled records")
        }
        let decoded = try JSONDecoder().decode(FilmStockDefinition.self, from: data).stock
        XCTAssertEqual(decoded.spectralProfile.layerSensitivity, published)
    }

    func testFloorHoldsEveryLayerAtItsShareOfPeakAndIsIdempotent() throws {
        var definition = try definition("velvia50")
        definition.sensitivityFloor = 0.02
        let stock = try definition.validated().stock
        guard case let .samples(published, _) = definition.spectral else {
            return XCTFail("velvia50 carries sampled records")
        }
        for (layer, source) in zip(stock.spectralProfile.layerSensitivity, published) {
            let peak = try XCTUnwrap(source.max())
            XCTAssertEqual(layer.max(), peak, "the floor must not move a layer's peak")
            XCTAssertEqual(try XCTUnwrap(layer.min()), 0.02 * peak, accuracy: 1e-9 * peak)
            for (floored, original) in zip(layer, source) {
                XCTAssertEqual(floored, max(original, 0.02 * peak))
            }
        }
        // Exporting the rendered stock writes the floored records and no floor; read back they
        // render the same records, and flooring them again changes nothing.
        let exported = FilmStockDefinition(id: "velvia50-floored", stock: stock)
        XCTAssertNil(exported.sensitivityFloor)
        XCTAssertEqual(exported.stock.spectralProfile.layerSensitivity,
                       stock.spectralProfile.layerSensitivity)
        XCTAssertEqual(stock.spectralProfile.floored(at: 0.02).layerSensitivity,
                       stock.spectralProfile.layerSensitivity)
    }

    func testFloorChangesTheRenderIdentity() throws {
        var definition = try definition("provia100f")
        let published = definition.stock
        definition.sensitivityFloor = 0.02
        let floored = definition.stock
        XCTAssertNotEqual(SpectralRuntime.cacheIdentifier(for: published, paper: .screen),
                          SpectralRuntime.cacheIdentifier(for: floored, paper: .screen))
    }

    func testValidationBoundsTheFloor() throws {
        var definition = try definition("provia100f")
        for share: Float in [0, 0.05, 0.1] {
            definition.sensitivityFloor = share
            XCTAssertNoThrow(try definition.validated())
        }
        for share: Float in [-0.01, 0.11, .nan, .infinity] {
            definition.sensitivityFloor = share
            XCTAssertThrowsError(try definition.validated(), "\(share)")
        }
    }
}
