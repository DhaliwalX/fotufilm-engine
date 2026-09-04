import XCTest
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class NegativeViewingTests: XCTestCase {
    private func activation(_ density: Float,
                            curve: CharacteristicCurve) -> Float {
        (density - curve.dMin) / (curve.dMax - curve.dMin)
    }

    /// The table is indexed by the negative's own activation, because the kernel hands it the
    /// negative's own density: FOTUFILM_CONFIG_DEVELOP_COMPLEMENT is zero for a negative however
    /// it is viewed, so nothing is inverted on the way in and nothing is inverted back.
    func testActivationRecoversTheTrueDensity() {
        let stock = TestStocks.negative
        let table = SpectralRuntime.negativeViewing(for: stock, look: .lightBox)
        let dyes = stock.spectralProfile.imageDyeDensity
        let nodes = SpectralRuntime.lutDimension - 1

        for step in stride(from: 0, through: nodes, by: 4) {
            let a = Float(step) / Float(nodes)
            let density = (0..<3).map {
                stock.curves[$0].dMin
                    + a * (stock.curves[$0].dMax - stock.curves[$0].dMin)
            }
            let index = SIMD3<Float>(
                activation(density[0], curve: stock.curves[0]),
                activation(density[1], curve: stock.curves[1]),
                activation(density[2], curve: stock.curves[2]))
            let sampled = table.sample(index)
            let direct = SpectralRuntime.transmissionRGB(density: density,
                                                         dyes: dyes)
            for channel in 0..<3 {
                XCTAssertEqual(sampled[channel], direct[channel], accuracy: 1e-6,
                               "channel \(channel) at activation \(a)")
            }
        }
    }

    func testLightBoxKeepsTheOrangeBase() {
        let stock = TestStocks.negative
        let base = SpectralRuntime.transmissionRGB(
            density: stock.curves.map(\.dMin),
            dyes: stock.spectralProfile.imageDyeDensity)
        XCTAssertGreaterThan(base.x, base.y)
        XCTAssertGreaterThan(base.y, base.z)
    }

    func testScannerNeutralisesTheBase() {
        let stock = TestStocks.negative
        let table = SpectralRuntime.negativeViewing(for: stock, look: .scanner)
        let atBase = table.sample(SIMD3<Float>(repeating: 0))
        for channel in 0..<3 {
            XCTAssertEqual(atBase[channel], 1, accuracy: 1e-4)
        }
    }

    func testTheTwoLooksDifferOnlyByAConstant() {
        let stock = TestStocks.negative
        let box = SpectralRuntime.negativeViewing(for: stock, look: .lightBox)
        let scan = SpectralRuntime.negativeViewing(for: stock, look: .scanner)
        var reference: SIMD3<Float>?
        for step in stride(from: 4, through: 28, by: 4) {
            let a = Float(step) / Float(SpectralRuntime.lutDimension - 1)
            let p = SIMD3<Float>(repeating: a)
            let boxed = box.sample(p), scanned = scan.sample(p)
            let ratio = SIMD3<Float>(scanned.x / boxed.x, scanned.y / boxed.y,
                                     scanned.z / boxed.z)
            if let reference {
                for channel in 0..<3 {
                    XCTAssertEqual(ratio[channel], reference[channel],
                                   accuracy: 1e-4)
                }
            } else {
                reference = ratio
            }
        }
        XCTAssertNotNil(reference)
    }

    func testNegativeIsOfferedOnlyForStocksThatHaveOne() {
        XCTAssertTrue(PrintPaper.choices(for: TestStocks.negative).contains(.negative))
        XCTAssertTrue(PrintPaper.choices(for: TestStocks.monochrome).contains(.negative))
        XCTAssertEqual(PrintPaper.choices(for: TestStocks.reversal), [.screen])
        XCTAssertEqual(PrintPaper.negative.resolved(for: TestStocks.reversal), .screen)
    }

    func testNegativeMediumUsesTheLightBoxOutputPath() {
        var mediumOptions = FotufilmEngine.Options()
        mediumOptions.paper = .negative
        let medium = FilmEngineInvocation(stock: TestStocks.negative,
                                          options: mediumOptions,
                                          width: 64, height: 64)

        var previewOptions = FotufilmEngine.Options()
        previewOptions.negativeViewing = .lightBox
        let preview = FilmEngineInvocation(stock: TestStocks.negative,
                                           options: previewOptions,
                                           width: 64, height: 64)

        XCTAssertNotEqual(medium.featureMask & FilmEngineFeature.reversal, 0)
        XCTAssertEqual(medium.featureMask, preview.featureMask)
        XCTAssertEqual(medium.spectralCacheID, preview.spectralCacheID)
        XCTAssertEqual(medium.spectral.filmOutput.values,
                       preview.spectral.filmOutput.values)
        XCTAssertNil(SpectralRuntime.tables(for: TestStocks.negative,
                                            paper: .negative).paperOutput)
        XCTAssertFalse(PrintPaper.negative.acceptsViewingIlluminant)
        XCTAssertFalse(PrintPaper.negative.acceptsPrintCorrection)
        XCTAssertEqual(PrintPaper.allCases.last, .negative,
                       "existing persisted medium indices must not move")
    }

    func testNegativeMediumDoesNotChangeTheRawDensitySpan() {
        var options = FotufilmEngine.Options()
        options.paper = .negative
        options.stage = .negative
        let invocation = FilmEngineInvocation(stock: TestStocks.negative,
                                              options: options,
                                              width: 64, height: 64)
        XCTAssertNotEqual(invocation.featureMask & FilmEngineFeature.densityOut, 0)
        XCTAssertEqual(invocation.featureMask & FilmEngineFeature.reversal, 0,
                       "the interchange must carry developed negative density")
    }

#if canImport(Metal)
    func testMetalMatchesCPUShowingTheNegative() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else {
            throw XCTSkip("Halide Metal unavailable")
        }
        let stock = TestStocks.negative
        var options = FotufilmEngine.Options()
        options.negativeViewing = .lightBox
        options.grainScale = 0

        let size = 96
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            let x = i % size, y = i / size
            pixels[i * 4] = x < size / 2 ? 230 : 40
            pixels[i * 4 + 1] = y < size / 2 ? 210 : 55
            pixels[i * 4 + 2] = (x + y) < size ? 180 : 70
            pixels[i * 4 + 3] = 255
        }
        let cpu = FotufilmEngine(stock: stock, options: options)
            .processSRGB8(pixels, width: size, height: size)
        var mediumOptions = options
        mediumOptions.negativeViewing = nil
        mediumOptions.paper = .negative
        let medium = FotufilmEngine(stock: stock, options: mediumOptions)
            .processSRGB8(pixels, width: size, height: size)
        XCTAssertEqual(medium, cpu,
                       "the output-medium choice must use the existing light-box render")
        let metal = try XCTUnwrap(
            gpu.processSRGB8(pixels, width: size, height: size,
                             stock: stock, options: options))
        var maxDiff = 0, sumDiff = 0
        for i in 0..<(size * size) {
            for c in 0..<3 {
                let d = abs(Int(cpu[i * 4 + c]) - Int(metal[i * 4 + c]))
                maxDiff = max(maxDiff, d)
                sumDiff += d
            }
        }
        XCTAssertLessThan(Double(sumDiff) / Double(size * size * 3), 1.0,
                          "mean disagreement over one 8-bit level")
        XCTAssertLessThan(maxDiff, 6, "worst pixel disagreement")

        var plain = options
        plain.negativeViewing = nil
        let print = FotufilmEngine(stock: stock, options: plain)
            .processSRGB8(pixels, width: size, height: size)
        func luma(_ image: [UInt8], _ x: Int, _ y: Int) -> Int {
            let i = (y * size + x) * 4
            return Int(image[i]) + Int(image[i + 1]) + Int(image[i + 2])
        }
        XCTAssertGreaterThan(luma(print, 20, 20), luma(print, 76, 76))
        XCTAssertLessThan(luma(cpu, 20, 20), luma(cpu, 76, 76))
    }
