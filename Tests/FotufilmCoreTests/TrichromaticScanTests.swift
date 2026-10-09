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
    /// pixels, and its middle pushed `bow` pixels along: its pixel (x, y) shows the film at the
    /// turned, shifted and bowed point.
    private func exposure(colour: SIMD3<Float>, turn: Double, shift: (Double, Double),
                          bow: Double = 0) -> [Float] {
        let angle = turn * .pi / 180, cx = Double(width) / 2, cy = Double(height) / 2
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - cx, dy = Double(y) - cy
                let bulge = bow * sin(.pi * Double(x) / Double(width)) * sin(.pi * Double(y) / Double(height))
                let fx = cos(angle) * dx - sin(angle) * dy + cx + shift.0 + bulge
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
        // White light through a colour negative's orange mask: mostly red, but each dye layer
        // holds its own picture, so the colour changes from place to place.
        var masked = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                masked[i] = 0.5 * film(Double(x), Double(y))
                masked[i + 1] = 0.15 * film(Double(x) + 2000, Double(y))
                masked[i + 2] = 0.03 * film(Double(x), Double(y) + 2000)
            }
        }
        XCTAssertEqual(try TrichromaticScan.measure(masked, width: width, height: height).light, .other)
    }

    private func layer(_ rgba: [Float]) throws -> [Float] {
        let measured = try TrichromaticScan.measure(rgba, width: width, height: height)
        return try TrichromaticScan.layer(rgba, width: width, height: height, colour: measured.colour)
    }

    func testARepeatedExposureIsTold() throws {
        let colour = SIMD3<Float>(0.4, 0.01, 0)
        let first = try layer(exposure(colour: colour, turn: 0, shift: (0, 0)))
        // The same frame again, the film unmoved; and the next frame, further along.
        let again = try layer(exposure(colour: colour * 0.9, turn: 0, shift: (0, 0)))
        let next = try layer(exposure(colour: colour, turn: 0.2, shift: (1500, 7)))
        func repeats(_ later: [Float], _ earlier: [Float]) throws -> Bool {
            try later.withUnsafeBufferPointer { later in
                try earlier.withUnsafeBufferPointer { earlier in
                    try TrichromaticScan.repeats(later, earlier: earlier, width: width, height: height)
                }
            }
        }
        XCTAssertTrue(try repeats(again, first))
        XCTAssertFalse(try repeats(next, first))
    }

    func testABowedLayerLinesUpLoosely() throws {
        let red = try layer(exposure(colour: SIMD3(0.5, 0.02, 0), turn: 0, shift: (0, 0)))
        let flat = try layer(exposure(colour: SIMD3(0.01, 0.4, 0.05), turn: 0.3, shift: (9, -4)))
        let bowed = try layer(exposure(colour: SIMD3(0.01, 0.4, 0.05), turn: 0.3, shift: (9, -4),
                                       bow: 6))
        XCTAssertFalse(try TrichromaticScan.register(flat, to: red, width: width, height: height).loose)
        XCTAssertTrue(try TrichromaticScan.register(bowed, to: red, width: width, height: height).loose)
    }

    func testARollWithARetakeMerges() throws {
        let lights: [SIMD3<Float>] = [SIMD3(0.5, 0.02, 0), SIMD3(0.01, 0.4, 0.05), SIMD3(0.04, 0.02, 0.3)]
        // Two frames a pass at a time, red then green then blue; the first red frame retaken.
        let shots: [(name: String, light: Int, frame: Double)] = [
            ("01", 0, 0), ("02", 0, 0), ("03", 0, 1500), ("04", 1, 0), ("05", 1, 1500),
            ("06", 2, 0), ("07", 2, 1500),
        ]
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("trichromatic-roll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = shots.map { folder.appendingPathComponent("\($0.name).raw") }
        let outcome = try TrichromaticRoll.merge(
            files,
            decode: { url in
                let shot = shots.first { url.lastPathComponent.hasPrefix($0.name) }!
                return (self.exposure(colour: lights[shot.light], turn: 0.1 * Double(shot.light),
                                      shift: (shot.frame + 3 * Double(shot.light), 0)),
                        self.width, self.height)
            },
            readers: 2,
            store: { _, red in red })
        XCTAssertEqual(outcome.repeats.map(\.lastPathComponent), ["01.raw"])
        XCTAssertEqual(outcome.frames.map { $0.sources.map(\.lastPathComponent) },
                       [["02.raw", "04.raw", "06.raw"], ["03.raw", "05.raw", "07.raw"]])
        XCTAssertTrue(outcome.failures.isEmpty)
    }

    func testExposuresGroupAlternatingOrInPasses() throws {
        let r = TrichromaticScan.Light.red, g = TrichromaticScan.Light.green
        let b = TrichromaticScan.Light.blue, blank = TrichromaticScan.Light.blank
        // Frame by frame, each light's leader first.
        XCTAssertEqual(try TrichromaticScan.frames([blank, r, blank, g, blank, b, g, r, b]),
                       [[1, 3, 5], [7, 6, 8]])
        // Frame by frame, the lights in a different order each frame: two blues meet between
        // frames.
        XCTAssertEqual(try TrichromaticScan.frames([r, g, b, b, r, g, g, b, r]),
                       [[0, 1, 2], [4, 5, 3], [8, 6, 7]])
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
