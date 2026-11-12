import XCTest
@testable import FotufilmCore

final class PlainNegativeScanTests: XCTestCase {
    private let border = SIMD3<Float>(0.8, 0.45, 0.2)

    /// Film `density` over the base, as a scanner reads it.
    private func sample(_ density: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3((0..<3).map { border[$0] * pow(10, -density[$0]) })
    }

    func testTheDensestEndPrintsAsDiffuseWhiteAndEveryStopFollowsTheNegativesContrast() {
        let reading = PlainNegativeScan(border: border, denseEnd: SIMD3(1.2, 1.1, 0.88))
        // Red and blue are balanced onto green at the densest end: a neutral highlight.
        XCTAssertEqual(reading.gains.x, 1.1 / 1.2, accuracy: 1e-6)
        XCTAssertEqual(reading.gains.z, 1.1 / 0.88, accuracy: 1e-6)
        let white = reading.light(of: sample(SIMD3(1.2, 1.1, 0.88)))
        for c in 0..<3 { XCTAssertEqual(white[c], PlainNegativeScan.highlight, accuracy: 1e-4) }
        // One stop down is gamma × log10(2) less density.
        let step = PlainNegativeScan.gamma * log10(Float(2))
        let grey = reading.light(of: sample(SIMD3(1.2 - step / reading.gains.x, 1.1 - step,
                                                   0.88 - step / reading.gains.z)))
        for c in 0..<3 { XCTAssertEqual(grey[c], PlainNegativeScan.highlight / 2, accuracy: 1e-4) }
    }

    func testAFlatFrameReadsUnbalancedAndBlankSamplesAreBlack() {
        let flat = PlainNegativeScan(border: border, denseEnd: nil)
        XCTAssertEqual(flat.gains, .one)
        XCTAssertEqual(flat.reference, PlainNegativeScan.defaultReference)
        XCTAssertEqual(PlainNegativeScan(border: border, denseEnd: SIMD3(0.01, 0.02, 0.01)), flat)
        // Gains stay within what a scanner channel can plausibly be off by.
        XCTAssertEqual(PlainNegativeScan(border: border, denseEnd: SIMD3(0.1, 1, 3)).gains,
                       SIMD3(2, 1, 0.5))
        XCTAssertEqual(flat.light(of: SIMD3(0, 0.2, 0.1)), .zero)
        XCTAssertEqual(flat.light(of: SIMD3(.nan, 0.2, 0.1)), .zero)
    }

    // MARK: - Read through the scan's light and camera

    private typealias Tones = ApproximateNegativeScan.Tones
    private let setups: [NegativeScanSetup] = [
        .init(light: .white, camera: .generic), .init(light: .screen, camera: .generic),
        .init(light: .halogen, camera: .generic), .init(light: .rgb, camera: .generic),
        .init(light: .white, camera: .scanner),
        .init(light: .white, camera: .profile("sony-ilce-7cm2")),
    ]

    func testTheOrdinaryFilmsMaskIsOrange() {
        func at(_ nanometres: Float) -> Float {
            let index = SpectralGrid.wavelengths.indices.min {
                abs(SpectralGrid.wavelengths[$0] - nanometres)
                    < abs(SpectralGrid.wavelengths[$1] - nanometres)
            }!
            return PlainNegativeScan.mask[index]
        }
        XCTAssertEqual(at(650), 0.2, accuracy: 0.02)
        XCTAssertEqual(at(550), 0.6, accuracy: 0.02)
        XCTAssertEqual(at(450), 0.85, accuracy: 0.02)
    }

