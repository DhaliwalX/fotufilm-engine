import XCTest
@testable import FotufilmCore

final class NegativeFilmSuggestionsTests: XCTestCase {
    private let suggestions = NegativeFilmSuggestions(stocks: FilmStock.presets)

    /// A clear base as a typical camera records it: the predicted colour at the typical saturation.
    private func captured(_ base: SIMD3<Float>, lamp: SIMD3<Float> = .one) -> SIMD3<Float> {
        let mean = base.sum() / 3
        let d = mean + NegativeFilmSuggestions.saturation.typical * (base - mean)
        return lamp * SIMD3(pow(10, -d.x), pow(10, -d.y), pow(10, -d.z))
    }

    func testEveryColourNegativeIsSuggestedFromItsOwnBase() throws {
        let colour = suggestions.films.filter { $0.base.max() - $0.base.min() > 0.1 }
        XCTAssertFalse(colour.isEmpty)
        for film in colour {
            let ranked = suggestions.suggest(.init(border: captured(film.base)), limit: 3)
            XCTAssertTrue(ranked.contains { $0.films.contains(film) }, film.id)
            XCTAssertEqual(ranked.map(\.likelihood), ranked.map(\.likelihood).sorted(by: >))
            XCTAssertLessThanOrEqual(ranked.map(\.likelihood).reduce(0, +), 1.0001)
        }
    }

    func testBlackAndWhiteBasesAreOneSuggestionUntilALightFrameMeasuresDensity() throws {
        let mono = suggestions.films.filter { $0.base.max() - $0.base.min() < 0.001 }
        guard mono.count >= 2, let thin = mono.min(by: { $0.base.x < $1.base.x }),
              let dense = mono.max(by: { $0.base.x < $1.base.x }) else {
            throw XCTSkip("Needs two black-and-white films")
        }
        let border = SIMD3<Float>(repeating: pow(10, -dense.base.x))
        let colourOnly = try XCTUnwrap(suggestions.suggest(.init(border: border)).first)
        XCTAssertTrue(colourOnly.films.contains(thin) && colourOnly.films.contains(dense))
        let measured = try XCTUnwrap(suggestions.suggest(
            .init(border: border, lamp: .one, measuresDensity: true)).first)
        XCTAssertEqual(measured.films.first, dense)
    }

    func testTheLampPastTheFilmEdgeIsFoundAndTheBaseReadUnderIt() throws {
        let gold = try XCTUnwrap(suggestions.films.first { $0.id == "gold200" })
        // A band of the light the scan was balanced on beside the film, a blurred edge between
        // them, and a scan exposed below the light's full level.
        let lamp = SIMD3<Float>(repeating: 0.7), base = captured(gold.base, lamp: lamp)
        let width = 100, height = 50
        var preview = ImageBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            let t = min(max(Float(x - 18) / 4, 0), 1)
            let pixel = lamp + (base - lamp) * t
            for c in 0..<3 { preview.planes[c][y * width + x] = pixel[c] }
        } }
        let reading = try XCTUnwrap(NegativeFilmSuggestions.read(preview: preview))
        let seen = try XCTUnwrap(reading.lamp)
        for c in 0..<3 {
            XCTAssertEqual(seen[c], lamp[c], accuracy: 0.02)
            XCTAssertEqual(reading.border[c], base[c], accuracy: 0.01)
        }
        XCTAssertFalse(reading.measuresDensity)
        let ranked = suggestions.suggest(reading, limit: 3)
        XCTAssertTrue(ranked.contains { $0.films.contains(gold) })
    }

    func testABlackAndWhiteBaseIsNotTakenForTheLamp() throws {
        var preview = ImageBuffer(width: 100, height: 1)
        for x in 0..<100 {
            let value: Float = x < 20 ? 0.9 : 0.5
            for c in 0..<3 { preview.planes[c][x] = value }
        }
        let reading = try XCTUnwrap(NegativeFilmSuggestions.read(preview: preview))
        XCTAssertNil(reading.lamp)
        XCTAssertEqual(reading.border.x, 0.9, accuracy: 0.01)
    }

    func testAScanWithNoLightReadsNothing() {
        XCTAssertNil(NegativeFilmSuggestions.read(preview: ImageBuffer(width: 8, height: 8)))
    }
}
