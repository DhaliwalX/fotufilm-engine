import XCTest
@testable import FotufilmCore

final class LabScanTimingTests: XCTestCase {
    private func scanDensity(_ stock: FilmStock, read: Float, scale: Float, shift: Float) -> Float {
        let curve = PrintPaper.labScan.printCurve(for: stock)
        let mid = PrintPaper.labScan.printExposureMidpoints(for: stock)[1]
        return curve.density(logExposure: mid + shift + scale * read) - curve.dMin
    }

    func testUnmeteredFrameScansAtTheFixedProfile() throws {
        let film = try XCTUnwrap(FilmStock.named("portra400"))
        let levels = LabScanTiming.levels(for: film, sceneHighlightStops: nil)
        XCTAssertEqual(levels.scale, .one)
        XCTAssertEqual(levels.shift, 0)
    }

    func testDenseFrameShiftsItsHighlightToWhiteAtTheStockContrast() throws {
        for id in ["portra400", "gold200"] {
            let film = try XCTUnwrap(FilmStock.named(id), id)
            let levels = LabScanTiming.levels(for: film, sceneHighlightStops: 6)
            XCTAssertEqual(levels.scale.y, 1, id)
            let high = LabScanTiming.reads(for: film, stops: 6).y
            XCTAssertEqual(scanDensity(film, read: high, scale: 1, shift: levels.shift),
                           LabScanTiming.whiteDensity, accuracy: 0.005, id)
            // Its base scans at or past black, so red and blue keep close to the green contrast.
            XCTAssertLessThan(levels.scale.x, 1.1, id)
            XCTAssertLessThan(levels.scale.z, 1.1, id)
        }
    }

    func testThinFrameKeepsItsBaseBlackWithinTheStretch() throws {
        for id in ["portra400", "gold200"] {
            let film = try XCTUnwrap(FilmStock.named(id), id)
            for stops: Float in [-2, 0, 1] {
                let levels = LabScanTiming.levels(for: film, sceneHighlightStops: stops)
                XCTAssertGreaterThan(levels.scale.y, 1, "\(id) \(stops)")
                XCTAssertLessThanOrEqual(levels.scale.y, LabScanTiming.maxStretch, "\(id) \(stops)")
                let base = LabScanTiming.reads(for: film, stops: nil)
                for c in 0..<3 {
                    XCTAssertGreaterThanOrEqual(levels.scale[c], levels.scale.y)
                    XCTAssertGreaterThanOrEqual(
                        scanDensity(film, read: base[c], scale: levels.scale[c], shift: levels.shift),
                        LabScanTiming.blackDensity - 0.01, "\(id) \(stops) record \(c)")
                }
            }
        }
    }

    func testExposureStillActsOnTheScan() throws {
        let film = try XCTUnwrap(FilmStock.named("portra400"))
        let metered = LabScanTiming.levels(for: film, sceneHighlightStops: 5, exposureEV: 1)
        let unexposed = LabScanTiming.levels(for: film, sceneHighlightStops: 4)
        XCTAssertEqual(metered.shift, unexposed.shift, accuracy: 1e-5)
        XCTAssertEqual(metered.scale.y, unexposed.scale.y, accuracy: 1e-5)
    }

    func testBacklitFrameOpensUpPartway() {
        XCTAssertEqual(LabScanTiming.highlight(.init(median: 0, bright: 2, dark: -3)), 2)
        XCTAssertEqual(LabScanTiming.highlight(.init(median: 0, bright: 5, dark: -3)), 4)
        XCTAssertEqual(LabScanTiming.highlight(.init(median: -6, bright: 4, dark: -9)), 2)
    }

    func testFrameInsideThePrintIsNotDodged() {
        let dodge = LabScanTiming.dodge(.init(median: 0, bright: 2, dark: -3))
        XCTAssertEqual(dodge.hold, 0)
        XCTAssertEqual(dodge.lift, 0)
        XCTAssertEqual(LabScanTiming.meteredHighlight(.init(median: 0, bright: 2, dark: -3)), 2)
    }