#endif

    func testReversalStockIgnoresTheOption() {
        var asked = FotufilmEngine.Options()
        asked.negativeViewing = .lightBox
        let plain = FilmEngineInvocation(stock: TestStocks.reversal,
                                         options: FotufilmEngine.Options(),
                                         width: 64, height: 64)
        let negative = FilmEngineInvocation(stock: TestStocks.reversal,
                                            options: asked,
                                            width: 64, height: 64)
        XCTAssertEqual(plain.featureMask, negative.featureMask)
        XCTAssertEqual(plain.spectralCacheID, negative.spectralCacheID)
        XCTAssertEqual(plain.configuration, negative.configuration)
    }

    func testNegativeStockTakesTheTransparencyBranch() {
        var asked = FotufilmEngine.Options()
        asked.negativeViewing = .lightBox
        let plain = FilmEngineInvocation(stock: TestStocks.negative,
                                         options: FotufilmEngine.Options(),
                                         width: 64, height: 64)
        let negative = FilmEngineInvocation(stock: TestStocks.negative,
                                            options: asked,
                                            width: 64, height: 64)
        XCTAssertEqual(plain.featureMask & FilmEngineFeature.reversal, 0)
        XCTAssertNotEqual(negative.featureMask & FilmEngineFeature.reversal, 0)
        XCTAssertNotEqual(plain.spectralCacheID, negative.spectralCacheID)

        let enlargerRadius = FilmEngineInvocation.printMTFOffset + 1
        XCTAssertGreaterThan(plain.configuration[enlargerRadius], 0,
                             "the printed reference has no enlarger to switch off")
        XCTAssertEqual(negative.configuration[enlargerRadius], 0)
        // The grain blur slots may legitimately differ: printed grain carries the enlarger's
        // sub-resolution spread folded into its sigma, and a light-box negative never meets
        // one — so the printed field is never the narrower of the two. The amplitudes are
        // film-referred and identical, sign included: the negative is developed as a negative
        // however it is shown, so its grain is added in the same density either way.
        var blurSlots = Set<Int>()
        blurSlots.insert(FilmEngineInvocation.grainSigmaOffset)
        blurSlots.insert(FilmEngineInvocation.grainSigmaOffset + 1)
        blurSlots.insert(FilmEngineInvocation.mottleSigmaOffset)
        blurSlots.insert(FilmEngineInvocation.mottleSigmaOffset + 1)
        for layer in 0..<3 {
            blurSlots.insert(FilmEngineInvocation.grainSigmaLayerOffset + layer)
            blurSlots.insert(FilmEngineInvocation.mottleSigmaLayerOffset + layer)
        }
        for slot in blurSlots where slot != FilmEngineInvocation.grainSigmaOffset + 1
            && slot != FilmEngineInvocation.mottleSigmaOffset + 1 {
            XCTAssertGreaterThanOrEqual(plain.configuration[slot],
                                        negative.configuration[slot],
                                        "printed grain blur is never the narrower one")
        }
        for index in plain.configuration.indices {
            if index == enlargerRadius || blurSlots.contains(index) { continue }
            XCTAssertEqual(negative.configuration[index],
                           plain.configuration[index], accuracy: 0,
                           "configuration index \(index)")
        }
    }
}
