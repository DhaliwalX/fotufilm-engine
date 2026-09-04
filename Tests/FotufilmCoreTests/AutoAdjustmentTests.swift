import XCTest
@testable import FotufilmCore

final class AutoAdjustmentTests: XCTestCase {

    func testNeutralToneScaleIsMonotone() {
        let stops = Array(stride(from: Float(-8), through: 8, by: 0.25))
        for stock in TestStocks.all {
            let scale = SpectralRuntime.neutralToneScale(
                stops: stops, stock: stock, printCorrection: 0.05)
            for i in 1..<scale.count {
                XCTAssertGreaterThanOrEqual(
                    scale[i], scale[i - 1] - 1e-5,
                    "\(stock.name) tone scale not monotone at \(stops[i]) stops")
            }
        }
    }

    func testNeutralToneScaleAnchorsMidGrey() {
        for stock in TestStocks.all {
            let mid = SpectralRuntime.neutralToneScale(
                stops: [0], stock: stock, printCorrection: 0.05)[0]
            XCTAssertGreaterThan(mid, 0.05, "\(stock.name) mid-grey prints black")
            XCTAssertLessThan(mid, 0.5, "\(stock.name) mid-grey prints white")
        }
    }

    func testNegativeToneScaleIsInvertedAndKeepsUsableLatitude() {
        let stops = Array(stride(from: Float(-4), through: 4, by: 0.25))
        let scale = SpectralRuntime.neutralToneScale(
            stops: stops, stock: TestStocks.negative, paper: .negative,
            printCorrection: 0.05)
        for i in 1..<scale.count {
            XCTAssertLessThanOrEqual(scale[i], scale[i - 1] + 1e-5,
                                     "viewed-negative scale lost its polarity")
        }
        let window = AutoAdjustment.latitude(stock: TestStocks.negative,
                                              paper: .negative)
        XCTAssertLessThan(window.shadows, -1)
        XCTAssertGreaterThan(window.highlights, 1)
    }

    func testLatitudeFollowsTheCurves() {
        for stock in TestStocks.all {
            let window = AutoAdjustment.latitude(stock: stock)
            XCTAssertLessThan(window.shadows, -1, "\(stock.name) window misses the toe")
            XCTAssertGreaterThan(window.highlights, 1, "\(stock.name) window misses the shoulder")
        }
        var clipped = TestStocks.reversal
        for layer in 0..<3 {
            clipped.curves[layer].shoulder -= 0.45
        }
        let full = AutoAdjustment.latitude(stock: TestStocks.reversal)
        let early = AutoAdjustment.latitude(stock: clipped)
        XCTAssertLessThan(early.highlights, full.highlights - 0.4,
                          "an earlier shoulder must cost highlight latitude")
        XCTAssertEqual(early.shadows, full.shadows, accuracy: 0.75,
                       "the shoulder move should not rewrite the toe")
    }

    func testSolveMetersTheMedianOntoItsTarget() {
        let stops = [Float](repeating: -3, count: 512)
        let solution = AutoAdjustment.solve(regionStops: stops,
                                            stock: TestStocks.negative)
        XCTAssertEqual(solution.exposureEV, 3 + AutoAdjustment.kMedianTarget,
                       accuracy: 0.01)
        XCTAssertEqual(solution.highlights, 0)
        XCTAssertEqual(solution.shadows, 0)
    }

    func testSolveLeavesAWellMeteredSceneAlone() {
        let stops = (0..<512).map {
            AutoAdjustment.kMedianTarget + Float($0 % 5) * 0.1 - 0.2
        }
        let solution = AutoAdjustment.solve(regionStops: stops,
                                            stock: TestStocks.negative)
        XCTAssertEqual(solution.exposureEV, 0, accuracy: 0.15)
        XCTAssertEqual(solution.highlights, 0, accuracy: 1e-4)
        XCTAssertEqual(solution.shadows, 0, accuracy: 1e-4)
    }

