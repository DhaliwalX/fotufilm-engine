import XCTest
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
import Metal
#endif

final class PositivePrintPaperTests: XCTestCase {
    private let papers: [PrintPaper] = [.ilfochromeCPS1K, .ilfochromeCLM1K]
    private var stock: FilmStock { FilmStock.presets["provia100f"]! }

    private func options(_ paper: PrintPaper, printer: PrinterProfile? = nil) -> FotufilmEngine.Options {
        var o = FotufilmEngine.Options()
        o.paper = paper; o.printer = printer
        o.grainScale = 0; o.halationScale = 0; o.couplerScale = 0; o.localTone = false
        return o
    }

    func testSelectionAliasesAndPersistedIndices() {
        XCTAssertEqual(PrintPaper.preset(id: "ilfochrome"), .ilfochromeCPS1K)
        XCTAssertEqual(PrintPaper.preset(id: "cibachrome"), .ilfochromeCPS1K)
        XCTAssertEqual(PrintPaper.preset(id: "cibachrome-clm-1k"), .ilfochromeCLM1K)
        XCTAssertEqual(Array(PrintPaper.allCases.prefix(10)),
                       [.ektacolorEdge, .enduraPremier, .crystalArchive,
                        .vision2383, .vision2393, .eternaCP, .labScan, .telecine, .screen, .negative])
        XCTAssertEqual(PrintPaper.default(for: stock), .screen)
        var instant = stock; instant.isReflectionPrint = true
        XCTAssertEqual(PrintPaper.choices(for: instant), [.screen])
        for paper in papers {
            XCTAssertTrue(PrintPaper.choices(for: stock).contains(paper))
            XCTAssertFalse(PrintPaper.choices(for: TestStocks.negative).contains(paper))
            XCTAssertEqual(paper.resolved(for: TestStocks.negative), .ektacolorEdge)
            XCTAssertEqual(paper.resolved(for: instant), .screen)
            XCTAssertFalse(paper.supportsHDRDelivery(for: stock))
            XCTAssertTrue(Enlarger.illuminates(stock: stock, paper: paper))
        }
    }

    func testPositivePaperBorderIsUnexposedDarkAndSmooth() {
        for paper in papers {
            let frame = PrintFrameConfiguration(frame: .paper, formatID: "35mm",
                stockID: "provia100f", paper: paper)
            XCTAssertEqual(frame.frame, .paper)
            XCTAssertFalse(frame.hasLustre)
            for c in 0..<3 {
                XCTAssertGreaterThan(frame.baseRGB[c], 0)
                XCTAssertLessThan(frame.baseRGB[c], 0.03)
            }
        }
    }

    func testPublishedDensityRangeAndMidtoneContrast() {
        // Ilford TDS 307US, August 2003, p. 1. Endpoints remain an analytic approximation.
        for (paper, range, contrast) in [(PrintPaper.ilfochromeCPS1K, Float(2), Float(1.4)),
                                         (.ilfochromeCLM1K, 2.05, 1.15)] {
            let curve = paper.printCurves(for: stock)[1]
            XCTAssertEqual(curve.dMax - curve.dMin, range, accuracy: 1e-6)
            let slope = (curve.density(logExposure: 0.001) - curve.density(logExposure: -0.001)) / 0.002
            XCTAssertEqual(slope, contrast, accuracy: 0.0002)
        }
    }

