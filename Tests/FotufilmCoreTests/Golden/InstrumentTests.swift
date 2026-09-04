import XCTest
@testable import FotufilmCore

final class GoldenInstrumentTests: XCTestCase {

    func testPNGRoundTripIsByteExact() throws {
        var image = RGBAImage(width: 37, height: 11)
        for i in 0..<(37 * 11) {
            image.pixels[i * 4] = UInt8(truncatingIfNeeded: i)
            image.pixels[i * 4 + 1] = UInt8(truncatingIfNeeded: i * 7)
            image.pixels[i * 4 + 2] = UInt8(truncatingIfNeeded: 255 - i)
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("golden-roundtrip-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try image.pngData().write(to: url)
        let read = try RGBAImage.read(url)

        XCTAssertEqual(read.width, image.width)
        XCTAssertEqual(read.height, image.height)
        XCTAssertEqual(read.pixels, image.pixels,
                       "a PNG round trip changed the pixels, so every golden "
                       + "comparison is measuring ImageIO rather than the render")
    }

    func testComparisonIsZeroOnlyForIdenticalImages() throws {
        var a = RGBAImage(width: 16, height: 16)
        for i in 0..<(16 * 16) {
            a.pixels[i * 4] = UInt8(i)
            a.pixels[i * 4 + 1] = UInt8(255 - i)
            a.pixels[i * 4 + 2] = 128
        }
        let same = PrintDifference.compare(golden: a, against: a)
        XCTAssertEqual(same.channel.worst, 0)
        XCTAssertEqual(same.deltaITP.worst, 0)
        XCTAssertEqual(same.percentOverOneCode, 0)

        var b = a
        b.pixels[40 * 4 + 1] = b.pixels[40 * 4 + 1] &+ 4
        let moved = PrintDifference.compare(golden: a, against: b)
        XCTAssertEqual(moved.channel.worst, 4)
        XCTAssertGreaterThan(moved.deltaITP.worst, 0)
    }

    func testPQAnchors() {
        XCTAssertEqual(PrintDifference.ITP.pq(10000), 1, accuracy: 1e-9)
        XCTAssertLessThan(PrintDifference.ITP.pq(0), 1e-5)
        XCTAssertGreaterThanOrEqual(PrintDifference.ITP.pq(0), 0)
        var previous = -1.0
        for nits in stride(from: 0.0, through: 10000.0, by: 37.0) {
            let value = PrintDifference.ITP.pq(nits)
            XCTAssertGreaterThan(value, previous, "PQ is not monotone at \(nits)")
            previous = value
        }
    }

    func testDeltaITPIsAMetric() {
        let grey = (0.18, 0.18, 0.18)
        XCTAssertEqual(PrintDifference.ITP.between(grey, grey), 0,
                       accuracy: 1e-9)
        let other = (0.20, 0.18, 0.17)
        XCTAssertEqual(PrintDifference.ITP.between(grey, other),
                       PrintDifference.ITP.between(other, grey),
                       accuracy: 1e-9)
        var previous = 0.0
        for step in stride(from: 0.002, through: 0.05, by: 0.002) {
            let far = (0.18 + step, 0.18, 0.18)
            let value = PrintDifference.ITP.between(grey, far)
            XCTAssertGreaterThan(value, previous,
                                 "ΔE ITP did not grow at step \(step)")
            previous = value
        }
    }

    func testDeltaITPScalingOnTheNeutralAxis() {
        let a = (0.18, 0.18, 0.18), b = (0.22, 0.22, 0.22)
        let ia = PrintDifference.ITP.ictcp(a.0, a.1, a.2).i
        let ib = PrintDifference.ITP.ictcp(b.0, b.1, b.2).i
        let expected = 720 * abs(ia - ib)
        XCTAssertEqual(PrintDifference.ITP.between(a, b), expected,
                       accuracy: expected * 0.02,
                       "ΔE ITP on a neutral pair must be 720·ΔI")
        XCTAssertGreaterThan(expected, 0)
        let neutral = PrintDifference.ITP.ictcp(0.18, 0.18, 0.18)
        XCTAssertEqual(neutral.ct, 0, accuracy: 1e-4)
        XCTAssertEqual(neutral.cp, 0, accuracy: 1e-4)
    }

    func testOneCodeAtMidGreyIsAboutOneJND() {
        let low = PrintDifference.displayLinear(128)
        let high = PrintDifference.displayLinear(129)
        let delta = PrintDifference.ITP.between((low, low, low),
                                                (high, high, high))
        XCTAssertGreaterThan(delta, 0.1,
                             "one code at mid grey scored \(delta), which is "
                             + "far below a JND — the metric is underscaled")
        XCTAssertLessThan(delta, 10,
                          "one code at mid grey scored \(delta), which is far "
                          + "above a JND — the metric is overscaled")
        let full = PrintDifference.ITP.between((0, 0, 0), (1, 1, 1))
        XCTAssertGreaterThan(full, 100)
    }

    func testTheLumaChromaSplitSeparatesTheTwoKindsOfError() {
        let base = PrintDifference.opponent(120, 120, 120)
        let brighter = PrintDifference.opponent(130, 130, 130)
        XCTAssertEqual(abs(base.luma - brighter.luma), 10, accuracy: 0.01)
        XCTAssertEqual(abs(base.cb - brighter.cb), 0, accuracy: 0.01)
        XCTAssertEqual(abs(base.cr - brighter.cr), 0, accuracy: 0.01)

        let cast = PrintDifference.opponent(140, 120, 100)
        let neutralish = PrintDifference.opponent(120, 120, 120)
        let dLuma = abs(cast.luma - neutralish.luma)
        let dChroma = ((cast.cb - neutralish.cb) * (cast.cb - neutralish.cb)
                       + (cast.cr - neutralish.cr) * (cast.cr - neutralish.cr))
            .squareRoot()
        XCTAssertGreaterThan(dChroma, dLuma * 2,
                             "a colour cast read as mostly luma, so the split "
                             + "is not separating the two kinds of error")
    }

    func testReferenceChartsHaveTheStructureTheyClaim() {
        let checker = ReferenceChart.colorChecker
        XCTAssertEqual(checker.width, 144)
        XCTAssertEqual(checker.height, 96)
        XCTAssertEqual(Set(checker.zones).count, 24,
                       "the ColorChecker must have 24 distinct patches")
        var greys: [Float] = []
        for column in 0..<6 {
            let x = column * 24 + 12, y = 3 * 24 + 12
            let i = y * checker.width + x
            let r = checker.image.planes[0][i]
            let g = checker.image.planes[1][i]
            let b = checker.image.planes[2][i]
            XCTAssertEqual(r, g, accuracy: 0.01, "grey patch \(column) is not neutral")
            XCTAssertEqual(g, b, accuracy: 0.01, "grey patch \(column) is not neutral")
            greys.append(g)
        }
        XCTAssertEqual(greys, greys.sorted(by: >),
                       "the grey axis must descend from white to black")
        XCTAssertGreaterThan(greys.first!, 0.8)
        XCTAssertLessThan(greys.last!, 0.06)

        let wedge = ReferenceChart.stepWedge
        XCTAssertEqual(Set(wedge.zones).count, 21)
        var steps: [Float] = []
        for index in 0..<21 {
            let x = (index % 7) * 24 + 12, y = (index / 7) * 24 + 12
            steps.append(wedge.image.planes[1][y * wedge.width + x])
        }
        let ratio = pow(10.0 as Float, -0.15)
        for index in 1..<21 {
            XCTAssertEqual(steps[index] / steps[index - 1], ratio,
                           accuracy: 1e-4,
                           "wedge step \(index) is not 0.15 density below "
                           + "step \(index - 1)")
        }
        XCTAssertGreaterThan(steps.first!, 1.0, "the wedge must start in the "
                             + "headroom so the shoulder is swept")
        XCTAssertEqual(steps.first! / steps.last!, 1000, accuracy: 1,
                       "21 steps of 0.15 is 3.0 density, a factor of 1000")

        let gamut = ReferenceChart.gamut
        let specular = gamut.image.planes[1][(3 * 24 + 12) * gamut.width + 12]
        XCTAssertGreaterThan(specular, 1.0)

        let spatial = ReferenceChart.spatial
        let row = 16 * spatial.width
        let left = spatial.image.planes[1][row + 10]
        let right = spatial.image.planes[1][row + spatial.width - 10]
        XCTAssertGreaterThan(right / max(left, 1e-6), 50,
                             "the hard edge is not a hard edge")
        XCTAssertEqual(Set(spatial.zones).count, 4)
    }

    func testEveryReferencePictureIsDistinct() {
        let charts = ReferenceChart.all
        XCTAssertGreaterThanOrEqual(charts.count, 4)
        XCTAssertEqual(Set(charts.map(\.name)).count, charts.count,
                       "two reference pictures share a name, so one's golden "
                       + "would overwrite the other's")
        for (index, chart) in charts.enumerated() {
            for other in charts[(index + 1)...]
            where other.width == chart.width && other.height == chart.height {
                XCTAssertNotEqual(chart.image.planes, other.image.planes,
                                  "\(chart.name) and \(other.name) are the "
                                  + "same picture")
            }
        }
    }

    func testTheAmplifiedDifferenceIsVisible() {
        var a = RGBAImage(width: 4, height: 4)
        for i in 0..<16 { a.pixels[i * 4] = 100; a.pixels[i * 4 + 1] = 100 }
        var b = a
        b.pixels[1] = 101
        let diff = RGBAImage.amplifiedDifference(a, b, gain: 32)
        XCTAssertEqual(diff.pixels[1], 32,
                       "one code must amplify to something a screen shows")
        XCTAssertEqual(diff.pixels[0], 0, "an identical channel must stay black")
        var far = a
        far.pixels[0] = 250
        XCTAssertEqual(RGBAImage.amplifiedDifference(a, far, gain: 32).pixels[0],
                       255)
    }
}
