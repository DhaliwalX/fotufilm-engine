import XCTest
@testable import FotufilmCore

final class ReciprocityTests: XCTestCase {

    private static var fresh: FilmStock {
        FilmStock.presets["example-negative-400"]!
    }

    func testAbsentStatementHoldsTheLaw() {
        var unstated = Self.fresh
        unstated.reciprocityFailure = nil
        for seconds: Float in [10, 100, 3600] {
            let met = unstated.reciprocity(shutterSeconds: seconds)
            for layer in 0..<3 {
                XCTAssertEqual(met.curves[layer].toe,
                               unstated.curves[layer].toe, "at \(seconds)")
                XCTAssertEqual(met.curves[layer].shoulder,
                               unstated.curves[layer].shoulder, "at \(seconds)")
            }
        }
    }

    func testCorrectionFreezesPastTheStatedRow() {
        var stated = Self.fresh
        stated.reciprocityFailure = ReciprocityFailure(
            thresholdSeconds: 1.53, lostStopsPerDecade: 0.72,
            statedThroughSeconds: 32)
        let atLimit = stated.reciprocity(shutterSeconds: 32)
        let far = stated.reciprocity(shutterSeconds: 300)
        for layer in 0..<3 {
            XCTAssertEqual(far.curves[layer].toe, atLimit.curves[layer].toe,
                           "layer \(layer)")
            XCTAssertEqual(far.curves[layer].shoulder,
                           atLimit.curves[layer].shoulder, "layer \(layer)")
        }
        // The bound only caps: inside the row the correction still grows.
        let inside = stated.reciprocity(shutterSeconds: 8)
        XCTAssertGreaterThan(atLimit.curves[2].toe, inside.curves[2].toe)
    }

    func testHoldSheetStaysInsideItsHold() {
        var held = Self.fresh
        held.reciprocityFailure = ReciprocityFailure(
            thresholdSeconds: 1, lostStopsPerDecade: 0,
            statedThroughSeconds: 1)
        let met = held.reciprocity(shutterSeconds: 100)
        for layer in 0..<3 {
            XCTAssertEqual(met.curves[layer].toe, held.curves[layer].toe)
            XCTAssertEqual(met.curves[layer].shoulder, held.curves[layer].shoulder)
        }
    }

    func testInsideTheLawIsUntouched() {
        let stock = Self.fresh
        for seconds: Float in [0, 0.5, 1] {
            let same = stock.reciprocity(shutterSeconds: seconds)
            XCTAssertEqual(SpectralRuntime.cacheIdentifier(for: same),
                           SpectralRuntime.cacheIdentifier(for: stock), "at \(seconds)")
            for layer in 0..<3 {
                XCTAssertEqual(same.curves[layer].toe, stock.curves[layer].toe)
                XCTAssertEqual(same.curves[layer].shoulder, stock.curves[layer].shoulder)
            }
        }
    }

    func testDecadeIsOneStopOnTheBlueRecord() {
        let stock = Self.fresh
        let met = stock.reciprocity(shutterSeconds: 10)
        let stop = Float(log10(2.0))
        for x in stride(from: Float(-1.5), through: 1.5, by: 0.5) {
            XCTAssertEqual(met.curves[2].density(logExposure: x + stop),
                           stock.curves[2].density(logExposure: x),
                           accuracy: 1e-5, "at \(x)")
        }
    }

    func testGreenHoldsAndMonochromeCannotCast() {
        let stock = Self.fresh
        let met = stock.reciprocity(shutterSeconds: 100)
        let shift = (0..<3).map { met.curves[$0].toe - stock.curves[$0].toe }
        XCTAssertGreaterThan(shift[0], shift[2])
        XCTAssertGreaterThan(shift[2], shift[1])
        guard let mono = FilmStock.presets["example-monochrome-100"] else {
            return XCTFail("example-monochrome-100 preset missing")
        }
        let monoMet = mono.reciprocity(shutterSeconds: 100)
        let monoShift = (0..<3).map { monoMet.curves[$0].toe - mono.curves[$0].toe }
        XCTAssertEqual(monoShift[0], monoShift[1], accuracy: 1e-6)
        XCTAssertEqual(monoShift[1], monoShift[2], accuracy: 1e-6)
    }

