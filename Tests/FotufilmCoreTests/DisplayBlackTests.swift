import XCTest
@testable import FotufilmCore

/// Display black: a physical print's maximum density shown as the display's black, paper white
/// held, and the sRGB delivery's fit of the print into its container's gamut.
final class DisplayBlackTests: XCTestCase {
    private static var negative: FilmStock { FilmStock.presets["example-negative-400"]! }

    private let physical: [PrintPaper] = [.ektacolorEdge, .enduraPremier, .crystalArchive,
                                          .vision2383, .vision2393, .eternaCP]

    func testPaperBlackLandsOnDisplayBlackAndWhiteHolds() throws {
        let stock = Self.negative
        for paper in physical {
            let display = try XCTUnwrap(SpectralRuntime.tables(for: stock, paper: paper).paperOutput)
            let booth = try XCTUnwrap(SpectralRuntime.tables(
                for: stock, paper: paper, displayBlack: false).paperOutput)
            let black = display.sample(SIMD3(repeating: 1))
            let paperBlack = booth.sample(SIMD3(repeating: 1))
            for c in 0..<3 {
                XCTAssertEqual(black[c], 0, accuracy: 1e-6, "\(paper) channel \(c)")
                XCTAssertGreaterThan(paperBlack[c], 0, "\(paper) channel \(c)")
                XCTAssertEqual(display.sample(.zero)[c], booth.sample(.zero)[c], accuracy: 1e-6,
                               "\(paper) white, channel \(c)")
            }
            XCTAssertNotEqual(
                SpectralRuntime.cacheIdentifier(for: stock, paper: paper),
                SpectralRuntime.cacheIdentifier(for: stock, paper: paper, displayBlack: false),
                "\(paper)")
        }
    }

    /// Scans, the digital reference and a viewed negative have no paper black of their own, and
    /// a directly viewed transparency has no paper at all: the choice leaves them untouched.
    func testMediaWithoutAPaperBlackIgnoreTheChoice() {
        for stock in FilmStock.presets.values {
            for paper in [PrintPaper.screen, .labScan, .telecine, .negative] {
                XCTAssertEqual(
                    SpectralRuntime.cacheIdentifier(for: stock, paper: paper),
                    SpectralRuntime.cacheIdentifier(for: stock, paper: paper, displayBlack: false),
                    "\(stock.name) on \(paper)")
            }
        }
    }

    /// The analytic tone scale mirrors the displayed print, and auto adjustment's latitude still
    /// reads the paper itself.
    func testRenderedWedgeAgreesWithTheToneScaleEitherWay() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        let stock = Self.negative
        let stops: [Float] = [-6, -4, -2, 0, 2]
        var input = ImageBuffer(width: stops.count, height: 4)
        for i in 0..<(input.width * input.height) {
            for c in 0..<3 {
                input.planes[c][i] = stock.developedDensity(
                    layer: c, logExposure: stops[i % stops.count] * log10(2))
            }
        }
        let w = ColorScience.displayP3LuminanceWeights
        for displayBlack in [true, false] {
            var options = FotufilmEngine.Options()
            options.paper = .ektacolorEdge
            options.stage = .print
            options.grainScale = 0; options.halationScale = 0; options.couplerScale = 0
            options.localTone = false
            options.displayBlack = displayBlack
            let output = try XCTUnwrap(HalideBackend.print(density: input, stock: stock,
                                                           options: options))
            let reference = SpectralRuntime.neutralToneScale(
                stops: stops, stock: stock, paper: .ektacolorEdge, printCorrection: 0,
                displayBlack: displayBlack)
            for i in stops.indices {
                let luma = w.0 * output.planes[0][i] + w.1 * output.planes[1][i]
                    + w.2 * output.planes[2][i]
                XCTAssertEqual(ColorScience.linearToSrgb(luma),
                               ColorScience.linearToSrgb(reference[i]), accuracy: 1 / 255,
                               "display black \(displayBlack), \(stops[i]) stops")
            }
        }
    }

    // MARK: - Gamut

    func testGamutFitIsTheIdentityInsideAndHoldsLuminanceAndHueOutside() {
        let luma = ColorScience.srgbLuminanceWeights
        let inside = SIMD3<Float>(0.2, 0.7, 0.4)
        XCTAssertEqual(ColorScience.fitToGamut(inside, luminance: luma), inside)
        for colour in [SIMD3<Float>(-0.11, 0.52, -0.04), SIMD3(1.3, 0.2, 0.1),
                       SIMD3(0.05, 0.3, 1.2), SIMD3(-0.2, 0.9, 1.1)] {
            let fitted = ColorScience.fitToGamut(colour, luminance: luma)
            func y(_ c: SIMD3<Float>) -> Float { luma.0 * c.x + luma.1 * c.y + luma.2 * c.z }
            XCTAssertEqual(y(fitted), y(colour), accuracy: 1e-5, "\(colour)")
            XCTAssertTrue((0..<3).allSatisfy { fitted[$0] >= -1e-6 && fitted[$0] <= 1 + 1e-6 })
            // Moving along the line to grey keeps every channel's offset from Y in proportion.
            let before = colour - SIMD3(repeating: y(colour))
            let after = fitted - SIMD3(repeating: y(colour))
            let ratio = after / before
            XCTAssertEqual(ratio.x, ratio.y, accuracy: 1e-4, "\(colour)")
            XCTAssertEqual(ratio.y, ratio.z, accuracy: 1e-4, "\(colour)")
        }
    }

    /// A saturated P3 print colour on the sRGB delivery keeps its hue and luminance instead of
    /// losing a channel to the clip.
    func testSRGBDeliveryFitsInsteadOfClipping() {
        let p3Green = SIMD3<Float>(0.05, 0.6, 0.05)
        let converted = ColorScience.linearDisplayP3ToSRGB(p3Green)
        XCTAssertLessThan(min(converted.x, converted.z), 0, "the fixture must be outside sRGB")
        let source: [Float] = [p3Green.x, p3Green.y, p3Green.z, 1]
        var out = [Float](repeating: 0, count: 4)
        source.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                FilmOutputConversion.sRGBSDR.convert(src, from: 0, count: 4, into: dst)
            }
        }
        let linear = SIMD3((0..<3).map { ColorScience.srgbToLinear(out[$0]) })
        let luma = ColorScience.srgbLuminanceWeights
        let p3 = ColorScience.displayP3LuminanceWeights
        XCTAssertEqual(luma.0 * linear.x + luma.1 * linear.y + luma.2 * linear.z,
                       p3.0 * p3Green.x + p3.1 * p3Green.y + p3.2 * p3Green.z, accuracy: 2e-3)
        XCTAssertGreaterThan(max(linear.x, linear.z), 0.01)
    }
}