    func testSolveKeepsABigSkyOffTheShoulder() {
        for stock in [TestStocks.negative, TestStocks.reversal] {
            let window = AutoAdjustment.latitude(stock: stock)
            var stops = [Float](repeating: -1.3, count: 640)
            stops += [Float](repeating: 2.0, count: 280)
            stops += [Float](repeating: 2.5, count: 80)
            let solution = AutoAdjustment.solve(regionStops: stops, stock: stock)
            let bright: Float = 2.5
            let landed = bright + solution.exposureEV
            XCTAssertLessThanOrEqual(
                landed, window.highlights + 1e-3,
                "\(stock.name): exposure pushed the sky past the latitude edge")
            let t = min(max(landed / 6, 0), 1)
            let recovered = landed + 3 * t * t * (3 - 2 * t) * solution.highlights
            XCTAssertLessThanOrEqual(
                recovered, window.highlights - AutoAdjustment.kHighlightHeadroom + 0.3,
                "\(stock.name): recovery left the sky on the shoulder")
        }
    }

    func testSolveRecoversHighlightsBeyondTheLatitude() {
        let window = AutoAdjustment.latitude(stock: TestStocks.negative)
        var stops = [Float](repeating: 0, count: 900)
        stops += [Float](repeating: window.highlights + 4, count: 100)
        let solution = AutoAdjustment.solve(regionStops: stops,
                                            stock: TestStocks.negative)
        XCTAssertLessThan(solution.highlights, -0.2,
                          "out-of-latitude highlights were not recovered")
        XCTAssertLessThanOrEqual(solution.exposureEV, 0,
                                 "metering pushed unreachable highlights further out")
    }

    func testSolveLiftsShadowsBelowTheToe() {
        let window = AutoAdjustment.latitude(stock: TestStocks.reversal)
        var stops = [Float](repeating: 0, count: 900)
        stops += [Float](repeating: window.shadows - 3, count: 100)
        let solution = AutoAdjustment.solve(regionStops: stops,
                                            stock: TestStocks.reversal)
        XCTAssertGreaterThan(solution.shadows, 0.2,
                             "out-of-latitude shadows were not lifted")
        XCTAssertEqual(solution.highlights, 0, accuracy: 1e-4)
    }

    func testSolveStaysInsideTheControls() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let stops = (0..<256).map { _ in
                Float.random(in: -14...14, using: &generator)
            }
            for stock in TestStocks.all {
                let solution = AutoAdjustment.solve(regionStops: stops, stock: stock)
                XCTAssertGreaterThanOrEqual(solution.exposureEV, -3)
                XCTAssertLessThanOrEqual(solution.exposureEV, 3)
                XCTAssertGreaterThanOrEqual(solution.highlights, -1)
                XCTAssertLessThanOrEqual(solution.highlights, 0)
                XCTAssertGreaterThanOrEqual(solution.shadows, 0)
                XCTAssertLessThanOrEqual(solution.shadows, 1)
            }
        }
    }

    func testSolveOfNothingIsNeutral() {
        XCTAssertEqual(AutoAdjustment.solve(regionStops: [],
                                            stock: TestStocks.negative),
                       .neutral)
    }

    func testSolveReadsTheRegionalMeasurement() {
        let width = 128, height = 128
        var measurement = ToneBaseMeasurement(
            frameWidth: width, frameHeight: height,
            balance: SIMD3(1, 1, 1), exposureGain: 1)
        let value = 0.18 * exp2(Float(-2))
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = value; pixels[i * 4 + 1] = value
            pixels[i * 4 + 2] = value
        }
        pixels.withUnsafeBufferPointer {
            measurement.add(linearRGBA: $0.baseAddress!, rows: 0..<height)
        }
        let solution = AutoAdjustment.solve(
            regionStops: measurement.regionStops(), stock: TestStocks.negative)
        XCTAssertEqual(solution.exposureEV, 2 + AutoAdjustment.kMedianTarget,
                       accuracy: 0.05)
    }
}
