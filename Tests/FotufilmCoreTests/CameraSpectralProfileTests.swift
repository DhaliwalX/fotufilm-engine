import XCTest
@testable import FotufilmCore

final class CameraSpectralProfileTests: XCTestCase {
    // MARK: Matrix derivation

    private func colorimetricCamera() -> CameraSpectralProfile {
        var red = [Float](), green = [Float](), blue = [Float]()
        for i in 0..<SpectralGrid.count {
            let working = SpectralGrid.linearRec2020(fromXYZ: SIMD3(
                SpectralGrid.xBar[i], SpectralGrid.yBar[i], SpectralGrid.zBar[i]))
            red.append(working.x); green.append(working.y); blue.append(working.z)
        }
        return CameraSpectralProfile(id: "test.colorimetric",
                                     gridSensitivity: [red, green, blue])
    }

    private func gaussianCamera() -> CameraSpectralProfile {
        func bump(peak: Float) -> [Float] {
            SpectralGrid.wavelengths.map { wavelength in
                let x = (wavelength - peak) / 30
                return exp(-0.5 * x * x)
            }
        }
        return CameraSpectralProfile(
            id: "test.gaussian",
            wavelengths: SpectralGrid.wavelengths,
            red: bump(peak: 600), green: bump(peak: 550), blue: bump(peak: 450))
    }

    private func apply(_ matrix: [SIMD3<Float>], _ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3((matrix[0] * v).sum(), (matrix[1] * v).sum(), (matrix[2] * v).sum())
    }

    func testColorimetricCameraRecoversIdentity() {
        let matrix = colorimetricCamera().matrixToRec2020()
        // For this camera every training sample's normalized response *equals* its normalized
        // colorimetric target — both are M·XYZ divided per channel by M·whiteXYZ — so the
        // least squares has an exact solution at identity. The only perturbations left are the
        // ridge term (1e-6 relative) and Float accumulation over 41-sample integrals, so 1e-3
        // elementwise is generous without being blind to a real regression.
        for row in 0..<3 {
            for column in 0..<3 {
                let expected: Float = row == column ? 1 : 0
                XCTAssertEqual(matrix[row][column], expected, accuracy: 1e-3,
                               "matrix[\(row)][\(column)]")
            }
        }
    }

    func testWhitePreservationIsExact() {
        for profile in [colorimetricCamera(), gaussianCamera()] {
            let matrix = profile.matrixToRec2020()
            let white = apply(matrix, SIMD3(1, 1, 1))
            // The row normalization pins each row's sum to 1 by a single division, so camera
            // white lands on working white to within a few ulps of that division.
            XCTAssertEqual(white.x, 1, accuracy: 1e-6)
            XCTAssertEqual(white.y, 1, accuracy: 1e-6)
            XCTAssertEqual(white.z, 1, accuracy: 1e-6)
        }
    }

    func testGaussianCameraSolveBeatsIdentity() {
        let profile = gaussianCamera()
        let matrix = profile.matrixToRec2020()
        let training = CameraSpectralProfile.trainingReflectances()
        var solvedError: Float = 0
        var identityError: Float = 0
        for reflectance in training {
            let camera = profile.cameraResponse(reflectance: reflectance,
                                                illuminant: SpectralGrid.d65)
            let target = CameraSpectralProfile.colorimetricTarget(
                reflectance: reflectance, illuminant: SpectralGrid.d65)
            let corrected = apply(matrix, camera) - target
            let raw = camera - target
            solvedError += (corrected * corrected).sum()
            identityError += (raw * raw).sum()
        }
        let solvedRMS = (solvedError / Float(training.count * 3)).squareRoot()
        let identityRMS = (identityError / Float(training.count * 3)).squareRoot()
        XCTAssertLessThan(solvedRMS, identityRMS,
                          "solved \(solvedRMS) vs identity \(identityRMS)")
        // Not just numerically lower: the correction should remove most of the error, or the
        // matrix is not doing the colorimetric work it exists for.
        XCTAssertLessThan(solvedRMS, 0.5 * identityRMS,
                          "solved \(solvedRMS) vs identity \(identityRMS)")
    }