    func testStatedThresholdHoldsTheLaw() {
        var stated = Self.fresh
        stated.reciprocityFailure = ReciprocityFailure(
            thresholdSeconds: 128, lostStopsPerDecade: 1)
        let met = stated.reciprocity(shutterSeconds: 30)
        for layer in 0..<3 {
            XCTAssertEqual(met.curves[layer].toe, stated.curves[layer].toe)
            XCTAssertEqual(met.curves[layer].shoulder, stated.curves[layer].shoulder)
        }
        let classic = Self.fresh.reciprocity(shutterSeconds: 30)
        let perStop = Float(log10(2.0))
        XCTAssertGreaterThan(
            (classic.curves[2].toe - Self.fresh.curves[2].toe) / perStop, 1.4)
    }

    func testStatedTableIsReproducedWithinItsRounding() {
        var stated = Self.fresh
        stated.reciprocityFailure = ReciprocityFailure(
            thresholdSeconds: 1.53, lostStopsPerDecade: 0.72)
        let perStop = Float(log10(2.0))
        for (seconds, published): (Float, Float) in
            [(4, 1.0 / 3), (8, 0.5), (16, 2.0 / 3), (32, 1)] {
            let met = stated.reciprocity(shutterSeconds: seconds)
            let mean = (0..<3).map {
                (met.curves[$0].toe - stated.curves[$0].toe) / perStop
            }.reduce(0, +) / 3
            XCTAssertEqual(mean, published, accuracy: 0.07, "at \(seconds) s")
        }
    }

    func testStatedRateIsTheWholeMonochromeCorrection() throws {
        guard var mono = FilmStock.presets["example-monochrome-100"] else {
            return XCTFail("example-monochrome-100 preset missing")
        }
        // The classic cubic-grain B&W table: +1 stop at 1 s, +2 at 10 s.
        mono.reciprocityFailure = ReciprocityFailure(
            thresholdSeconds: 0.1, lostStopsPerDecade: 1)
        let met = mono.reciprocity(shutterSeconds: 10)
        let perStop = Float(log10(2.0))
        for layer in 0..<3 {
            XCTAssertEqual((met.curves[layer].toe - mono.curves[layer].toe) / perStop,
                           2, accuracy: 1e-4)
        }
    }

    func testStatedWeightsSetTheCast() {
        var stated = Self.fresh
        stated.reciprocityFailure = ReciprocityFailure(
            thresholdSeconds: 1, lostStopsPerDecade: 0.5,
            layerWeights: [0.89, 0.89, 1.22])
        let met = stated.reciprocity(shutterSeconds: 100)
        let shift = (0..<3).map { met.curves[$0].toe - stated.curves[$0].toe }
        XCTAssertGreaterThan(shift[2], shift[0])
        XCTAssertEqual(shift[0], shift[1], accuracy: 1e-6)
    }

    func testPackRoundTripCarriesTheStatement() throws {
        guard var definition = FilmStock.presetDefinitions.values.first else {
            throw XCTSkip("no stock pack installed")
        }
        definition.reciprocityFailure = ReciprocityFailure(
            thresholdSeconds: 120, lostStopsPerDecade: 0.54,
            statedThroughSeconds: 1000)
        let round = try JSONDecoder().decode(
            FilmStockDefinition.self, from: JSONEncoder().encode(definition))
        XCTAssertEqual(round.reciprocityFailure, definition.reciprocityFailure)
        XCTAssertEqual(round.stock.reciprocityFailure, definition.reciprocityFailure)

        definition.reciprocityFailure = ReciprocityFailure(
            thresholdSeconds: 1, lostStopsPerDecade: 1, layerWeights: [1, 1])
        XCTAssertThrowsError(try definition.validate())

        // A stated bound cannot sit inside the law it bounds.
        definition.reciprocityFailure = ReciprocityFailure(
            thresholdSeconds: 10, lostStopsPerDecade: 1,
            statedThroughSeconds: 5)
        XCTAssertThrowsError(try definition.validate())
    }

