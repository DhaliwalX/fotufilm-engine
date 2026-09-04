import XCTest
@testable import FotufilmCore
@testable import FotufilmStockMatch

final class StockMatchTests: XCTestCase {

    private func scene(
        range: ClosedRange<Float>, count: Int = 512,
        chroma: Float = 0.4, texture: Float = 0.08, specular: Float = 0,
        floored: Int = 0
    ) -> StockMatch.SceneDescription {
        let span = range.upperBound - range.lowerBound
        var stops = (0..<count).map { index -> Float in
            range.lowerBound + span * Float(index) / Float(count - 1)
        }
        for index in 0..<min(floored, count) { stops[index] = -19.9 }
        return StockMatch.SceneDescription(
            regionStops: stops, chromaMedian: chroma, chromaHigh: chroma,
            specularFraction: specular, textureEnergy: texture)
    }

    func testABlackTailDoesNotSwampTheScore() {
        let ordinary = scene(range: -6...4)
        let withBlack = scene(range: -6...4, floored: 2)

        for stock in TestStocks.all {
            let a = StockMatch.fit(scene: ordinary, stock: stock)
            let b = StockMatch.fit(scene: withBlack, stock: stock)
            XCTAssertLessThan(
                b.total - a.total, 0.5,
                "\(stock.name): two black regions moved the score by "
                + "\(b.total - a.total); the term is reading depth, not area")
        }
    }

    func testEveryTermIsAPenalty() {
        for stock in TestStocks.all {
            for range in [Float(-2)...2, Float(-8)...6, Float(-14)...10] {
                let fit = StockMatch.fit(scene: scene(range: range),
                                         stock: stock)
                XCTAssertGreaterThanOrEqual(fit.meterMiss, 0)
                XCTAssertGreaterThanOrEqual(fit.outsideLatitude, 0)
                XCTAssertGreaterThanOrEqual(fit.recoveryDemand, 0)
                XCTAssertGreaterThanOrEqual(fit.grainExposure, 0)
                XCTAssertGreaterThanOrEqual(fit.total, 0)
            }
        }
    }

    func testAWiderSceneCostsMore() {
        for stock in TestStocks.all {
            let easy = StockMatch.fit(scene: scene(range: -2...2), stock: stock)
            let hard = StockMatch.fit(scene: scene(range: -14...10), stock: stock)
            XCTAssertGreaterThan(
                hard.total, easy.total + 0.1,
                "\(stock.name) charged no more for a scene it cannot hold")
        }
    }

    func testGrainIsChargedOnlyOnASmoothFrame() {
        var grainy = TestStocks.negative
        grainy.grainStrength = 0.02
        let smooth = StockMatch.fit(scene: scene(range: -4...4, texture: 0.001),
                                    stock: grainy)
        let textured = StockMatch.fit(scene: scene(range: -4...4, texture: 0.5),
                                      stock: grainy)
        XCTAssertGreaterThan(smooth.grainExposure, textured.grainExposure * 4,
                             "a smooth frame must show more of the grain")
        XCTAssertEqual(textured.grainExposure, 0, accuracy: 0.01,
                       "foliage should hide essentially all of it")
        XCTAssertEqual(smooth.outsideLatitude, textured.outsideLatitude,
                       accuracy: 1e-6)
    }

    func testMonochromeIsGatedOnTheScenesOwnColour() {
        let colourful = scene(range: -4...4, chroma: 0.4)
        let colourless = scene(range: -4...4, chroma: 0.01)

        XCTAssertFalse(
            StockMatch.fit(scene: colourful, stock: TestStocks.monochrome)
                .isEligible,
            "a monochrome film must not be chosen for a colour photograph")
        XCTAssertTrue(
            StockMatch.fit(scene: colourless, stock: TestStocks.monochrome)
                .isEligible,
            "a photograph with no colour in it has nothing to lose")
        for stock in [TestStocks.negative, TestStocks.reversal] {
            XCTAssertTrue(StockMatch.fit(scene: colourful, stock: stock).isEligible)
            XCTAssertTrue(StockMatch.fit(scene: colourless, stock: stock).isEligible)
        }
    }

    func testTheFilmsAreActuallySeparated() {
        let description = scene(range: -7...5)
        let totals = TestStocks.all.map {
            StockMatch.fit(scene: description, stock: $0).total
        }
        let spread = (totals.max() ?? 0) - (totals.min() ?? 0)
        XCTAssertGreaterThan(spread, 0.05,
                             "the archetypes scored indistinguishably: \(totals)")
    }

    func testAnEmptySceneScoresNothing() {
        let empty = StockMatch.SceneDescription(
            regionStops: [], chromaMedian: 0, chromaHigh: 0,
            specularFraction: 0, textureEnergy: 0)
        for stock in TestStocks.all {
            XCTAssertEqual(StockMatch.fit(scene: empty, stock: stock).total, 0,
                           accuracy: 1e-6)
        }
    }
}
