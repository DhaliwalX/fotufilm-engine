import XCTest
@testable import FotufilmCore

final class HalationSpectrumTests: XCTestCase {

    private func stock() throws -> FilmStock {
        try XCTUnwrap(FilmStock.presets["example-negative-400"],
                      "the example negative is not installed")
    }

    func testAFlatLadderResamplesToNothing() {
        XCTAssertTrue(HalationSpectrum.resampled(HalationSpectrum.neutral).isEmpty)
        XCTAssertTrue(HalationSpectrum.isNeutral(HalationSpectrum.neutral))
        // A stored curve with a different handle count is invalid and must resolve to neutral.
        XCTAssertTrue(HalationSpectrum.resampled([0, 1]).isEmpty)
    }

    func testADrawnLadderLandsOnTheGridThroughItsHandles() throws {
        var handles = HalationSpectrum.neutral
        let green = try XCTUnwrap(HalationSpectrum.handleNM.firstIndex(of: 550))
        handles[green] = 3
        let row = HalationSpectrum.resampled(handles)
        XCTAssertEqual(row.count, SpectralGrid.count)
        XCTAssertEqual(row[34], 8, accuracy: 1e-5,
                       "550 nm is grid slot 34, and three stops is eight times")
        // Monotone interpolation stays inside its handles, so the lobe does not ring above the
        // travel the row actually offers.
        XCTAssertLessThanOrEqual(row.max() ?? 0, 8 + 1e-4)
        XCTAssertGreaterThanOrEqual(row.min() ?? 0, 1 - 1e-6)
    }

    func testAHandleBeyondTheTravelIsHeldAtIt() {
        var handles = HalationSpectrum.neutral
        handles[3] = 40
        let row = HalationSpectrum.resampled(handles)
        XCTAssertEqual(row.max() ?? 0,
                       exp2(HalationSpectrum.travelStops.upperBound),
                       accuracy: 1e-3)
    }

    func testStopsBelowRestCloseTheReturnDown() {
        var handles = HalationSpectrum.neutral
        handles[HalationSpectrum.handleNM.firstIndex(of: 650)!] = -3
        handles[HalationSpectrum.handleNM.firstIndex(of: 700)!] = -3
        let row = HalationSpectrum.resampled(handles)
        XCTAssertEqual(row[54], 0.125, accuracy: 1e-5,
                       "650 nm is grid slot 54, and minus three stops is an eighth")
        XCTAssertLessThan(row.min() ?? 1, 1)
    }

    func testAFlatGainScalesEveryRecordByItself() throws {
        let stock = try stock()
        let flat = [Float](repeating: 1.4, count: SpectralGrid.count)
        let gain = HalationSpectrum.recordGain(spectrum: flat,
                                               sensitivity: stock.spectralProfile.layerSensitivity)
        XCTAssertEqual(gain.count, 3)
        for record in gain { XCTAssertEqual(record, 1.4, accuracy: 1e-5) }
    }

    func testLiftingOneEndOfTheBandFavoursTheRecordThatReadsThere() throws {
        let stock = try stock()
        var handles = HalationSpectrum.neutral
        handles[HalationSpectrum.handleNM.firstIndex(of: 550)!] = 4
        handles[HalationSpectrum.handleNM.firstIndex(of: 500)!] = 4
        let gain = HalationSpectrum.recordGain(
            spectrum: HalationSpectrum.resampled(handles),
            sensitivity: stock.spectralProfile.layerSensitivity)
        XCTAssertGreaterThan(gain[1], gain[0],
                             "a green lift must green the halo, not brighten it")
        XCTAssertGreaterThan(gain[1], 1)
    }

    func testADegenerateSpectrumLeavesTheFilmAlone() throws {
        let stock = try stock()
        for spectrum in [[Float](), [Float](repeating: 1, count: 7)] {
            let gain = HalationSpectrum.recordGain(spectrum: spectrum,
                                                   sensitivity: stock.spectralProfile.layerSensitivity)
            XCTAssertEqual(gain, [1, 1, 1])
        }
    }

    func testTheTravelCanTurnAMaskedNegativesRedHaloGreen() throws {
        var stock = try stock()
        // Explicit red-dominant input, independent of the installed pack's authored look.
        stock.halationStrength = [0.05, 0.001, 0.0005]
        let strength = stock.halationStrength
        XCTAssertGreaterThan(strength[0], 0)
        XCTAssertGreaterThan(strength[1], 0, "this stock returns no green to lift")
        XCTAssertGreaterThan(strength[0], strength[1] * 10,
                             "this stock's halo is not red to begin with, so "
                             + "turning it green measures nothing")

        var handles = HalationSpectrum.neutral
        for (index, nm) in HalationSpectrum.handleNM.enumerated() {
            if nm >= 500 && nm <= 550 {
                handles[index] = HalationSpectrum.travelStops.upperBound
            } else if nm >= 600 {
                handles[index] = HalationSpectrum.travelStops.lowerBound
            }
        }
        let gain = HalationSpectrum.recordGain(
            spectrum: HalationSpectrum.resampled(handles),
            sensitivity: stock.spectralProfile.layerSensitivity)
        XCTAssertGreaterThan(strength[1] * gain[1], strength[0] * gain[0],
                             "the travel tops out before the halo can turn")
    }

    // MARK: - Through the engine

    private func invocation(_ options: FotufilmEngine.Options,
                            _ stock: FilmStock) -> FilmEngineInvocation {
        FilmEngineInvocation(stock: stock, options: options,
                             width: 4000, height: 2667)
    }

    func testAFlatCurveIsTheRenderThatCameBeforeIt() throws {
        let stock = try stock()
        var flat = FotufilmEngine.Options()
        flat.halationReturnGain =
            HalationSpectrum.resampled(HalationSpectrum.neutral)
        XCTAssertEqual(invocation(flat, stock).configuration,
                       invocation(FotufilmEngine.Options(), stock).configuration)
    }

    func testADrawnCurveChangesTheHaloTheKernelsAreConfiguredWith() throws {
        let stock = try stock()
        var handles = HalationSpectrum.neutral
        handles[HalationSpectrum.handleNM.firstIndex(of: 450)!] = 4
        handles[HalationSpectrum.handleNM.firstIndex(of: 500)!] = 4

        var drawn = FotufilmEngine.Options()
        drawn.halationReturnGain = HalationSpectrum.resampled(handles)
        XCTAssertNotEqual(invocation(drawn, stock).configuration,
                          invocation(FotufilmEngine.Options(), stock).configuration)

        // And it is not the amount slider wearing another name: no setting of `halationScale`
        // reproduces it, because a scale moves all three records by one factor and this does not.
        let gain = HalationSpectrum.recordGain(spectrum: drawn.halationReturnGain,
                                               sensitivity: stock.spectralProfile.layerSensitivity)
        XCTAssertNotEqual(gain[0], gain[2],
                          "a blue lift moved the red record as much as the blue one")
        XCTAssertGreaterThan(gain[2], gain[0])
    }
}
