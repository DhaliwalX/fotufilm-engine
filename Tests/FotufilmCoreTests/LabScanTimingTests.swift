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
