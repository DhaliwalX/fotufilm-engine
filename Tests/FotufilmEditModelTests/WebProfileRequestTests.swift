import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class WebProfileRequestTests: XCTestCase {
    private func request(_ controls: [String: Any], stock id: String = "gold200",
                         medium: String? = nil, filters: [String]? = nil, metering: String? = nil,
                         definition: FilmStockDefinition? = nil) throws -> WebProfileRequest {
        let stock = try XCTUnwrap(definition ?? FilmStock.presetDefinitions[id])
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stock))
        var input: [String: Any] = ["stock": encoded, "width": 80, "height": 64, "controls": controls]
        if let medium { input["medium"] = medium }
        if let filters { input["filters"] = filters }
        if let metering { input["filterMetering"] = metering }
        return try JSONDecoder().decode(WebProfileRequest.self, from: JSONSerialization.data(withJSONObject: input))
    }

    func testPrinterControlsComposeAndDisablingRestoresDefaultPath() throws {
        var values: [String: Any] = ["printerEnabled": true, "printerLamp": 3400,
            "printerExposure": 1.25, "printerMagenta": 0.6, "printerYellow": 0.7,
            "printerPreflash": 0.05, "enlarger": "condenser"]
        let options = try request(values).configured().1
        XCTAssertEqual(options.printer, PrinterProfile(lampKelvin: 3400, exposureEV: 1.25, magenta: 0.6, yellow: 0.7))
        XCTAssertEqual(options.printerPreflash, 0.05)
        XCTAssertEqual(options.enlarger, .condenser)
        values["printerEnabled"] = false
        XCTAssertNil(try request(values).configured().1.printer)
        values["printerLamp"] = 3700
        XCTAssertThrowsError(try request(values).configured())
    }

    func testViewingChoicesUseMediumAndNegativeViewingCannotLeakIntoPaper() throws {
        XCTAssertEqual(try request(["printLight": "tungsten"]).configured().1.printViewingKelvin, 2856)
        XCTAssertThrowsError(try request(["printLight": "tungsten"], medium: "screen").configured())
        XCTAssertEqual(try request(["negativeViewing": "scanner"], medium: "negative").configured().1.negativeViewing, .scanner)
        XCTAssertNil(try request(["negativeViewing": "scanner"], medium: "ektacolor-edge").configured().1.negativeViewing)
    }

    func testHalationCurveAndReturnHaveDistinctNeutralAndOverrideStates() throws {
        XCTAssertNil(try request([:]).configured().1.halationReturnRatio)
        let zero = try request(["halationReturn": 0]).configured().1
        XCTAssertEqual(zero.halationReturnRatio, 0)
        let values: [Double] = [0, 0.2, 0.3, 0, -0.2, 0.5, 1]
        let options = try request(["halationSpectrum": values]).configured().1
        XCTAssertEqual(options.halationReturnGain, HalationSpectrum.resampled(values.map(Float.init)))
        XCTAssertThrowsError(try request(["halationSpectrum": [1, 2]]).configured())
    }

    func testPushAcceptsOnlyListedConditions() throws {
        var definition = try XCTUnwrap(FilmStock.presetDefinitions["example-negative-400"])
        let stock = try definition.validated().stock
        definition.development = .init(FilmDevelopmentProfile(
            developer: "synthetic fixture", temperatureC: 20, agitation: "test",
            source: "synthetic regression", sourcePage: 1,
            conditions: [.init(stops: 1, label: "Push 1", timeMinutes: 10, basis: .measured,
                               curves: stock.curves)]))
        XCTAssertEqual(try request(["push": 1], definition: definition).configured().1.developmentEV, 1)
        XCTAssertThrowsError(try request(["push": 0.5], definition: definition).configured())
        XCTAssertThrowsError(try request(["push": 1]).configured())
    }

    func testShutterUsesOnlyTheStocksStatedChoices() throws {
        let definition = try XCTUnwrap(FilmStock.presetDefinitions["hp5plus400"])
        let stock = try definition.validated().stock
        let seconds = try XCTUnwrap(EditorControlCatalogue.shutterTimes(for: stock).first)
        XCTAssertEqual(try request(["shutter": String(Int(seconds))], stock: "hp5plus400").configured().1.shutterSeconds, Float(seconds))
        XCTAssertNil(try request(["shutter": "off"], stock: "hp5plus400").configured().1.shutterSeconds)
        XCTAssertThrowsError(try request(["shutter": "123456"], stock: "hp5plus400").configured())
    }
    func testLensStackMatchesNativeResolutionAndMetering() throws {
        let ids = ["w85b", "blackpromist-1/2", "w81a", "fog-1"]
        let options = try request([:], filters: ids, metering: "filmSpeed").configured().1
        let fitted = EditorLensFilters.resolve(ids)
        XCTAssertEqual(options.lensFilters, LensFilterStack(fitted.absorbing, compensation: .filmSpeed))
        XCTAssertEqual(options.diffusionFilter, fitted.diffusion)
        XCTAssertEqual(fitted.unusedDiffusion, ["fog-1"])
        XCTAssertEqual(fitted.absorbing.map(\.id), ["w85b", "w81a"])
        XCTAssertThrowsError(try request([:], filters: ["missing"]).configured())
        XCTAssertThrowsError(try request([:], metering: "missing").configured())
        XCTAssertTrue(try request([:], filters: []).configured().1.lensFilters.isEmpty)
    }

}
