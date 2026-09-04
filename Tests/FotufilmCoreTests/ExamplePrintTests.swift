import XCTest
@testable import FotufilmCore

final class ExamplePrintTests: XCTestCase {
    func testSourceExamplesAreVisibleWithoutProductPacks() throws {
        XCTAssertFalse(FilmStock.presetIDs.isEmpty)
        XCTAssertEqual(Set(FilmStock.presetIDs), Set(FilmStock.allPresetIDs))
        for id in FilmStock.presetIDs {
            XCTAssertTrue(id.hasPrefix("example-"))
            XCTAssertNotNil(FilmStock.named(id))
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
