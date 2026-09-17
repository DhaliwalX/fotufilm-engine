import XCTest
@testable import FotufilmCore

final class PreflashTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
    }

    private func uniform(_ r: Float, _ g: Float, _ b: Float, size: Int = 32) -> ImageBuffer {
        var img = ImageBuffer(width: size, height: size)
        for i in 0..<img.pixelCount {
            img.planes[0][i] = r
            img.planes[1][i] = g
            img.planes[2][i] = b
        }
        return img
    }

    private func centerPixel(_ img: ImageBuffer) -> (Float, Float, Float) {
        img[img.width / 2, img.height / 2]
    }

    private var cleanOptions: FotufilmEngine.Options {
        var o = FotufilmEngine.Options()
        o.grainScale = 0
        return o
    }

    func testZeroPreflashBitIdentical() throws {
        let optionsDefault = cleanOptions
        var optionsExplicitZero = cleanOptions
        optionsExplicitZero.cameraPreflash = 0
        optionsExplicitZero.printerPreflash = 0

        let image = uniform(0.18, 0.18, 0.18)
        for stock in TestStocks.all {
            let simA = FotufilmEngine(stock: stock, options: optionsDefault)
            let simB = FotufilmEngine(stock: stock, options: optionsExplicitZero)
            let outA = simA.process(linearRGB: image)
            let outB = simB.process(linearRGB: image)

            for c in 0..<3 {
                for i in 0..<outA.pixelCount {
                    XCTAssertEqual(outA.planes[c][i], outB.planes[c][i],
                                   "Pixel mismatch at plane \(c) index \(i) for stock \(stock.name)")
                }
            }
        }
    }

    func testCameraPreflashLiftsShadowsWithoutAffectingHighlights() throws {
        let stock = TestStocks.negative
        var optionsPlain = cleanOptions
        optionsPlain.stage = .negative

        var optionsFlayed = cleanOptions
        optionsFlayed.stage = .negative
        optionsFlayed.cameraPreflash = 0.05

        let simPlain = FotufilmEngine(stock: stock, options: optionsPlain)
        let simFlayed = FotufilmEngine(stock: stock, options: optionsFlayed)

        // Shadow exposure: 0.002 linear radiance (zone I/II deep toe)
        let shadowPlain = centerPixel(simPlain.process(linearRGB: uniform(0.002, 0.002, 0.002)))
        let shadowFlayed = centerPixel(simFlayed.process(linearRGB: uniform(0.002, 0.002, 0.002)))

        // Highlight exposure: 5.0 linear radiance (bright highlight)
        let highlightPlain = centerPixel(simPlain.process(linearRGB: uniform(5.0, 5.0, 5.0)))
        let highlightFlayed = centerPixel(simFlayed.process(linearRGB: uniform(5.0, 5.0, 5.0)))

        // On negative film, preflash lifts shadow density out of base+fog
        let shadowDelta = shadowFlayed.1 - shadowPlain.1
        let highlightDelta = highlightFlayed.1 - highlightPlain.1

        XCTAssertGreaterThan(shadowDelta, 0.05,
                             "Camera preflash must significantly lift deep shadow density on the negative")
        XCTAssertLessThan(highlightDelta, 0.01,
                          "Camera preflash must leave highlight density virtually unchanged")
        XCTAssertGreaterThan(shadowDelta / max(highlightDelta, 1e-6), 10.0,
                             "Shadow lift must be at least an order of magnitude larger than highlight shift")
    }

    func testPrinterPreflashSoftensHighlightsWithoutLiftingDMax() throws {
        let stock = TestStocks.negative
        var optionsPlain = cleanOptions
        optionsPlain.paper = .ektacolorEdge

        var optionsFlayed = cleanOptions
        optionsFlayed.paper = .ektacolorEdge
        optionsFlayed.printerPreflash = 0.06

        let simPlain = FotufilmEngine(stock: stock, options: optionsPlain)
        let simFlayed = FotufilmEngine(stock: stock, options: optionsFlayed)

        // On a reflection print from a negative:
        // Highlights in scene -> dense negative -> high reflection print luminance (near white paper).
        // Shadows in scene -> clear negative -> low reflection print luminance (paper Dmax black).
        let highlightPlain = centerPixel(simPlain.process(linearRGB: uniform(4.0, 4.0, 4.0)))
        let highlightFlayed = centerPixel(simFlayed.process(linearRGB: uniform(4.0, 4.0, 4.0)))

        let shadowPlain = centerPixel(simPlain.process(linearRGB: uniform(0.001, 0.001, 0.001)))
        let shadowFlayed = centerPixel(simFlayed.process(linearRGB: uniform(0.001, 0.001, 0.001)))

        // Printer preflash adds uniform exposure to the paper, pulling highlights down into paper tone
        let highlightLumaDiff = highlightPlain.1 - highlightFlayed.1
        let shadowLumaDiff = abs(shadowPlain.1 - shadowFlayed.1)

        XCTAssertGreaterThan(highlightLumaDiff, 0.01,
                             "Printer preflash must soften paper highlights by adding exposure to dense negative regions")
        XCTAssertLessThan(shadowLumaDiff, 0.005,
                          "Printer preflash must not move maximum shadow density on the print")
        XCTAssertGreaterThan(highlightLumaDiff / max(shadowLumaDiff, 1e-6), 5.0,
                             "Highlight softening must dominate any shadow floor movement")
    }

    func testPrinterPreflashGatedToActiveEnlargerMedium() throws {
        let stock = TestStocks.negative

        // 1. Digital Reference (.screen): Enlarger does NOT illuminate screen medium
        var optionsScreenPlain = cleanOptions
        optionsScreenPlain.paper = .screen
        optionsScreenPlain.printerPreflash = 0

        var optionsScreenPreflash = cleanOptions
        optionsScreenPreflash.paper = .screen
        optionsScreenPreflash.printerPreflash = 0.05

        let simScreenA = FotufilmEngine(stock: stock, options: optionsScreenPlain)
        let simScreenB = FotufilmEngine(stock: stock, options: optionsScreenPreflash)
        let image = uniform(0.5, 0.5, 0.5)
        let outScreenA = simScreenA.process(linearRGB: image)
        let outScreenB = simScreenB.process(linearRGB: image)

        for c in 0..<3 {
            for i in 0..<outScreenA.pixelCount {
                XCTAssertEqual(outScreenA.planes[c][i], outScreenB.planes[c][i],
                               "Printer preflash must be gated off when medium is .screen")
            }
        }

        // 2. Negative view: Enlarger does NOT illuminate negative
        var optionsNegPlain = cleanOptions
        optionsNegPlain.paper = .negative
        optionsNegPlain.printerPreflash = 0

        var optionsNegPreflash = cleanOptions
        optionsNegPreflash.paper = .negative
        optionsNegPreflash.printerPreflash = 0.05

        let simNegA = FotufilmEngine(stock: stock, options: optionsNegPlain)
        let simNegB = FotufilmEngine(stock: stock, options: optionsNegPreflash)
        let outNegA = simNegA.process(linearRGB: image)
        let outNegB = simNegB.process(linearRGB: image)

        for c in 0..<3 {
            for i in 0..<outNegA.pixelCount {
                XCTAssertEqual(outNegA.planes[c][i], outNegB.planes[c][i],
                               "Printer preflash must be gated off when medium is .negative")
            }
        }
    }

    func testInvocationSlotPacking() throws {
        let stock = TestStocks.negative

        var options = cleanOptions
        options.cameraPreflash = 0.08
        options.printerPreflash = 0.04
        options.paper = .ektacolorEdge

        let invocation = FilmEngineInvocation(stock: stock, options: options, width: 32, height: 32)
        XCTAssertEqual(invocation.configuration[FilmEngineInvocation.cameraPreflashOffset], 0.08, accuracy: 1e-6)
        XCTAssertEqual(invocation.configuration[FilmEngineInvocation.printerPreflashOffset], 0.04, accuracy: 1e-6)

        // When gated off:
        var optionsGated = cleanOptions
        optionsGated.cameraPreflash = 0.08
        optionsGated.printerPreflash = 0.04
        optionsGated.paper = .screen

        let invocationGated = FilmEngineInvocation(stock: stock, options: optionsGated, width: 32, height: 32)
        XCTAssertEqual(invocationGated.configuration[FilmEngineInvocation.cameraPreflashOffset], 0.08, accuracy: 1e-6)
        XCTAssertEqual(invocationGated.configuration[FilmEngineInvocation.printerPreflashOffset], 0.0, accuracy: 1e-6)
    }
}
