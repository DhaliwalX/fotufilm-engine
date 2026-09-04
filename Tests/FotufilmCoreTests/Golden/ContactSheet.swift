import Foundation

enum ContactSheet {

    struct Entry {
        let chart: String
        let chartPurpose: String
        let stockID: String
        let stockName: String
        let current: RGBAImage
        let golden: RGBAImage?
        let report: PrintDifference.Report?
        let verdict: Verdict

        enum Verdict: String {
            case matched = "matched"
            case moved = "MOVED"
            case new = "new"
        }
    }

    static func write(_ entries: [Entry], to directory: URL,
                      thresholds: String, summary: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var html = header(summary: summary, thresholds: thresholds,
                          entries: entries)
        let charts = Array(Set(entries.map(\.chart))).sorted()
        for chart in charts {
            let group = entries.filter { $0.chart == chart }
                .sorted { a, b in
                    let rank: (Entry) -> Int = {
                        switch $0.verdict {
                        case .moved: return 0
                        case .new: return 1
                        case .matched: return 2
                        }
                    }
                    if rank(a) != rank(b) { return rank(a) < rank(b) }
                    return a.stockID < b.stockID
                }
            html += section(chart: chart, entries: group)
        }
        html += "</main>\n"
        let url = directory.appendingPathComponent("index.html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func header(summary: String, thresholds: String,
                               entries: [Entry]) -> String {
        let moved = entries.filter { $0.verdict == .moved }.count
        let new = entries.filter { $0.verdict == .new }.count
        let matched = entries.filter { $0.verdict == .matched }.count
        return """
        <title>Film stock goldens</title>
        <style>
        :root {
          color-scheme: light dark;
          --bg: #fbfbfa; --fg: #16150f; --dim: #6b6963;
          --line: #e0ded6; --card: #ffffff;
          --moved: #b3261e; --new: #8a6d00; --ok: #2b6a3f;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #14140f; --fg: #f0efe8; --dim: #9c9a92;
            --line: #302f28; --card: #1c1c16;
            --moved: #ff6a5e; --new: #e0b23c; --ok: #6fca8c;
          }
        }
        :root[data-theme="dark"] {
          --bg: #14140f; --fg: #f0efe8; --dim: #9c9a92;
          --line: #302f28; --card: #1c1c16;
          --moved: #ff6a5e; --new: #e0b23c; --ok: #6fca8c;
        }
        :root[data-theme="light"] {
          --bg: #fbfbfa; --fg: #16150f; --dim: #6b6963;
          --line: #e0ded6; --card: #ffffff;
          --moved: #b3261e; --new: #8a6d00; --ok: #2b6a3f;
        }
        body { margin: 0; background: var(--bg); color: var(--fg);
          font: 14px/1.5 ui-sans-serif, -apple-system, system-ui, sans-serif; }
        main { max-width: 1180px; margin: 0 auto; padding: 32px 20px 80px; }
        h1 { font-size: 22px; margin: 0 0 4px; letter-spacing: -0.01em; }
        h2 { font-size: 16px; margin: 40px 0 2px; }
        p.dim, .meta { color: var(--dim); margin: 0; }
        .tally { display: flex; gap: 18px; margin: 18px 0 6px;
          font-variant-numeric: tabular-nums; flex-wrap: wrap; }
        .tally b { font-size: 20px; display: block; font-weight: 650; }
        pre.thresholds { background: var(--card); border: 1px solid var(--line);
          border-radius: 8px; padding: 12px 14px; overflow-x: auto;
          font-size: 12px; color: var(--dim); margin: 14px 0 0; }
        .grid { display: grid; gap: 14px; margin-top: 16px;
          grid-template-columns: repeat(auto-fill, minmax(210px, 1fr)); }
        .card { background: var(--card); border: 1px solid var(--line);
          border-radius: 10px; padding: 10px; }
        .card.moved { border-color: var(--moved); }
        .name { font-weight: 620; margin-bottom: 1px; }
        .id { color: var(--dim); font-size: 11.5px;
          font-family: ui-monospace, monospace; }
        .frames { position: relative; margin: 8px 0 6px;
          border-radius: 6px; overflow: hidden; background: #000; }
        .frames img { display: block; width: 100%; height: auto;
          image-rendering: pixelated; }
        .frames img.golden { position: absolute; inset: 0; opacity: 0; }
        .frames:hover img.golden { opacity: 1; }
        .frames:hover img.now { opacity: 0; }
        .flip { position: absolute; right: 6px; bottom: 6px; font-size: 10px;
          letter-spacing: 0.04em; text-transform: uppercase;
          background: rgba(0,0,0,0.62); color: #fff; padding: 2px 6px;
          border-radius: 4px; pointer-events: none; }
        .diff { border-radius: 6px; overflow: hidden; background: #000; }
        .diff img { display: block; width: 100%; height: auto;
          image-rendering: pixelated; }
        .verdict { font-size: 11px; font-weight: 700; letter-spacing: 0.05em;
          text-transform: uppercase; }
        .verdict.moved { color: var(--moved); }
        .verdict.new { color: var(--new); }
        .verdict.matched { color: var(--ok); }
        table.m { width: 100%; border-collapse: collapse; margin-top: 7px;
          font-size: 11.5px; font-variant-numeric: tabular-nums; }
        table.m td { padding: 1px 0; }
        table.m td:first-child { color: var(--dim); }
        table.m td:last-child { text-align: right; }
        .legend { font-size: 12px; color: var(--dim); margin-top: 4px; }
        </style>
        <main>
        <h1>Film stock goldens</h1>
        <p class="dim">\(escape(summary))</p>
        <div class="tally">
          <div><b style="color:var(--moved)">\(moved)</b>moved</div>
          <div><b style="color:var(--new)">\(new)</b>new</div>
          <div><b style="color:var(--ok)">\(matched)</b>matched</div>
        </div>
        <p class="legend">Hover a tile to flip between this run and the
        committed golden. The strip beneath is the absolute difference,
        amplified 32&times; — black means identical.</p>
        <pre class="thresholds">\(escape(thresholds))</pre>

        """
    }

    private static func section(chart: String, entries: [Entry]) -> String {
        var html = """
        <h2>\(escape(chart))</h2>
        <p class="meta">\(escape(entries.first?.chartPurpose ?? ""))</p>
        <div class="grid">

        """
        for entry in entries { html += card(entry) }
        return html + "</div>\n"
    }

    private static func card(_ entry: Entry) -> String {
        var frames = """
        <div class="frames"><img class="now" src="\(dataURI(entry.current))" alt="">
        """
        if let golden = entry.golden {
            frames += """
            <img class="golden" src="\(dataURI(golden))" alt="">\
            <span class="flip">hover: golden</span>
            """
        }
        frames += "</div>"

        var diff = ""
        if let golden = entry.golden {
            let amplified = RGBAImage.amplifiedDifference(
                golden, entry.current, gain: 32)
            diff = """
            <div class="diff"><img src="\(dataURI(amplified))" alt=""></div>
            """
        }

        var metrics = ""
        if let report = entry.report {
            metrics = """
            <table class="m">
            <tr><td>worst channel</td><td>\(fmt(report.channel.worst, 0)) \
            codes at \(report.channel.worstAt.x),\(report.channel.worstAt.y)</td></tr>
            <tr><td>over 1 code</td><td>\(fmt(report.percentOverOneCode, 3))%</td></tr>
            <tr><td>&Delta;E ITP p99.9</td><td>\(fmt(report.deltaITP.p999, 2))</td></tr>
            <tr><td>&Delta;E ITP worst</td><td>\(fmt(report.deltaITP.worst, 2))</td></tr>
            <tr><td>luma / chroma</td><td>\(fmt(report.luma.worst, 2)) / \
            \(fmt(report.chroma.worst, 2))</td></tr>
            </table>
            """
        }

        return """
        <div class="card \(entry.verdict == .moved ? "moved" : "")">
          <div class="name">\(escape(entry.stockName))</div>
          <div class="id">\(escape(entry.stockID))</div>
          \(frames)
          \(diff)
          <div class="verdict \(entry.verdict == .moved ? "moved"
              : entry.verdict == .new ? "new" : "matched")">\
        \(entry.verdict.rawValue)</div>
          \(metrics)
        </div>

        """
    }

    private static func dataURI(_ image: RGBAImage) -> String {
        guard let data = try? image.pngData() else { return "" }
        return "data:image/png;base64," + data.base64EncodedString()
    }

    private static func fmt(_ value: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", value)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