    // MARK: Resampling

    func testResamplingReproducesLinearFunctionExactly() {
        // 5 nm samples of a function linear in wavelength: linear interpolation is exact on
        // such data, and grid points coincide with measured wavelengths, which the resampler
        // returns untouched — so the comparison is bit-exact, not approximate.
        let wavelengths: [Float] = stride(from: Float(380), through: 780, by: 5).map { $0 }
        func value(_ wavelength: Float) -> Float { 0.001 * (wavelength - 380) }
        let samples = wavelengths.map(value)
        let profile = CameraSpectralProfile(
            id: "test.resample.linear", wavelengths: wavelengths,
            red: samples, green: samples, blue: samples)
        for (i, wavelength) in SpectralGrid.wavelengths.enumerated() {
            XCTAssertEqual(profile.sensitivity[0][i], value(wavelength))
        }
    }

    func testResamplingZeroesOutsideMeasuredRange() {
        // Measured span 400–720: the grid points the instrument never saw stay zero rather
        // than extrapolating sensitivity the camera may not have.
        let wavelengths: [Float] = stride(from: Float(400), through: 720, by: 10).map { $0 }
        let flat = [Float](repeating: 1, count: wavelengths.count)
        let profile = CameraSpectralProfile(
            id: "test.resample.range", wavelengths: wavelengths,
            red: flat, green: flat, blue: flat)
        for (i, wavelength) in SpectralGrid.wavelengths.enumerated() {
            let expected: Float = (wavelength >= 400 && wavelength <= 720) ? 1 : 0
            XCTAssertEqual(profile.sensitivity[0][i], expected, "at \(wavelength) nm")
        }
    }

    func testResamplingDropsDataOutsideGridAndClampsNegatives() {
        // Data running past both grid ends is simply consumed by interpolation — nothing
        // outside 380...780 survives into the stored samples — and a negative excursion
        // (measurement noise) clamps to zero instead of becoming negative sensitivity. The
        // clamp happens before interpolation, so the grid points between the excursion and
        // its 10 nm neighbours read halfway to zero.
        let wavelengths: [Float] = stride(from: Float(300), through: 860, by: 10).map { $0 }
        let samples = wavelengths.map { $0 == 500 ? Float(-0.5) : 0.25 }
        let profile = CameraSpectralProfile(
            id: "test.resample.outside", wavelengths: wavelengths,
            red: samples, green: samples, blue: samples)
        XCTAssertEqual(profile.sensitivity[0].count, SpectralGrid.count)
        for (i, wavelength) in SpectralGrid.wavelengths.enumerated() {
            let expected: Float = wavelength == 500 ? 0
                : (abs(wavelength - 500) < 10 ? 0.25 * (abs(wavelength - 500) / 10) : 0.25)
            XCTAssertEqual(profile.sensitivity[0][i], expected, "at \(wavelength) nm")
            XCTAssertGreaterThanOrEqual(profile.sensitivity[0][i], 0)
        }
    }

    // MARK: Dual-illuminant blending

    func testDualIlluminantAnchorsGenuinelyDiffer() {
        let anchors = gaussianCamera().dualIlluminantMatrices()
        var maxGap: Float = 0
        for row in 0..<3 {
            for column in 0..<3 {
                maxGap = max(maxGap,
                             abs(anchors.tungsten[row][column]
                                 - anchors.daylight[row][column]))
            }
        }
        XCTAssertGreaterThan(maxGap, 0.01,
                             "anchor matrices too similar for the blend to be load-bearing")
    }

