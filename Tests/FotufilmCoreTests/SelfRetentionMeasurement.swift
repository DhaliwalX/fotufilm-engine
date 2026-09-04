import XCTest
@testable import FotufilmCore

final class SelfRetentionMeasurement: XCTestCase {

    func testReportSelfRetentionCost() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FOTUFILM_MEASURE"] != nil,
                          "set FOTUFILM_MEASURE=1 to run the measurement")

        let charts = ReferenceChart.all.filter { $0.name == "gamut" || $0.name == "spatial" }
        XCTAssertEqual(charts.count, 2, "both charts must be present to compare them")

        let stocks = GoldenStocks.all.filter { $0.stock.couplerGeometry != nil }
        XCTAssertFalse(stocks.isEmpty, "no stock with geometry loaded")

        var rows: [String] = []
        for chart in charts {
            for entry in stocks {
                guard let geometry = entry.stock.couplerGeometry else { continue }

                var raised = entry.stock
                raised.couplerGeometry?.selfRetention = 1

                let before = RGBAImage(print: develop(chart, with: entry.stock))
                let after = RGBAImage(print: develop(chart, with: raised))
                let report = PrintDifference.compare(golden: before, against: after)

                // With no lateral spread, `blur(a) == a`, so anything left is the diagonal acting
                // on flat colour rather than across an edge. If the self term really were an edge
                // effect this column would be zero.
                var flatBefore = entry.stock
                flatBefore.couplerDiffusionMM = 0
                var flatAfter = raised
                flatAfter.couplerDiffusionMM = 0
                let flat = PrintDifference.compare(
                    golden: RGBAImage(print: develop(chart, with: flatBefore)),
                    against: RGBAImage(print: develop(chart, with: flatAfter)))

                rows.append(String(
                    format: "%-9@ %-22@ self %.4f -> 1.0  dE p99.9 %6.2f  worst %6.2f"
                        + "  | no lateral spread: p99.9 %6.2f",
                    chart.name as NSString, entry.id as NSString,
                    Double(geometry.selfRetention),
                    report.deltaITP.p999, report.deltaITP.worst,
                    flat.deltaITP.p999))
            }
        }

        print("=== selfRetention 0.091 vs 1.0 (gate for reference: dE ITP p99.9 < 1.0) ===")
        for row in rows.sorted() { print(row) }
    }

    private func develop(_ chart: ReferenceChart, with stock: FilmStock) -> ImageBuffer {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        return FotufilmEngine(stock: stock, options: options)
            .process(linearRGB: chart.image)
    }
}
