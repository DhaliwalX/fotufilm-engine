import XCTest
@testable import FotufilmCore

final class GoldenImageTests: XCTestCase {

    static let codeThreshold = 1.0
    static let percentAllowed = 0.02
    static let hardFailCodes = 3.0
    static let visibleThreshold = 1.0

    private static var thresholdSummary: String {
        """
        channel difference    > \(codeThreshold) code fails a pixel
        pixels allowed past   \(percentAllowed)% of the frame
        hard fail             any channel off by \(hardFailCodes) codes
        dE ITP (BT.2124)      p99.9 < \(visibleThreshold)  (1.0 = specified JND)
        grain                 off — see the note in the test
        """
    }

    func testEveryStockMatchesItsGolden() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
        let mode = GoldenStore.Mode.current
        let stocks = GoldenStocks.all

        XCTAssertEqual(stocks.count, GoldenStocks.fileCount,
                       "the sweep loaded \(stocks.count) stocks but there are "
                       + "\(GoldenStocks.fileCount) stock files on disk — a "
                       + "stock that fails to load silently leaves the "
                       + "catalogue untested")
        XCTAssertGreaterThan(stocks.count, 1, "no stock pack loaded at all")

        let charts = ReferenceChart.all
        var entries: [ContactSheet.Entry] = []
        var moved: [String] = []
        var missing: [String] = []
        var rewritten = 0

        for chart in charts {
            for entry in stocks {
                let (id, stock) = (entry.id, entry.stock)
                let current = RGBAImage(print: develop(chart, with: stock))
                let golden = try GoldenStore.read(
                    visibility: entry.visibility, chart: chart.name, stock: id)
                let label = "\(chart.name)/\(id)"

                guard let golden else {
                    if mode == .update {
                        try GoldenStore.write(current, visibility: entry.visibility,
                                              chart: chart.name, stock: id)
                        rewritten += 1
                    } else {
                        missing.append(label)
                    }
                    entries.append(.init(
                        chart: chart.name, chartPurpose: chart.purpose,
                        stockID: id, stockName: stock.name, current: current,
                        golden: nil, report: nil, verdict: .new))
                    continue
                }

                guard golden.width == current.width,
                      golden.height == current.height else {
                    moved.append("\(label): golden is "
                                 + "\(golden.width)x\(golden.height), render is "
                                 + "\(current.width)x\(current.height)")
                    if mode == .update {
                        try GoldenStore.write(current, visibility: entry.visibility,
                                              chart: chart.name, stock: id)
                        rewritten += 1
                    }
                    entries.append(.init(
                        chart: chart.name, chartPurpose: chart.purpose,
                        stockID: id, stockName: stock.name, current: current,
                        golden: nil, report: nil, verdict: .moved))
                    continue
                }

                let report = PrintDifference.compare(golden: golden,
                                                     against: current)
                var reasons: [String] = []
                if report.percentOverOneCode > Self.percentAllowed {
                    reasons.append(String(
                        format: "%.3f%% of channels off by more than "
                        + "%.0f code", report.percentOverOneCode,
                        Self.codeThreshold))
                }
                if report.channel.worst >= Self.hardFailCodes {
                    reasons.append(String(
                        format: "a channel off by %.0f codes at (%d,%d)",
                        report.channel.worst,
                        report.channel.worstAt.x, report.channel.worstAt.y))
                }
                if report.deltaITP.p999 >= Self.visibleThreshold {
                    reasons.append(String(
                        format: "visible: dE ITP p99.9 %.2f",
                        report.deltaITP.p999))
                }

                if reasons.isEmpty {
                    entries.append(.init(
                        chart: chart.name, chartPurpose: chart.purpose,
                        stockID: id, stockName: stock.name, current: current,
                        golden: golden, report: report, verdict: .matched))
                } else {
                    moved.append("\(label): " + reasons.joined(separator: "; ")
                                 + " [\(report.oneLine)]")
                    if mode == .update {
                        try GoldenStore.write(current, visibility: entry.visibility,
                                              chart: chart.name, stock: id)
                        rewritten += 1
                    }
                    entries.append(.init(
                        chart: chart.name, chartPurpose: chart.purpose,
                        stockID: id, stockName: stock.name, current: current,
                        golden: golden, report: report, verdict: .moved))
                }
            }
        }

        let summary = "\(stocks.count) stocks × \(charts.count) reference "
            + "pictures = \(entries.count) renders"
        let page = try ContactSheet.write(
            entries, to: GoldenStore.reviewDirectory,
            thresholds: Self.thresholdSummary, summary: summary)
        print("GOLDEN \(summary)")
        print("GOLDEN review page: \(page.path)")

        if mode == .update {
            XCTFail("""
                rewrote \(rewritten) golden(s) from this run — \
                open \(page.path), confirm the renders are what you meant, \
                then run again without FOTUFILM_GOLDEN to check them
                """)
            return
        }

        if !missing.isEmpty {
            XCTFail("""
                \(missing.count) golden(s) do not exist, so nothing was \
                checked for them — generate with FOTUFILM_GOLDEN=update: \
                \(missing.prefix(8).joined(separator: ", "))\
                \(missing.count > 8 ? " …" : "")
                """)
        }
        for line in moved.prefix(20) { XCTFail(line) }
        XCTAssertTrue(moved.isEmpty,
                      "\(moved.count) render(s) moved — see \(page.path)")
    }

    private func develop(_ chart: ReferenceChart,
                         with stock: FilmStock) -> ImageBuffer {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        return FotufilmEngine(stock: stock, options: options)
            .process(linearRGB: chart.image)
    }
}
