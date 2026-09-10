import XCTest
@testable import FotufilmCore

final class ReleasePrintTests: XCTestCase {
    private let prints: [PrintPaper] = [.vision2383, .vision2393, .eternaCP]

    func testMediumOwnsGreyForStillAndMotionPictureNegatives() throws {
        for id in ["gold200", "vision250d", "eterna500", "trix400"] {
            var stock = try XCTUnwrap(FilmStock.named(id))
            // Old packs can carry any valid paperMidDensity. It must not retime a medium.
            stock.paperMidDensity = 0.3
            for paper in prints + [.ektacolorEdge] {
                var options = FotufilmEngine.Options()
                options.paper = paper
                let invocation = FilmEngineInvocation(stock: stock, options: options,
                                                       width: 16, height: 16)
                let midpoints = [FilmEngineInvocation.paperMidpointRedOffset, 62,
                                 FilmEngineInvocation.paperMidpointBlueOffset]
                for (channel, curve) in paper.printCurves(for: stock).enumerated() {
                    let density = curve.density(
                        logExposure: invocation.configuration[midpoints[channel]]) - curve.dMin
                    let viewed = (pow(10, -density) + paper.viewingFlare)
                        / (1 + paper.viewingFlare)
                    XCTAssertEqual(viewed, paper.isProjected ? 0.1 : pow(10, -0.744),
                                   accuracy: 1e-5, "\(id) \(paper) record \(channel)")
                }
                let tone = SpectralRuntime.neutralToneScale(
                    stops: [0], stock: stock, paper: paper, printCorrection: 1)
                XCTAssertEqual(tone[0], paper.isProjected ? 0.1 : pow(10, -0.744),
                               accuracy: 1e-4, "analytic mirror: \(id) \(paper)")
            }
        }
    }

    func testStockLegacyGreyDoesNotChangeTableIdentity() {
        var stock = TestStocks.negative
        for paper in prints + [.ektacolorEdge, .screen, .labScan, .telecine] {
            let original = SpectralRuntime.cacheIdentifier(for: stock, paper: paper)
            stock.paperMidDensity += 0.1
            XCTAssertEqual(original, SpectralRuntime.cacheIdentifier(for: stock, paper: paper))
        }
    }

    func test2383RecordsMatchPublishedCurveReadings() {
        // H-1-2383 (March 2022), PDF p. 4: log exposure 0.5, 1.0, 1.5.
        let curves = PrintPaper.vision2383.printCurves(for: TestStocks.negative)
        let readings: [[Float]] = [[0.183, 0.975, 3.098], [0.599, 2.257, 3.748],
                                   [1.468, 3.522, 4.037]]
        for channel in 0..<3 {
            for (index, exposure) in [Float(0.5), 1, 1.5].enumerated() {
                XCTAssertEqual(curves[channel].density(logExposure: exposure),
                               readings[channel][index], accuracy: 0.06)
            }
        }
        XCTAssertGreaterThan(curves[2].dMin, curves[0].dMin)
        XCTAssertGreaterThan(curves[2].dMin, curves[1].dMin)
        XCTAssertGreaterThan(curves[0].toe, curves[1].toe)
        XCTAssertGreaterThan(curves[1].toe, curves[2].toe)
    }

    func testLADIncreases2383HighlightExposureRange() {
        let curve = Vision2383PrintSpectra.greenCurve
        let old = curve.logExposure(density: curve.dMin + 0.744)
        let lad = curve.logExposure(density: curve.dMin + PrintPaper.vision2383.anchorDensity)
        let highlight = curve.logExposure(density: curve.dMin + 0.1)
        let shadow = curve.logExposure(density: curve.dMin + 3)
        // Printer exposure stops. A negative of gamma ~0.6 expands this into about
        // half a stop of additional scene highlight room, with less shadow room.
        XCTAssertGreaterThan((lad - highlight) / log10(2), (old - highlight) / log10(2) + 0.25)
        XCTAssertLessThan((shadow - lad) / log10(2), (shadow - old) / log10(2) - 0.25)
    }

    func testAdditivePrinterBlocksUVAndTimesAllReceivingLayers() throws {
        for id in ["gold200", "vision250d", "eterna500"] {
            let stock = try XCTUnwrap(FilmStock.named(id))
            let density = stock.curves.map { $0.density(logExposure: 0) }
            let dyes = stock.spectralProfile.imageDyeDensity
            for paper in prints {
                let lamp = SpectralRuntime.printingLamp(paper: paper, density: density, dyes: dyes)
                XCTAssertEqual(lamp.count, SpectralGrid.count)
                XCTAssertTrue(lamp.allSatisfy { $0.isFinite && $0 >= 0 })
                for (i, wavelength) in SpectralGrid.wavelengths.enumerated()
                    where wavelength <= 400 || wavelength >= 730 {
                    XCTAssertEqual(lamp[i], 0)
                }
                let mid = SpectralRuntime.paperExposure(density: density, dyes: dyes,
                    lamp: lamp, paperSensitivity: paper.sensitivity)
                XCTAssertGreaterThan(mid.y, 0)
                XCTAssertEqual(mid.x / mid.y, 1, accuracy: 1e-4, "\(id) \(paper)")
                XCTAssertEqual(mid.z / mid.y, 1, accuracy: 1e-4, "\(id) \(paper)")
                // Filtering alters relative colour responses, not just the scalar anchor.
                let bare = SpectralGrid.enlarger3200K
                let bareMid = SpectralRuntime.paperExposure(density: density, dyes: dyes,
                    lamp: bare, paperSensitivity: paper.sensitivity)
                var coloured = density
                coloured[2] += 0.8
                let timed = SpectralRuntime.paperExposure(density: coloured, dyes: dyes,
                    lamp: lamp, paperSensitivity: paper.sensitivity) / mid
                let untimed = SpectralRuntime.paperExposure(density: coloured, dyes: dyes,
                    lamp: bare, paperSensitivity: paper.sensitivity) / bareMid
                let delta = timed - untimed
                XCTAssertGreaterThan((delta * delta).sum(), 1e-7)
            }
        }
    }

