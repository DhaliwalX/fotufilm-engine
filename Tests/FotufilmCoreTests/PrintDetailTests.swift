import XCTest
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class PrintDetailTests: XCTestCase {
    // MARK: The hold

    /// Mid-grey, black 0.8 darker, and the highlight knee and white 0.2 and 0.4 lighter.
    private let mid: Float = 0.745, black: Float = 1.545
    private let knee: Float = 0.545, white: Float = 0.345

    private func hold(at offset: Float, shadows: Float = 1, highlights: Float = 1) -> Float {
        PrintDetail.hold(at: mid + offset, mid: mid, black: black, knee: knee, white: white,
                         packed: [shadows, highlights, knee, white])
    }

    func testShadowHoldIsZeroBetweenTheKneesAndAtBlack() {
        let knee = PrintDetail.shadowKneeShare * 0.8
        for offset: Float in [-0.2, 0, knee - 0.001, knee, 0.8, 1.2] {
            XCTAssertEqual(hold(at: offset), 0, accuracy: 1e-9, "offset \(offset)")
        }
        XCTAssertGreaterThan(hold(at: 0.5), 0)
    }

    func testHighlightsBurnInPastTheirKneeAndNeverReachTheWhite() {
        XCTAssertEqual(hold(at: -0.2), 0, accuracy: 1e-9)
        XCTAssertEqual(hold(at: -0.199), 0)
        for offset: Float in [-0.3, -0.5, -1, -3] {
            XCTAssertLessThan(hold(at: offset), 0, "offset \(offset)")
            let printed = mid + offset - hold(at: offset)
            XCTAssertGreaterThan(printed, white, "offset \(offset) stays short of the white")
        }
    }

    func testZeroStrengthsHoldNothing() {
        for offset in stride(from: Float(-3), through: 1.2, by: 0.05) {
            XCTAssertEqual(hold(at: offset, shadows: 0, highlights: 0), 0)
        }
    }

    func testPrintedExposureNeverReverses() {
        // The print must stay monotonic: what printed darker still prints darker.
        for strengths: (Float, Float) in [(1, 0), (0, 1), (1, 1), (0.5, 0.5)] {
            var previous = -Float.infinity
            for offset in stride(from: Float(-2), through: 1.0, by: 0.002) {
                let printed = mid + offset
                    - hold(at: offset, shadows: strengths.0, highlights: strengths.1)
                XCTAssertGreaterThan(printed, previous, "offset \(offset) at \(strengths)")
                previous = printed
            }
        }
    }

    func testPackedHoldsStrengthsInRangeAndPlacesTheKneeAboveTheWhite() {
        let curve = CharacteristicCurve(dMin: 0.1, gamma: 2.8, toe: -0.5, toeWidth: 0.2,
                                        shoulder: 1.0, shoulderWidth: 0.2)
        let curves = [curve, curve, curve], midpoints: [Float] = [0, 0, 0]
        XCTAssertEqual(PrintDetail.packed(shadows: -1, highlights: 3, curves: curves,
                                          midpoints: midpoints)[0...1], [0, 1])
        XCTAssertEqual(PrintDetail.packed(shadows: 0.4, highlights: .nan, curves: curves,
                                          midpoints: midpoints)[0...1], [0.4, 0])
        let packed = PrintDetail.packed(shadows: 0, highlights: 0, curves: curves,
                                        midpoints: midpoints)
        let aim = curve.density(logExposure: 0)
        XCTAssertEqual(packed[2], curve.logExposure(density: aim - log10(2)), accuracy: 1e-5)
        XCTAssertEqual(packed[3], curve.logExposure(density: 0.1 + PrintDetail.whiteDensity),
                       accuracy: 1e-5)
        XCTAssertLessThan(packed[3], packed[2])
        XCTAssertLessThan(packed[2], 0)
    }

    // MARK: Rendered

    private func ramp(stops: [Float], colour: SIMD3<Float> = .one) -> ImageBuffer {
        let size = 16
        var image = ImageBuffer(width: size * stops.count, height: size)
        for (index, stop) in stops.enumerated() {
            let value = colour * 0.18 * exp2(stop)
            for y in 0..<size {
                for x in index * size..<(index + 1) * size {
                    let i = y * image.width + x
                    image.planes[0][i] = value.x
                    image.planes[1][i] = value.y
                    image.planes[2][i] = value.z
                }
            }
        }
        return image
    }

    private func patches(_ image: ImageBuffer, count: Int) -> [SIMD3<Float>] {
        let size = image.width / count
        return (0..<count).map { index in
            let p = image[index * size + size / 2, image.height / 2]
            return SIMD3(p.0, p.1, p.2)
        }
    }

    private func render(_ image: ImageBuffer, stock: FilmStock, paper: PrintPaper,
                        strength: Float?, highlights: Float? = nil, configure: (inout FotufilmEngine.Options) -> Void = { _ in })
        -> ImageBuffer {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.paper = paper
        if let strength { options.shadowDetail = strength }
        if let highlights { options.highlightDetail = highlights }
        configure(&options)
        return FotufilmEngine(stock: stock, options: options).process(linearRGB: image)
    }

    private func vision500T() throws -> FilmStock {
        try XCTUnwrap(FilmStock.named("vision500t"))
    }

    private func luminance(_ rgb: SIMD3<Float>) -> Float {
        (rgb * PrintFinish.luminance).sum()
    }

    func testZeroIsBitIdentical() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
        let image = ramp(stops: [-9, -6, -4, -2, 0, 2, 4, 6])
        for stock in [try vision500T(), TestStocks.negative, TestStocks.reversal, TestStocks.monochrome] {
            for paper: PrintPaper in [.vision2383, .screen, .ilfochromeCPS1K] {
                let plain = render(image, stock: stock, paper: paper, strength: nil)
                let zero = render(image, stock: stock, paper: paper, strength: 0, highlights: 0)
                XCTAssertEqual(plain.planes, zero.planes, "\(stock.name) on \(paper)")
            }
        }
    }

    func testOpensPrintShadowsAndKeepsBlackAndMidGrey() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
        let stops: [Float] = [-14, -6, -5, -4, -3, 0, 2]
        let image = ramp(stops: stops)
        let plain = patches(render(image, stock: try vision500T(), paper: .vision2383,
                                   strength: 0), count: stops.count)
        let opened = patches(render(image, stock: try vision500T(), paper: .vision2383,
                                    strength: 1), count: stops.count)
        let before = plain.map(luminance), after = opened.map(luminance)
        // Black is the clear base and stays where it was.
        XCTAssertEqual(after[0], before[0], accuracy: max(before[0] * 0.02, 1e-6))
        // The shadows between come up, by more than a third of a stop somewhere.
        XCTAssertGreaterThan(zip(after[1...4], before[1...4]).map { $0 / $1 }.max()!, 1.26)
        for index in 1...4 { XCTAssertGreaterThanOrEqual(after[index], before[index]) }
        // Mid-grey and above are untouched.
        for index in 5...6 { XCTAssertEqual(after[index], before[index], accuracy: before[index] * 1e-4) }
        // The tone scale still runs from black up.
        for index in 1..<after.count { XCTAssertGreaterThan(after[index], after[index - 1]) }
    }

    func testOpenedShadowsKeepTheirColour() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
        let stops: [Float] = [-5, -4]
        let blue = SIMD3<Float>(0.25, 0.35, 1.6)
        let image = ramp(stops: stops, colour: blue)
        let plain = patches(render(image, stock: try vision500T(), paper: .vision2383,
                                   strength: 0), count: stops.count)
        let opened = patches(render(image, stock: try vision500T(), paper: .vision2383,
                                    strength: 1), count: stops.count)
        func saturation(_ rgb: SIMD3<Float>) -> Float { (rgb.max() - rgb.min()) / rgb.max() }
        for index in stops.indices {
            XCTAssertGreaterThan(luminance(opened[index]), luminance(plain[index]))
            XCTAssertGreaterThanOrEqual(saturation(opened[index]), saturation(plain[index]) - 0.02)
            XCTAssertEqual(opened[index].z, opened[index].max(), "the patch stays blue")
        }
    }

    func testHighlightsComeDownAndKeepMidGrey() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
        let stops: [Float] = [0, 2, 3, 4, 5, 6, 8]
        let image = ramp(stops: stops)
        let plain = patches(render(image, stock: try vision500T(), paper: .vision2383,
                                   strength: nil, highlights: 0), count: stops.count)
        let burnt = patches(render(image, stock: try vision500T(), paper: .vision2383,
                                   strength: nil, highlights: 1), count: stops.count)
        let before = plain.map(luminance), after = burnt.map(luminance)
        XCTAssertEqual(after[0], before[0], accuracy: before[0] * 1e-4, "mid-grey stays")
        for index in 2..<stops.count { XCTAssertLessThan(after[index], before[index]) }
        // The plain print squeezes +4 to +8 stops against its white; burnt in, they keep at least
        // that separation as displayed, with room left below the white.
        func shown(_ y: Float) -> Float { y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055 }
        XCTAssertGreaterThanOrEqual(shown(after[6]) - shown(after[3]), shown(before[6]) - shown(before[3]))
        XCTAssertLessThan(after[6], 0.85 * before[6])
        for index in 1..<after.count { XCTAssertGreaterThan(after[index], after[index - 1]) }
    }

    func testBurntHighlightsKeepTheirColour() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
        let stops: [Float] = [3, 4]
        let warm = SIMD3<Float>(1.4, 0.8, 0.35)
        let image = ramp(stops: stops, colour: warm)
        let plain = patches(render(image, stock: try vision500T(), paper: .vision2383,
                                   strength: nil, highlights: 0), count: stops.count)
        let burnt = patches(render(image, stock: try vision500T(), paper: .vision2383,
                                   strength: nil, highlights: 1), count: stops.count)
        func saturation(_ rgb: SIMD3<Float>) -> Float { (rgb.max() - rgb.min()) / rgb.max() }
        for index in stops.indices {
            XCTAssertLessThan(luminance(burnt[index]), luminance(plain[index]))
            XCTAssertGreaterThan(saturation(burnt[index]), saturation(plain[index]))
            XCTAssertEqual(burnt[index].x, burnt[index].max(), "the patch stays warm")
        }
    }

    #if canImport(Metal)
    func testMetalAgreesWithCPU() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide engine required")
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let width = 32, height = 12
        var scene = ImageBuffer(width: width, height: height)
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let level = 0.18 * exp2(Float(x) / Float(width - 1) * 17 - 10)
            let colour: [Float] = y < 4 ? [1, 1, 1] : y < 8 ? [0.15, 0.25, 1] : [1, 0.32, 0.02]
            let i = y * width + x
            for c in 0..<3 { scene.planes[c][i] = level * colour[c]; rgba[4 * i + c] = level * colour[c] }
        }}
        let cases: [(String, PrintPaper)] = [
            ("vision500t", .vision2383), ("vision500t", .screen), ("provia100f", .screen),
            ("provia100f", .ilfochromeCPS1K), ("hp5plus400", .screen),
        ]
        for (id, paper) in cases {
            for strength: Float in [0, 1] {
                var options = FotufilmEngine.Options()
                options.paper = paper; options.grainScale = 0; options.halationScale = 0
                options.localTone = false
                options.shadowDetail = strength
                options.highlightDetail = strength
                let film = try XCTUnwrap(FilmStock.named(id))
                let cpu = try FotufilmEngine(stock: film, options: options).processChecked(linearRGB: scene)
                let metal = try XCTUnwrap(gpu.processLinearFloat(rgba, width: width, height: height,
                                                                stock: film, options: options))
                var worst: Float = 0
                for i in 0..<(width * height) { for c in 0..<3 {
                    XCTAssertTrue(cpu.planes[c][i].isFinite && metal[4 * i + c].isFinite)
                    // 2383's CPU print keeps a few slightly negative out-of-gamut values that the
                    // Metal print holds at zero, Shadow Detail or not; compare what is displayed.
                    let d = abs(max(cpu.planes[c][i], 0) - max(metal[4 * i + c], 0))
                    worst = max(worst, d)
                }}
                XCTAssertLessThan(worst, 2e-4, "\(id) on \(paper) strength \(strength)")
            }
        }
    }
    #endif

    func testWorksOnSlidesAndBlackAndWhiteOnEveryRoute() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
        let stops: [Float] = [-6, -5, -4, -3, 0, 2, 3, 4]
        let image = ramp(stops: stops)
        let slide = try XCTUnwrap(FilmStock.named("provia100f"))
        let silver = try XCTUnwrap(FilmStock.named("hp5plus400"))
        let cases: [(FilmStock, PrintPaper, DigitalReferenceStyle, String)] = [
            (slide, .screen, .referenceExposure, "slide viewed directly"),
            (slide, .screen, .gradedPrint, "slide through Digital Reference's graded curve"),
            (slide, .ilfochromeCPS1K, .referenceExposure, "slide on positive paper"),
            (silver, .ektacolorEdge, .referenceExposure, "black-and-white print"),
            (silver, .screen, .referenceExposure, "black-and-white on Digital Reference"),
        ]
        for (stock, paper, style, label) in cases {
            func patches(shadows: Float, highlights: Float) -> [Float] {
                self.patches(render(image, stock: stock, paper: paper, strength: shadows,
                                    highlights: highlights) { $0.digitalReference = style },
                             count: stops.count).map(luminance)
            }
            let plain = patches(shadows: 0, highlights: 0)
            let opened = patches(shadows: 1, highlights: 0)
            let burnt = patches(shadows: 0, highlights: 1)
            XCTAssertEqual(opened[4], plain[4], accuracy: plain[4] * 1e-4, "\(label): grey")
            XCTAssertEqual(burnt[4], plain[4], accuracy: plain[4] * 1e-4, "\(label): grey")
            XCTAssertGreaterThan(zip(opened[0...3], plain[0...3]).map { $0 / $1 }.max()!, 1.1,
                                 "\(label): shadows open")
            XCTAssertLessThan(zip(burnt[5...7], plain[5...7]).map { $0 / $1 }.min()!, 0.95,
                              "\(label): highlights come down")
            for index in 1..<stops.count {
                XCTAssertGreaterThan(opened[index], opened[index - 1], "\(label) shadows")
                XCTAssertGreaterThan(burnt[index], burnt[index - 1], "\(label) highlights")
            }
        }
    }

    func testLeavesTheViewedNegativeAndCineonAlone() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
        let image = ramp(stops: [-6, -4, -2, 0, 3, 6])
        for paper: PrintPaper in [.negative, .cineonLog] {
            let plain = render(image, stock: try vision500T(), paper: paper, strength: 0)
            let asked = render(image, stock: try vision500T(), paper: paper, strength: 1,
                               highlights: 1)
            XCTAssertEqual(plain.planes, asked.planes, "\(paper)")
        }
    }
}
