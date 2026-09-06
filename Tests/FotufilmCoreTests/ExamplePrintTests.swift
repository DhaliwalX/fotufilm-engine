import XCTest
@testable import FotufilmCore

final class ExamplePrintTests: XCTestCase {
    func testReleasedProfilesAreAvailableAndExamplesRemainForTests() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode([String: String].self, from: Data(
            contentsOf: root.appendingPathComponent("licenses/FILM-PROFILES.json")))
        XCTAssertEqual(manifest.count, 40)
        XCTAssertEqual(Set(FilmStock.presetIDs), Set(manifest.keys))
        for id in manifest.keys.sorted() {
            let definition = try XCTUnwrap(FilmStock.presetDefinitions[id], id)
            try definition.validate()
            XCTAssertNotEqual(definition.isExample, true, id)
            XCTAssertNotNil(definition.grainDensityProfile, "\(id) must state its runtime grain parameters")
            XCTAssertEqual(definition.stock.spectralProfile.layerSensitivity.count, 3, id)
            for record in definition.stock.spectralProfile.layerSensitivity {
                XCTAssertEqual(record.count, SpectralGrid.count, id)
                XCTAssertTrue(record.allSatisfy { $0.isFinite && $0 >= 0 }, id)
            }
        }
        let starter = Set(["gold200", "trix400", "provia100f"])
        for id in starter {
            let definition = try XCTUnwrap(FilmStock.presetDefinitions[id])
            try definition.validate()
            XCTAssertNotEqual(definition.isExample, true)
            let stock = definition.stock
            XCTAssertEqual(stock.grainDensityProfile, [5.1682, 0.117436, 0.421188])
            XCTAssertTrue(stock.curves.allSatisfy { $0.secondary != nil })
            XCTAssertEqual(stock.spectralProfile.layerSensitivity.count, 3)
            for record in stock.spectralProfile.layerSensitivity {
                XCTAssertEqual(record.count, SpectralGrid.count)
                XCTAssertTrue(record.allSatisfy { $0.isFinite && $0 >= 0 })
            }
        }
        XCTAssertTrue(try XCTUnwrap(FilmStock.named("trix400")).isMonochrome)
        XCTAssertTrue(try XCTUnwrap(FilmStock.named("provia100f")).isReversal)
        XCTAssertFalse(try XCTUnwrap(FilmStock.named("gold200")).isReversal)
        for id in ["example-negative-400", "example-monochrome-100", "example-reversal-64"] {
            XCTAssertNotNil(FilmStock.named(id))
            XCTAssertFalse(FilmStock.presetIDs.contains(id))
        }
    }

    func testAnalyticReceiverIsFiniteAndNeutral() {
        for index in 0..<SpectralGrid.count {
            let sum = SpectralGrid.paperDyes.reduce(Float.zero) { $0 + $1[index] }
            XCTAssertEqual(sum, 1, accuracy: 1e-6)
            for record in SpectralGrid.paperSensitivity {
                XCTAssertTrue(record[index].isFinite)
                XCTAssertGreaterThanOrEqual(record[index], 0)
            }
        }
        XCTAssertEqual(Illuminant.xenonProjection.count, SpectralGrid.count)
        XCTAssertEqual(Illuminant.xenonProjection[Illuminant.anchorIndex], 1, accuracy: 1e-6)
    }

    func testExampleCurvesAreMonotonicAndInvertible() {
        for paper in PrintPaper.allCases {
            for curve in paper.printCurves(for: TestStocks.negative) {
                var previous: Float = -.infinity
                for exposure in stride(from: Float(-1), through: 1, by: 0.1) {
                    let density = curve.density(logExposure: exposure)
                    XCTAssertTrue(density.isFinite)
                    XCTAssertGreaterThan(density, previous)
                    XCTAssertEqual(curve.logExposure(density: density), exposure, accuracy: 0.001)
                    previous = density
                }
            }
        }
    }
}
