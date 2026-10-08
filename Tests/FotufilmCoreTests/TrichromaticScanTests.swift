import XCTest
import FotufilmCore

/// Exposures under red, green and blue light: which light each was made under, how they group
/// into frames, how far apart their layers lie, and the merged file.
final class TrichromaticScanTests: XCTestCase {
    private let width = 1200, height = 800

    /// A negative's transmittance: detail at every scale, as grain and a picture give it, never
    /// repeating (smoothly interpolated lattice noise, octave on octave), and a hard edge.
    private func film(_ x: Double, _ y: Double) -> Float {
        func lattice(_ i: Int, _ j: Int, _ octave: Int) -> Double {
            var h = UInt64(bitPattern: Int64(i &* 73_856_093 ^ j &* 19_349_663 ^ octave &* 83_492_791))
            h = (h ^ (h >> 33)) &* 0xff51afd7ed558ccd
            h = (h ^ (h >> 33)) &* 0xc4ceb9fe1a85ec53
            return Double(h >> 11) / Double(1 << 53) - 0.5
        }
        var value = 0.0, cell = 64.0, amplitude = 1.0
        for octave in 0..<6 {
            let fx = x / cell, fy = y / cell
            let i = Int(fx.rounded(.down)), j = Int(fy.rounded(.down))
            let tx = fx - Double(i), ty = fy - Double(j)
            let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
            let top = lattice(i, j, octave) * (1 - sx) + lattice(i + 1, j, octave) * sx
            let bottom = lattice(i, j + 1, octave) * (1 - sx) + lattice(i + 1, j + 1, octave) * sx
            value += amplitude * (top * (1 - sy) + bottom * sy)
            cell /= 2
            amplitude *= 0.7
        }
        if (x - 600) * 0.3 + (y - 400) > 0 { value += 0.5 }
        return Float(pow(10, -0.6 - 0.8 * value))
    }

