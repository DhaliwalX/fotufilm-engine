#if canImport(Metal)
import Metal
import XCTest
@testable import FotufilmCore
@testable import FotufilmMetal

final class HeadroomPlacementTests: XCTestCase {
    // MARK: The placement math

    func testSDRSourcesAskForNothing() {
        let window: (shadows: Float, highlights: Float) = (-3, 2)
        XCTAssertEqual(AutoAdjustment.headroomHighlights(
            contentHeadroom: 1, window: window), 0)
        // A malformed declaration below 1 is treated as SDR, not as a push.
        XCTAssertEqual(AutoAdjustment.headroomHighlights(
            contentHeadroom: 0.5, window: window), 0)
    }

    func testAWindowThatAlreadyCoversTheRangeAsksForNothing() {
        // Ektachrome E100's measured window reaches +3.25 stops; a headroom whose top stays
        // under that edge (2.47 + log2 H <= 3.25 means H <= 1.7) needs no recovery.
        let wide: (shadows: Float, highlights: Float) = (-5, 3.25)
        XCTAssertEqual(AutoAdjustment.headroomHighlights(
            contentHeadroom: 1.5, window: wide), 0)
        // The same headroom against a negative's +2 window is excess and must recover.
        let negative: (shadows: Float, highlights: Float) = (-3, 2)
        XCTAssertLessThan(AutoAdjustment.headroomHighlights(
            contentHeadroom: 1.5, window: negative), 0)
    }

    func testRecoveryGrowsWithDeclaredHeadroomAndStaysInRange() {
        let window: (shadows: Float, highlights: Float) = (-3, 2)
        var previous: Float = 0
        for headroom in [Float](arrayLiteral: 2, 4, 8, 16) {
            let value = AutoAdjustment.headroomHighlights(
                contentHeadroom: headroom, window: window)
            XCTAssertLessThanOrEqual(value, previous,
                                     "more declared range must never ask for less recovery")
            XCTAssertGreaterThanOrEqual(value, -1)
            previous = value
        }
        // Doubling over a two-stop window already asks, quadrupling asks for more, and
        // eightfold headroom exhausts the control (measured: -0.44, -0.79, -1).
        XCTAssertLessThan(AutoAdjustment.headroomHighlights(
            contentHeadroom: 2, window: window), -0.1)
        XCTAssertLessThan(
            AutoAdjustment.headroomHighlights(contentHeadroom: 4, window: window),
            AutoAdjustment.headroomHighlights(contentHeadroom: 2, window: window))
        XCTAssertEqual(previous, -1)
    }

    // MARK: The developed print

    private func developedGreen(
        _ exposure: Float, stock: FilmStock, headroom: Float,
        _ gpu: HalideMetalFilmRenderer
    ) throws -> Float {
        let side = 64
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.sceneHeadroom = headroom
        var pixels = [Float](repeating: 1, count: side * side * 4)
        for index in 0..<(side * side) {
            pixels[index * 4] = exposure
            pixels[index * 4 + 1] = exposure
            pixels[index * 4 + 2] = exposure
        }
        let print = try XCTUnwrap(gpu.processLinearFloat(
            pixels, width: side, height: side, stock: stock,
            options: options, memoryBudget: 96 << 20))
        return print[((side / 2) * side + side / 2) * 4 + 1]
    }

    func testDeclaredHeadroomKeepsHDRStopsSeparatedOnThePrint() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        for stock in [TestStocks.negative, TestStocks.reversal] {
            let flatLow = try developedGreen(3, stock: stock, headroom: 1, gpu)
            let flatHigh = try developedGreen(6, stock: stock, headroom: 1, gpu)
            let placedLow = try developedGreen(3, stock: stock, headroom: 6, gpu)
            let placedHigh = try developedGreen(6, stock: stock, headroom: 6, gpu)
            let flatGap = flatHigh - flatLow
            let placedGap = placedHigh - placedLow
            print("HEADROOM \(stock.name): flat \(flatLow)/\(flatHigh) gap \(flatGap), "
                  + "placed \(placedLow)/\(placedHigh) gap \(placedGap)")
            // BT.2446's requirement of a tone mapping is exactly this: tonal separation
            // survives up to the content peak instead of ending in a clip. Measured, the
            // placement reopens the one-stop gap 6.1x on the negative (0.015 -> 0.092,
            // where the print had flattened) and 1.40x on the reversal (0.180 -> 0.252,
            // whose own shoulder still separated); 1.25 sits under the weaker of the two
            // without flaking on either.
            XCTAssertGreaterThan(
                placedGap, flatGap * 1.25,
                "\(stock.name): placement did not reopen highlight separation "
                + "(flat \(flatGap), placed \(placedGap))")
            XCTAssertLessThan(placedHigh, flatHigh,
                              "\(stock.name): the brightest light did not come down")
        }
    }

    func testMidGreyStaysAnchoredUnderDeclaredHeadroom() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        for stock in [TestStocks.negative, TestStocks.reversal] {
            let flat = try developedGreen(0.18, stock: stock, headroom: 1, gpu)
            let placed = try developedGreen(0.18, stock: stock, headroom: 6, gpu)
            XCTAssertEqual(placed, flat, accuracy: 0.02,
                           "\(stock.name): mid-grey moved under headroom placement")
        }
    }

    func testSDRDevelopIsUntouchedByTheWiring() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let side = 48
        var pixels = [Float](repeating: 1, count: side * side * 4)
        for index in 0..<(side * side) {
            let value = Float(index % side) / Float(side - 1) * 1.5
            pixels[index * 4] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
        }
        var plain = FotufilmEngine.Options()
        plain.grainScale = 0
        var declared = plain
        declared.sceneHeadroom = 1
        let before = try XCTUnwrap(gpu.processLinearFloat(
            pixels, width: side, height: side, stock: TestStocks.negative,
            options: plain, memoryBudget: 96 << 20))
        let after = try XCTUnwrap(gpu.processLinearFloat(
            pixels, width: side, height: side, stock: TestStocks.negative,
            options: declared, memoryBudget: 96 << 20))
        XCTAssertEqual(before, after, "headroom 1 must not change a single value")
    }

    // MARK: The no-film path

    func testPlainDevelopSharesTheHeadroomPlacement() {
        var options = FotufilmEngine.Options()
        options.sceneHeadroom = 1
        XCTAssertEqual(PlainDevelop(options: options).highlights, 0,
                       "headroom 1 must leave the no-film develop untouched")
        options.sceneHeadroom = 2
        let placed = PlainDevelop(options: options).highlights
        XCTAssertLessThan(placed, 0, "a declared range must engage the shaping")
        options.sceneHeadroom = 4
        let wider = PlainDevelop(options: options).highlights
        XCTAssertLessThan(wider, placed, "a wider range must pull harder")
        // The shaping stacks under what the user asked for and stays inside the control.
        options.highlights = -1
        XCTAssertEqual(PlainDevelop(options: options).highlights, -1)
    }
}
#endif
