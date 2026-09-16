import XCTest
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class DigitalReferenceReceiverTests: XCTestCase {
    private var stock: FilmStock { TestStocks.negative }

    /// Walks only development and the receiver. Independent layer exposure is intentional:
    /// these interventions test whether the output preserves the negative's information.
    private func positive(_ stock: FilmStock, exposure: SIMD3<Float>,
                          style: DigitalReferenceStyle = .default,
                          sceneHighlightStops: Float? = nil) -> SIMD3<Float> {
        let tables = SpectralRuntime.tables(for: stock, paper: .screen, digitalReference: style)
        let activation = SIMD3<Float>((0..<3).map { c in
            let curve = stock.curves[c]
            let density = stock.developedDensity(layer: c, logExposure: exposure[c])
            return (density - curve.dMin) / (curve.dMax - curve.dMin)
        })
        let relative = tables.filmOutput.sample(activation)
        let curves = PrintPaper.screen.printCurves(for: stock, digitalReference: style)
        let midpoints = PrintPaper.screen.printExposureMidpoints(for: stock,
                                                                 digitalReference: style)
        let levels = DigitalReferenceReceiver.levels(for: stock, style: style,
                                                     sceneHighlightStops: sceneHighlightStops)
        let printed = SIMD3<Float>((0..<3).map { c in
            let curve = curves[c]
            let x = midpoints[c] + levels.shift + levels.scale * relative[c]
            return (curve.density(logExposure: x) - curve.dMin) / (curve.dMax - curve.dMin)
        })
        return tables.paperOutput!.sample(printed)
    }

    private static let styles = DigitalReferenceStyle.allCases

    private func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        (a - b).maxMagnitude
    }

    func testNegativeDyeSpectraAffectScreenColors() {
        var changed = stock
        let dyes = stock.spectralProfile.imageDyeDensity
        changed.spectralProfile.imageDyeDensity = [dyes[2], dyes[0], dyes[1]]
        let exposures: [SIMD3<Float>] = [SIMD3(0.4, -0.5, -0.6), SIMD3(-0.6, 0.3, -0.4),
                                        SIMD3(-0.5, -0.3, 0.4)]
        let differences = exposures.map { distance(positive(stock, exposure: $0),
                                                   positive(changed, exposure: $0)) }
        XCTAssertGreaterThan(differences.min()!, 0.025,
                             "a digital positive must respond to the negative's dye spectra")
    }

    func testIndividualLayerCurvesSurviveAnUnchangedMeanCurve() {
        var original = stock
        original.curves = [Float(0.45), 0.65, 0.85].enumerated().map { c, gamma in
            CharacteristicCurve(dMin: [Float(0.2), 0.6, 0.9][c], gamma: gamma,
                                toe: -1.2, toeWidth: 0.2, shoulder: 2.5, shoulderWidth: 0.3)
        }
        var changed = original
        changed.curves = [original.curves[2], original.curves[0], original.curves[1]]
        // Permuting the records leaves their average unchanged. A curve-to-average inverse
        // would erase this difference everywhere, even with identical exposure in all layers.
        for logExposure: Float in [-0.7, 0.6] {
            let exposure = SIMD3<Float>(repeating: logExposure)
            XCTAssertGreaterThan(distance(positive(original, exposure: exposure),
                                          positive(changed, exposure: exposure)), 0.015)
        }
        for film in [original, changed] {
            let gray = positive(film, exposure: .zero)
            XCTAssertLessThan(distance(gray, SIMD3(repeating: 0.18)), 0.004,
                              "single-point reference balance must remain stable")
        }
    }

    func testReceiverIsFixedAcrossColorNegatives() {
        var changed = stock
        changed.paperCurve.gamma *= 1.5
        changed.curves.reverse()
        changed.spectralProfile.layerSensitivity.reverse()
        for style in Self.styles {
            let original = SpectralRuntime.tables(for: stock, paper: .screen,
                                                  digitalReference: style)
            let other = SpectralRuntime.tables(for: changed, paper: .screen,
                                               digitalReference: style)
            XCTAssertEqual(original.paperOutput!.values, other.paperOutput!.values,
                           "\(style): the receiver must not characterize away each film's capture response")
        }
        let original = SpectralRuntime.tables(for: stock, paper: .screen)
        let other = SpectralRuntime.tables(for: changed, paper: .screen)
        let density = SIMD3<Float>(0.2, 0.5, 0.8)
        XCTAssertNotEqual(original.filmOutput.sample(density), other.filmOutput.sample(density))
        XCTAssertEqual(PrintPaper.screen.printCurves(for: stock).map(\.gamma),
                       PrintPaper.screen.printCurves(for: changed).map(\.gamma))
    }

    func testReceiverSeparatesSmallReferenceDyeChangesAndHoldsNeutral() {
        let dyes = SpectralGrid.dyes(family: .kodakNegative)
        func energy(_ density: SIMD3<Float>) -> SIMD3<Float> {
            SpectralRuntime.paperExposure(density: [density.x, density.y, density.z],
                dyes: dyes, lamp: DigitalReferenceReceiver.illuminant,
                paperSensitivity: DigitalReferenceReceiver.sensitivity)
        }
        let center = SIMD3<Float>(repeating: 1)
        let reference = energy(center)
        for channel in 0..<3 {
            var delta = SIMD3<Float>(repeating: 0)
            delta[channel] = 0.002
            let ratio = energy(center + delta) / reference
            let reading = DigitalReferenceReceiver.read(SIMD3(
                log10(ratio.x), log10(ratio.y), log10(ratio.z)))
            XCTAssertLessThan(distance(reading, -delta), 2e-6,
                              "receiver band overlap must not create a shared color bias")
        }
        for level: Float in [-3, -0.5, 0, 0.5, 3] {
            let neutral = SIMD3<Float>(repeating: level)
            XCTAssertLessThan(distance(DigitalReferenceReceiver.read(neutral), neutral), 1e-6)
        }
    }

    func testYellowStaysDistinctFromOrangeAcrossNegativeFamilies() throws {
        func hue(_ color: SIMD3<Float>) -> Float {
            let linear = ColorScience.linearDisplayP3ToSRGB(color)
            let rgb = SIMD3<Float>((0..<3).map {
                ColorScience.linearToSrgb(min(max(linear[$0], 0), 1))
            })
            let low = min(rgb.x, rgb.y, rgb.z), high = max(rgb.x, rgb.y, rgb.z)
            let span = max(high - low, 1e-6)
            let sector: Float = high == rgb.x ? (rgb.y - rgb.z) / span
                : high == rgb.y ? 2 + (rgb.z - rgb.x) / span
                : 4 + (rgb.x - rgb.y) / span
            return sector < 0 ? (sector + 6) * 60 : sector * 60
        }
        let colors: [SIMD3<Float>] = [SIMD3(0.8, 0.75, 0.12), SIMD3(0.85, 0.48, 0.12)]
        var scene = ImageBuffer(width: 32, height: 16)
        for (patch, color) in colors.enumerated() {
            let linear = SIMD3<Float>((0..<3).map { ColorScience.srgbToLinear(color[$0]) })
            let rgb = ColorScience.linearSRGBToRec2020(linear)
            for y in 0..<16 { for x in (patch * 16)..<((patch + 1) * 16) {
                for c in 0..<3 { scene.planes[c][y * 32 + x] = rgb[c] }
            }}
        }
        for id in ["portra400", "gold200", "superia400", "vision500t"] {
            var film = try XCTUnwrap(FilmStock.named(id), id)
            film.emulsionDiffusionMM = [0, 0, 0]
            film.emulsionDiffusionSecondaryMM = [0, 0, 0]
            film.adjacencyStrength = 0
            for couplers: Float in [0, 1] {
                var options = FotufilmEngine.Options()
                options.paper = .screen; options.grainScale = 0; options.halationScale = 0
                options.flareScale = 0; options.couplerScale = couplers; options.localTone = false
                let output = try FotufilmEngine(stock: film, options: options)
                    .processChecked(linearRGB: scene)
                let yellow = hue(SIMD3((0..<3).map { output.planes[$0][8 * 32 + 8] }))
                let orange = hue(SIMD3((0..<3).map { output.planes[$0][8 * 32 + 24] }))
                XCTAssertGreaterThan(yellow, 49, "\(id), couplers \(couplers)")
                XCTAssertLessThan(yellow, 72, "\(id), couplers \(couplers)")
                XCTAssertGreaterThan(yellow - orange, 12, id)
            }
        }
    }

    func testEveryStyleHoldsMidGreyAndReachesDisplayBlack() throws {
        // One 8-bit sRGB code is 3.0e-4 of display white. The darkest receiver exposure any
        // negative can deliver is its own base, and the green record must land within a code of
        // zero there on every style, while mid-grey stays on the 18% anchor.
        let oneCode: Float = 1 / (255 * 12.92)
        for style in Self.styles {
            for id in ["portra400", "gold200", "superia200", "vision500t", "eterna500"] {
                let film = try XCTUnwrap(FilmStock.named(id), id)
                let base = positive(film, exposure: SIMD3(repeating: -8), style: style)
                XCTAssertLessThan(base.y, 1.5 * oneCode, "\(id) \(style)")
                XCTAssertGreaterThanOrEqual(min(base.x, base.y, base.z), 0, "\(id) \(style)")
                let grey = positive(film, exposure: .zero, style: style)
                XCTAssertLessThan(distance(grey, SIMD3(repeating: 0.18)), 0.005,
                                  "\(id) \(style): the anchor must stay on mid-grey")
            }
        }
    }

    func testAutoLevelsPlacesTheMeteredHighlightAtWhite() throws {
        let film = try XCTUnwrap(FilmStock.named("gold200"))
        let weights = ColorScience.displayP3LuminanceWeights
        func luminance(_ rgb: SIMD3<Float>) -> Float {
            weights.0 * rgb.x + weights.1 * rgb.y + weights.2 * rgb.z
        }
        // Without a meter the frame renders as the graded print.
        for stops: Float in [-3, 0, 2] {
            let exposure = SIMD3<Float>(repeating: stops * log10(2))
            XCTAssertLessThan(distance(positive(film, exposure: exposure, style: .autoLevels),
                                       positive(film, exposure: exposure, style: .gradedPrint)),
                              1e-5)
        }
        // A frame whose brightest content sits eight stops up lands that content near white and
        // moves its mid-grey down; one whose brightest content is two stops up brightens it.
        let bright = SIMD3<Float>(repeating: 8 * log10(2))
        let high = luminance(positive(film, exposure: bright, style: .autoLevels,
                                      sceneHighlightStops: 8))
        XCTAssertGreaterThan(high, 0.85)
        XCTAssertLessThan(luminance(positive(film, exposure: .zero, style: .autoLevels,
                                             sceneHighlightStops: 8)), 0.12)
        XCTAssertGreaterThan(luminance(positive(film, exposure: .zero, style: .autoLevels,
                                                sceneHighlightStops: 2)), 0.25)
        // The base is black whatever the frame holds.
        for stops: Float in [1, 4, 10] {
            XCTAssertLessThan(positive(film, exposure: SIMD3(repeating: -8), style: .autoLevels,
                                       sceneHighlightStops: stops).y, 1.5 / (255 * 12.92))
        }
    }

    func testStylesDifferOnlyWhereTheyShould() throws {
        let film = try XCTUnwrap(FilmStock.named("gold200"))
        // The graded print rolls highlights into paper white where the reference exposure lets
        // them run on toward display white; both share the film-base black.
        let high = SIMD3<Float>(repeating: 3 * log10(2))
        XCTAssertLessThan(positive(film, exposure: high, style: .gradedPrint).y,
                          positive(film, exposure: high, style: .referenceExposure).y)
        let mid = SIMD3<Float>(repeating: -1 * log10(2))
        XCTAssertEqual(positive(film, exposure: mid, style: .gradedPrint).y,
                       positive(film, exposure: mid, style: .referenceExposure).y, accuracy: 0.02)
    }

    func testScreenNeutralRampIsFiniteMonotonicAndMatchesToneAnalysis() {
        let stops = stride(from: Float(-6), through: 4, by: 0.125).map { $0 }
        let weights = ColorScience.displayP3LuminanceWeights
        for (film, style) in [(stock, DigitalReferenceStyle.referenceExposure),
                              (stock, .gradedPrint), (stock, .autoLevels),
                              (TestStocks.monochrome, .default)] {
            let analytic = SpectralRuntime.neutralToneScale(stops: stops, stock: film,
                                                           paper: .screen, printCorrection: 0,
                                                           digitalReference: style)
            var previous: Float = -1
            for (index, stop) in stops.enumerated() {
                let rgb = positive(film, exposure: SIMD3(repeating: stop * log10(Float(2))),
                                   style: style)
                XCTAssertTrue((0..<3).allSatisfy { rgb[$0].isFinite && rgb[$0] >= 0 })
                let y = weights.0 * rgb.x + weights.1 * rgb.y + weights.2 * rgb.z
                XCTAssertGreaterThanOrEqual(y + 2e-4, previous)
                XCTAssertEqual(y, analytic[index], accuracy: 0.006,
                               "\(style): auto exposure must use the same tone scale as the receiver")
                previous = y
            }
        }
    }

    func testMeterOnlyChangesAutoLevelsAndPreservesTables() throws {
        let film = try XCTUnwrap(FilmStock.named("gold200"))
        for style in Self.styles {
            var options = FotufilmEngine.Options()
            options.paper = .screen; options.digitalReference = style
            options.localTone = false
            var invocation = try FilmEngineInvocation(validating: film, options: options,
                                                       width: 16, height: 16)
            let original = invocation.configuration
            let cache = invocation.spectralCacheID
            let pixels = [Float](repeating: 8, count: 16 * 16 * 4)
            var measurement = invocation.toneBaseMeasurement()
            pixels.withUnsafeBufferPointer { measurement.add(linearRGBA: $0.baseAddress!, rows: 0..<16) }
            invocation.setToneBase(measurement)
            let metered = invocation.configuration
            invocation.setToneBase(measurement)
            XCTAssertEqual(invocation.configuration, metered, "Repeated measurements must not accumulate")
            XCTAssertEqual(invocation.spectralCacheID, cache, "Metering must not rebuild spectral tables")
            let midpoint = FilmEngineInvocation.paperMidpointRedOffset
            if style == .autoLevels {
                XCTAssertNotEqual(original[midpoint], metered[midpoint])
            } else {
                XCTAssertEqual(original[midpoint], metered[midpoint])
            }
        }
    }

    #if canImport(Metal)
    func testScreenColorAndGrayRampMatchesCPUOnMetal() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide engine required")
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let width = 32, height = 24
        var scene = ImageBuffer(width: width, height: height)
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let level = 0.18 * pow(Float(2), Float(x) / Float(width - 1) * 9 - 6)
            let color: [Float] = y < 4 ? [1, 1, 1] : y < 8 ? [1, 0.2, 0.1]
                : y < 12 ? [0.2, 1, 0.1] : y < 16 ? [0.15, 0.25, 1]
                : y < 20 ? [1, 0.87, 0.02] : [1, 0.32, 0.02]
            let i = y * width + x
            for c in 0..<3 { scene.planes[c][i] = level * color[c]; rgba[4 * i + c] = level * color[c] }
        }}
        var options = FotufilmEngine.Options()
        options.paper = .screen; options.grainScale = 0; options.halationScale = 0
        options.localTone = false
        for style in Self.styles {
            options.digitalReference = style
            for id in ["portra400", "gold200", "superia400", "vision500t"] {
            let film = try XCTUnwrap(FilmStock.named(id), id)
            let cpu = try FotufilmEngine(stock: film, options: options).processChecked(linearRGB: scene)
            let metal = try XCTUnwrap(gpu.processLinearFloat(rgba, width: width, height: height,
                                                            stock: film, options: options))
            for i in 0..<(width * height) { for c in 0..<3 {
                XCTAssertTrue(cpu.planes[c][i].isFinite && metal[4 * i + c].isFinite)
                XCTAssertEqual(cpu.planes[c][i], metal[4 * i + c], accuracy: 2e-4, id)
            }}
            }
        }
    }
    #endif
}

private extension SIMD3 where Scalar == Float {
    var maxMagnitude: Float { Swift.max(abs(x), Swift.max(abs(y), abs(z))) }
}