    func testReflectiveAndScanLampsRetainTheirExistingSpectra() {
        let stock = TestStocks.negative
        let density = stock.curves.map { $0.density(logExposure: 0) }
        for paper: PrintPaper in [.ektacolorEdge, .enduraPremier, .crystalArchive, .labScan, .telecine] {
            XCTAssertEqual(SpectralRuntime.printingLamp(
                paper: paper, density: density, dyes: stock.spectralProfile.imageDyeDensity),
                paper.isScan ? SpectralGrid.equalEnergy : SpectralGrid.enlarger3200K)
        }
    }
}

#if canImport(Metal) && canImport(CoreGraphics)
import Metal
import FotufilmMetal

extension ReleasePrintTests {
    func testReleasePrintDeliveryAgreesOnCPUAndMetal() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide engine required")
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let side = 16, count = 16 * 16
        let neutrals = [Float(-6), -4, -2, -1, 0, 1, 3, 5]
            .map { SIMD3<Float>(repeating: 0.18 * exp2($0)) }
        let colours = neutrals + [SIMD3(0.6, 0.03, 0.02), SIMD3(0.03, 0.6, 0.06),
            SIMD3(0.02, 0.08, 0.6), SIMD3(0.6, 0.5, 0.02), SIMD3(0.5, 0.2, 0.12),
            SIMD3(0.15, 0.06, 0.03), SIMD3(0.05, 0.4, 0.4), SIMD3(0.5, 0.03, 0.4)]
        let bytes = count * 4 * MemoryLayout<Float>.stride
        let input = try XCTUnwrap(device.makeBuffer(length: bytes, options: .storageModeShared))
        let output = try XCTUnwrap(device.makeBuffer(length: bytes, options: .storageModeShared))
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.halationScale = 0
        options.couplerScale = 0
        options.localTone = false
        for id in ["gold200", "vision250d"] {
            var stock = try XCTUnwrap(FilmStock.named(id))
            stock.flare = 0
            for paper in prints {
                options.paper = paper
                var chart = ImageBuffer(width: 128, height: 32)
                var worst: Float = 0
                // Uniform frames isolate colour response while still running the full pipeline.
                for (patch, colour) in colours.enumerated() {
                    var scene = ImageBuffer(width: side, height: side)
                    let rgba = input.contents().assumingMemoryBound(to: Float.self)
                    for i in 0..<count {
                        for channel in 0..<3 {
                            scene.planes[channel][i] = colour[channel]
                            rgba[i * 4 + channel] = colour[channel]
                        }
                        rgba[i * 4 + 3] = 1
                    }
                    let cpu = FotufilmEngine(stock: stock, options: options).process(linearRGB: scene)
                    XCTAssertTrue(gpu.processLinearFloat(input: input, output: output,
                        width: side, height: side, stock: stock, options: options))
                    let metal = output.contents().assumingMemoryBound(to: Float.self)
                    for i in 0..<count {
                        for channel in 0..<3 {
                            // CPU's raw P3 can be signed outside the gamut; Metal float
                            // output already applies the delivery floor. Compare like values.
                            XCTAssertTrue(cpu.planes[channel][i].isFinite)
                            let expected = max(cpu.planes[channel][i], 0)
                            XCTAssertTrue(metal[i * 4 + channel].isFinite)
                            worst = max(worst, abs(expected - metal[i * 4 + channel]))
                            let x = (patch % 8) * side + i % side
                            let y = (patch / 8) * side + i / side
                            chart.planes[channel][y * chart.width + x] = expected
                        }
                    }
                }
                print("PRINT FIELDS \(id) \(paper) CPU/Metal max \(worst)")
                XCTAssertLessThan(worst, 1e-4, "\(id) \(paper): CPU/Metal delta \(worst)")
                if let directory = ProcessInfo.processInfo.environment["FOTUFILM_RELEASE_PRINT_REVIEW_DIR"] {
                    let destination = URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent("\(id)-\(paper.rawValue).png")
                    try RGBAImage(print: chart).pngData().write(to: destination)
                }
            }
        }
    }
}
#endif
