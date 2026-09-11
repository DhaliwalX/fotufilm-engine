import XCTest
@testable import FotufilmCore

final class ReleasePrintTests: XCTestCase {
    private let prints: [PrintPaper] = [.vision2383, .vision2393, .eternaCP]

    func testMediumOwnsGreyForStillAndMotionPictureNegatives() throws {
        for id in ["gold200", "vision250d", "vision500t", "eterna500", "trix400"] {
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
                let curves = paper.printCurves(for: stock)
                let expectedMidpoints = paper.printExposureMidpoints(for: stock)
                for (channel, curve) in curves.enumerated() {
                    let density = curve.density(
                        logExposure: invocation.configuration[midpoints[channel]])
                    XCTAssertEqual(invocation.configuration[midpoints[channel]], expectedMidpoints[channel])
                    if let aim = paper.ladStatusA, !stock.isMonochrome {
                        XCTAssertEqual(density, aim[channel], accuracy: 1e-5,
                                       "\(id) \(paper): LAD is gross Status A density")
                    }
                }
                let tone = SpectralRuntime.neutralToneScale(
                    stops: [0], stock: stock, paper: paper, printCorrection: 1)
                let receiver = SpectralRuntime.printReceiver(stock: stock, paper: paper,
                    viewingLight: SpectralRuntime.referenceViewingLight(for: paper))
                let density = SIMD3((0..<3).map {
                    curves[$0].density(logExposure: expectedMidpoints[$0]) - curves[$0].dMin
                })
                let rgb = receiver.rgb(density: density)
                let w = ColorScience.displayP3LuminanceWeights
                XCTAssertEqual(tone[0], rgb.x*w.0 + rgb.y*w.1 + rgb.z*w.2,
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
        let lad = curve.logExposure(density: 1.06)
        let highlight = curve.logExposure(density: curve.dMin + 0.1)
        let shadow = curve.logExposure(density: curve.dMin + 3)
        // Printer exposure stops. A negative of gamma ~0.6 expands this into about
        // half a stop of additional scene highlight room, with less shadow room.
        XCTAssertGreaterThan((lad - highlight) / log10(2), (old - highlight) / log10(2) + 0.25)
        XCTAssertLessThan((shadow - lad) / log10(2), (shadow - old) / log10(2) - 0.25)
    }

    func testAdditivePrinterBlocksUVAndTimesAllReceivingLayers() throws {
        for id in ["gold200", "vision250d", "vision500t", "eterna500"] {
            let stock = try XCTUnwrap(FilmStock.named(id))
            let density = stock.curves.map { $0.density(logExposure: 0) }
            let dyes = stock.spectralProfile.imageDyeDensity
            for paper in prints {
                let illumination = SpectralRuntime.printingIllumination(stock: stock,
                    paper: paper, density: density, dyes: dyes)
                let lamp = illumination.lamp
                XCTAssertEqual(lamp.count, SpectralGrid.count)
                XCTAssertTrue(lamp.allSatisfy { $0.isFinite && $0 >= 0 })
                for (i, wavelength) in SpectralGrid.wavelengths.enumerated()
                    where wavelength <= 400 || wavelength >= 730 {
                    XCTAssertEqual(lamp[i], 0)
                }
                let mid = SpectralRuntime.paperExposure(density: density, dyes: dyes,
                    lamp: lamp, paperSensitivity: paper.sensitivity)
                XCTAssertGreaterThan(mid.y, 0)
                for channel in 0..<3 {
                    XCTAssertEqual(mid[channel] / illumination.referenceEnergy[channel], 1,
                                   accuracy: 1e-4, "\(id) \(paper)")
                }
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

    func testLADAimsAndSensitivityMeasurementDensities() {
        let stock = TestStocks.negative
        XCTAssertEqual(PrintPaper.vision2383.ladStatusA, SIMD3(1.09, 1.06, 1.03))
        XCTAssertEqual(PrintPaper.vision2393.ladStatusA, SIMD3(1.09, 1.06, 1.03))
        XCTAssertEqual(PrintPaper.eternaCP.ladStatusA, SIMD3(1.10, 1.05, 1.05))
        for paper in prints {
            let curves = paper.printCurves(for: stock)
            let reference = paper.sensitivityReferenceExposures(for: stock)
            for channel in 0..<3 {
                XCTAssertEqual(curves[channel].density(logExposure: reference[channel]),
                    paper == .eternaCP ? 1 + curves[channel].dMin : 1, accuracy: 1e-5)
            }
        }
        XCTAssertEqual(PrintPaper.vision2383.sensitivity,
                       Vision2383PrintSpectra.layerSensitivity.map(SpectralGrid.continuedTails))
        XCTAssertEqual(PrintPaper.vision2393.sensitivity,
                       Vision2393PrintSpectra.layerSensitivity.map(SpectralGrid.continuedTails))
        XCTAssertEqual(PrintPaper.eternaCP.sensitivity,
                       EternaCPPrintSpectra.layerSensitivity.map(SpectralGrid.continuedTails))
    }

    func testPrinterMixMatchesAnIndependentLinearSolve() throws {
        let stock = try XCTUnwrap(FilmStock.named("vision250d"))
        let density = stock.curves.map { $0.density(logExposure: 0) }
        let dyes = stock.spectralProfile.imageDyeDensity
        let beams = SpectralGrid.releasePrinterBeams
        func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x)
        }
        func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a*b).sum() }
        for paper in prints {
            let columns = beams.map {
                SpectralRuntime.paperExposure(density: density, dyes: dyes,
                    lamp: $0, paperSensitivity: paper.sensitivity)
            }
            let target = paper.printingAim(for: stock)
            let determinant = dot(columns[0], cross(columns[1], columns[2]))
            let weights = SIMD3(dot(target, cross(columns[1], columns[2])),
                dot(columns[0], cross(target, columns[2])),
                dot(columns[0], cross(columns[1], target))) / determinant
            XCTAssertGreaterThan(min(weights.x, min(weights.y, weights.z)), 0)
            let expected = (0..<SpectralGrid.count).map {
                beams[0][$0]*weights.x + beams[1][$0]*weights.y + beams[2][$0]*weights.z
            }
            let actual = SpectralRuntime.releasePrinterLamp(density: density, dyes: dyes,
                sensitivity: paper.sensitivity, target: target)
            let peak = expected.max()!
            for i in actual.indices { XCTAssertEqual(actual[i]/peak, expected[i]/peak, accuracy: 1e-5) }
            // Blue-to-magenta leakage is still present, but must not be inflated by
            // flattening the sheet's layer speeds. This is a model invariant, not a lab fit.
            let blueFraction = columns[2].y * weights.z / target.y
            XCTAssertLessThan(blueFraction, 0.03, "\(paper): \(blueFraction)")
            XCTAssertGreaterThan(blueFraction, 0)
        }
    }

    func testUnreachablePrinterAimDoesNotSubtractPhotons() {
        let paper = PrintPaper.vision2383
        let density: [Float] = [0, 0, 0]
        let dyes = TestStocks.negative.spectralProfile.imageDyeDensity
        let target = SIMD3<Float>(0, 1, 0)
        let lamp = SpectralRuntime.releasePrinterLamp(density: density, dyes: dyes,
            sensitivity: paper.sensitivity, target: target)
        XCTAssertTrue(lamp.allSatisfy { $0.isFinite && $0 >= 0 })
        let response = SpectralRuntime.paperExposure(density: density, dyes: dyes,
            lamp: lamp, paperSensitivity: paper.sensitivity)
        XCTAssertGreaterThan(response.y, 0.9)
        XCTAssertGreaterThan(response.x + response.z, 0,
            "overlapping layers cannot expose only green; retain the timing residual")
    }

    func testSceneBalanceDoesNotSelectADifferentPrinterSource() throws {
        let stock = try XCTUnwrap(FilmStock.named("vision250d"))
        var retagged = stock
        retagged.referenceIlluminantKelvin = 3200
        let density = stock.curves.map { $0.density(logExposure: 0) }
        let dyes = stock.spectralProfile.imageDyeDensity
        for paper in prints {
            XCTAssertEqual(SpectralRuntime.printingIllumination(stock: stock, paper: paper,
                density: density, dyes: dyes).lamp,
                SpectralRuntime.printingIllumination(stock: retagged, paper: paper,
                density: density, dyes: dyes).lamp)
            // Retained neutral silver changes the required overall exposure, not beam colour.
            let plain = SpectralRuntime.printingIllumination(stock: stock, paper: paper,
                density: density, dyes: dyes)
            let silver = SpectralRuntime.printingIllumination(stock: stock, paper: paper,
                density: density, dyes: dyes, neutralDensity: 0.7)
            for i in plain.lamp.indices { XCTAssertEqual(plain.lamp[i], silver.lamp[i], accuracy: 1e-5) }
            for c in 0..<3 {
                XCTAssertEqual(silver.referenceEnergy[c] / plain.referenceEnergy[c],
                               pow(10, -0.7), accuracy: 1e-5)
            }
        }
        XCTAssertEqual(FotufilmEngine.Options().printCorrection, 0)
    }

    func testReflectiveAndScanLampsRetainTheirExistingSpectra() {
        let stock = TestStocks.negative
        let density = stock.curves.map { $0.density(logExposure: 0) }
        for paper: PrintPaper in [.ektacolorEdge, .enduraPremier, .crystalArchive, .labScan, .telecine] {
            XCTAssertEqual(SpectralRuntime.printingIllumination(stock: stock,
                paper: paper, density: density, dyes: stock.spectralProfile.imageDyeDensity).lamp,
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
        for id in ["gold200", "vision250d", "vision500t"] {
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