    func testMatrixCCTEndpointsReturnAnchorsExactly() {
        let anchors = gaussianCamera().dualIlluminantMatrices()
        // At the anchor temperatures the weight formula evaluates to exactly 1 and exactly 0
        // (numerator and denominator are the same expression, or the numerator is zero), and
        // the blend returns the anchor rows untouched — bitwise, not approximately.
        XCTAssertEqual(anchors.matrix(cct: 2856), anchors.tungsten)
        XCTAssertEqual(anchors.matrix(cct: 6504), anchors.daylight)
        // Beyond the anchors the weight clamps: no extrapolated correction exists to return.
        XCTAssertEqual(anchors.matrix(cct: 2000), anchors.tungsten)
        XCTAssertEqual(anchors.matrix(cct: 12000), anchors.daylight)
    }

    func testMatrixCCTMidpointLiesBetweenAnchors() {
        let anchors = gaussianCamera().dualIlluminantMatrices()
        let mid = anchors.matrix(cct: 4400)
        // A convex combination of the anchors lies elementwise between them; the white
        // re-pinning divides each row by a sum within a few ulps of 1, which perturbs
        // elements far less than 1e-5.
        for row in 0..<3 {
            for column in 0..<3 {
                let a = anchors.tungsten[row][column]
                let b = anchors.daylight[row][column]
                XCTAssertGreaterThanOrEqual(mid[row][column], min(a, b) - 1e-5,
                                            "matrix[\(row)][\(column)]")
                XCTAssertLessThanOrEqual(mid[row][column], max(a, b) + 1e-5,
                                         "matrix[\(row)][\(column)]")
            }
        }
        // Lying between the anchors is necessary but does not pin the *rule*: a blend linear
        // in kelvin would also land between them, just at fraction 0.577 instead of the DNG
        // mired fraction (1/4400 − 1/6504) / (1/2856 − 1/6504) ≈ 0.3746. Recover the
        // fraction from the element the anchors disagree on most, where the ulp-level white
        // re-pinning is proportionally smallest.
        var row = 0, column = 0
        var maxGap: Float = -1
        for r in 0..<3 {
            for c in 0..<3 {
                let gap = abs(anchors.tungsten[r][c] - anchors.daylight[r][c])
                if gap > maxGap { maxGap = gap; row = r; column = c }
            }
        }
        let fraction = (mid[row][column] - anchors.daylight[row][column])
            / (anchors.tungsten[row][column] - anchors.daylight[row][column])
        XCTAssertEqual(fraction, 0.3746, accuracy: 5e-3,
                       "blend must be linear in mired, not in kelvin")
    }

    func testMatrixCCTPreservesWhiteAtEveryTemperature() {
        let anchors = gaussianCamera().dualIlluminantMatrices()
        for cct in [Float(2000), 2856, 3400, 4400, 5600, 6504, 12000] {
            let white = apply(anchors.matrix(cct: cct), SIMD3(1, 1, 1))
            XCTAssertEqual(white.x, 1, accuracy: 1e-6, "at \(cct) K")
            XCTAssertEqual(white.y, 1, accuracy: 1e-6, "at \(cct) K")
            XCTAssertEqual(white.z, 1, accuracy: 1e-6, "at \(cct) K")
        }
    }

    func testMatrixCCTIsMonotoneInMired() {
        let anchors = gaussianCamera().dualIlluminantMatrices()
        // Pick the element the anchors disagree on most: it carries the blend's largest
        // excursion, so a broken weight shows up here first.
        var row = 0, column = 0
        var maxGap: Float = -1
        for r in 0..<3 {
            for c in 0..<3 {
                let gap = abs(anchors.tungsten[r][c] - anchors.daylight[r][c])
                if gap > maxGap { maxGap = gap; row = r; column = c }
            }
        }
        // Walk from the daylight anchor to the tungsten anchor in equal mired steps — the
        // scale the blend is linear in. The element must march monotonically from its
        // daylight value to its tungsten value; the white re-pinning perturbs each step by
        // ulps, hence the 1e-6 slack.
        let coolMired: Float = 1e6 / 6504
        let warmMired: Float = 1e6 / 2856
        let towardTungsten = anchors.tungsten[row][column] >= anchors.daylight[row][column]
        var previous = anchors.daylight[row][column]
        for step in 1...8 {
            let fraction = Float(step) / 8
            let mired = coolMired + (warmMired - coolMired) * fraction
            let value = anchors.matrix(cct: 1e6 / mired)[row][column]
            if towardTungsten {
                XCTAssertGreaterThanOrEqual(value, previous - 1e-6, "step \(step)")
            } else {
                XCTAssertLessThanOrEqual(value, previous + 1e-6, "step \(step)")
            }
            previous = value
        }
        XCTAssertEqual(previous, anchors.tungsten[row][column], accuracy: 1e-6)
    }

