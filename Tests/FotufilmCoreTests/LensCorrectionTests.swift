import XCTest
@testable import FotufilmCore

final class LensCorrectionModelTests: XCTestCase {
    // MARK: - Distortion

    func testPoly3HoldsTheCornerFixed() {
        for k1: Float in [-0.1, -0.02, 0.02, 0.1] {
            let model = LensCorrection.Distortion.poly3(k1: k1)
            XCTAssertEqual(model.sourceRadius(1), 1, accuracy: 1e-6,
                           "k1 = \(k1) moved the corner")
            XCTAssertEqual(model.sourceRadius(0), 0, accuracy: 1e-9)
        }
    }

    func testBarrelReadsOutwardAndPincushionInward() {
        let barrel = LensCorrection.Distortion.poly3(k1: -0.08)
        let pincushion = LensCorrection.Distortion.poly3(k1: 0.08)
        for r: Float in [0.25, 0.5, 0.75] {
            XCTAssertGreaterThan(barrel.sourceRadius(r), r)
            XCTAssertLessThan(pincushion.sourceRadius(r), r)
        }
    }

    func testPoly5MatchesItsPolynomial() {
        let model = LensCorrection.Distortion.poly5(k1: 0.03, k2: -0.01)
        for r: Float in [0, 0.3, 0.6, 1] {
            let expected = r * (1 + 0.03 * r * r - 0.01 * pow(r, 4))
            XCTAssertEqual(model.sourceRadius(r), expected, accuracy: 1e-6)
        }
    }

    func testPTLensMatchesItsPolynomial() {
        let a: Float = 0.004, b: Float = -0.021, c: Float = 0.009
        let model = LensCorrection.Distortion.ptLens(a: a, b: b, c: c)
        for r: Float in [0, 0.35, 0.7, 1] {
            let expected = r * (a * r * r * r + b * r * r + c * r
                                + (1 - a - b - c))
            XCTAssertEqual(model.sourceRadius(r), expected, accuracy: 1e-6)
        }
        // PTLens also holds the corner, by construction of its constant term.
        XCTAssertEqual(model.sourceRadius(1), 1, accuracy: 1e-6)
    }

    func testScalingDistortionWalksToTheIdentity() {
        let model = LensCorrection.Distortion.ptLens(a: 0.004, b: -0.021,
                                                     c: 0.009)
        XCTAssertTrue(model.scaled(by: 0).isIdentity)
        for r: Float in [0.3, 0.7, 1] {
            XCTAssertEqual(model.scaled(by: 1).sourceRadius(r),
                           model.sourceRadius(r), accuracy: 1e-6)
            let half = model.scaled(by: 0.5).sourceRadius(r)
            let full = model.sourceRadius(r)
            // Half the coefficients is half the displacement from where it started.
            XCTAssertEqual(half - r, (full - r) / 2, accuracy: 1e-6)
        }
    }

    // MARK: - Vignetting

    func testVignetteGainIsTheReciprocalOfTransmission() {
        let model = LensCorrection.Vignetting.radial(k1: -0.4, k2: 0.05, k3: 0)
        XCTAssertEqual(model.transmission(0), 1, accuracy: 1e-9)
        XCTAssertEqual(model.gain(0), 1, accuracy: 1e-9)
        for r: Float in [0.25, 0.5, 0.9, 1] {
            let t = model.transmission(r)
            XCTAssertLessThan(t, 1, "corners should be darker at r = \(r)")
            XCTAssertEqual(model.gain(r) * t, 1, accuracy: 1e-5)
        }
    }

    func testVignetteGainStaysFiniteWhenTransmissionCollapses() {
        let absurd = LensCorrection.Vignetting.radial(k1: -5, k2: 0, k3: 0)
        let gain = absurd.gain(1)
        XCTAssertTrue(gain.isFinite)
        XCTAssertLessThanOrEqual(gain, 20)
        XCTAssertGreaterThan(gain, 0)
    }

    // MARK: - Lateral chroma

    func testChromaLeavesGreenAlone() {
        let model = LensCorrection.LateralChroma.linear(red: 1.001, blue: 0.999)
        let stack = LensCorrectionStack([
            LensCorrection(lateralChroma: model)
        ])
        for r: Float in [0.2, 0.6, 1] {
            XCTAssertEqual(stack.sample(atRadius: r).green, r, accuracy: 1e-6)
        }
    }

