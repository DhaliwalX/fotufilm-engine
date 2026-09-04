import Foundation
@testable import FotufilmCore
@testable import FotufilmImaging

enum PrintDifference {

    enum ITP {
        // BT.2100 PQ constants.
        private static let m1 = 0.1593017578125
        private static let m2 = 78.84375
        private static let c1 = 0.8359375
        private static let c2 = 18.8515625
        private static let c3 = 18.6875

        static let referenceWhiteNits = 100.0

        static func pq(_ nits: Double) -> Double {
            let y = pow(max(nits, 0) / 10000, m1)
            return pow((c1 + c2 * y) / (1 + c3 * y), m2)
        }

        static func ictcp(_ r: Double, _ g: Double, _ b: Double)
            -> (i: Double, ct: Double, cp: Double) {
            let m = HLGTransfer.displayP3ToRec2020
            let wide = (
                Double(m[0]) * r + Double(m[1]) * g + Double(m[2]) * b,
                Double(m[3]) * r + Double(m[4]) * g + Double(m[5]) * b,
                Double(m[6]) * r + Double(m[7]) * g + Double(m[8]) * b)
            let scale = referenceWhiteNits
            let l = (1688 * wide.0 + 2146 * wide.1 + 262 * wide.2) / 4096 * scale
            let mid = (683 * wide.0 + 2951 * wide.1 + 462 * wide.2) / 4096 * scale
            let s = (99 * wide.0 + 309 * wide.1 + 3688 * wide.2) / 4096 * scale
            let lp = pq(l), mp = pq(mid), sp = pq(s)
            return (i: 0.5 * lp + 0.5 * mp,
                    ct: (6610 * lp - 13613 * mp + 7003 * sp) / 4096,
                    cp: (17933 * lp - 17390 * mp - 543 * sp) / 4096)
        }

        static func between(_ a: (Double, Double, Double),
                            _ b: (Double, Double, Double)) -> Double {
            let x = ictcp(a.0, a.1, a.2)
            let y = ictcp(b.0, b.1, b.2)
            let di = x.i - y.i
            let dt = 0.5 * (x.ct - y.ct)
            let dp = x.cp - y.cp
            return 720 * (di * di + dt * dt + dp * dp).squareRoot()
        }
    }

    static func displayLinear(_ code: UInt8) -> Double {
        Double(ColorScience.srgbToLinear(Float(code) / 255))
    }

    static func opponent(_ r: Double, _ g: Double, _ b: Double)
        -> (luma: Double, cb: Double, cr: Double) {
        let w = HLGTransfer.displayP3Luminance
        let luma = Double(w.x) * r + Double(w.y) * g + Double(w.z) * b
        return (luma, b - luma, r - luma)
    }

    struct Spread {
        var mean = 0.0
        var worst = 0.0
        var p999 = 0.0
        var worstAt = (x: 0, y: 0)

        fileprivate var samples: [Double] = []

        mutating func add(_ value: Double, x: Int = 0, y: Int = 0) {
            if value > worst {
                worst = value
                worstAt = (x, y)
            }
            samples.append(value)
        }

        mutating func finish() {
            guard !samples.isEmpty else { return }
            mean = samples.reduce(0, +) / Double(samples.count)
            let sorted = samples.sorted()
            let rank = Int((0.999 * Double(sorted.count - 1)).rounded())
            p999 = sorted[rank]
            samples = []
        }

        func percentAbove(_ threshold: Double) -> Double {
            guard !samples.isEmpty else { return 0 }
            let over = samples.filter { $0 > threshold }.count
            return 100 * Double(over) / Double(samples.count)
        }
    }

    struct Report {
        var channel = Spread()
        var percentOverOneCode = 0.0
        var deltaITP = Spread()
        var luma = Spread()
        var chroma = Spread()
        var goldenSpan = (darkest: 255, brightest: 0)

        var oneLine: String {
            String(format:
                "channel worst %.0f at (%d,%d) over-1-code %.3f%% | "
                + "dE-ITP mean %.2f p99.9 %.2f worst %.2f | "
                + "luma mean %.2f worst %.2f | chroma mean %.2f worst %.2f",
                channel.worst, channel.worstAt.x, channel.worstAt.y,
                percentOverOneCode,
                deltaITP.mean, deltaITP.p999, deltaITP.worst,
                luma.mean, luma.worst, chroma.mean, chroma.worst)
        }
    }

    static func compare(golden: RGBAImage, against current: RGBAImage)
        -> Report {
        precondition(golden.width == current.width
                     && golden.height == current.height,
                     "size mismatch is a caller error, not a difference")
        var report = Report()
        var channel = Spread(), deltaITP = Spread()
        var luma = Spread(), chroma = Spread()
        for y in 0..<golden.height {
            for x in 0..<golden.width {
                let i = (y * golden.width + x) * 4
                let g = (golden.pixels[i], golden.pixels[i + 1],
                         golden.pixels[i + 2])
                let c = (current.pixels[i], current.pixels[i + 1],
                         current.pixels[i + 2])
                for (a, b) in [(g.0, c.0), (g.1, c.1), (g.2, c.2)] {
                    channel.add(abs(Double(a) - Double(b)), x: x, y: y)
                }
                report.goldenSpan.darkest = min(
                    report.goldenSpan.darkest,
                    Int(g.0), Int(g.1), Int(g.2))
                report.goldenSpan.brightest = max(
                    report.goldenSpan.brightest,
                    Int(g.0), Int(g.1), Int(g.2))

                let gl = (displayLinear(g.0), displayLinear(g.1),
                          displayLinear(g.2))
                let cl = (displayLinear(c.0), displayLinear(c.1),
                          displayLinear(c.2))
                deltaITP.add(ITP.between(gl, cl), x: x, y: y)

                let go = opponent(Double(g.0), Double(g.1), Double(g.2))
                let co = opponent(Double(c.0), Double(c.1), Double(c.2))
                luma.add(abs(go.luma - co.luma), x: x, y: y)
                chroma.add(((go.cb - co.cb) * (go.cb - co.cb)
                            + (go.cr - co.cr) * (go.cr - co.cr))
                    .squareRoot(), x: x, y: y)
            }
        }
        report.percentOverOneCode = channel.percentAbove(1.0)
        channel.finish()
        deltaITP.finish()
        luma.finish()
        chroma.finish()
        report.channel = channel
        report.deltaITP = deltaITP
        report.luma = luma
        report.chroma = chroma
        return report
    }
}