    func testEveryChannelReadsMostlyItsOwnDyeAndNarrowBandsNeedLittleElse() {
        for setup in setups {
            let weights = PlainNegativeScan.weights(setup: setup, separation: 1)
            for row in 0..<3 {
                XCTAssertGreaterThan(weights[row][row], 0.8, "\(setup)")
                for column in 0..<3 where column != row {
                    XCTAssertLessThan(abs(weights[row][column]), weights[row][row], "\(setup)")
                }
            }
            // No separation reads each dye from its own channel alone.
            let own = PlainNegativeScan.weights(setup: setup, separation: 0)
            for row in 0..<3 {
                for column in 0..<3 where column != row { XCTAssertEqual(own[row][column], 0) }
                XCTAssertGreaterThan(own[row][row], 0.8)
            }
        }
        // Narrow bands sit on the dyes' peaks and see little of the others; a camera's broad
        // red sees the magenta dye and must take it out.
        let bands = PlainNegativeScan.weights(setup: setups[3], separation: 1)
        let camera = PlainNegativeScan.weights(setup: setups[0], separation: 1)
        XCTAssertLessThan(abs(bands[0].y), 0.05)
        XCTAssertLessThan(camera[0].y, -0.3)
    }

    func testTheOrdinaryFilmsGreysAndColoursReadBackAsTheirDyes() {
        // The fit's own film, scanned as the reading sees it and read back.
        let dyes = NegativeScanCrosstalk.plainDyes
        for setup in setups {
            let response = setup.response()
            func scan(_ amounts: SIMD3<Float>) -> SIMD3<Float> {
                var read = SIMD3<Float>.zero
                for i in 0..<SpectralGrid.count {
                    let density = PlainNegativeScan.mask[i] + amounts.x * dyes[0][i]
                        + amounts.y * dyes[1][i] + amounts.z * dyes[2][i]
                    read += pow(10, -density)
                        * SIMD3(response[0][i], response[1][i], response[2][i])
                }
                return read
            }
            let clear = scan(.zero)
            let weights = PlainNegativeScan.weights(setup: setup, separation: 1)
            for amounts in [SIMD3<Float>(0.4, 0.4, 0.4), SIMD3(1.1, 1.1, 1.1), SIMD3(0.9, 0.6, 0.6),
                            SIMD3(0.5, 0.8, 0.5), SIMD3(0.7, 0.7, 1)] {
                let film = scan(amounts)
                let read = NegativeScanCrosstalk.apply(
                    weights, SIMD3((0..<3).map { -log10(film[$0] / clear[$0]) }))
                for dye in 0..<3 {
                    XCTAssertEqual(read[dye], amounts[dye], accuracy: 0.06, "\(setup) \(amounts)")
                }
            }
        }
    }

    func testAFrameIsBalancedOnItsPickedNeutralItsDensestEndOrItsRoll() {
        let setup = setups[0]
        let weights = PlainNegativeScan.weights(setup: setup, separation: 1)
        let dense = SIMD3<Float>(1.2, 1.1, 0.88), picked = SIMD3<Float>(0.5, 0.6, 0.62)
        func assertGrey(_ light: SIMD3<Float>, line: UInt = #line) {
            XCTAssertGreaterThan(light.y, 0, line: line)
            XCTAssertEqual(light.x, light.y, accuracy: 1e-4 * light.y, line: line)
            XCTAssertEqual(light.z, light.y, accuracy: 1e-4 * light.y, line: line)
        }
        func gains(_ neutral: SIMD3<Float>) -> SIMD3<Float> {
            let read = NegativeScanCrosstalk.apply(weights, neutral)
            return SIMD3(read.y / read.x, 1, read.y / read.z)
        }
        func assertEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, line: UInt = #line) {
            for c in 0..<3 { XCTAssertEqual(a[c], b[c], accuracy: 1e-6, line: line) }
        }
        let own = PlainNegativeScan(border: border, setup: setup, separation: 1, mode: .frame,
                                    tones: Tones(denseEnd: dense))
        XCTAssertEqual(own.weights, weights)
        // With no film and no roll to say how steep its records are, red's and blue's densities
        // are scaled onto green's at the neutral.
        assertEqual(own.gains, gains(dense))
        XCTAssertEqual(own.balance, .one)
        XCTAssertEqual(own.toe, PlainNegativeScan.modelToe)
        XCTAssertEqual(own.reference, NegativeScanCrosstalk.apply(weights, dense).y)
        // The densest end prints as diffuse white, and the clear film, which no exposure made,
        // as black.
        let white = own.light(of: sample(dense))
        for c in 0..<3 { XCTAssertEqual(white[c], PlainNegativeScan.highlight, accuracy: 1e-4) }
        XCTAssertEqual(own.light(of: border), .zero)