    func testChromaScalesEachChannelsRadius() {
        let model = LensCorrection.LateralChroma.linear(red: 1.002, blue: 0.998)
        for r: Float in [0.3, 0.7, 1] {
            let radii = model.sourceRadii(r)
            XCTAssertEqual(radii.red, r * 1.002, accuracy: 1e-6)
            XCTAssertEqual(radii.blue, r * 0.998, accuracy: 1e-6)
        }
    }

    // MARK: - Stacking

    func testStagesComposeByEvaluationNotAddition() {
        let first = LensCorrection(distortion: .poly3(k1: -0.06))
        let second = LensCorrection(distortion: .poly3(k1: 0.03))
        let stack = LensCorrectionStack([first, second])
        for r: Float in [0.25, 0.5, 0.8] {
            let expected = second.distortion.sourceRadius(
                first.distortion.sourceRadius(r))
            XCTAssertEqual(stack.sample(atRadius: r).green, expected,
                           accuracy: 1e-6)
            // And that is not the same as summing the coefficients, or the test above proves nothing.
            let summed = LensCorrection.Distortion.poly3(k1: -0.03)
                .sourceRadius(r)
            XCTAssertNotEqual(expected, summed, accuracy: 1e-7)
        }
    }

    func testStackedGainsMultiply() {
        let first = LensCorrection(vignetting: .radial(k1: -0.3, k2: 0, k3: 0))
        let second = LensCorrection(vignetting: .radial(k1: -0.2, k2: 0, k3: 0))
        let stack = LensCorrectionStack([first, second])
        let r: Float = 0.8
        // The second stage sees the radius the first mapped to — here unchanged, there being no
        // distortion — so the gains simply multiply.
        XCTAssertEqual(stack.sample(atRadius: r).gain,
                       first.vignetting.gain(r) * second.vignetting.gain(r),
                       accuracy: 1e-5)
    }

    func testAPlaneWarpAnswersForEveryColourAtOnce() {
        let warp = LensCorrection.PlaneWarp(
            red: .init(k0: 1, k1: 0.06),
            green: .init(k0: 1, k1: 0.05),
            blue: .init(k0: 1, k1: 0.04))
        var correction = LensCorrection(distortion: .poly3(k1: -0.5),
                                        lateralChroma: .linear(red: 1.5,
                                                               blue: 0.5))
        correction.planeWarp = warp
        for r: Float in [0.25, 0.5, 1] {
            let sample = correction.sample(atRadius: r)
            XCTAssertEqual(sample.red, r * warp.red.factor(r), accuracy: 1e-6)
            XCTAssertEqual(sample.green, r * warp.green.factor(r),
                           accuracy: 1e-6)
            XCTAssertEqual(sample.blue, r * warp.blue.factor(r), accuracy: 1e-6)
        }
    }

    func testAPlaneWarpComposesWithTheSlidersOnTopOfIt() {
        var measured = LensCorrection()
        measured.planeWarp = LensCorrection.PlaneWarp(
            red: .init(k0: 1, k1: 0.06),
            green: .init(k0: 1, k1: 0.05),
            blue: .init(k0: 1, k1: 0.04))
        let byHand = LensCorrection(distortion: .poly3(k1: -0.02))
        let stack = LensCorrectionStack([measured, byHand])
        for r: Float in [0.3, 0.7, 1] {
            let first = measured.sample(atRadius: r)
            let sample = stack.sample(atRadius: r)
            XCTAssertEqual(sample.red,
                           byHand.distortion.sourceRadius(first.red),
                           accuracy: 1e-6, "at r = \(r)")
            XCTAssertEqual(sample.blue,
                           byHand.distortion.sourceRadius(first.blue),
                           accuracy: 1e-6, "at r = \(r)")
        }
    }

    func testAPlaneWarpScalesTowardsLeavingThePictureAlone() {
        var correction = LensCorrection()
        correction.planeWarp = LensCorrection.PlaneWarp(
            red: .init(k0: 1.02, k1: 0.06),
            green: .init(k0: 1, k1: 0.05),
            blue: .init(k0: 0.98, k1: 0.04))
        XCTAssertTrue(correction.scaled(by: 0).isIdentity)
        let half = correction.scaled(by: 0.5)
        let r: Float = 0.8
        let whole = correction.sample(atRadius: r)
        let part = half.sample(atRadius: r)
        for (moved, halved) in [(whole.red, part.red), (whole.green, part.green),
                                (whole.blue, part.blue)] {
            XCTAssertEqual(halved - r, (moved - r) / 2, accuracy: 1e-6)
        }
    }

