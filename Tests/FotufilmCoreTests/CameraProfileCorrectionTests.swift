import XCTest
@testable import FotufilmCore

final class CameraProfileCorrectionTests: XCTestCase {
    private let base: [Float] = [
        0.82, 0.13, 0.05,
        0.04, 0.88, 0.08,
        -0.02, 0.10, 0.92,
    ]

    private let sonyCamera = CameraIdentity(make: "Sony", model: "ILCE-7CM2")

    // MARK: The gate: every skip returns the base elementwise-unchanged

    func testNilCameraReturnsBaseUnchanged() {
        XCTAssertEqual(CameraProfileCorrection.composedGamut(
            base: base, camera: nil, cct: 3200), base)
    }

    func testNilTemperatureReturnsBaseUnchanged() {
        XCTAssertEqual(CameraProfileCorrection.composedGamut(
            base: base, camera: sonyCamera, cct: nil), base)
    }

    func testDaylightTemperatureRetainsSubCodeValueCorrection() {
        XCTAssertNotEqual(CameraProfileCorrection.composedGamut(
            base: base, camera: sonyCamera,
            cct: CameraProfileCorrection.skipKelvin), base)
        // The profile's actual D65 anchor is identity and still requires no pass.
        XCTAssertEqual(CameraProfileCorrection.composedGamut(
            base: base, camera: sonyCamera, cct: 6504), base)
    }

    func testUnknownCameraReturnsBaseUnchanged() {
        XCTAssertEqual(CameraProfileCorrection.composedGamut(
            base: base,
            camera: CameraIdentity(make: "Nokia", model: "3310"),
            cct: 3200), base)
    }

    func testKillSwitchReturnsBaseUnchanged() {
        // FOTUFILM_PROFILE_OFF disables resolution entirely; `isDisabled` reads the live
        // environment through getenv, so the switch can be flipped in-process here.
        setenv("FOTUFILM_PROFILE_OFF", "1", 1)
        defer { unsetenv("FOTUFILM_PROFILE_OFF") }
        XCTAssertTrue(CameraProfileCorrection.isDisabled)
        XCTAssertEqual(CameraProfileCorrection.composedGamut(
            base: base, camera: sonyCamera, cct: 3200), base)
    }

    // MARK: The composition

    func testWarmSceneComposesCorrectionTimesBase() throws {
        unsetenv("FOTUFILM_PROFILE_OFF")
        let profile = try XCTUnwrap(CameraSpectralProfileStore.resolve(sonyCamera))
        XCTAssertEqual(profile.id, "sony-ilce-7cm2")
        let correction = profile.dualIlluminantMatrices().correction(cct: 3200)
        // The gate only fires when the delta is observable; a correction below the deviation
        // floor would make this test vacuous, so assert the premise too.
        XCTAssertGreaterThanOrEqual(
            DualIlluminantMatrices.maxDeviationFromIdentity(correction),
            CameraProfileCorrection.minimumDeviation)

        let composed = CameraProfileCorrection.composedGamut(
            base: base, camera: sonyCamera, cct: 3200)
        XCTAssertNotEqual(composed, base)
        for row in 0..<3 {
            for column in 0..<3 {
                let expected = correction[row].x * base[column]
                    + correction[row].y * base[3 + column]
                    + correction[row].z * base[6 + column]
                XCTAssertEqual(composed[row * 3 + column], expected, accuracy: 1e-6,
                               "row \(row) column \(column)")
            }
        }
    }

    func testCompositionPreservesWhite() {
        unsetenv("FOTUFILM_PROFILE_OFF")
        // The correction's rows are pinned to sum to one and the base's rows sum to one, so
        // the composed matrix still carries camera white (1, 1, 1) to working white: each
        // composed row's sum is the correction row against the base's row sums. A camera grey
        // must stay grey through the composed path exactly as it does through the stills' pass.
        let composed = CameraProfileCorrection.composedGamut(
            base: base, camera: sonyCamera, cct: 3200)
        XCTAssertNotEqual(composed, base)
        for row in 0..<3 {
            let sum = composed[row * 3] + composed[row * 3 + 1] + composed[row * 3 + 2]
            XCTAssertEqual(sum, 1, accuracy: 1e-5, "row \(row)")
        }
    }
}
