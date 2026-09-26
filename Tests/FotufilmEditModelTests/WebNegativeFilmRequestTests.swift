import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class WebNegativeFilmRequestTests: XCTestCase {
    func testBrowserSuggestionsMatchTheNativeReading() throws {
        let native = NegativeFilmSuggestions(stocks: FilmStock.presets)
        let gold = try XCTUnwrap(native.films.first { $0.id == "gold200" })
        // A neutral light beside the film and the clear base across the rest of the frame, as
        // saturated as a camera typically records it.
        let mean = gold.base.sum() / 3, typical: Float = 1.25
        let base = mean + typical * (gold.base - mean)
        let width = 64, height = 8
        var planes = [[Float]](repeating: [Float](repeating: 0, count: width * height), count: 3)
        for y in 0..<height { for x in 0..<width { for c in 0..<3 {
            planes[c][y * width + x] = x < 12 ? 0.8 : 0.8 * pow(10, -base[c])
        } } }
        var samples = Data()
        for plane in planes { for value in plane {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { samples.append(contentsOf: $0) }
        } }
        let films = native.films.map { ["id": $0.id, "name": $0.name, "base": [$0.base.x, $0.base.y, $0.base.z]] }
        let request: [String: Any] = ["kind": "negative-film", "width": width, "height": height,
                                      "samples": samples.base64EncodedString(), "films": films]
        let response = try WebRenderRequest.prepare(JSONSerialization.data(withJSONObject: request))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(result["lamp"] as? Bool, true)
        let suggestions = try XCTUnwrap(result["suggestions"] as? [[String: Any]])
        let expected = native.suggest(try XCTUnwrap(NegativeFilmSuggestions.read(
            preview: ImageBuffer(width: width, height: height, planes: planes))), limit: 3)
        XCTAssertEqual(suggestions.map { $0["films"] as? [String] }, expected.map { $0.films.map(\.id) })
        XCTAssertTrue(expected.contains { $0.films.contains(gold) })
    }

    func testMalformedSamplesAreRejected() {
        let request: [String: Any] = ["kind": "negative-film", "width": 4, "height": 4,
                                      "samples": Data(count: 12).base64EncodedString(), "films": []]
        XCTAssertThrowsError(try WebRenderRequest.prepare(JSONSerialization.data(withJSONObject: request)))
    }
}
