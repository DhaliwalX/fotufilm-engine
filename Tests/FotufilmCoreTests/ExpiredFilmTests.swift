import XCTest
@testable import FotufilmCore

final class ExpiredFilmTests: XCTestCase {

    private static var fresh: FilmStock {
        FilmStock.presets["example-negative-400"]!
    }

    func testFreshRollIsUntouched() {
        let stock = Self.fresh
        let same = stock.expired(years: 0)
        XCTAssertEqual(SpectralRuntime.cacheIdentifier(for: same),
                       SpectralRuntime.cacheIdentifier(for: stock))
        XCTAssertEqual(same.grainStrength, stock.grainStrength)
        for layer in 0..<3 {
            XCTAssertEqual(same.curves[layer].dMin, stock.curves[layer].dMin)
            XCTAssertEqual(same.curves[layer].toe, stock.curves[layer].toe)
        }
    }

    func testDecadeIsOneStopOnTheGreenLayer() {
        let stock = Self.fresh
        let aged = stock.expired(years: 10)
        let stop = Float(log10(2.0))
        let fog = FilmStock.expiredFogPerStopLost
        for x in stride(from: Float(-1.5), through: 1.5, by: 0.5) {
            XCTAssertEqual(aged.curves[1].density(logExposure: x + stop),
                           stock.curves[1].density(logExposure: x) + fog,
                           accuracy: 1e-5, "at \(x)")
        }
    }

    func testBlueGoesFirst() {
        let stock = Self.fresh
        let aged = stock.expired(years: 10)
        let fog = (0..<3).map { aged.curves[$0].dMin - stock.curves[$0].dMin }
        XCTAssertGreaterThan(fog[2], fog[1])
        XCTAssertGreaterThan(fog[1], fog[0])
        let shift = (0..<3).map { aged.curves[$0].toe - stock.curves[$0].toe }
        XCTAssertGreaterThan(shift[2], shift[1])
        XCTAssertGreaterThan(shift[1], shift[0])
    }

    func testGrainRisesWithTheFog() {
        let stock = Self.fresh
        let aged = stock.expired(years: 10)
        let meanFog = FilmStock.expiredFogPerStopLost
            * FilmStock.expiredSpeedLossStopsPerDecade
        XCTAssertEqual(aged.grainStrength / stock.grainStrength,
                       1 + FilmStock.expiredGrainPerFog * meanFog,
                       accuracy: 1e-5)
    }

    func testMidHoldsAndTheToeCrosses() {
        let stock = Self.fresh
        let aged = stock.expired(years: 10)
        let perStop = Float(log10(2.0))
        func printed(_ stock: FilmStock, stops: Float, extraEV: Float,
                     paper: PrintPaper = FotufilmEngine.Options().paper(for: Self.fresh)) -> SIMD3<Float> {
            let tables = SpectralRuntime.tables(for: stock, paper: paper)
            let ranges = stock.curves.map { $0.dMax - $0.dMin }
            let p = SIMD3<Float>(
                (stock.curves[0].density(logExposure: (stops + extraEV) * perStop)
                    - stock.curves[0].dMin) / ranges[0],
                (stock.curves[1].density(logExposure: (stops + extraEV) * perStop)
                    - stock.curves[1].dMin) / ranges[1],
                (stock.curves[2].density(logExposure: (stops + extraEV) * perStop)
                    - stock.curves[2].dMin) / ranges[2])
            let logE = tables.filmOutput.sample(p)
            let paperCurves = paper.printCurves(for: stock)
            let activation = SIMD3<Float>((0..<3).map { channel in
                let curve = paperCurves[channel]
                let xMid = curve.logExposure(
                    density: curve.dMin + paper.anchorDensity(stock.paperMidDensity))
                return (curve.density(logExposure: xMid + logE[channel])
                        - curve.dMin) / (curve.dMax - curve.dMin)
            })
            return tables.paperOutput!.sample(activation)
        }
        func luminance(_ rgb: SIMD3<Float>) -> Float {
            let w = ColorScience.displayP3LuminanceWeights
            return w.0 * rgb.x + w.1 * rgb.y + w.2 * rgb.z
        }
        func chroma(_ rgb: SIMD3<Float>) -> Float {
            let peak = max(rgb.x, rgb.y, rgb.z)
            guard peak > 1e-6 else { return 0 }
            return (peak - min(rgb.x, rgb.y, rgb.z)) / peak
        }
        // The tables anchor the print on the aged stock's own logE = 0 density — the
        // lab times the roll it received — so the aged mid corrects with no help.
        let freshMid = printed(stock, stops: 0, extraEV: 0)
        let agedMid = printed(aged, stops: 0, extraEV: 0)
        print("MEASURE mid fresh \(freshMid) aged \(agedMid)")
        XCTAssertEqual(luminance(agedMid) / luminance(freshMid), 1, accuracy: 0.15)
        // Fog compresses the toe, so deep shadows print lifted. Measured 1.106 at
        // −3 stops; pinned with room for LUT resampling, not for the effect vanishing.
        let freshShadow = printed(stock, stops: -3, extraEV: 0)
        let agedShadow = printed(aged, stops: -3, extraEV: 0)
        XCTAssertGreaterThan(luminance(agedShadow) / luminance(freshShadow), 1.05)
        // And the floor crosses: the fresh print's deepest shadow leans warm, the
        // fogged one's leans cool, because the blue record's fog is the heaviest and
        // yellow fog on a negative prints blue.
        let freshFloor = printed(stock, stops: -3.5, extraEV: 0)
        let agedFloor = printed(aged, stops: -3.5, extraEV: 0)
        XCTAssertGreaterThan(freshFloor.x, freshFloor.z)
        XCTAssertGreaterThan(agedFloor.z, agedFloor.x)
    }
}