    func testPaperSDRDeliveryDoesNotApplyTheSlideHighlightShoulder() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        XCTAssertEqual(options(.screen).sdrShoulderKnee(for: stock), FilmSDRDelivery.reversalShoulderKnee)
        for paper in papers {
            let o = options(paper)
            XCTAssertEqual(o.sdrShoulderKnee(for: stock), FilmSDRDelivery.standardShoulderKnee)
            let engine = FotufilmEngine(stock: stock, options: o)
            var input = ImageBuffer(width: 8, height: 8)
            for c in 0..<3 { input.planes[c] = Array(repeating: 1, count: 64) }
            let linear = try XCTUnwrap(HalideBackend.process(image: input, stock: stock, options: o))
            let rgb = ColorScience.linearDisplayP3ToSRGB(SIMD3((0..<3).map {
                ColorScience.displayShoulder(linear.planes[$0][0], knee: FilmSDRDelivery.standardShoulderKnee)
            }))
            let bytes = engine.processSRGB8(Array(repeating: 255, count: 256), width: 8, height: 8)
            for c in 0..<3 {
                let expected = min(max(ColorScience.linearToSrgb(rgb[c]) * 255, 0), 255)
                XCTAssertEqual(Float(bytes[c]), expected, accuracy: 1.5)
            }
        }
    }

    func testPositivePaperHasSeparateTablesAndViewingLight() throws {
        let direct = SpectralRuntime.tables(for: stock, paper: .screen)
        XCTAssertNil(direct.paperOutput)
        for paper in papers {
            let base = SpectralRuntime.tables(for: stock, paper: paper)
            let warm = SpectralRuntime.tables(for: stock, paper: paper, printViewingKelvin: 2856)
            XCTAssertNotNil(base.paperOutput)
            XCTAssertNotEqual(base.filmOutput.values, direct.filmOutput.values)
            XCTAssertEqual(base.filmOutput.values, warm.filmOutput.values)
            XCTAssertNotEqual(base.paperOutput?.values, warm.paperOutput?.values)
            XCTAssertNotEqual(SpectralRuntime.cacheIdentifier(for: stock, paper: paper),
                              SpectralRuntime.cacheIdentifier(for: stock, paper: .screen))
            let a = FilmEngineInvocation(stock: stock, options: options(paper, printer: .simulatedTungsten), width: 32, height: 8)
            let b = FilmEngineInvocation(stock: stock, options: options(paper, printer: PrinterProfile(exposureEV: 1)), width: 32, height: 8)
            XCTAssertEqual(a.featureMask & FilmEngineFeature.reversal, 0, "paper must run after reversal development")
            XCTAssertEqual(a.configuration[FilmEngineInvocation.developComplementOffset], 1)
            XCTAssertEqual(a.spectralCacheID, b.spectralCacheID)
            for slot in [FilmEngineInvocation.paperMidpointRedOffset, 62, FilmEngineInvocation.paperMidpointBlueOffset] {
                XCTAssertEqual(b.configuration[slot] - a.configuration[slot], -log10(Float(2)), accuracy: 1e-6)
            }
        }
    }

    func testRenderedWedgeStaysPositiveAndAnchoredAndAgreesWithToneScale() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        let stops: [Float] = [-4, -2, -1, 0, 1, 2, 4]
        var input = ImageBuffer(width: stops.count, height: 8)
        for i in 0..<(input.width * input.height) {
            for c in 0..<3 { input.planes[c][i] = stock.developedDensity(layer: c, logExposure: stops[i % stops.count] * log10(2)) }
        }
        for paper in papers {
            var o = options(paper); o.stage = .print
            let output = try XCTUnwrap(HalideBackend.print(density: input, stock: stock, options: o))
            let reference = SpectralRuntime.neutralToneScale(stops: stops, stock: stock, paper: paper, printCorrection: 0)
            let w = ColorScience.displayP3LuminanceWeights
            var previous: Float = 0
            for i in stops.indices {
                let rgb = SIMD3(output.planes[0][i], output.planes[1][i], output.planes[2][i])
                let luma = w.0 * rgb.x + w.1 * rgb.y + w.2 * rgb.z
                XCTAssertGreaterThan(luma, previous)
                // The analytic wavelength integral bypasses the renderer's two 33-cube interpolations.
                XCTAssertEqual(luma, reference[i], accuracy: 0.006)
                XCTAssertTrue((0..<3).allSatisfy { rgb[$0].isFinite && rgb[$0] >= 0 && rgb[$0] <= 1.001 })
                previous = luma
                if stops[i] == 0 { XCTAssertEqual(luma, pow(10, -paper.midDensity), accuracy: 0.004) }
            }
            o.printer = .simulatedTungsten
            let base = try XCTUnwrap(HalideBackend.print(density: input, stock: stock, options: o))
            o.printer = PrinterProfile(exposureEV: 1)
            let more = try XCTUnwrap(HalideBackend.print(density: input, stock: stock, options: o))
            XCTAssertGreaterThan(more.planes[1][3], base.planes[1][3])
        }
    }

    func testPrinterMatchingHandlesPositiveExposureDirection() throws {
        let target = SIMD3<Float>((0..<3).map { stock.developedDensity(layer: $0, logExposure: 0) })
        for paper in papers {
            for stop: Float in [-1, 1] {
                let reference = SIMD3<Float>((0..<3).map { stock.developedDensity(layer: $0, logExposure: stop * log10(2)) })
                for mode in [PrinterProfile.Matching.density, .densityAndColor] {
                    let match = try PrinterProfile.simulatedTungsten.matching(mode,
                        referenceDensity: reference, targetDensity: target, stock: stock, paper: paper)
                    XCTAssertFalse(match.limited)
                    XCTAssertLessThan(match.residual, 0.005)
                    XCTAssertLessThan(match.printer.exposureEV * stop, 0)
                }
            }
        }
    }

