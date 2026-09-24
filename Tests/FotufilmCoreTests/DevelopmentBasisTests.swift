import XCTest
@testable import FotufilmCore

final class DevelopmentBasisTests: XCTestCase {
    private func definition(_ basis: FilmDevelopmentBasis) throws -> FilmStockDefinition {
        var definition = try XCTUnwrap(FilmStock.presetDefinitions["example-negative-400"])
        let curves = try definition.validated().stock.curves
        definition.development = .init(FilmDevelopmentProfile(
            developer: "C-41", temperatureC: 37.8, agitation: "test",
            source: "synthetic fixture", sourcePage: 1,
            conditions: [FilmDevelopmentCondition(stops: 1, label: "Push 1", timeMinutes: 3.75,
                                                  basis: basis, curves: curves)]))
        return definition
    }

    func testEveryBasisSurvivesAPackRoundTrip() throws {
        for basis: FilmDevelopmentBasis in [.measured, .transferred(from: "Portra 800"), .estimated] {
            let data = try JSONEncoder().encode(try definition(basis))
            let decoded = try JSONDecoder().decode(FilmStockDefinition.self, from: data).validated()
            XCTAssertEqual(decoded.stock.developmentProfile?.conditions.first?.basis, basis)
        }
    }

    func testABasisMustNameItsSourceExactlyWhenItIsTransferred() throws {
        for (basis, stock) in [("transferred", nil), ("transferred", ""), ("measured", "Portra 800"),
                               ("estimated", "Portra 800"), ("inferred", nil)] as [(String, String?)] {
            var candidate = try definition(.measured)
            candidate.development?.conditions[0].basis = basis
            candidate.development?.conditions[0].basisStock = stock
            XCTAssertThrowsError(try candidate.validate(), "\(basis) / \(stock ?? "nil")") { error in
                XCTAssertTrue("\(error)".contains("development.conditions[0].basis"), "\(error)")
            }
        }
    }
}
