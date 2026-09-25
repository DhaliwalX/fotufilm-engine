import XCTest
@testable import FotufilmCore

final class FilmTileBuildTests: XCTestCase {
    /// Every tile builder lays the Swift reference's film: the same crystals, clouds and light,
    /// texel for texel — to float rounding and the reference's own truncation of the clouds at
    /// its tile margins. A builder this host cannot run is skipped.
    func testBuilderLaysTheReferenceFilm() throws {
        let stock = TestStocks.negative
        let grain = FilmGrain(stock: stock)
        let builders: [FilmGrain.TileBuilder] = [.metal, .halide]
        var ran = 0
        for builder in builders {
            guard grain.builtLights(record: 0, grosses: [grain.records[0].dMin], seed: FilmGrain.tileSeed,
                                    builders: [builder]) != nil else { continue }
            ran += 1
            for r in 0..<3 {
                let record = grain.records[r]
                let grosses = [0.1, 0.45, 0.8].map { record.dMin + (record.dMax - record.dMin) * $0 }
                let built = try XCTUnwrap(grain.builtLights(record: r, grosses: grosses,
                                                            seed: FilmGrain.tileSeed, builders: [builder]),
                                          "\(builder)")
                for (k, gross) in grosses.enumerated() {
                    let reference = grain.referenceTileLight(record: r, gross: gross, seed: FilmGrain.tileSeed)
                    let a = built[k].map { -log10(Double($0)) }, b = reference.map { -log10(Double($0)) }
                    let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
                    var ab = 0.0, aa = 0.0, bb = 0.0, worst = 0.0
                    for (x, y) in zip(a, b) {
                        ab += (x - ma) * (y - mb); aa += (x - ma) * (x - ma); bb += (y - mb) * (y - mb)
                        worst = max(worst, abs(x - y))
                    }
                    let label = "\(builder) record \(r) level \(k)"
                    XCTAssertGreaterThan(ab / (aa * bb).squareRoot(), 0.9999, label)
                    XCTAssertEqual((aa / bb).squareRoot(), 1, accuracy: 1e-3, label)
                    XCTAssertEqual(ma, mb, accuracy: 1e-4, label)
                    XCTAssertLessThan(worst, 2e-3, label)
                }
            }
        }
        #if canImport(Metal)
        XCTAssertGreaterThan(ran, 0, "no builder ran")
        #endif
    }
}
