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
        assertEqual(own.gains, gains(dense))
        XCTAssertEqual(own.reference, NegativeScanCrosstalk.apply(weights, dense).y)
        // The densest end prints as diffuse white.
        let white = own.light(of: sample(dense))
        for c in 0..<3 { XCTAssertEqual(white[c], PlainNegativeScan.highlight, accuracy: 1e-4) }

        // A picked neutral takes the densest end's place, which still times the print.
        let chosen = PlainNegativeScan(border: border, setup: setup, separation: 1, mode: .frame,
                                       tones: Tones(denseEnd: dense, picked: picked))
        assertEqual(chosen.gains, gains(picked))
        XCTAssertEqual(chosen.reference, own.reference)
        let grey = chosen.light(of: sample(picked))
        XCTAssertEqual(grey.x, grey.y, accuracy: 1e-4 * grey.y)
        XCTAssertEqual(grey.z, grey.y, accuracy: 1e-4 * grey.y)

        // On its roll the frame takes the roll's neutral over its own.
        let roll = ApproximateNegativeScan.RollBalance(colour: [1.05, 0.85], frames: 12, level: 1)
        let rolled = PlainNegativeScan(border: border, setup: setup, separation: 1, mode: .roll,
                                       tones: Tones(denseEnd: dense, picked: picked), roll: roll)
        assertEqual(rolled.gains, gains(SIMD3(1.05, 1, 0.85)))
        XCTAssertEqual(rolled.reference, own.reference)
        // Without a roll measured, it is balanced as a frame of its own.
        XCTAssertEqual(PlainNegativeScan(border: border, setup: setup, separation: 1, mode: .roll,
                                         tones: Tones(denseEnd: dense, picked: picked)), chosen)

        // Unbalanced, the film reads as it is, timed on its densest end all the same.
        let none = PlainNegativeScan(border: border, setup: setup, separation: 1, mode: .none,
                                     tones: Tones(denseEnd: dense, picked: picked), roll: roll)
        XCTAssertEqual(none.gains, .one)
        XCTAssertEqual(none.reference, own.reference)
    }

    func testAFrameWithNothingToReadIsUnbalancedThroughItsSetup() {
        let setup = setups[0]
        let flat = PlainNegativeScan(border: border, setup: setup, separation: 1, mode: .frame,
                                     tones: Tones())
        XCTAssertEqual(flat.gains, .one)
        XCTAssertEqual(flat.reference, PlainNegativeScan.defaultReference)
        XCTAssertEqual(PlainNegativeScan(border: border, setup: setup, separation: 1, mode: .frame,
                                         tones: Tones(denseEnd: SIMD3(.nan, 1, 1),
                                                      picked: SIMD3(0.01, 0.02, 0.01))), flat)
        // Gains stay within what a channel can plausibly be off by.
        let far = PlainNegativeScan(border: border, setup: setups[3], separation: 0, mode: .frame,
                                    tones: Tones(denseEnd: SIMD3(0.1, 1, 3)))
        XCTAssertEqual(far.gains.x, 2)
        XCTAssertEqual(far.gains.z, 0.5)
    }
}
