import XCTest
@testable import FotufilmCore

/// The lamp house: a condenser head reads a negative's densities at their Callier values and
/// prints it harder; a diffuser head is the null every sheet was measured in.
final class EnlargerTests: XCTestCase {
    private let stops: [Float] = Array(stride(from: Float(-3), through: 3, by: 0.5))

    private func contrast(_ scale: [Float]) -> Float {
        // Mean log-luminance slope per stop between -2 and +2 stops of mid-grey.
        let logs = scale.map { log2(max($0, 1e-6)) }
        let low = stops.firstIndex(of: -2)!, high = stops.firstIndex(of: 2)!
        return (logs[high] - logs[low]) / (stops[high] - stops[low])
    }

    func testADiffuserHeadIsTheIdentity() {
        for stock in [TestStocks.negative, TestStocks.monochrome, TestStocks.reversal] {
            let plain = SpectralRuntime.tables(for: stock)
            let diffuser = SpectralRuntime.tables(
                for: stock, callier: Enlarger.diffuser.callierCoefficient(
                    for: stock, paper: .default))
            XCTAssertEqual(SpectralRuntime.cacheIdentifier(for: stock),
                           SpectralRuntime.cacheIdentifier(for: stock, callier: 1))
            XCTAssertEqual(plain.filmOutput.values, diffuser.filmOutput.values)
            XCTAssertEqual(plain.paperOutput?.values, diffuser.paperOutput?.values)
        }
    }

    func testTheCoefficientFollowsTheImageMaterial() {
        let condenser = Enlarger.condenser
        XCTAssertEqual(condenser.callierCoefficient(for: TestStocks.monochrome, paper: .default),
                       Enlarger.silverCallierCoefficient)
        XCTAssertEqual(condenser.callierCoefficient(for: TestStocks.negative, paper: .default),
                       Enlarger.dyeCallierCoefficient)
        XCTAssertGreaterThan(Enlarger.silverCallierCoefficient, Enlarger.dyeCallierCoefficient)
        XCTAssertGreaterThan(Enlarger.dyeCallierCoefficient, 1)
    }

    func testRetainedSilverScattersLikeSilverNotLikeDye() {
        let stock = TestStocks.negative
        func printing(bleach: Float, callier: Float) -> [Float] {
            SpectralRuntime.tables(for: stock, paper: .default, bleachBypass: bleach,
                                   callier: callier).filmOutput.values
        }
        func spread(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        }
        let dye = Enlarger.dyeCallierCoefficient
        func headEffect(bleach: Float) -> Float {
            spread(printing(bleach: bleach, callier: dye), printing(bleach: bleach, callier: 1))
        }
        let plain = headEffect(bleach: 0)
        let some = headEffect(bleach: 0.3)
        let most = headEffect(bleach: 0.8)
        XCTAssertGreaterThan(some, plain,
                             "retained silver should carry the silver coefficient, not the dye's")
        XCTAssertGreaterThan(most, some, "more retained silver, more of the head")
        XCTAssertGreaterThan(most, plain * 2)
    }

    func testOnlyAnEnlargedReflectionPrintHasALampHouse() {
        let condenser = Enlarger.condenser
        // A reversal is its own positive; the paper is irrelevant.
        XCTAssertEqual(condenser.callierCoefficient(for: TestStocks.reversal, paper: .default), 1)
        // No optical enlargement: viewed negative, scans, the screen's direct read, and a
        // contact-printed release print.
        for paper in [PrintPaper.negative, .labScan, .telecine, .screen, .vision2383] {
            XCTAssertEqual(condenser.callierCoefficient(for: TestStocks.monochrome, paper: paper), 1,
                           "\(paper.id) has no enlarger in the path")
        }
        // Where nothing is illuminated the tables' identity does not move either.
        XCTAssertEqual(
            SpectralRuntime.cacheIdentifier(for: TestStocks.monochrome, paper: .screen),
            SpectralRuntime.cacheIdentifier(for: TestStocks.monochrome, paper: .screen,
                                            callier: Enlarger.silverCallierCoefficient))
    }

    func testACondenserHeadPrintsASilverNegativeHarderAndHoldsMidGrey() {
        let stock = TestStocks.monochrome
        let diffuser = SpectralRuntime.neutralToneScale(
            stops: stops, stock: stock, printCorrection: 0.05)
        let condenser = SpectralRuntime.neutralToneScale(
            stops: stops, stock: stock, printCorrection: 0.05,
            callier: Enlarger.silverCallierCoefficient)
        let mid = stops.firstIndex(of: 0)!
        XCTAssertEqual(condenser[mid], diffuser[mid], accuracy: diffuser[mid] * 0.02,
                       "the print re-times through the scaled mid-grey")
        let gain = contrast(condenser) / contrast(diffuser)
        XCTAssertGreaterThan(gain, 1.15, "a 1.4 Callier coefficient is a visible grade step")
        XCTAssertLessThan(gain, Enlarger.silverCallierCoefficient + 0.05,
                          "the paper's own shoulder bounds the gain at the coefficient")
    }

    func testACondenserHeadBarelyMovesADyeNegative() {
        let stock = TestStocks.negative
        let diffuser = SpectralRuntime.neutralToneScale(
            stops: stops, stock: stock, printCorrection: 0.05)
        let condenser = SpectralRuntime.neutralToneScale(
            stops: stops, stock: stock, printCorrection: 0.05,
            callier: Enlarger.dyeCallierCoefficient)
        let gain = contrast(condenser) / contrast(diffuser)
        XCTAssertGreaterThan(gain, 1.0)
        XCTAssertLessThan(gain, 1.10)
    }

    func testTheHeadNarrowsTheLatitudeItPrintsThrough() {
        let stock = TestStocks.monochrome
        let diffuser = AutoAdjustment.latitude(stock: stock)
        let condenser = AutoAdjustment.latitude(
            stock: stock, callier: Enlarger.silverCallierCoefficient)
        XCTAssertLessThanOrEqual(condenser.highlights - condenser.shadows,
                                 diffuser.highlights - diffuser.shadows)
    }
}