    func testAStatedGainIsAppliedAsGivenRatherThanInverted() {
        let stated = LensCorrection.Vignetting.radialGain(
            k0: 0.5, k1: 0.25, k2: 0, k3: 0, k4: 0)
        XCTAssertEqual(stated.gain(1), 1.75, accuracy: 1e-6)
        XCTAssertEqual(stated.transmission(1), 1 / 1.75, accuracy: 1e-6)
        // A transmission with the same coefficients would brighten the corner far more.
        let measured = LensCorrection.Vignetting.radial(k1: 0.5, k2: 0.25, k3: 0)
        XCTAssertEqual(measured.gain(1), 1 / 1.75, accuracy: 1e-6)
    }

    func testAWildFalloffIsHeldToSomethingAPhotographSurvives() {
        let runaway = LensCorrection.Vignetting.radialGain(
            k0: 1e6, k1: 0, k2: 0, k3: 0, k4: 0)
        XCTAssertEqual(runaway.gain(1), 20, accuracy: 1e-6)
        let inverted = LensCorrection.Vignetting.radialGain(
            k0: -100, k1: 0, k2: 0, k3: 0, k4: 0)
        XCTAssertEqual(inverted.gain(1), 0.05, accuracy: 1e-6)
    }

    func testAnIdentityStageIsDroppedRatherThanEvaluated() {
        let stack = LensCorrectionStack([LensCorrection(), LensCorrection()])
        XCTAssertTrue(stack.isIdentity)
        XCTAssertEqual(stack.stages.count, 0)
        XCTAssertEqual(stack.sample(atRadius: 0.5).green, 0.5, accuracy: 1e-9)
        XCTAssertEqual(stack.sample(atRadius: 0.5).gain, 1, accuracy: 1e-9)
    }

    // MARK: - The table the renderer reads

    func testTheTableCarriesRatiosAndSurvivesTheCentre() {
        let stack = LensCorrectionStack([
            LensCorrection(distortion: .poly3(k1: -0.08))
        ])
        let table = stack.resamplingTable(entries: 512)
        XCTAssertEqual(table.count, 512 * 4)
        for value in table { XCTAssertTrue(value.isFinite) }
        // At the centre the ratio is the curve's constant term, 1 - k1.
        XCTAssertEqual(table[1], 1.08, accuracy: 1e-3)
        // At the corner poly3 holds the radius, so the ratio is one.
        XCTAssertEqual(table[(512 - 1) * 4 + 1], 1, accuracy: 1e-4)
    }

    func testTheTableAgreesWithTheModelBetweenItsEntries() {
        let stack = LensCorrectionStack([
            LensCorrection(distortion: .ptLens(a: 0.004, b: -0.021, c: 0.009),
                           vignetting: .radial(k1: -0.35, k2: 0.04, k3: 0),
                           lateralChroma: .linear(red: 1.0012, blue: 0.9988))
        ])
        let entries = LensCorrectionStackTestSupport.entries
        let table = stack.resamplingTable(entries: entries)
        let step = 1 / Float(entries - 1)
        for i in 0..<(entries - 1) {
            // Halfway between two entries is where linear reading is furthest from the curve.
            let r = (Float(i) + 0.5) * step
            let exact = stack.sample(atRadius: r)
            let readRed = (table[i * 4] + table[(i + 1) * 4]) / 2
            let readGain = (table[i * 4 + 3] + table[(i + 1) * 4 + 3]) / 2
            // A ratio error of 1e-5 on a 6000 px frame is under a twentieth of a pixel.
            XCTAssertEqual(readRed, exact.red / max(r, 1e-6), accuracy: 1e-5)
            XCTAssertEqual(readGain, exact.gain, accuracy: 1e-5)
        }
    }

