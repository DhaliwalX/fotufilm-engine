import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class WebAutoAdjustmentRequestTests: XCTestCase {
    private func input(stock: String?, stops: [Float], correction: Float = 0) throws -> Data {
        var request: [String: Any] = ["kind": "auto-adjust", "regionStops": stops,
                                       "printCorrection": correction]
        if let stock {
            let definition = try XCTUnwrap(FilmStock.presetDefinitions[stock])
            request["stock"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definition))
        }
        return try JSONSerialization.data(withJSONObject: request)
    }

    func testWebSolveUsesNativeLatitudeAndOrderStatistics() throws {
        for stockID in [nil, "gold200", "ektachromee100", "hp5plus400"] as [String?] {
            // Test stocks are selected from the public catalogue, including negative and reversal.
            for correction: Float in [0, 0.6] {
                for stops in [[Float](repeating: -3, count: 64),
                              (0..<512).map { -10 + Float($0) / 24 }] {
                    let encoded = try WebRenderRequest.prepare(input(stock: stockID, stops: stops, correction: correction))
                    let result = try JSONDecoder().decode(WebAutoAdjustmentRequest.Result.self, from: encoded)
                    let window = stockID.map { AutoAdjustment.latitude(
                        stock: FilmStock.presetDefinitions[$0]!.stock, printCorrection: correction)
                    } ?? PlainDevelop.latitude
                    let expected = AutoAdjustment.solve(scene: AutoAdjustment.SceneStops(regionStops: stops)!, window: window)
                    XCTAssertEqual(result.exposureEV, expected.exposureEV)
                    XCTAssertEqual(result.highlights, expected.highlights)
                    XCTAssertEqual(result.shadows, expected.shadows)
                    XCTAssertEqual(result.shadowLatitude, window.shadows)
                    XCTAssertEqual(result.highlightLatitude, window.highlights)
                }
            }
        }
    }

    func testMalformedAndUnboundedMeasurementsAreRejected() throws {
        for stops: [Float] in [[], Array(repeating: 0, count: 4097), [1000]] {
            XCTAssertThrowsError(try WebRenderRequest.prepare(input(stock: nil, stops: stops)))
        }
        for correction: Float in [-0.01, 1.01] {
            XCTAssertThrowsError(try WebRenderRequest.prepare(input(stock: nil, stops: [0], correction: correction)))
        }
        XCTAssertThrowsError(try WebRenderRequest.prepare(Data(#"{"kind":"auto-adjust","stock":{},"regionStops":[0]}"#.utf8)))
        let valid = try WebRenderRequest.prepare(input(stock: nil, stops: [-3]))
        XCTAssertGreaterThan(try JSONDecoder().decode(WebAutoAdjustmentRequest.Result.self, from: valid).exposureEV, 2)
        let extreme = try WebRenderRequest.prepare(input(stock: nil, stops: [128]))
        XCTAssertEqual(try JSONDecoder().decode(WebAutoAdjustmentRequest.Result.self, from: extreme).exposureEV, -3)
    }
}
