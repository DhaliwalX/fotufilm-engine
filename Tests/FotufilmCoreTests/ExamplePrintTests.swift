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

    func testReceiverIsFiniteAndNeutral() {
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

    /// A measured print receiver is not a gentle analytic ramp: RA-4 paper runs at gamma 5.9 and
    /// a release print steeper still, so each record reaches D-max inside a few tenths of a decade
    /// and is flat on either side of it. The invariants that survive that, and that the print stage
    /// actually relies on, are these — finite and never falling anywhere, strictly rising and
    /// invertible across the record's own active span.
    func testPrintCurvesAreNonDecreasingAndInvertibleAcrossTheirActiveSpan() {
        for paper in PrintPaper.allCases {
            for (record, curve) in paper.printCurves(for: TestStocks.negative).enumerated() {
                let label = "\(paper.rawValue) record \(record)"
                var previous: Float = -.infinity
                for exposure in stride(from: Float(-4), through: 4, by: 0.05) {
                    let density = curve.density(logExposure: exposure)
                    XCTAssertTrue(density.isFinite, label)
                    // The plateau above D-max is a clamp, so it carries float jitter of a few
                    // parts in ten million. That is six orders below a visible density step.
                    XCTAssertGreaterThanOrEqual(density, previous - 1e-5, label)
                    previous = density
                }

                // Strictly inside the toe and shoulder the curve is the printing stage's working
                // range, and it has to be one-to-one there for the timing solve to invert it.
                let span = curve.shoulder - curve.toe
                XCTAssertGreaterThan(span, 0, label)
                var last: Float = -.infinity
                for step in 1...9 {
                    let exposure = curve.toe + span * Float(step) / 10
                    let density = curve.density(logExposure: exposure)
                    XCTAssertGreaterThan(density, last, label)
                    XCTAssertEqual(curve.logExposure(density: density), exposure,
                                   accuracy: 0.001, label)
                    last = density
                }
            }
        }
    }
}