    func testSourceReachIsTheWidestPointNotTheCorner() {
        let barrel = LensCorrectionStack([
            LensCorrection(distortion: .poly3(k1: -0.05))
        ])
        XCTAssertEqual(barrel.sample(atRadius: 1).green, 1, accuracy: 1e-6,
                       "poly3 should still be pinning the corner")
        // Widest at the centre, where the ratio is 1 - k1.
        XCTAssertEqual(barrel.sourceReach(), 1.05, accuracy: 1e-3)

        // A correction that only reads inward needs no room made for it.
        let pincushion = LensCorrectionStack([
            LensCorrection(distortion: .poly3(k1: 0.05))
        ])
        XCTAssertEqual(pincushion.sourceReach(), 1, accuracy: 1e-6)
        XCTAssertEqual(LensCorrectionStack([]).sourceReach(), 1, accuracy: 1e-6)
    }
}

enum LensCorrectionStackTestSupport {
    static let entries = 1024
}

final class LensProfileTests: XCTestCase {
    private func zoom() -> LensProfile {
        LensProfile(
            maker: "Sony", model: "FE 24-70mm F2.8 GM", mount: "Sony E",
            cropFactor: 1,
            calibrations: [
                LensCalibration(focalLength: 24,
                                distortion: .poly3(k1: -0.08),
                                vignetting: .radial(k1: -0.5, k2: 0, k3: 0),
                                lateralChroma: .linear(red: 1.001, blue: 0.999)),
                LensCalibration(focalLength: 70,
                                distortion: .poly3(k1: 0.02),
                                vignetting: .radial(k1: -0.2, k2: 0, k3: 0),
                                lateralChroma: .linear(red: 1.0002,
                                                       blue: 0.9998)),
            ])
    }

    func testAFocalLengthBetweenMeasurementsIsReadBetweenThem() {
        let profile = zoom()
        let correction = profile.correction(focalLength: 47, aperture: 4)
        guard case .poly3(let k1) = correction.distortion else {
            return XCTFail("expected poly3, got \(correction.distortion)")
        }
        // 47mm is very nearly half way from 24 to 70.
        XCTAssertEqual(k1, (-0.08 + 0.02) / 2, accuracy: 0.002)
    }

    func testOutsideTheMeasuredRangeTheNearestMeasurementIsHeld() {
        let profile = zoom()
        for focal: Float in [10, 24] {
            guard case .poly3(let k1) = profile
                .correction(focalLength: focal, aperture: 4).distortion else {
                return XCTFail("expected poly3")
            }
            XCTAssertEqual(k1, -0.08, accuracy: 1e-6)
        }
        for focal: Float in [70, 200] {
            guard case .poly3(let k1) = profile
                .correction(focalLength: focal, aperture: 4).distortion else {
                return XCTFail("expected poly3")
            }
            XCTAssertEqual(k1, 0.02, accuracy: 1e-6)
        }
    }

    func testMixedModelsPickTheNearerRatherThanBlending() {
        let profile = LensProfile(
            maker: "Test", model: "Mixed 20-80mm", calibrations: [
                LensCalibration(focalLength: 20, distortion: .poly3(k1: -0.05)),
                LensCalibration(focalLength: 80,
                                distortion: .ptLens(a: 0.001, b: -0.01,
                                                    c: 0.002)),
            ])
        guard case .poly3 = profile.correction(focalLength: 30,
                                               aperture: nil).distortion else {
            return XCTFail("30mm should take the 20mm measurement whole")
        }
        guard case .ptLens = profile.correction(focalLength: 70,
                                                aperture: nil).distortion else {
            return XCTFail("70mm should take the 80mm measurement whole")
        }
    }

    func testVignettingIsTakenFromTheNearestAperture() {
        let profile = LensProfile(
            maker: "Test", model: "Prime 50mm", calibrations: [
                LensCalibration(focalLength: 50, aperture: 1.4,
                                vignetting: .radial(k1: -0.8, k2: 0, k3: 0)),
                LensCalibration(focalLength: 50, aperture: 8,
                                vignetting: .radial(k1: -0.1, k2: 0, k3: 0)),
            ])
        guard case .radial(let wide, _, _) = profile
            .correction(focalLength: 50, aperture: 1.4).vignetting,
              case .radial(let stopped, _, _) = profile
            .correction(focalLength: 50, aperture: 11).vignetting else {
            return XCTFail("expected radial vignetting")
        }
        XCTAssertEqual(wide, -0.8, accuracy: 1e-6)
        XCTAssertEqual(stopped, -0.1, accuracy: 1e-6)
    }

    // MARK: - Matching