    func testProfileMatrixConvenienceAgreesWithHeldAnchors() {
        // The one-shot convenience must be the same blend as the held pair — it exists so a
        // call site without a cache still gets identical numbers, not a second code path.
        let profile = gaussianCamera()
        let anchors = profile.dualIlluminantMatrices()
        for cct in [Float(2856), 4400, 6504] {
            XCTAssertEqual(profile.matrix(cct: cct), anchors.matrix(cct: cct), "at \(cct) K")
        }
    }

    // MARK: Illuminant-aware correction

    private func cofactorInverse(_ m: [SIMD3<Float>]) -> [SIMD3<Double>] {
        let a = m.map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) }
        let det = a[0].x * (a[1].y * a[2].z - a[1].z * a[2].y)
                - a[0].y * (a[1].x * a[2].z - a[1].z * a[2].x)
                + a[0].z * (a[1].x * a[2].y - a[1].y * a[2].x)
        precondition(abs(det) > 1e-12)
        return [
            SIMD3((a[1].y * a[2].z - a[1].z * a[2].y) / det,
                  (a[0].z * a[2].y - a[0].y * a[2].z) / det,
                  (a[0].y * a[1].z - a[0].z * a[1].y) / det),
            SIMD3((a[1].z * a[2].x - a[1].x * a[2].z) / det,
                  (a[0].x * a[2].z - a[0].z * a[2].x) / det,
                  (a[0].z * a[1].x - a[0].x * a[1].z) / det),
            SIMD3((a[1].x * a[2].y - a[1].y * a[2].x) / det,
                  (a[0].y * a[2].x - a[0].x * a[2].y) / det,
                  (a[0].x * a[1].y - a[0].y * a[1].x) / det),
        ]
    }

    func testCorrectionAtDaylightAnchorIsIdentity() {
        // M(6504)·M(6504)⁻¹ in Double on Float-rounded anchors: identity to well inside 1e-6.
        // This is the pillar of the ingest contract — a daylight scene must not move at all.
        let correction = gaussianCamera().dualIlluminantMatrices().correction(cct: 6504)
        for row in 0..<3 {
            for column in 0..<3 {
                let expected: Float = row == column ? 1 : 0
                XCTAssertEqual(correction[row][column], expected, accuracy: 1e-6,
                               "correction[\(row)][\(column)]")
            }
        }
    }

    func testCorrectionAtTungstenEqualsTungstenTimesInverseDaylight() {
        let anchors = gaussianCamera().dualIlluminantMatrices()
        let correction = anchors.correction(cct: 2856)
        // The reference product, built with an independent inverse and the same white re-pin.
        let inverse = cofactorInverse(anchors.daylight)
        for row in 0..<3 {
            var expected = SIMD3<Double>.zero
            for k in 0..<3 {
                expected += Double(anchors.tungsten[row][k]) * inverse[k]
            }
            expected /= expected.x + expected.y + expected.z
            for column in 0..<3 {
                XCTAssertEqual(Double(correction[row][column]), expected[column],
                               accuracy: 1e-6, "correction[\(row)][\(column)]")
            }
        }
        // And the tungsten correction must be a real correction, or the wiring is vacuous:
        // the Gaussian camera's anchors genuinely differ, so the delta must too.
        XCTAssertGreaterThan(
            DualIlluminantMatrices.maxDeviationFromIdentity(correction), 0.01)
    }

    func testCorrectionPreservesWhiteAtEveryTemperature() {
        let anchors = gaussianCamera().dualIlluminantMatrices()
        for cct in [Float(2000), 2856, 3200, 4400, 5500, 6504, 12000] {
            let white = apply(anchors.correction(cct: cct), SIMD3(1, 1, 1))
            XCTAssertEqual(white.x, 1, accuracy: 1e-6, "at \(cct) K")
            XCTAssertEqual(white.y, 1, accuracy: 1e-6, "at \(cct) K")
            XCTAssertEqual(white.z, 1, accuracy: 1e-6, "at \(cct) K")
        }
    }

    func testCorrectionIsSmoothAndMonotoneInMired() {
        let anchors = gaussianCamera().dualIlluminantMatrices()
        // The element the tungsten correction moves most carries the blend's largest
        // excursion, so a broken weight or a sign flip shows up here first.
        let tungsten = anchors.correction(cct: 2856)
        var row = 0, column = 0
        var maxGap: Float = -1
        for r in 0..<3 {
            for c in 0..<3 {
                let expected: Float = r == c ? 1 : 0
                let gap = abs(tungsten[r][c] - expected)
                if gap > maxGap { maxGap = gap; row = r; column = c }
            }
        }
        // Walk daylight → tungsten in equal mired steps, the scale the blend is linear in.
        // The element must march monotonically from its identity value to its tungsten value,
        // and smoothly: linear-in-mired blending of two fixed anchors (plus an ulp-level white
        // re-pin) cannot produce a step bigger than about twice the mean step.
        let coolMired: Float = 1e6 / 6504
        let warmMired: Float = 1e6 / 2856
        let start = anchors.correction(cct: 6504)[row][column]
        let total = tungsten[row][column] - start
        let towardTungsten = total >= 0
        var previous = start
        var largestStep: Float = 0
        for step in 1...8 {
            let mired = coolMired + (warmMired - coolMired) * Float(step) / 8
            let value = anchors.correction(cct: 1e6 / mired)[row][column]
            if towardTungsten {
                XCTAssertGreaterThanOrEqual(value, previous - 1e-6, "step \(step)")
            } else {
                XCTAssertLessThanOrEqual(value, previous + 1e-6, "step \(step)")
            }
            largestStep = max(largestStep, abs(value - previous))
            previous = value
        }
        XCTAssertEqual(previous, tungsten[row][column], accuracy: 1e-6)
        XCTAssertLessThan(largestStep, 2 * abs(total) / 8 + 1e-6,
                          "blend is not smooth in mired")
    }

    // MARK: Ingest correction wiring

    private func registeredGaussianIdentity() -> (camera: CameraIdentity, id: String) {
        let profile = CameraSpectralProfile(
            id: "test.correction.gaussian", make: "CorrectionMake",
            model: "Gauss-1",
            wavelengths: SpectralGrid.wavelengths,
            red: SpectralGrid.wavelengths.map { exp(-0.5 * pow(($0 - 600) / 30, 2)) },
            green: SpectralGrid.wavelengths.map { exp(-0.5 * pow(($0 - 550) / 30, 2)) },
            blue: SpectralGrid.wavelengths.map { exp(-0.5 * pow(($0 - 450) / 30, 2)) })
        CameraSpectralProfileStore.register(profile)
        return (CameraIdentity(make: "CorrectionMake", model: "Gauss-1"), profile.id)
    }

    func testResolveRequiresCameraAndTemperature() {
        let (camera, id) = registeredGaussianIdentity()
        // A warm scene on a known body resolves, names the profile, and carries a matrix
        // whose deviation clears the floor the wiring applies.
        let resolved = CameraProfileCorrection.resolve(camera: camera, sceneKelvin: 3200)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.profileID, id)
        XCTAssertEqual(resolved?.cct, 3200)
        XCTAssertGreaterThanOrEqual(resolved?.maxDeviation ?? 0,
                                    CameraProfileCorrection.minimumDeviation)
        // Daylight below the profile anchor still carries its small correction.
        XCTAssertNotNil(CameraProfileCorrection.resolve(
            camera: camera, sceneKelvin: CameraProfileCorrection.skipKelvin))
        // At the actual D65 anchor the correction is exact identity.
        XCTAssertNil(CameraProfileCorrection.resolve(camera: camera, sceneKelvin: 6504))
        XCTAssertNil(CameraProfileCorrection.resolve(camera: camera, sceneKelvin: nil))
        // So does a body the store cannot name.
        XCTAssertNil(CameraProfileCorrection.resolve(
            camera: CameraIdentity(make: "CorrectionMake", model: "Absent-9"),
            sceneKelvin: 3200))
        XCTAssertNil(CameraProfileCorrection.resolve(camera: nil, sceneKelvin: 3200))
    }

    func testApplyMatchesRowMultiplyAndPreservesAlpha() {
        let matrix: [SIMD3<Float>] = [SIMD3(0.9, 0.08, 0.02),
                                      SIMD3(-0.05, 1.1, -0.05),
                                      SIMD3(0.01, -0.04, 1.03)]
        var floats: [Float] = [0.2, 0.5, 0.8, 1.0, 1.5, 0.1, 0.0, 0.5]
        let original = floats
        CameraProfileCorrection.apply(matrix, toRGBA: &floats)
        for pixel in 0..<2 {
            let v = SIMD3(original[pixel * 4], original[pixel * 4 + 1],
                          original[pixel * 4 + 2])
            for channel in 0..<3 {
                XCTAssertEqual(floats[pixel * 4 + channel],
                               (matrix[channel] * v).sum(), accuracy: 1e-6)
            }
            XCTAssertEqual(floats[pixel * 4 + 3], original[pixel * 4 + 3],
                           "alpha is transport, not light")
        }
    }

    // MARK: Store

    func testStoreRegisterAndLookupByID() {
        let profile = CameraSpectralProfile(
            id: "test.store.byid", make: "Acme", model: "One",
            gridSensitivity: [[Float]](repeating: [Float](repeating: 1,
                                                          count: SpectralGrid.count),
                              count: 3))
        CameraSpectralProfileStore.register(profile)
        XCTAssertEqual(CameraSpectralProfileStore.profile(id: "test.store.byid"), profile)
        XCTAssertNil(CameraSpectralProfileStore.profile(id: "test.store.absent"))
    }

    func testStoreResolvesCameraIdentity() {
        let profile = CameraSpectralProfile(
            id: "test.store.resolve", make: "TestMake", model: "X-100",
            gridSensitivity: [[Float]](repeating: [Float](repeating: 1,
                                                          count: SpectralGrid.count),
                              count: 3))
        CameraSpectralProfileStore.register(profile)

        // An explicit profile id wins outright.
        XCTAssertEqual(CameraSpectralProfileStore.resolve(CameraIdentity(
            spectralProfileID: "test.store.resolve")), profile)
        // Make + model fall back, case-insensitively, when no id is stated.
        XCTAssertEqual(CameraSpectralProfileStore.resolve(CameraIdentity(
            make: "testmake", model: "x-100")), profile)
        XCTAssertEqual(CameraSpectralProfileStore.resolve(CameraIdentity(
            make: "TESTMAKE", model: "X-100",
            spectralProfileID: "test.store.absent")), profile)
        // Unknown cameras resolve to nothing — the caller falls back to colorimetry.
        XCTAssertNil(CameraSpectralProfileStore.resolve(CameraIdentity(
            make: "TestMake", model: "Y-200")))
        XCTAssertNil(CameraSpectralProfileStore.resolve(CameraIdentity(make: "TestMake")))
        XCTAssertNil(CameraSpectralProfileStore.resolve(nil))
    }
}