        // A picked neutral takes the densest end's place, which still times the print.
        let chosen = PlainNegativeScan(border: border, setup: setup, separation: 1, mode: .frame,
                                       tones: Tones(denseEnd: dense, picked: picked))
        XCTAssertEqual(chosen.reference, own.reference)
        assertEqual(chosen.gains, gains(picked))
        assertGrey(chosen.light(of: sample(picked)))
        XCTAssertEqual(chosen.light(of: sample(dense)).y, PlainNegativeScan.highlight,
                       accuracy: 1e-4)
        // Scaled there, a grey halfway to the neutral is grey too, whatever its records' contrast.
        assertGrey(chosen.light(of: sample(picked * 0.5)))

        // On its roll the frame takes the roll's neutral over its own.
        let roll = ApproximateNegativeScan.RollBalance(colour: [1.05, 0.85], frames: 12, level: 1)
        let rolled = PlainNegativeScan(border: border, setup: setup, separation: 1, mode: .roll,
                                       tones: Tones(denseEnd: dense, picked: picked), roll: roll)
        assertGrey(rolled.light(of: sample(SIMD3(1.05, 1, 0.85))))
        XCTAssertEqual(rolled.reference, own.reference)
        assertEqual(rolled.gains, gains(SIMD3(1.05, 1, 0.85)))
        // Without a roll measured, it is balanced as a frame of its own.
        XCTAssertEqual(PlainNegativeScan(border: border, setup: setup, separation: 1, mode: .roll,
                                         tones: Tones(denseEnd: dense, picked: picked)), chosen)

        // A roll that measured its tonal steps says the contrast: red and blue are made as steep
        // as green by it, whichever neutral balances the frame, and the neutral is then balanced
        // by each channel's light.
        let stepped = ApproximateNegativeScan.RollBalance(colour: [1.05, 0.85], frames: 12,
                                                          level: 1, slopes: [0.95, 1.1])
        let read = NegativeScanCrosstalk.apply(weights, SIMD3(0.95, 1, 1.1))
        for mode in [ApproximateNegativeScan.BalanceMode.frame, .roll] {
            let steep = PlainNegativeScan(border: border, setup: setup, separation: 1, mode: mode,
                                          tones: Tones(denseEnd: dense), roll: stepped)
            XCTAssertEqual(steep.gains.x, read.y / read.x, accuracy: 1e-6)
            XCTAssertEqual(steep.gains.y, 1)
            XCTAssertEqual(steep.gains.z, read.y / read.z, accuracy: 1e-6)
            XCTAssertNotEqual(steep.balance.x, 1, accuracy: 0.01)
            XCTAssertEqual(steep.balance.y, 1)
            let white = steep.light(of: sample(mode == .roll ? SIMD3(1.05, 1, 0.85) : dense))
            assertGrey(white)
        }