    func testAnExactNameMatches() {
        let catalogue = LensCatalogue(profiles: [zoom()])
        let shot = LensShot(lensModel: "FE 24-70mm F2.8 GM",
                            lensMaker: "Sony", focalLength: 35, aperture: 4)
        XCTAssertEqual(catalogue.match(shot)?.model, "FE 24-70mm F2.8 GM")
    }

    func testPunctuationAndSpacingDoNotDecideAMatch() {
        let catalogue = LensCatalogue(profiles: [zoom()])
        for written in ["FE 24-70mm f/2.8 GM", "Sony FE 24-70 mm F2.8 GM",
                        "fe 24-70mm f2.8 gm"] {
            XCTAssertNotNil(catalogue.match(LensShot(lensModel: written,
                                                     focalLength: 35)),
                            "\(written) should have found the profile")
        }
    }

    func testADifferentLensInTheSameFamilyDoesNotMatch() {
        let catalogue = LensCatalogue(profiles: [zoom()])
        let other = LensShot(lensModel: "FE 70-200mm F2.8 GM OSS",
                             lensMaker: "Sony", focalLength: 135)
        XCTAssertNil(catalogue.match(other))
    }

    func testAnUnknownLensFindsNothing() {
        let catalogue = LensCatalogue(profiles: [zoom()])
        XCTAssertNil(catalogue.match(LensShot(lensModel: "Some Other 50mm")))
        XCTAssertNil(catalogue.match(LensShot(lensModel: "")))
    }

    func testAProfileThatCannotReachTheFocalLengthIsRejected() {
        let catalogue = LensCatalogue(profiles: [zoom()])
        let impossible = LensShot(lensModel: "FE 24-70mm F2.8 GM",
                                  lensMaker: "Sony", focalLength: 400)
        XCTAssertNil(catalogue.match(impossible))
    }

    func testAnEmptyCatalogueMatchesNothingAndSaysSo() {
        let catalogue = LensCatalogue()
        XCTAssertTrue(catalogue.isEmpty)
        XCTAssertNil(catalogue.match(LensShot(lensModel: "FE 24-70mm F2.8 GM")))
    }

    // MARK: - Round trip

    func testACatalogueSurvivesBeingWrittenAndReadBack() throws {
        let catalogue = LensCatalogue(profiles: [zoom()])
        let restored = try LensCatalogue.load(from: catalogue.encoded())
        XCTAssertEqual(restored.profiles, catalogue.profiles)
    }
}

final class LensAdjustmentTests: XCTestCase {
    func testNeutralIsTheIdentity() {
        XCTAssertTrue(LensAdjustment.neutral.isNeutral)
        XCTAssertTrue(LensAdjustment.neutral.correction.isIdentity)
    }

    func testDistortionSliderReadsTheWayItIsLabelled() {
        let barrel = LensAdjustment(distortion: -1).correction
        let pincushion = LensAdjustment(distortion: 1).correction
        XCTAssertGreaterThan(barrel.distortion.sourceRadius(0.5), 0.5)
        XCTAssertLessThan(pincushion.distortion.sourceRadius(0.5), 0.5)
    }

    func testVignetteTravelCoversWhatARealLensLoses() {
        let full = LensAdjustment(vignetting: -1).correction
        let gainAtCorner = full.vignetting.gain(1)
        let stops = log2(gainAtCorner)
        XCTAssertGreaterThan(stops, 1.4)
        XCTAssertLessThan(stops, 1.7)
    }

    func testChromaTravelStaysWithinWhatLensesActuallyDo() {
        let full = LensAdjustment(redCyan: 1, blueYellow: -1).correction
        let radii = full.lateralChroma.sourceRadii(1)
        XCTAssertEqual(radii.red - 1, 0.005, accuracy: 1e-6)
        XCTAssertEqual(1 - radii.blue, 0.005, accuracy: 1e-6)
    }

    func testEachSliderTouchesOnlyItsOwnTerm() {
        XCTAssertTrue(LensAdjustment(distortion: 0.5).correction
            .vignetting.isIdentity)
        XCTAssertTrue(LensAdjustment(distortion: 0.5).correction
            .lateralChroma.isIdentity)
        XCTAssertTrue(LensAdjustment(vignetting: 0.5).correction
            .distortion.isIdentity)
        XCTAssertTrue(LensAdjustment(redCyan: 0.5).correction
            .distortion.isIdentity)
    }
}
