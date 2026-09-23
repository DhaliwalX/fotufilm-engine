import XCTest
@testable import FotufilmCore

final class FilmGrainTests: XCTestCase {

    private static let stocks: [(String, FilmStock)] = [
        ("negative", TestStocks.negative), ("reversal", TestStocks.reversal),
        ("monochrome", TestStocks.monochrome),
    ]

    /// A flat developed negative at `net` above each record's base.
    private func flat(_ stock: FilmStock, net: Float, side: Int) -> ImageBuffer {
        ImageBuffer(width: side, height: side, planes: (0..<3).map { r in
            [Float](repeating: stock.curves[r].dMin + net, count: side * side)
        })
    }

    private func moments(_ values: [Float]) -> (mean: Float, sigma: Float, skew: Float) {
        let n = Float(values.count)
        let mean = values.reduce(0, +) / n
        var m2: Float = 0, m3: Float = 0
        for v in values { let d = v - mean; m2 += d * d; m3 += d * d * d }
        m2 /= n; m3 /= n
        return (mean, m2.squareRoot(), m2 > 0 ? m3 / pow(m2, 1.5) : 0)
    }

    func testNamedResolvesTheFilmModel() {
        XCTAssertEqual(GrainModel.named("film"), .film)
        XCTAssertEqual(GrainModel.named("real-film"), .film)
        XCTAssertEqual(GrainModel.film.title, "Film")
    }

    /// The grain is the fluctuation about the pipeline's developed density: the frame's mean
    /// stays on the curve at every density.
    func testToneStaysTheCurves() {
        for (name, stock) in Self.stocks {
            let grain = FilmGrain(stock: stock)
            for net: Float in [0.15, 0.6, 1.2] {
                let negative = flat(stock, net: net, side: 160)
                // Four microns a pixel: a hundred blocks of the tile under the frame.
                let grained = grain.apply(to: negative, pxPerMM: 250, seed: 3)
                for r in 0..<3 {
                    let m = moments(grained.planes[r])
                    XCTAssertEqual(m.mean, negative.planes[r][0], accuracy: 0.015,
                                   "\(name) record \(r) at net \(net)")
                    XCTAssertGreaterThan(m.sigma, 0.005, "\(name) record \(r) at net \(net)")
                }
            }
        }
    }

