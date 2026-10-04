import XCTest
@testable import FotufilmCore

final class FilmFrameGrainTests: XCTestCase {
    private func binding(_ id: String) throws -> FilmGrain.TileBinding {
        let stock = try XCTUnwrap(FilmStock.named(id))
        return FilmGrain.binding(stock: stock, reference: nil, checkCancellation: {})
    }

    /// A frame of gross density rising across it and down it, as interleaved RGBA.
    private func ramp(_ grain: FilmGrain, width: Int, height: Int) -> [Float] {
        var frame = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                for r in 0..<3 {
                    let record = grain.records[r]
                    let t = (Float(x) / Float(width) + Float(y) / Float(height)) / 2
                    frame[(y * width + x) * 4 + r] = record.dMin + 0.1 + t * (record.dMax - record.dMin) * 0.7
                }
            }
        }
        return frame
    }

    private func correlation(_ a: [Float], _ b: [Float]) -> Double {
        let ma = a.reduce(0.0) { $0 + Double($1) } / Double(a.count)
        let mb = b.reduce(0.0) { $0 + Double($1) } / Double(b.count)
        var ab = 0.0, aa = 0.0, bb = 0.0
        for i in a.indices {
            let x = Double(a[i]) - ma, y = Double(b[i]) - mb
            ab += x * y; aa += x * x; bb += y * y
        }
        return ab / (aa * bb).squareRoot()
    }

    /// At 1 µm pixels the frame renderer reads its texels one by one: the film the Swift
    /// reference lays, crystal by crystal, with no period.
    func testFrameGrainLaysTheReferenceFilm() throws {
        guard FilmGrain.laysFrameGrain else { throw XCTSkip("No Metal") }
        for (id, minimum) in [("portra400", 0.999), ("trix400", 0.995)] {
            let film = try binding(id)
            let grain = film.grain
            let width = 160, height = 120
            let frame = ramp(grain, width: width, height: height)
            let seed: UInt32 = 7
            let laid = try frame.withUnsafeBufferPointer { frame in
                try XCTUnwrap(film.frameGrain(density: frame, channels: 4, width: width, height: height,
                                              pxPerMM: 1000, amount: 1, look: FilmGrain.Look(),
                                              seed: seed, raw: true, shouldContinue: { true }))
            }
            for r in grain.monochrome ? [1] : [0, 1, 2] {
                let plane = (0..<(width * height)).map { frame[$0 * 4 + r] }
                var unused = [Float]()
                let reference = grain.render(
                    record: r, width: width, height: height, pxPerMM: 1000,
                    supersample: grain.frameSupersample(r), seed: FilmGrain.frameFilmSeed(seed),
                    grossAt: { x, y in FilmGrain.bilinear(plane, width, height, x, y) },
                    pointMeans: &unused, wantPointMeans: false)
                let rho = correlation(laid[r], reference)
                let worst = zip(laid[r], reference).map { abs($0 - $1) }.max() ?? 0
                XCTAssertGreaterThan(rho, minimum, "\(id) record \(r): worst \(worst)")
            }
        }
    }

    /// At a frame's own pitch the crystal-by-crystal grain is as strong as the tiles', and its
    /// mean over a flat frame is the developed density's.
    func testFrameGrainReadsAsTheTiles() throws {
        guard FilmGrain.laysFrameGrain else { throw XCTSkip("No Metal") }
        for id in ["portra400", "trix400"] {
            let film = try binding(id)
            let grain = film.grain
            let side = 384
            let pxPerMM: Float = 1000.0 / 6
            let flat = ImageBuffer(width: side, height: side, planes: (0..<3).map { r in
                [Float](repeating: grain.records[r].dMin + 0.8, count: side * side)
            })
            let tiled = grain.apply(to: flat, pxPerMM: pxPerMM, seed: 3)
            var frame = [Float](repeating: 1, count: side * side * 4)
            for i in 0..<(side * side) { for r in 0..<3 { frame[i * 4 + r] = flat.planes[r][i] } }
            let laid = try frame.withUnsafeBufferPointer { frame in
                try XCTUnwrap(film.frameGrain(density: frame, channels: 4, width: side, height: side,
                                              pxPerMM: pxPerMM, amount: 1, look: FilmGrain.Look(),
                                              seed: 3, shouldContinue: { true }))
            }
            for r in grain.monochrome ? [1] : [0, 1, 2] {
                let tiles = (0..<(side * side)).map { tiled.planes[r][$0] - flat.planes[r][$0] }
                func moments(_ v: [Float]) -> (Double, Double) {
                    let m = v.reduce(0.0) { $0 + Double($1) } / Double(v.count)
                    let s = (v.reduce(0.0) { $0 + (Double($1) - m) * (Double($1) - m) } / Double(v.count)).squareRoot()
                    return (m, s)
                }
                let (_, tileSigma) = moments(tiles)
                let (frameMean, frameSigma) = moments(laid[r])
                XCTAssertEqual(frameSigma / tileSigma, 1, accuracy: 0.08, "\(id) record \(r)")
                XCTAssertEqual(frameMean, 0, accuracy: 0.002, "\(id) record \(r)")
            }
        }
    }
}
