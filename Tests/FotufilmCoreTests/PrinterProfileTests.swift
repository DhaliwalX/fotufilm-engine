import XCTest
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class PrinterProfileTests: XCTestCase {
    private var stock: FilmStock { FilmStock.presets["portra400"]! }
    private let paper = PrintPaper.ektacolorEdge
    private let midpointSlots = [FilmEngineInvocation.paperMidpointRedOffset, 62,
                                 FilmEngineInvocation.paperMidpointBlueOffset]

    private func options(_ printer: PrinterProfile?) -> FotufilmEngine.Options {
        var o = FotufilmEngine.Options()
        o.printer = printer; o.paper = paper; o.stage = .print
        o.grainScale = 0; o.halationScale = 0; o.couplerScale = 0; o.localTone = false
        return o
    }

    func testNormalizationAndRoundTrip() throws {
        let p = PrinterProfile(lampKelvin: .nan, exposureEV: 99, magenta: -1, yellow: .infinity).normalized
        XCTAssertEqual(p, PrinterProfile(lampKelvin: 3200, exposureEV: 6, magenta: 0, yellow: 0.5))
        let roundTrip = try JSONDecoder().decode(PrinterProfile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(roundTrip, p)
        let bare = PrinterProfile(magenta: 0, yellow: 0).filteredSpectrum
        let filtered = PrinterProfile.simulatedTungsten.filteredSpectrum
        XCTAssertEqual(bare[36], 1, accuracy: 1e-6)
        XCTAssertTrue(zip(filtered, bare).allSatisfy { $0 <= $1 })
        XCTAssertLessThan(filtered[34] / bare[34], filtered[60] / bare[60])
    }

    func testExposureChangesOnlyThreePackedMidpointsAndReusesLUT() {
        let a = FilmEngineInvocation(stock: stock, options: options(.simulatedTungsten), width: 32, height: 8)
        let b = FilmEngineInvocation(stock: stock, options: options(PrinterProfile(exposureEV: 1)), width: 32, height: 8)
        XCTAssertEqual(a.spectralCacheID, b.spectralCacheID)
        XCTAssertEqual(a.spectral.filmOutput.values, b.spectral.filmOutput.values)
        XCTAssertEqual(a.spectral.paperOutput?.values, b.spectral.paperOutput?.values)
        for i in a.configuration.indices {
            if midpointSlots.contains(i) {
                XCTAssertEqual(b.configuration[i] - a.configuration[i], log10(Float(2)), accuracy: 1e-6)
            } else { XCTAssertEqual(a.configuration[i], b.configuration[i], "slot \(i)") }
        }
    }

    func testUnsupportedOutputsAndNegativeStageIgnoreThePrinter() {
        for medium in [PrintPaper.screen, .labScan, .telecine, .negative, .vision2383] {
            XCTAssertEqual(SpectralRuntime.cacheIdentifier(for: stock, paper: medium),
                           SpectralRuntime.cacheIdentifier(for: stock, paper: medium,
                              printer: PrinterProfile(lampKelvin: 2800, exposureEV: 2, magenta: 1)))
            var plain = options(nil); plain.paper = medium
            var edited = plain; edited.printer = PrinterProfile(exposureEV: 2)
            let a = FilmEngineInvocation(stock: stock, options: plain, width: 16, height: 8)
            let b = FilmEngineInvocation(stock: stock, options: edited, width: 16, height: 8)
            XCTAssertEqual(a.configuration, b.configuration, medium.id)
            XCTAssertEqual(a.spectralCacheID, b.spectralCacheID, medium.id)
        }
        var a = options(nil); a.stage = .negative
        var b = a; b.printer = PrinterProfile(exposureEV: 2)
        XCTAssertEqual(FilmEngineInvocation(stock: stock, options: a, width: 16, height: 8).configuration,
                       FilmEngineInvocation(stock: stock, options: b, width: 16, height: 8).configuration)
        for look in [NegativeViewing.lightBox, .scanner] {
            var plain = options(nil); plain.negativeViewing = look
            var edited = plain; edited.printer = PrinterProfile(exposureEV: 2)
            let a = FilmEngineInvocation(stock: stock, options: plain, width: 16, height: 8)
            let b = FilmEngineInvocation(stock: stock, options: edited, width: 16, height: 8)
            XCTAssertEqual(a.configuration, b.configuration)
            XCTAssertEqual(a.spectralCacheID, b.spectralCacheID)
        }
        XCTAssertEqual(SpectralRuntime.cacheIdentifier(for: TestStocks.reversal),
                       SpectralRuntime.cacheIdentifier(for: TestStocks.reversal, printer: .simulatedTungsten))
    }

    func testSpectralIntegrationKeepsItsReferenceFixed() {
        let baseline = PrinterProfile.simulatedTungsten
        let edited = PrinterProfile(lampKelvin: 2800, magenta: 0.8, yellow: 0.2)
        let reference = stock.curves.map { $0.density(logExposure: 0) }
        let calibration = SpectralRuntime.paperExposure(density: reference,
            dyes: stock.spectralProfile.imageDyeDensity, lamp: baseline.filteredSpectrum,
            paperSensitivity: paper.sensitivity)
        let table = SpectralRuntime.tables(for: stock, printer: edited)
        let p = SIMD3<Float>(0.25, 0.5, 0.75) // exact LUT lattice point
        let density = (0..<3).map { stock.curves[$0].dMin + p[$0] * (stock.curves[$0].dMax - stock.curves[$0].dMin) }
        let e = SpectralRuntime.paperExposure(density: density,
            dyes: stock.spectralProfile.imageDyeDensity, lamp: edited.filteredSpectrum,
            paperSensitivity: paper.sensitivity)
        let actual = table.filmOutput.sample(p)
        for c in 0..<3 { XCTAssertEqual(actual[c], log10(e[c] / calibration[c]), accuracy: 2e-5) }
        XCTAssertNotEqual(SpectralRuntime.cacheIdentifier(for: stock, printer: baseline),
                          SpectralRuntime.cacheIdentifier(for: stock, printer: edited))
        let referenceActivation = SIMD3<Float>((0..<3).map {
            (reference[$0] - stock.curves[$0].dMin) / (stock.curves[$0].dMax - stock.curves[$0].dMin)
        })
        let shifted = table.filmOutput.sample(referenceActivation)
        XCTAssertGreaterThan(abs(shifted.x) + abs(shifted.y) + abs(shifted.z), 0.05)
    }

    func testReferenceMatchingAndUnreachableTargets() throws {
        let target = SIMD3<Float>((0..<3).map { stock.developedDensity(layer: $0, logExposure: 0) })
        let base = PrinterProfile.simulatedTungsten
        let identity = try base.matching(.densityAndColor, referenceDensity: target, targetDensity: target, stock: stock)
        XCTAssertEqual(identity.printer, base)
        for kelvin: Float in [2800, 3200, 3600] {
            for ev: Float in [-2, -1, 1, 2] {
                let ref = SIMD3<Float>((0..<3).map { stock.developedDensity(layer: $0, logExposure: ev * log10(2)) })
                let p = PrinterProfile(lampKelvin: kelvin)
                let match = try p.matching(.densityAndColor, referenceDensity: ref, targetDensity: target, stock: stock)
                XCTAssertFalse(match.limited, "\(kelvin)K \(ev)EV")
                XCTAssertLessThan(match.residual, 2e-5)
                XCTAssertEqual(match.printer.lampKelvin, kelvin)
                let density = try p.matching(.density, referenceDensity: ref, targetDensity: target, stock: stock)
                XCTAssertFalse(density.limited)
                XCTAssertEqual(density.printer.magenta, p.magenta)
                XCTAssertEqual(density.printer.yellow, p.yellow)
            }
        }
        let impossible = try base.matching(.densityAndColor, referenceDensity: SIMD3(repeating: 8), targetDensity: target, stock: stock)
        XCTAssertTrue(impossible.limited)
        XCTAssertGreaterThan(impossible.residual, 0.1)
        XCTAssertThrowsError(try base.matching(.density, referenceDensity: SIMD3(repeating: .nan), targetDensity: target, stock: stock))
        XCTAssertThrowsError(try base.matching(.density, referenceDensity: target, targetDensity: target, stock: stock, paper: .screen))
    }

    private func negative() -> ImageBuffer {
        var image = ImageBuffer(width: 32, height: 8)
        for c in 0..<3 { for i in 0..<256 {
            let x = Float(i % 32) / 31
            image.planes[c][i] = stock.curves[c].dMin + 0.15 + x * Float(c + 2) * 0.5
        } }
        return image
    }

    func testMatchedReferenceAgreesWithHalideForColorAndMonochrome() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        for s in [stock, TestStocks.monochrome] {
            let reference = SIMD3<Float>(s.curves.map { $0.density(logExposure: 0.2) })
            let target = SIMD3<Float>(s.curves.map { $0.density(logExposure: 0) })
            let match = try PrinterProfile(lampKelvin: 3000).matching(.density,
                referenceDensity: reference, targetDensity: target, stock: s, paper: paper)
            XCTAssertFalse(match.limited)
            var image = ImageBuffer(width: 16, height: 8)
            for c in 0..<3 { image.planes[c] = [Float](repeating: reference[c], count: 128) }
            let rendered = try XCTUnwrap(HalideBackend.print(density: image, stock: s,
                                                             options: options(match.printer)))
            for c in 0..<3 {
                XCTAssertEqual(rendered.planes[c][0], match.referenceRGB[c], accuracy: 0.002)
            }
            if s.isMonochrome {
                XCTAssertEqual(match.referenceRGB.x, match.referenceRGB.y)
                XCTAssertEqual(match.referenceRGB.y, match.referenceRGB.z)
            }
        }
    }

    func testHalidePrintMatchesSpectralReferenceAndDarkensWithExposure() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        let input = negative()
        for p in [PrinterProfile.simulatedTungsten, PrinterProfile(lampKelvin: 2800, exposureEV: 1, magenta: 0.8, yellow: 0.2)] {
            let o = options(p), inv = FilmEngineInvocation(stock: stock, options: o, width: 32, height: 8)
            let actual = try XCTUnwrap(HalideBackend.print(density: input, stock: stock, options: o))
            let curves = paper.printCurves(for: stock)
            for i in 0..<256 {
                let activation = SIMD3<Float>((0..<3).map { (input.planes[$0][i] - stock.curves[$0].dMin) / (stock.curves[$0].dMax - stock.curves[$0].dMin) })
                let rel = inv.spectral.filmOutput.sample(activation)
                let paperActivation = SIMD3<Float>((0..<3).map { c in
                    let x = inv.configuration[midpointSlots[c]] + rel[c]
                    return (curves[c].density(logExposure: x) - curves[c].dMin) / (curves[c].dMax - curves[c].dMin)
                })
                let expected = inv.spectral.paperOutput!.sample(paperActivation)
                for c in 0..<3 { XCTAssertEqual(actual.planes[c][i], expected[c], accuracy: 0.0015) }
            }
        }
        let light = try XCTUnwrap(HalideBackend.print(density: input, stock: stock, options: options(.simulatedTungsten)))
        let dark = try XCTUnwrap(HalideBackend.print(density: input, stock: stock, options: options(PrinterProfile(exposureEV: 1))))
        XCTAssertLessThan(dark.planes[1].reduce(0,+), light.planes[1].reduce(0,+))
    }

#if canImport(Metal)
    func testHalideCPUAndMetalAgreeForPrinterEdits() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable)
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let input = negative()
        var rgba = [Float](repeating: 1, count: 256 * 4)
        for i in 0..<256 { for c in 0..<3 { rgba[i*4+c] = input.planes[c][i] } }
        for p in [PrinterProfile.simulatedTungsten, PrinterProfile(lampKelvin: 3600, exposureEV: -0.7, magenta: 0.1, yellow: 1)] {
            let o = options(p)
            let cpu = try XCTUnwrap(HalideBackend.print(density: input, stock: stock, options: o))
            let metal = try XCTUnwrap(gpu.processLinearFloat(rgba, width: 32, height: 8, stock: stock, options: o, frameIndex: 0))
            for i in 0..<256 { for c in 0..<3 {
                XCTAssertEqual(metal[i*4+c], cpu.planes[c][i], accuracy: 0.002)
            } }
        }
    }
#endif
}
