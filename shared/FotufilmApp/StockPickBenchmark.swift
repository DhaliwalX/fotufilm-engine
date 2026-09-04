import CoreGraphics
import Dispatch
import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmStockMatch)
import FotufilmStockMatch
#endif

/// What the automatic film choice spends its time on.
enum StockPickBenchmark {

    /// Wall clock in milliseconds, per phase, for one pick.
    struct Timings: Sendable {
        var decode = 0.0
        var proxy = 0.0
        var detect = 0.0
        var read = 0.0
        var develop = 0.0
        var readback = 0.0
        var score = 0.0
        var films = 0
        var width = 0
        var height = 0

        var total: Double {
            decode + proxy + detect + read + develop + readback + score
        }

        /// Element-wise, not per run: the machine is shared and interference only adds time, so a
        /// hitch in one phase should not throw away a good measurement of the other five.
        func fastest(of other: Timings) -> Timings {
            var best = self
            best.decode = min(decode, other.decode)
            best.proxy = min(proxy, other.proxy)
            best.detect = min(detect, other.detect)
            best.read = min(read, other.read)
            best.develop = min(develop, other.develop)
            best.readback = min(readback, other.readback)
            best.score = min(score, other.score)
            best.films = max(films, other.films)
            best.width = max(width, other.width)
            best.height = max(height, other.height)
            return best
        }

        var report: [String] {
            func label(_ name: String) -> String {
                name.padding(toLength: 12, withPad: " ", startingAt: 0)
            }
            func line(_ name: String, _ ms: Double) -> String {
                let share = total > 0 ? 100 * ms / total : 0
                return String(format: "  %@ %7.2f ms  %5.1f%%",
                              label(name), ms, share)
            }
            let each = films > 0 ? (develop + readback) / Double(films) : 0
            return [
                line("decode", decode),
                line("proxy", proxy),
                line("detect", detect),
                line("scene read", read),
                line("develop", develop),
                line("readback", readback),
                line("score", score),
                String(format: "  %@ %7.2f ms  (%d films, %.2f ms each, %dx%d)",
                       label("total"), total, films, each, width, height),
            ]
        }
    }

    /// The warm-up matters: the first develop of a film builds its spectral tables and the first
    /// Vision request loads a model, neither of which is paid on the second photograph a user
    /// opens.
    static func run(source: PhotoSource, state: EditState = EditState(),
                    films: [StockPreset] = StockPreset.all,
                    longEdge: Int = StockSuggestion.scoringLongEdge,
                    runs: Int = 5, warmups: Int = 1) -> Timings? {
        for _ in 0..<max(0, warmups) {
            _ = once(source: source, state: state, films: films,
                     longEdge: longEdge)
        }
        var best: Timings?
        for _ in 0..<max(1, runs) {
            guard let pass = once(source: source, state: state, films: films,
                                  longEdge: longEdge)
            else { return nil }
            best = best.map { $0.fastest(of: pass) } ?? pass
        }
        return best
    }

    private static func once(source: PhotoSource, state: EditState,
                             films: [StockPreset], longEdge: Int) -> Timings? {
        var timings = Timings()

        let decodeStart = DispatchTime.now()
        guard let scene = FilmRender.scene(source: source, state: state,
                                           longEdge: longEdge)
        else { return nil }
        timings.decode = milliseconds(since: decodeStart)
        timings.width = scene.width
        timings.height = scene.height

        let proxyStart = DispatchTime.now()
        let proxy = StockSuggestion.subjectProxy(of: source)
        timings.proxy = milliseconds(since: proxyStart)

        let detectStart = DispatchTime.now()
        let subject = proxy.flatMap { SubjectMask.detect(in: $0) }
        timings.detect = milliseconds(since: detectStart)

        let readStart = DispatchTime.now()
        guard let measured = StockSuggestion.read(scene, subject: subject)
        else { return nil }
        timings.read = milliseconds(since: readStart)

        var develop = 0.0, readback = 0.0
        let rankStart = DispatchTime.now()
        let ranking = StockRanking.rank(
            scene: measured,
            films: films.map {
                StockRanking.Film(id: $0.id, name: $0.name, stock: $0.stock)
            },
            printCorrection: Float(state.printCorrection)
        ) { film, bytes, width, height in
            var edit = state
            edit.stockID = film.id
            let engineStart = DispatchTime.now()
            let developed = FilmRender.develop(scene, state: edit,
                                               dynamicRange: .sdr)
            develop += milliseconds(since: engineStart)
            guard let developed else { return false }
            let drawStart = DispatchTime.now()
            let drawn = StockSuggestion.draw(developed.image.image, into: bytes,
                                             width: width, height: height)
            readback += milliseconds(since: drawStart)
            return drawn
        }
        let rank = milliseconds(since: rankStart)

        timings.develop = develop
        timings.readback = readback
        timings.score = max(0, rank - develop - readback)
        timings.films = ranking.ordered.count
        return timings
    }

    private static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds
               - start.uptimeNanoseconds) / 1_000_000
    }
}