        // Unbalanced, the film reads as it is, timed on its densest end all the same.
        let none = PlainNegativeScan(border: border, setup: setup, separation: 1, mode: .none,
                                     tones: Tones(denseEnd: dense, picked: picked), roll: stepped)
        XCTAssertEqual(none.gains, .one)
        XCTAssertEqual(none.balance, .one)
        XCTAssertEqual(none.reference, own.reference)
    }

    func testAFrameWithNothingToReadIsUnbalancedThroughItsSetup() {
        let setup = setups[0]
        let flat = PlainNegativeScan(border: border, setup: setup, separation: 1, mode: .frame,
                                     tones: Tones())
        XCTAssertEqual(flat.gains, .one)
        XCTAssertEqual(flat.balance, .one)
        XCTAssertEqual(flat.reference, PlainNegativeScan.defaultReference)
        XCTAssertEqual(PlainNegativeScan(border: border, setup: setup, separation: 1, mode: .frame,
                                         tones: Tones(denseEnd: SIMD3(.nan, 1, 1),
                                                      picked: SIMD3(0.01, 0.02, 0.01))), flat)
        // Gains stay within what a channel can plausibly be off by, and with a roll's contrast a
        // balance within what a channel's light can be.
        let far = PlainNegativeScan(border: border, setup: setups[3], separation: 0, mode: .frame,
                                    tones: Tones(denseEnd: SIMD3(0.1, 1, 3)))
        XCTAssertEqual(far.gains.x, 2)
        XCTAssertEqual(far.gains.z, 0.5)
        let steep = ApproximateNegativeScan.RollBalance(colour: [1, 1], frames: 8, level: 1,
                                                        slopes: [1, 1])
        let wide = PlainNegativeScan(border: border, setup: setups[3], separation: 0, mode: .frame,
                                     tones: Tones(denseEnd: SIMD3(0.1, 1, 3)), roll: steep)
        XCTAssertEqual(wide.balance.x, PlainNegativeScan.balanceRange.upperBound)
        XCTAssertEqual(wide.balance.z, PlainNegativeScan.balanceRange.lowerBound)
    }

    /// The first reading runs along a straight line. The current one has a toe: the clear film
    /// is no exposure, the shadows deepen, and the highlights stay where they were.
    func testTheToeDeepensTheShadowsAndLeavesTheHighlights() {
        let dense = SIMD3<Float>(1.1, 1.1, 1.1)
        let straight = PlainNegativeScan(border: border, denseEnd: dense)
        XCTAssertEqual(straight.toe, 0)
        XCTAssertEqual(straight.balance, .one)
        XCTAssertEqual(straight.flare, .zero)
        XCTAssertEqual(straight.lightScales, .one)
        var toed = straight
        toed.toe = 1
        let gamma = PlainNegativeScan.gamma
        for density in [Float(0.02), 0.1, 0.3, 0.6, 1.1] {
            let line = straight.light(of: sample(SIMD3(repeating: density))).y
            let curve = toed.light(of: sample(SIMD3(repeating: density))).y
            XCTAssertEqual(line, PlainNegativeScan.highlight * pow(10, (density - 1.1) / gamma),
                           accuracy: 1e-5)
            // Exposure over the toe's: ten to the density over gamma, less one.
            XCTAssertEqual(curve / PlainNegativeScan.highlight,
                           (pow(10, density / gamma) - 1) / (pow(10, 1.1 / gamma) - 1),
                           accuracy: 1e-5)
            XCTAssertLessThanOrEqual(curve, line + 1e-6)
        }
        XCTAssertEqual(toed.light(of: border), .zero)
        XCTAssertGreaterThan(straight.light(of: border).y, 0.01)
        // Film read under the clear film by noise is black, not light below none.
        XCTAssertEqual(toed.light(of: border * 1.02), .zero)
    }

    /// Stray light is taken off a sample and the clear film before their densities.
    func testAPlainReadingTakesOffTheScansStrayLight() {
        let dense = SIMD3<Float>(1.2, 1.1, 0.88)
        let setup = setups[0]
        let clean = PlainNegativeScan(border: border, setup: setup, separation: 1, mode: .frame,
                                      tones: Tones(denseEnd: dense))
        let flare = SIMD3<Float>(0.004, 0.002, 0.001)
        let lifted = PlainNegativeScan(border: border + flare, setup: setup, separation: 1,
                                       mode: .frame, tones: Tones(denseEnd: dense), flare: flare)
        for density in [Float(0.05), 0.5, 1.5, 2.2] {
            let film = sample(SIMD3(repeating: density))
            let expected = clean.light(of: film), read = lifted.light(of: film + flare)
            for c in 0..<3 { XCTAssertEqual(read[c], expected[c], accuracy: 2e-3 * max(expected[c], 0.01)) }
        }
        XCTAssertEqual(lifted.light(of: flare), .zero)
    }
}