    /// The exposure under a light of `colour` of the film moved by `turn` degrees and `shift`
    /// pixels: its pixel (x, y) shows the film at the turned and shifted point.
    private func exposure(colour: SIMD3<Float>, turn: Double, shift: (Double, Double)) -> [Float] {
        let angle = turn * .pi / 180, cx = Double(width) / 2, cy = Double(height) / 2
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - cx, dy = Double(y) - cy
                let fx = cos(angle) * dx - sin(angle) * dy + cx + shift.0
                let fy = sin(angle) * dx + cos(angle) * dy + cy + shift.1
                let t = film(fx, fy)
                for c in 0..<3 { rgba[(y * width + x) * 4 + c] = colour[c] * t }
            }
        }
        return rgba
    }

    func testLightsAreMeasuredAndBlanksLeftOut() throws {
        let red = exposure(colour: SIMD3(0.4, 0.01, 0), turn: 0, shift: (0, 0))
        XCTAssertEqual(try TrichromaticScan.measure(red, width: width, height: height).light, .red)
        let blue = exposure(colour: SIMD3(0.02, 0.05, 0.3), turn: 0, shift: (0, 0))
        XCTAssertEqual(try TrichromaticScan.measure(blue, width: width, height: height).light, .blue)
        // Bare green light: no picture.
        var blank = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            blank[4 * i] = 0.01
            blank[4 * i + 1] = 0.3 * (1 - 0.1 * Float(i % width) / Float(width))
            blank[4 * i + 2] = 0.02
        }
        XCTAssertEqual(try TrichromaticScan.measure(blank, width: width, height: height).light, .blank)
        // Grey light through a black-and-white negative is no one light.
        let grey = exposure(colour: SIMD3(0.3, 0.3, 0.3), turn: 0, shift: (0, 0))
        XCTAssertEqual(try TrichromaticScan.measure(grey, width: width, height: height).light, .other)
    }

    func testExposuresGroupAlternatingOrInPasses() throws {
        let r = TrichromaticScan.Light.red, g = TrichromaticScan.Light.green
        let b = TrichromaticScan.Light.blue, blank = TrichromaticScan.Light.blank
        // Frame by frame, each light's leader first.
        XCTAssertEqual(try TrichromaticScan.frames([blank, r, blank, g, blank, b, g, r, b]),
                       [[1, 3, 5], [7, 6, 8]])
        // A roll a pass at a time, blue first.
        XCTAssertEqual(try TrichromaticScan.frames([b, b, r, r, g, g]), [[2, 4, 0], [3, 5, 1]])
        // A pass one exposure longer than the others.
        XCTAssertThrowsError(try TrichromaticScan.frames([b, b, b, r, r, g, g])) {
            XCTAssertEqual($0 as? TrichromaticScan.Failure, .ungrouped(0))
        }
        XCTAssertThrowsError(try TrichromaticScan.frames([r, g, b, r, g])) {
            XCTAssertEqual($0 as? TrichromaticScan.Failure, .ungrouped(3))
        }
    }

    func testLayersLineUpAndMerge() throws {
        let colours: [SIMD3<Float>] = [SIMD3(0.5, 0.02, 0), SIMD3(0.01, 0.4, 0.05), SIMD3(0.04, 0.02, 0.3)]
        // Green turned 0.8° and moved, blue moved, as a film reloaded between passes moves.
        let moves: [(turn: Double, shift: (Double, Double))] = [(0, (0, 0)), (0.8, (23.5, -11.25)),
                                                                (-0.3, (-7.75, 15.5))]
        var layers: [[Float]] = []
        for (colour, move) in zip(colours, moves) {
            let rgba = exposure(colour: colour, turn: move.turn, shift: move.shift)
            let measured = try TrichromaticScan.measure(rgba, width: width, height: height)
            layers.append(try TrichromaticScan.layer(rgba, width: width, height: height,
                                                     colour: measured.colour))
        }
        let green = try TrichromaticScan.register(layers[1], to: layers[0], width: width, height: height)
        let blue = try TrichromaticScan.register(layers[2], to: layers[0], width: width, height: height)
        // Green's sample for red's pixel (x, y) is where green's exposure shows the same film:
        // the inverse of green's move.
        for (registration, move) in [(green, moves[1]), (blue, moves[2])] {
            let angle = -move.turn * .pi / 180, cx = Double(width) / 2, cy = Double(height) / 2
            for (x, y) in [(200.0, 150.0), (1000.0, 650.0), (600.0, 400.0)] {
                let dx = x - move.shift.0 - cx, dy = y - move.shift.1 - cy
                let ex = cos(angle) * dx - sin(angle) * dy + cx
                let ey = sin(angle) * dx + cos(angle) * dy + cy
                let a = registration.affine.map(Double.init)
                XCTAssertEqual(a[0] * x + a[1] * y + a[2], ex, accuracy: 0.15)
                XCTAssertEqual(a[3] * x + a[4] * y + a[5], ey, accuracy: 0.15)
            }
            XCTAssertLessThan(registration.residual, 0.2)
        }

        let file = try TrichromaticScan.merge(red: layers[0], green: layers[1], blue: layers[2],
                                              width: width, height: height, green: green, blue: blue)
        // Little-endian, uncompressed 16-bit RGB.
        XCTAssertEqual(Array(file.prefix(4)), [0x49, 0x49, 42, 0])
        let offset = file.count - width * height * 6
        func sample(_ x: Int, _ y: Int, _ c: Int) -> Float {
            let at = offset + ((y * width + x) * 3 + c) * 2
            return Float(UInt16(file[at]) | UInt16(file[at + 1]) << 8)
        }
        // Each layer lined up shows the same film: equal densities once each layer's own scale
        // (its clear end) is divided out.
        var scale = SIMD3<Float>(repeating: 0)
        for c in 0..<3 { scale[c] = sample(750, 200, c) / film(750, 200) }
        for (x, y) in [(300, 200), (900, 600), (450, 520)] {
            for c in 0..<3 {
                XCTAssertEqual(log10(sample(x, y, c) / scale[c] / film(Double(x), Double(y))), 0,
                               accuracy: 0.02, "channel \(c) at \(x), \(y)")
            }
        }
    }
}
