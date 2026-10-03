import XCTest
import FotufilmHalide
@testable import FotufilmCore

final class LabScanTimingTests: XCTestCase {
    private let log2Stop = Float(log10(2.0))

    /// Where the setup lands a grey at `stops` after the edit's exposure, in stops of the fixed
    /// profile: the grey whose green read its levelled scan reads.
    private func landed(_ setup: LabScanTiming.Setup, _ stops: Float, _ film: FilmStock) -> Float {
        let masking = LabScanTiming.profilePoints(for: film).masking.y
        func read(_ stops: Float) -> Float { LabScanTiming.reads(for: film, stops: stops).y * masking }
        let scanned = setup.scale.y * read(stops + setup.shift / log2Stop) + setup.print.y
        var low: Float = -16, high: Float = 16
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if read(middle) > scanned { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    /// The setup's own tone map, in stops of the fixed profile: steepened about the toe until the
    /// highlight would scan at white, then keyed on the median or bounded by white.
    private func placement(_ film: FilmStock, highlight: Float, median: Float,
                           exposureEV: Float = 0) -> (Float) -> Float {
        let points = LabScanTiming.profilePoints(for: film)
        let (middle, high) = (median - exposureEV, highlight - exposureEV)
        let contrast = min(max((points.white - points.toe) / (high - points.toe), 1),
                           LabScanTiming.maxStretch)
        func placed(_ x: Float) -> Float { points.toe + contrast * (x - points.toe) }
        let stops = min(0, (1 - LabScanTiming.keyShare) * middle - placed(middle),
                        points.white - placed(high))
        return { placed($0 - exposureEV) + exposureEV + stops }
    }

    func testUnmeteredFrameScansAtTheFixedProfile() throws {
        let film = try XCTUnwrap(FilmStock.named("portra400"))
        XCTAssertEqual(LabScanTiming.setup(for: film, sceneHighlightStops: nil,
                                           sceneMedianStops: nil), .identity)
    }

    func testOperatorKeysAndLighteningRideTheFilmsExposure() throws {
        let film = try XCTUnwrap(FilmStock.named("portra400"))
        let keyed = LabScanTiming.setup(for: film, sceneHighlightStops: nil, sceneMedianStops: nil,
                                        scanExposure: 1, keys: SIMD3(1, 0, -0.5))
        XCTAssertEqual(keyed.shift, log2Stop, accuracy: 1e-6)
        XCTAssertEqual(keyed.keys, SIMD3(-LabScanTiming.keyReach, 0, 0.5 * LabScanTiming.keyReach))
        XCTAssertEqual(keyed.scale, .one)
        XCTAssertEqual(keyed.print, .zero)
        // A darker scan levels the scan's records instead, a stop darker at both anchors.
        let darker = LabScanTiming.setup(for: film, sceneHighlightStops: nil, sceneMedianStops: nil,
                                         scanExposure: -1, keys: SIMD3(1, 0, -0.5))
        XCTAssertEqual(darker.shift, 0)
        XCTAssertEqual(darker.keys, keyed.keys)
        for stops in [-LabScanTiming.recordAnchorBelow, LabScanTiming.recordAnchorSpan] {
            XCTAssertEqual(landed(darker, stops, film), stops - 1, accuracy: 1e-3)
        }
        // Every layer forms at the exposure the keys give it.
        for (layer, curve) in keyed.curves(for: film).enumerated() {
            for x: Float in [-2, -0.5, 0, 1.5] {
                XCTAssertEqual(curve.density(logExposure: x),
                               film.curves[layer].density(
                                   logExposure: x + keyed.shift + keyed.keys[layer]),
                               accuracy: 1e-4, "layer \(layer) at \(x)")
            }
        }
        // A monochrome film takes the density alone, and a slide is not set up.
        let mono = try XCTUnwrap(FilmStock.named("example-monochrome-100"))
        XCTAssertEqual(LabScanTiming.setup(for: mono, sceneHighlightStops: nil, sceneMedianStops: nil,
                                           keys: SIMD3(1, 1, 1)).keys, .zero)
        let slide = try XCTUnwrap(FilmStock.named("example-reversal-64"))
        XCTAssertEqual(LabScanTiming.setup(for: slide, sceneHighlightStops: 2, sceneMedianStops: 0,
                                           scanExposure: 1), .identity)
    }

    func testRecordsScanTheBracketingGreysWhereTheFixedProfileScansTheirPlacedGreys() throws {
        // Each record, not just green: a grey at either anchor scans neutral.
        for id in ["portra400", "gold200", "superia400"] {
            let film = try XCTUnwrap(FilmStock.named(id), id)
            let masking = LabScanTiming.profilePoints(for: film).masking
            for (median, high): (Float, Float) in [(1, 7), (0, 2), (-3, 1), (2, 3)] {
                let setup = LabScanTiming.setup(for: film, sceneHighlightStops: high,
                                                sceneMedianStops: median)
                let place = placement(film, highlight: high, median: median)
                for stops in [median - LabScanTiming.recordAnchorBelow,
                              max(high, median + LabScanTiming.recordAnchorSpan)] {
                    let scanned = setup.scale * LabScanTiming.reads(for: film, stops: stops) * masking
                        + setup.print
                    let target = LabScanTiming.reads(for: film, stops: place(stops)) * masking
                    for c in 0..<3 {
                        XCTAssertEqual(scanned[c], target[c], accuracy: 1e-4,
                                       "\(id) \(median) \(high) at \(stops) record \(c)")
                    }
                }
            }
        }
    }

    func testDenseFrameIsPlacedOnItsHighlightAtTheStockContrast() throws {
        for id in ["portra400", "gold200"] {
            let film = try XCTUnwrap(FilmStock.named(id), id)
            let white = LabScanTiming.profilePoints(for: film).white
            let setup = LabScanTiming.setup(for: film, sceneHighlightStops: 7, sceneMedianStops: 1)
            XCTAssertEqual(landed(setup, 7, film), white, accuracy: 1e-3, id)
            XCTAssertEqual(landed(setup, -1, film), white - 8, accuracy: 1e-3, id)
        }
    }

    func testFrameOpensUpToWhiteAboutItsToeWithinTheStretch() throws {
        for id in ["portra400", "gold200"] {
            let film = try XCTUnwrap(FilmStock.named(id), id)
            let points = LabScanTiming.profilePoints(for: film)
            for (median, high): (Float, Float) in [(-6, 0), (-3, 1), (-1, 3)] {
                let setup = LabScanTiming.setup(for: film, sceneHighlightStops: high,
                                                sceneMedianStops: median)
                let place = placement(film, highlight: high, median: median)
                // Steepened, within the stretch, and never lifted past the toe; the scan lands
                // the anchors on the placement exactly (`testRecordsScanTheBracketingGreys…`).
                let span = place(high) - place(median)
                XCTAssertGreaterThanOrEqual(span, high - median - 1e-4, "\(id) \(median)")
                XCTAssertLessThanOrEqual(span, LabScanTiming.maxStretch * (high - median) + 1e-4,
                                         "\(id) \(median)")
                XCTAssertLessThanOrEqual(place(points.toe), points.toe + 1e-4, "\(id) \(median)")
                XCTAssertLessThanOrEqual(landed(setup, high, film), points.white + 1e-3,
                                         "\(id) \(median)")
            }
        }
    }

    func testFlatFrameKeepsItsKeyInsteadOfPrintingItsHighlightWhite() throws {
        let film = try XCTUnwrap(FilmStock.named("portra400"))
        // A frame whose brightest content is only two stops over its mid-grey median.
        let setup = LabScanTiming.setup(for: film, sceneHighlightStops: 2, sceneMedianStops: 0)
        let place = placement(film, highlight: 2, median: 0)
        XCTAssertEqual(place(0), 0, accuracy: 1e-4)
        // Between its anchors the levelled scan follows the placement to a fraction of a stop.
        XCTAssertEqual(landed(setup, 0, film), 0, accuracy: 0.1)
        XCTAssertLessThan(landed(setup, 2, film), LabScanTiming.profilePoints(for: film).white - 1)
    }

    func testKeyTakesOutHalfABrightFrameAndNeverLightensADarkOne() throws {
        let film = try XCTUnwrap(FilmStock.named("portra400"))
        let bright = LabScanTiming.setup(for: film, sceneHighlightStops: 3, sceneMedianStops: 2)
        XCTAssertEqual(landed(bright, 2, film), 1, accuracy: 0.1)
        // A low-key frame keeps its dark ground: the key would lift it four stops.
        let dark = LabScanTiming.setup(for: film, sceneHighlightStops: 0.2, sceneMedianStops: -8)
        XCTAssertLessThan(landed(dark, -8, film), -8)
    }

    func testExposureStillActsOnTheScanByItsOwnStops() throws {
        let film = try XCTUnwrap(FilmStock.named("portra400"))
        let exposed = LabScanTiming.setup(for: film, sceneHighlightStops: 3, sceneMedianStops: 0,
                                          exposureEV: 1)
        let unexposed = LabScanTiming.setup(for: film, sceneHighlightStops: 2,
                                            sceneMedianStops: -1)
        for stops: Float in [-3, 2] {
            XCTAssertEqual(landed(exposed, stops + 1, film), landed(unexposed, stops, film) + 1,
                           accuracy: 1e-3)
        }
        let lighter = LabScanTiming.setup(for: film, sceneHighlightStops: 2, sceneMedianStops: -1,
                                          scanExposure: 0.5)
        for stops: Float in [-3, 2] {
            XCTAssertEqual(landed(lighter, stops, film), landed(unexposed, stops, film) + 0.5,
                           accuracy: 1e-3)
        }
    }

    func testLabScanKeysTheFilmAndLevelsTheScansRecords() throws {
        let film = try XCTUnwrap(FilmStock.named("portra400"))
        var options = FotufilmEngine.Options()
        options.paper = .labScan
        let plain = try FilmEngineInvocation(validating: film, options: options, width: 16, height: 16)
        options.screenCMY = SIMD3(0.4, -0.2, 0.3)
        options.screenExposureEV = -0.7
        var keyed = try FilmEngineInvocation(validating: film, options: options, width: 16, height: 16)
        XCTAssertEqual(plain.spectralCacheID, keyed.spectralCacheID)
        let masking = (0..<3).map { Int(FOTUFILM_CONFIG_MASKING) + $0 }
        let midpoints = [FilmEngineInvocation.paperMidpointRedOffset,
                         Int(FOTUFILM_CONFIG_PAPER_MIDPOINT), FilmEngineInvocation.paperMidpointBlueOffset]
        func levels(_ invocation: FilmEngineInvocation) -> (scale: SIMD3<Float>, shift: SIMD3<Float>) {
            (SIMD3((0..<3).map { invocation.configuration[masking[$0]] / plain.configuration[masking[$0]] }),
             SIMD3((0..<3).map { invocation.configuration[midpoints[$0]] - plain.configuration[midpoints[$0]] }))
        }
        let unmetered = LabScanTiming.setup(for: film, sceneHighlightStops: nil, sceneMedianStops: nil,
                                            scanExposure: -0.7, keys: options.screenCMY)
        for c in 0..<3 {
            XCTAssertEqual(levels(keyed).scale[c], unmetered.scale[c], accuracy: 1e-5)
            XCTAssertEqual(levels(keyed).shift[c], unmetered.print[c], accuracy: 1e-5)
        }
        XCTAssertNotEqual(keyed.configuration[Int(FOTUFILM_CONFIG_CURVES) + 2],
                          plain.configuration[Int(FOTUFILM_CONFIG_CURVES) + 2])
        // The metered frame's setup levels the scan's records and keys the film's curves.
        var plane = [Float](repeating: 0.05, count: 16 * 16)
        for i in 0..<64 { plane[i] = 2 }
        plane.withUnsafeBufferPointer { values in
            keyed.measureToneBase(planarR: values.baseAddress!, g: values.baseAddress!,
                                  b: values.baseAddress!, width: 16, height: 16)
        }
        let setup = keyed.meterLevels.film
        XCTAssertNotEqual(setup.scale, unmetered.scale)
        for c in 0..<3 {
            XCTAssertEqual(levels(keyed).scale[c], setup.scale[c], accuracy: 1e-5)
            XCTAssertEqual(levels(keyed).shift[c], setup.print[c], accuracy: 1e-5)
        }
        let curves = setup.curves(for: film)
        XCTAssertEqual(keyed.configuration[Int(FOTUFILM_CONFIG_CURVES) + 2], curves[0].toe,
                       accuracy: 1e-5)
        XCTAssertEqual(keyed.configuration[Int(FOTUFILM_CONFIG_CURVES) + 4], curves[0].shoulder,
                       accuracy: 1e-5)
    }

    /// Each step of a wedge of `colour` rendered on Lab Scan at the fixed profile, keyed by
    /// `keys`, in linear Display P3.
    private func wedge(_ film: FilmStock, colour: SIMD3<Float>, keys: SIMD3<Float>,
                       stops: [Float]) throws -> [SIMD3<Float>] {
        let width = stops.count * 4
        var image = ImageBuffer(width: width, height: 4)
        for y in 0..<4 { for x in 0..<width {
            let scene = ColorScience.linearSRGBToRec2020(colour) * (0.18 * pow(2, stops[x / 4]))
            for c in 0..<3 { image.planes[c][y * width + x] = scene[c] }
        }}
        var options = FotufilmEngine.Options()
        options.paper = .labScan; options.grainScale = 0; options.halationScale = 0
        options.flareScale = 0; options.couplerScale = 0; options.localTone = false
        // A reading that leaves the frame at the fixed profile, undodged and unfinished: the
        // keys and the scan's inversion alone.
        let white = LabScanTiming.profilePoints(for: film).white
        options.sceneHighlightStops = white
        options.sceneToneStops = SIMD3(0, white, -4)
        options.labScanDodging = 0
        options.labScanLook = 0
        options.screenCMY = keys
        let output = try FotufilmEngine(stock: film, options: options).processChecked(linearRGB: image)
        return stops.indices.map { step in
            let i = 2 * width + step * 4 + 2
            return SIMD3(output.planes[0][i], output.planes[1][i], output.planes[2][i])
        }
    }

    func testColourKeysTintEveryToneAlikeAndSmoothly() throws {
        var film = try XCTUnwrap(FilmStock.named("portra400"))
        film.emulsionDiffusionMM = [0, 0, 0]; film.emulsionDiffusionSecondaryMM = [0, 0, 0]
        film.adjacencyStrength = 0
        let stops = Array(stride(from: Float(-6), through: 3, by: 0.25))
        let grey = stops.firstIndex(of: 0)!
        for colour: SIMD3<Float> in [SIMD3(1, 1, 1), SIMD3(0.8, 0.95, 1.2), SIMD3(1.25, 0.95, 0.65)] {
            let base = try wedge(film, colour: colour, keys: .zero, stops: stops)
            for keys: SIMD3<Float> in [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 0.6, -0.6)] {
                let keyed = try wedge(film, colour: colour, keys: keys, stops: stops)
                // The key's change to red's and blue's share of the light against green's.
                func tint(_ i: Int) -> SIMD2<Float> {
                    SIMD2(log(keyed[i].x / keyed[i].y) - log(base[i].x / base[i].y),
                          log(keyed[i].z / keyed[i].y) - log(base[i].z / base[i].y))
                }
                let mid = tint(grey)
                XCTAssertGreaterThan(max(abs(mid.x), abs(mid.y)), 0.5, "\(colour) keys \(keys)")
                // No darker tone takes a stronger tint than mid-grey. A scan the inversion cannot
                // explain comes back as a record that saw no light at all: a saturated blotch.
                for i in 0...grey {
                    let shade = tint(i)
                    XCTAssertLessThan(max(abs(shade.x) - abs(mid.x), abs(shade.y) - abs(mid.y)), 0.3,
                                      "\(colour) keys \(keys) at \(stops[i]) EV")
                }
                // And no step of the shadows jumps.
                let lab = keyed.map { LabScanFinish.oklab(ColorScience.linearDisplayP3ToSRGB($0)) }
                for i in 1..<grey where stops[i] <= -1.5 {
                    let bend = lab[i + 1] - 2 * lab[i] + lab[i - 1]
                    XCTAssertLessThan(max(abs(bend.y), abs(bend.z)), 0.008,
                                      "\(colour) keys \(keys) at \(stops[i]) EV")
                }
            }
        }
    }

    func testBacklitFrameOpensUpPartway() {
        XCTAssertEqual(LabScanTiming.highlight(.init(median: 0, bright: 2, dark: -3)), 2)
        XCTAssertEqual(LabScanTiming.highlight(.init(median: 0, bright: 5, dark: -3)), 4)
        XCTAssertEqual(LabScanTiming.highlight(.init(median: -6, bright: 4, dark: -9)), 2)
    }

    func testFrameInsideThePrintIsNotDodged() {
        let dodge = LabScanTiming.dodge(.init(median: 0, bright: 2, dark: -3))
        XCTAssertEqual(dodge.hold, 0)
        XCTAssertEqual(dodge.lift, 0)
    }

    func testWideFrameHoldsItsHighlightsAndLiftsItsShadowsAboutItsMedian() {
        let partial = LabScanTiming.dodge(.init(median: 1, bright: 5, dark: -4))
        XCTAssertEqual(partial.key, 1)
        XCTAssertEqual(partial.hold, LabScanTiming.dodgeMaxHold
                       * (4 - LabScanTiming.dodgeHighlightSpan) / LabScanTiming.dodgeRamp,
                       accuracy: 1e-6)
        XCTAssertEqual(partial.lift, LabScanTiming.dodgeMaxLift
                       * (5 - LabScanTiming.dodgeShadowSpan) / LabScanTiming.dodgeRamp,
                       accuracy: 1e-6)
        // The strength scales both, and 0 turns the dodge off.
        let doubled = LabScanTiming.dodge(.init(median: 1, bright: 5, dark: -4), strength: 2)
        XCTAssertEqual(doubled.hold, 2 * partial.hold, accuracy: 1e-6)
        XCTAssertEqual(LabScanTiming.dodge(.init(median: 0, bright: 9, dark: -9), strength: 0).hold, 0)
        let full = LabScanTiming.dodge(.init(median: 0, bright: 9, dark: -9))
        XCTAssertEqual(full.hold, LabScanTiming.dodgeMaxHold)
        XCTAssertEqual(full.lift, LabScanTiming.dodgeMaxLift)
    }

    func testDodgeKeysTheToneGridRegionallyOnTheMedian() throws {
        let film = try XCTUnwrap(FilmStock.named("portra400"))
        var options = FotufilmEngine.Options()
        options.paper = .labScan
        var invocation = try FilmEngineInvocation(validating: film, options: options,
                                                  width: 64, height: 64)
        // A dim room, a window eight stops brighter and a deep corner: wider than a print.
        var plane = [Float](repeating: 0.05, count: 64 * 64)
        for y in 0..<24 { for x in 0..<24 { plane[y * 64 + x] = 12 } }
        for y in 48..<64 { for x in 48..<64 { plane[y * 64 + x] = 0.0005 } }
        plane.withUnsafeBufferPointer { values in
            invocation.measureToneBase(planarR: values.baseAddress!, g: values.baseAddress!,
                                       b: values.baseAddress!, width: 64, height: 64)
        }
        XCTAssertTrue(invocation.toneKeyedLocally)
        XCTAssertFalse(invocation.toneControlsActive, "the dodge is not the user's tone")
        let adjust = FilmEngineInvocation.sceneAdjustOffset
        XCTAssertLessThan(invocation.configuration[adjust], 0)
        XCTAssertGreaterThan(invocation.configuration[adjust + 1], 0)
        XCTAssertGreaterThan(invocation.configuration[FilmEngineInvocation.toneGridSizeOffset], 1)
        // Keyed on the median: the room the median sits in reads near zero.
        let width = Int(invocation.configuration[FilmEngineInvocation.toneGridSizeOffset])
        let cell = 40 * width / 64 * width + 20 * width / 64
        let roomStops = log2(0.05 / 0.18 * ColorScience.luminanceWeights.0
                             + 0.05 / 0.18 * ColorScience.luminanceWeights.1
                             + 0.05 / 0.18 * ColorScience.luminanceWeights.2)
        let keyed = invocation.configuration[FilmEngineInvocation.toneGridAOffset + cell] * roomStops
            + invocation.configuration[FilmEngineInvocation.toneGridBOffset + cell]
        XCTAssertEqual(keyed, 0, accuracy: 0.5)
    }

    func testOnlyNegativesOnLabScanMeter() throws {
        let negative = try XCTUnwrap(FilmStock.named("portra400"))
        var options = FotufilmEngine.Options()
        options.paper = .labScan
        let scan = try FilmEngineInvocation(validating: negative, options: options, width: 64, height: 64)
        XCTAssertTrue(scan.sceneMeteringActive)
        options.paper = .ektacolorEdge
        let print = try FilmEngineInvocation(validating: negative, options: options, width: 64, height: 64)
        XCTAssertFalse(print.sceneMeteringActive && !print.localToneActive)
    }
}
