import XCTest
@testable import FotufilmCore
@testable import FotufilmStockMatch

final class StockRankingPerformanceTests: XCTestCase {

    private let width = 120
    private let height = 160

    private func fastest(runs: Int = 30, _ body: () -> Void) -> Double {
        body()
        var best = Double.infinity
        for _ in 0..<runs {
            let start = DispatchTime.now()
            body()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds
                                 - start.uptimeNanoseconds) / 1_000_000
            best = min(best, elapsed)
        }
        return best
    }

    private func scene() -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Float(x) / Float(width - 1)
                let v = Float(y) / Float(height - 1)
                let checker: Float = ((x / 2) + (y / 2)) % 2 == 0 ? 1.1 : 0.9
                let level = exp2(-8 + 11 * (u + v) / 2) * checker
                let index = (y * width + x) * 4
                pixels[index] = level * (0.6 + 0.8 * u)
                pixels[index + 1] = level
                pixels[index + 2] = level * (0.6 + 0.8 * v)
                pixels[index + 3] = 1
            }
        }
        return pixels
    }

    private func coverage() -> [Float] {
        (0..<(width * height)).map { index in
            let x = Float(index % width) / Float(width - 1)
            let y = Float(index / width) / Float(height - 1)
            let distance = ((x - 0.5) * (x - 0.5) + (y - 0.5) * (y - 0.5))
                .squareRoot()
            return max(0, min(1, (0.42 - distance) / 0.12))
        }
    }

    private func print8() -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            bytes[index * 4] = UInt8((index * 7) % 256)
            bytes[index * 4 + 1] = UInt8((index * 13) % 256)
            bytes[index * 4 + 2] = UInt8((index * 29) % 256)
        }
        return bytes
    }

    func testSceneReadingCost() {
        let pixels = scene()
        let mask = coverage()
        var withMask = 0.0, withoutMask = 0.0

        pixels.withUnsafeBufferPointer { source in
            withoutMask = fastest {
                _ = StockRanking.read(linearRGBA: source.baseAddress!,
                                      width: width, height: height)
            }
            withMask = fastest {
                _ = StockRanking.read(linearRGBA: source.baseAddress!,
                                      width: width, height: height,
                                      subjectCoverage: mask)
            }
        }
        print(String(format:
            "StockRanking scene read %dx%d: %.3f ms plain, %.3f ms masked",
            width, height, withoutMask, withMask))
        XCTAssertLessThan(withMask, 20, "the scene reading has fallen apart")
    }

    func testRankingCostWithoutTheEngine() throws {
        let films = try packOrFixtures()
        let pixels = scene()
        let mask = coverage()
        let bytes = print8()

        for (label, weights) in [("no subject", nil as [Float]?),
                                 ("subject weighted", mask)] {
            var eligible = 0
            var elapsed = 0.0
            pixels.withUnsafeBufferPointer { source in
                guard let reading = StockRanking.read(
                    linearRGBA: source.baseAddress!, width: width,
                    height: height, subjectCoverage: weights) else { return }
                elapsed = fastest(runs: 10) {
                    let ranking = StockRanking.rank(scene: reading,
                                                    films: films) {
                        _, buffer, _, _ in
                        bytes.withUnsafeBufferPointer {
                            buffer.baseAddress!.update(from: $0.baseAddress!,
                                                       count: buffer.count)
                        }
                        return true
                    }
                    eligible = ranking.ordered.count
                }
            }
            guard eligible > 0 else {
                return XCTFail("nothing was eligible to rank")
            }
            print(String(format:
                "StockRanking %dx%d, %@: %.3f ms for %d films (%.1f µs each)",
                width, height, label, elapsed, eligible,
                1000 * elapsed / Double(eligible)))
            XCTAssertLessThan(elapsed, 250, "the ranking has fallen apart")
        }
    }

    private func packOrFixtures() throws -> [StockRanking.Film] {
        let installed = FilmStock.presetIDs.compactMap { id -> StockRanking.Film? in
            guard let definition = FilmStock.presetDefinitions[id] else {
                return nil
            }
            return StockRanking.Film(id: id, name: definition.name,
                                     stock: definition.stock)
        }
        if installed.count >= 8 { return installed }
        return (0..<21).map {
            StockRanking.Film(id: "fixture-\($0)", name: "Fixture \($0)",
                              stock: TestStocks.all[$0 % TestStocks.all.count])
        }
    }
}