    func testWideFrameHoldsItsHighlightsAndLiftsItsShadowsAboutItsMedian() {
        let partial = LabScanTiming.dodge(.init(median: 1, bright: 5, dark: -4))
        XCTAssertEqual(partial.key, 1)
        XCTAssertEqual(partial.hold, LabScanTiming.dodgeMaxHold * 1.5 / 3, accuracy: 1e-6)
        XCTAssertEqual(partial.lift, LabScanTiming.dodgeMaxLift * 1.5 / 3, accuracy: 1e-6)
        let full = LabScanTiming.dodge(.init(median: 0, bright: 9, dark: -9))
        XCTAssertEqual(full.hold, LabScanTiming.dodgeMaxHold)
        XCTAssertEqual(full.lift, LabScanTiming.dodgeMaxLift)
        // The white point is set on the highlight as the hold prints it: four stops, opened up
        // to 3.5 for the backlight, then held.
        let scene = AutoAdjustment.SceneStops(median: 0, bright: 4, dark: -2)
        let reach: Float = 3.5 / 6
        let hold = LabScanTiming.dodgeMaxHold * 1.5 / 3
        XCTAssertEqual(LabScanTiming.meteredHighlight(scene),
                       3.5 - 3 * hold * reach * reach * (3 - 2 * reach), accuracy: 1e-5)
    }

    func testDodgeKeysTheToneGridRegionallyOnTheMedian() throws {
        let film = try XCTUnwrap(FilmStock.named("portra400"))
        var options = FotufilmEngine.Options()
        options.paper = .labScan
        var invocation = try FilmEngineInvocation(validating: film, options: options,
                                                  width: 64, height: 64)
        // A dim room, a window eight stops brighter and a deep corner: wider than a print.
        var plane = [Float](repeating: 0.05, count: 64 * 64)
        for y in 0..<24 { for x in 0..<24 { plane[y * 64 + x] = 12 } }
        for y in 48..<64 { for x in 48..<64 { plane[y * 64 + x] = 0.0005 } }
        plane.withUnsafeBufferPointer { values in
            invocation.measureToneBase(planarR: values.baseAddress!, g: values.baseAddress!,
                                       b: values.baseAddress!, width: 64, height: 64)
        }
        XCTAssertTrue(invocation.toneKeyedLocally)
        XCTAssertFalse(invocation.toneControlsActive, "the dodge is not the user's tone")
        let adjust = FilmEngineInvocation.sceneAdjustOffset
        XCTAssertLessThan(invocation.configuration[adjust], 0)
        XCTAssertGreaterThan(invocation.configuration[adjust + 1], 0)
        XCTAssertGreaterThan(invocation.configuration[FilmEngineInvocation.toneGridSizeOffset], 1)
        // Keyed on the median: the room the median sits in reads near zero.
        let width = Int(invocation.configuration[FilmEngineInvocation.toneGridSizeOffset])
        let cell = 40 * width / 64 * width + 20 * width / 64
        let roomStops = log2(0.05 / 0.18 * ColorScience.luminanceWeights.0
                             + 0.05 / 0.18 * ColorScience.luminanceWeights.1
                             + 0.05 / 0.18 * ColorScience.luminanceWeights.2)
        let keyed = invocation.configuration[FilmEngineInvocation.toneGridAOffset + cell] * roomStops
            + invocation.configuration[FilmEngineInvocation.toneGridBOffset + cell]
        XCTAssertEqual(keyed, 0, accuracy: 0.5)
    }

    func testOnlyNegativesOnLabScanMeter() throws {
        let negative = try XCTUnwrap(FilmStock.named("portra400"))
        var options = FotufilmEngine.Options()
        options.paper = .labScan
        let scan = try FilmEngineInvocation(validating: negative, options: options, width: 64, height: 64)
        XCTAssertTrue(scan.sceneMeteringActive)
        options.paper = .ektacolorEdge
        let print = try FilmEngineInvocation(validating: negative, options: options, width: 64, height: 64)
        XCTAssertFalse(print.sceneMeteringActive && !print.localToneActive)
    }
}