#if canImport(Metal)
    func testHandwrittenMetalPrintsPositivePaper() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(HandwrittenMetalFilmRenderer.shared)
        for paper in papers {
            let o = options(paper)
            let key = "positive-paper-" + paper.id
            XCTAssertTrue(renderer.prepareLinearHDR(key: key, stock: stock, options: o,
                                                     frameWidth: 8, frameHeight: 8))
            let colors: [SIMD3<Float>] = [SIMD3(repeating: 0.18), SIMD3(repeating: 1),
                                           SIMD3(0.8, 0.1, 0.05), SIMD3(0.05, 0.3, 0.8)]
            for color in colors {
                var input = ImageBuffer(width: 8, height: 8)
                var half = [Float16](repeating: 1, count: 256)
                for c in 0..<3 { for i in 0..<64 {
                    input.planes[c][i] = color[c]
                    half[i * 4 + c] = Float16(color[c])
                } }
                let bytes = half.count * MemoryLayout<Float16>.stride
                let source = try half.withUnsafeBytes {
                    try XCTUnwrap(device.makeBuffer(bytes: $0.baseAddress!, length: bytes, options: .storageModeShared))
                }
                let output = try XCTUnwrap(device.makeBuffer(length: bytes, options: .storageModeShared))
                XCTAssertTrue(renderer.processLinearHalf(input: source, output: output,
                    width: 8, height: 8, key: key, frameIndex: 0))
                let cpu = try XCTUnwrap(HalideBackend.process(image: input, stock: stock, options: o))
                let result = output.contents().assumingMemoryBound(to: Float16.self)
                for c in 0..<3 {
                    XCTAssertEqual(Float(result[c]), max(cpu.planes[c][0], 0), accuracy: 0.01)
                }
            }
        }
    }

    func testFullRenderCPUAndMetalAgreeAndMatchSplitStages() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        var input = ImageBuffer(width: 32, height: 16)
        var rgba = [Float](repeating: 1, count: 32 * 16 * 4)
        for i in 0..<(32 * 16) {
            for c in 0..<3 {
                let value = Float((i + c * 7) % 32) / 31
                input.planes[c][i] = value
                rgba[4 * i + c] = value
            }
        }
        for paper in papers {
            let o = options(paper, printer: PrinterProfile(exposureEV: 0.4, magenta: 0.3, yellow: 0.6))
            let cpu = try XCTUnwrap(HalideBackend.process(image: input, stock: stock, options: o))
            let metal = try XCTUnwrap(gpu.processLinearFloat(rgba, width: 32, height: 16, stock: stock, options: o, frameIndex: 0))
            var negativeOptions = o; negativeOptions.stage = .negative
            let density = try XCTUnwrap(HalideBackend.process(image: input, stock: stock, options: negativeOptions))
            var printOptions = o; printOptions.stage = .print
            let split = try XCTUnwrap(HalideBackend.print(density: density, stock: stock, options: printOptions))
            for c in 0..<3 { for i in 0..<(32 * 16) {
                // The Metal float delivery clamps negative out-of-gamut display channels.
                XCTAssertEqual(max(cpu.planes[c][i], 0), metal[i * 4 + c], accuracy: 0.002)
                XCTAssertEqual(cpu.planes[c][i], split.planes[c][i], accuracy: 0.002)
            } }
        }
    }
#endif
}