    /// The grain reads the sheet: a flat frame at each record's read density, through the 48 µm
    /// aperture in transmittance as a microdensitometer reads it, gives the sheet's RMS
    /// granularity, whichever form the stock's clouds take.
    func testFramesReadTheSheet() {
        for (name, stock) in Self.stocks {
            let grain = FilmGrain(stock: stock)
            let side = 768
            for layer in stock.isMonochrome ? [1] : [0, 1, 2] {
                let model = CrystalGrainModel(stock: stock, layer: layer)
                let gross = stock.curves[layer].density(
                    logExposure: model.logExposure(netDensity: model.readNetDensity))
                let flat = ImageBuffer(width: side, height: side, planes: (0..<3).map { r in
                    [Float](repeating: r == layer ? gross : stock.curves[r].dMin + 0.5,
                            count: side * side)
                })
                let plane = grain.apply(to: flat, pxPerMM: 1000, seed: 11).planes[layer]
                let light = plane.map { pow(10, -$0) }
                let radius = 24
                var readings: [Float] = []
                for cy in stride(from: radius, to: side - radius, by: 12) {
                    for cx in stride(from: radius, to: side - radius, by: 12) {
                        var total: Float = 0, count: Float = 0
                        for dy in -radius...radius {
                            for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
                                total += light[(cy + dy) * side + cx + dx]; count += 1
                            }
                        }
                        readings.append(-log10(total / count))
                    }
                }
                let sigma = moments(readings).sigma
                XCTAssertEqual(sigma / model.readSigma, 1, accuracy: 0.15,
                               "\(name) record \(layer): \(sigma) against \(model.readSigma)")
            }
        }
    }

    func testSameSeedSameFilm() {
        let stock = TestStocks.negative
        let grain = FilmGrain(stock: stock)
        let negative = flat(stock, net: 0.6, side: 64)
        let a = grain.apply(to: negative, pxPerMM: 2000, seed: 9)
        let b = grain.apply(to: negative, pxPerMM: 2000, seed: 9)
        let c = grain.apply(to: negative, pxPerMM: 2000, seed: 10)
        XCTAssertEqual(a.planes, b.planes)
        XCTAssertNotEqual(a.planes, c.planes)
    }

    /// The crystals sit on the film, not on the pixels: the same film rendered four times finer
    /// and averaged back — as light, the way the coarse pixels are formed — is the coarse render.
    func testEveryResolutionSamplesTheSameFilm() {
        let stock = TestStocks.negative
        let grain = FilmGrain(stock: stock)
        let coarse = grain.apply(to: flat(stock, net: 0.6, side: 64), pxPerMM: 1000, seed: 5)
        let fine = grain.apply(to: flat(stock, net: 0.6, side: 256), pxPerMM: 4000, seed: 5)
        for r in 0..<3 {
            var averaged = [Float](repeating: 0, count: 64 * 64)
            for y in 0..<64 {
                for x in 0..<64 {
                    var transmitted: Float = 0
                    for j in 0..<4 { for i in 0..<4 {
                        transmitted += pow(10, -fine.planes[r][(y * 4 + j) * 256 + x * 4 + i])
                    } }
                    averaged[y * 64 + x] = -log10(transmitted / 16)
                }
            }
            let a = coarse.planes[r], b = averaged
            let ma = moments(a), mb = moments(b)
            var covariance: Float = 0
            for i in a.indices { covariance += (a[i] - ma.mean) * (b[i] - mb.mean) }
            let correlation = covariance / Float(a.count) / (ma.sigma * mb.sigma)
            XCTAssertGreaterThan(correlation, 0.9, "record \(r)")
        }
    }

    /// Where few crystals developed the field is sparse dense clouds on clear film — a heavy
    /// dark tail — and where most did it evens out.
    func testSparseCloudsGiveAHeavyTail() {
        let stock = TestStocks.negative
        let grain = FilmGrain(stock: stock)
        let thin = moments(grain.apply(to: flat(stock, net: 0.08, side: 160), pxPerMM: 4000,
                                       seed: 2).planes[1])
        let dense = moments(grain.apply(to: flat(stock, net: 1.2, side: 160), pxPerMM: 4000,
                                        seed: 2).planes[1])
        XCTAssertGreaterThan(thin.skew, 1, "thin skew \(thin.skew)")
        XCTAssertLessThan(dense.skew, thin.skew, "dense skew \(dense.skew)")
    }

    /// A silver grain is opaque, so the sheet's granularity read backwards through Nutting's
    /// `D = 0.434 n a` gives its projected area; for Tri-X that lands on the 0.3–2.5 µm grains
    /// photomicrographs of negative emulsions show (Mees, *The Theory of the Photographic
    /// Process*, Ch. XXIV).
    func testSilverGrainSizeFollowsFromTheSheet() throws {
        let stock = try XCTUnwrap(FilmStock.named("trix400"), "trix400")
        let grain = FilmGrain(stock: stock)
        let diameters = grain.records[1].sublayers.map { 2 * $0.halfCapacityRadiusMM * 1000 }
        XCTAssertFalse(diameters.isEmpty)
        XCTAssertLessThan(diameters.max() ?? 0, 2.5, "\(diameters)")
        XCTAssertGreaterThan(diameters.min() ?? 0, 0.1, "\(diameters)")
    }

    /// The Halide kernel samples the tiles exactly as `FilmGrain.apply` does: the same grain,
    /// pixel for pixel, laid on the developed density inside the engine's own graph.
    func testHalideKernelIsTheSwiftModel() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide required")
        for (name, stock) in Self.stocks {
            var options = FotufilmEngine.Options()
            options.grainModel = .film
            options.halationScale = 0
            options.seed = 0x1234_5678
            options.format = FilmFormat(name: "film grain bench", frameHeightMM: 0.4)
            var image = ImageBuffer(width: 200, height: 200)
            for c in 0..<3 { for i in 0..<image.pixelCount {
                image.planes[c][i] = 0.01 * pow(2, Float(i % 200) / 20)
            } }
            let grained = FotufilmEngine(stock: stock, options: options).developNegative(linearRGB: image)
            var plain = options; plain.grainScale = 0
            let clean = FotufilmEngine(stock: stock, options: plain).developNegative(linearRGB: image)
            let expected = FilmGrain.registered(stock: stock, reference: nil).grain
                .apply(to: clean, pxPerMM: 500, seed: 0x1234_5678)
            for r in 0..<3 {
                var worst: Float = 0, grain: Float = 0
                for i in 0..<image.pixelCount {
                    worst = max(worst, abs(grained.planes[r][i] - expected.planes[r][i]))
                    grain = max(grain, abs(expected.planes[r][i] - clean.planes[r][i]))
                }
                XCTAssertGreaterThan(grain, 0.01, "\(name) record \(r) lays grain")
                XCTAssertLessThan(worst, 2e-3, "\(name) record \(r)")
            }
        }
    }
}