    func testMidHoldsWhileShadowsSlideIntoTheToe() {
        let stock = Self.fresh
        let met = stock.reciprocity(shutterSeconds: 30)
        let perStop = Float(log10(2.0))
        func printed(_ stock: FilmStock, stops: Float) -> SIMD3<Float> {
            let tables = SpectralRuntime.tables(for: stock)
            let ranges = stock.curves.map { $0.dMax - $0.dMin }
            let p = SIMD3<Float>(
                (stock.curves[0].density(logExposure: stops * perStop)
                    - stock.curves[0].dMin) / ranges[0],
                (stock.curves[1].density(logExposure: stops * perStop)
                    - stock.curves[1].dMin) / ranges[1],
                (stock.curves[2].density(logExposure: stops * perStop)
                    - stock.curves[2].dMin) / ranges[2])
            let logE = tables.filmOutput.sample(p)
            let paperCurve = FotufilmEngine.Options().paper(for: stock).printCurve(for: stock)
            let xMid = paperCurve.logExposure(
                density: paperCurve.dMin
                    + FotufilmEngine.Options().paper(for: stock).anchorDensity(stock.paperMidDensity))
            let range = paperCurve.dMax - paperCurve.dMin
            let activation = SIMD3<Float>(
                (paperCurve.density(logExposure: xMid + logE.x) - paperCurve.dMin) / range,
                (paperCurve.density(logExposure: xMid + logE.y) - paperCurve.dMin) / range,
                (paperCurve.density(logExposure: xMid + logE.z) - paperCurve.dMin) / range)
            return tables.paperOutput!.sample(activation)
        }
        func luminance(_ rgb: SIMD3<Float>) -> Float {
            let w = ColorScience.luminanceWeights
            return w.0 * rgb.x + w.1 * rgb.y + w.2 * rgb.z
        }
        func chroma(_ rgb: SIMD3<Float>) -> Float {
            let peak = max(rgb.x, rgb.y, rgb.z)
            guard peak > 1e-6 else { return 0 }
            return (peak - min(rgb.x, rgb.y, rgb.z)) / peak
        }
        let freshMid = printed(stock, stops: 0)
        let metMid = printed(met, stops: 0)
        XCTAssertEqual(luminance(metMid) / luminance(freshMid), 1, accuracy: 0.15)
        // Toe compression lifts the flattened shadows: measured 1.163 at −2 stops;
        // pinned with room for LUT resampling, not for the effect.
        let freshShadow = printed(stock, stops: -2)
        let metShadow = printed(met, stops: -2)
        XCTAssertGreaterThan(luminance(metShadow) / luminance(freshShadow), 1.1)
        // And casts them warm: chroma 0.073 → 0.192, red flattest so red lightest.
        XCTAssertGreaterThan(chroma(metShadow), chroma(freshShadow) + 0.08)
        XCTAssertGreaterThan(metShadow.x, metShadow.y)
        XCTAssertGreaterThan(metShadow.y, metShadow.z)
        // Highlights lean cool: chroma 0.028 → 0.041 at +1.5 stops, b>g>r.
        let freshHigh = printed(stock, stops: 1.5)
        let metHigh = printed(met, stops: 1.5)
        XCTAssertGreaterThan(chroma(metHigh), chroma(freshHigh) + 0.005)
        XCTAssertGreaterThan(metHigh.z, metHigh.y)
        XCTAssertGreaterThan(metHigh.y, metHigh.x)
    }
}
