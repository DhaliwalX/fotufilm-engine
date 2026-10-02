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

    func testFlatFrameKeepsItsKeyInsteadOfPrintingItsHighlightWhite() throws {
        let film = try XCTUnwrap(FilmStock.named("portra400"))
        // A frame whose brightest content is only two stops over its mid-grey median.
        let placed = LabScanTiming.levels(for: film, sceneHighlightStops: 2)
        let keyed = LabScanTiming.levels(for: film, sceneHighlightStops: 2, sceneMedianStops: 0)
        XCTAssertEqual(keyed.scale, placed.scale)
        XCTAssertGreaterThan(keyed.shift, placed.shift)
        // Its median scans where the fixed profile scans mid-grey.
        let median = LabScanTiming.reads(for: film, stops: 0).y
        XCTAssertEqual(scanDensity(film, read: median, scale: keyed.scale.y, shift: keyed.shift),
                       scanDensity(film, read: median, scale: 1, shift: 0), accuracy: 0.005)
        // The highlight then scans short of white.
        let high = LabScanTiming.reads(for: film, stops: 2).y
        XCTAssertGreaterThan(scanDensity(film, read: high, scale: keyed.scale.y, shift: keyed.shift),
                             LabScanTiming.whiteDensity + 0.05)
    }

    func testKeyTakesOutHalfAMisexposureAndNeverLiftsPastThePoints() throws {
        let film = try XCTUnwrap(FilmStock.named("portra400"))
        let fixed = { (stops: Float) in
            self.scanDensity(film, read: LabScanTiming.reads(for: film, stops: stops).y,
                             scale: 1, shift: 0)
        }
        // Two stops under: the median scans as one stop under would at the fixed profile.
        let under = LabScanTiming.levels(for: film, sceneHighlightStops: 0, sceneMedianStops: -2)
        XCTAssertEqual(scanDensity(film, read: LabScanTiming.reads(for: film, stops: -2).y,
                                   scale: under.scale.y, shift: under.shift),
                       fixed(-1), accuracy: 0.005)
        // A bright highlight bounds the key: the frame is never lighter than its placement.
        let wide = LabScanTiming.levels(for: film, sceneHighlightStops: 6, sceneMedianStops: -4)
        XCTAssertEqual(wide.shift, LabScanTiming.levels(for: film, sceneHighlightStops: 6).shift)
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
    }

    func testWideFrameHoldsItsHighlightsAndLiftsItsShadowsAboutItsMedian() {
        let partial = LabScanTiming.dodge(.init(median: 1, bright: 5, dark: -4))
        XCTAssertEqual(partial.key, 1)
        XCTAssertEqual(partial.hold, LabScanTiming.dodgeMaxHold
                       * (4 - LabScanTiming.dodgeHighlightSpan) / LabScanTiming.dodgeRamp,
                       accuracy: 1e-6)
        XCTAssertEqual(partial.lift, LabScanTiming.dodgeMaxLift
                       * (5 - LabScanTiming.dodgeShadowSpan) / LabScanTiming.dodgeRamp,
                       accuracy: 1e-6)
        // The strength scales both, and 0 turns the dodge off.
        let doubled = LabScanTiming.dodge(.init(median: 1, bright: 5, dark: -4), strength: 2)
        XCTAssertEqual(doubled.hold, 2 * partial.hold, accuracy: 1e-6)
        XCTAssertEqual(LabScanTiming.dodge(.init(median: 0, bright: 9, dark: -9), strength: 0).hold, 0)
        let full = LabScanTiming.dodge(.init(median: 0, bright: 9, dark: -9))
        XCTAssertEqual(full.hold, LabScanTiming.dodgeMaxHold)
        XCTAssertEqual(full.lift, LabScanTiming.dodgeMaxLift)
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
