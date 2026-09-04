import XCTest
@testable import FotufilmCore

final class ProfileAccuracyTests: XCTestCase {

    // MARK: CIE machinery (Double, independent of the production Float paths)

    private static let xyzFromRec2020: [SIMD3<Double>] = {
        // Columns of the forward matrix are the images of the XYZ basis vectors.
        var forward = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for axis in 0..<3 {
            var basis = SIMD3<Float>.zero
            basis[axis] = 1
            let column = SpectralGrid.linearRec2020(fromXYZ: basis)
            forward[0][axis] = Double(column.x)
            forward[1][axis] = Double(column.y)
            forward[2][axis] = Double(column.z)
        }
        // Cofactor inverse.
        let a = forward
        let det = a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
                - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        precondition(abs(det) > 1e-12)
        return [
            SIMD3((a[1][1] * a[2][2] - a[1][2] * a[2][1]) / det,
                  (a[0][2] * a[2][1] - a[0][1] * a[2][2]) / det,
                  (a[0][1] * a[1][2] - a[0][2] * a[1][1]) / det),
            SIMD3((a[1][2] * a[2][0] - a[1][0] * a[2][2]) / det,
                  (a[0][0] * a[2][2] - a[0][2] * a[2][0]) / det,
                  (a[0][2] * a[1][0] - a[0][0] * a[1][2]) / det),
            SIMD3((a[1][0] * a[2][1] - a[1][1] * a[2][0]) / det,
                  (a[0][1] * a[2][0] - a[0][0] * a[2][1]) / det,
                  (a[0][0] * a[1][1] - a[0][1] * a[1][0]) / det),
        ]
    }()

    private func lab(_ rgb: SIMD3<Float>) -> SIMD3<Double> {
        func xyz(_ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3((Self.xyzFromRec2020[0] * v).sum(),
                  (Self.xyzFromRec2020[1] * v).sum(),
                  (Self.xyzFromRec2020[2] * v).sum())
        }
        let sample = xyz(SIMD3(Double(rgb.x), Double(rgb.y), Double(rgb.z)))
        let white = xyz(SIMD3(1, 1, 1))
        func f(_ t: Double) -> Double {
            let clamped = max(t, 0)
            let epsilon = 216.0 / 24389.0
            let kappa = 24389.0 / 27.0
            return clamped > epsilon ? cbrt(clamped) : (kappa * clamped + 16) / 116
        }
        let fx = f(sample.x / white.x)
        let fy = f(sample.y / white.y)
        let fz = f(sample.z / white.z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    private func deltaE2000(_ lab1: SIMD3<Double>, _ lab2: SIMD3<Double>) -> Double {
        let c1 = (lab1.y * lab1.y + lab1.z * lab1.z).squareRoot()
        let c2 = (lab2.y * lab2.y + lab2.z * lab2.z).squareRoot()
        let meanC = (c1 + c2) / 2
        let g = 0.5 * (1 - (pow(meanC, 7) / (pow(meanC, 7) + pow(25.0, 7))).squareRoot())
        let a1 = (1 + g) * lab1.y
        let a2 = (1 + g) * lab2.y
        let c1p = (a1 * a1 + lab1.z * lab1.z).squareRoot()
        let c2p = (a2 * a2 + lab2.z * lab2.z).squareRoot()
        func hue(_ a: Double, _ b: Double) -> Double {
            guard a != 0 || b != 0 else { return 0 }
            let angle = atan2(b, a) * 180 / .pi
            return angle >= 0 ? angle : angle + 360
        }
        let h1 = hue(a1, lab1.z)
        let h2 = hue(a2, lab2.z)
        let deltaL = lab2.x - lab1.x
        let deltaC = c2p - c1p
        var deltah = 0.0
        if c1p * c2p != 0 {
            deltah = h2 - h1
            if deltah > 180 { deltah -= 360 }
            if deltah < -180 { deltah += 360 }
        }
        let deltaH = 2 * (c1p * c2p).squareRoot() * sin(deltah * .pi / 360)
        let meanL = (lab1.x + lab2.x) / 2
        let meanCp = (c1p + c2p) / 2
        var meanH = h1 + h2
        if c1p * c2p != 0 {
            if abs(h1 - h2) > 180 {
                meanH += meanH < 360 ? 360 : -360
            }
            meanH /= 2
        }
        let t = 1 - 0.17 * cos((meanH - 30) * .pi / 180)
              + 0.24 * cos(2 * meanH * .pi / 180)
              + 0.32 * cos((3 * meanH + 6) * .pi / 180)
              - 0.20 * cos((4 * meanH - 63) * .pi / 180)
        let deltaTheta = 30 * exp(-pow((meanH - 275) / 25, 2))
        let rc = 2 * (pow(meanCp, 7) / (pow(meanCp, 7) + pow(25.0, 7))).squareRoot()
        let sl = 1 + 0.015 * pow(meanL - 50, 2) / (20 + pow(meanL - 50, 2)).squareRoot()
        let sc = 1 + 0.045 * meanCp
        let sh = 1 + 0.015 * meanCp * t
        let rt = -sin(2 * deltaTheta * .pi / 180) * rc
        let termL = deltaL / sl
        let termC = deltaC / sc
        let termH = deltaH / sh
        return (termL * termL + termC * termC + termH * termH + rt * termC * termH)
            .squareRoot()
    }

    private func apply(_ matrix: [SIMD3<Float>], _ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3((matrix[0] * v).sum(), (matrix[1] * v).sum(), (matrix[2] * v).sum())
    }

    // MARK: The claim

    private struct Score {
        var mean = 0.0
        var max = 0.0
    }

    func testHeldOutDeltaEOfEveryBundledProfile() throws {
        let profiles = CameraSpectralProfileStore.bundledProfiles
        XCTAssertEqual(profiles.count, 52, "the shipped dataset moved; re-measure the bounds")

        let training = CameraSpectralProfile.trainingReflectances()
        XCTAssertEqual(training.count, 84, "24 chart patches + 60 sweep patches")
        // The split is only a held-out claim if the reconstructions are real spectra; the
        // headless fallback (flat greys plus Gaussian bumps) would change what is measured.
        let probe = training[6] // the orange chart patch — strongly non-flat when loaded
        XCTAssertGreaterThan((probe.max() ?? 0) - (probe.min() ?? 0), 1e-3,
                             "spectral reconstruction table not loaded")
        var fit: [[Float]] = []
        var held: [[Float]] = []
        for (index, reflectance) in training.enumerated() {
            if index.isMultiple(of: 2) { fit.append(reflectance) } else {
                held.append(reflectance)
            }
        }

        var results: [(id: String, d65: Score, a: Score)] = []
        for profile in profiles {
            var scores: [Score] = []
            for illuminant in [Illuminant.d65, Illuminant.a] {
                let matrix = profile.matrixToRec2020(illuminant: illuminant,
                                                       training: fit)
                var score = Score()
                for reflectance in held {
                    let camera = profile.cameraResponse(reflectance: reflectance,
                                                        illuminant: illuminant)
                    let predicted = apply(matrix, camera)
                    let target = CameraSpectralProfile.colorimetricTarget(
                        reflectance: reflectance, illuminant: illuminant)
                    let delta = deltaE2000(lab(predicted), lab(target))
                    score.mean += delta
                    score.max = Swift.max(score.max, delta)
                }
                score.mean /= Double(held.count)
                scores.append(score)
            }
            results.append((profile.id, scores[0], scores[1]))
            // The log line is the accuracy claim: one row per body, held-out ΔE2000.
            print(String(format: "profile-accuracy %@ D65 mean %.3f max %.3f | A mean %.3f max %.3f",
                         profile.id, scores[0].mean, scores[0].max,
                         scores[1].mean, scores[1].max))
        }

        // Bounds set from measurement, not aspiration. Measured on rawtoaces-data
        // e9b8503 plus the Weta ILCE-7CM2 record (2026-08-11, this suite, release):
        // worst held-out mean 1.284 ΔE2000 under D65 (fujifilm-gfx-100) and 1.562
        // under A (canon-powershot-s90); worst held-out max 4.978 under D65
        // (fujifilm-gfx-100) and 8.859 under A (hasselblad-l2d-20c); best body
        // sony-ilce-7rm4 at 0.385 mean. The asserts sit at ~1.5× the measured worst
        // — enough that Float-integral noise or a table refresh cannot flake them,
        // tight enough that a broken solve, a corrupted profile, or a degenerate
        // training split (whose means land well above 2) fails loudly.
        for result in results {
            XCTAssertLessThan(result.d65.mean, 1.9,
                              "\(result.id): held-out mean ΔE2000 under D65")
            XCTAssertLessThan(result.a.mean, 2.3,
                              "\(result.id): held-out mean ΔE2000 under A")
            XCTAssertLessThan(result.d65.max, 7.5,
                              "\(result.id): held-out max ΔE2000 under D65")
            XCTAssertLessThan(result.a.max, 13.3,
                              "\(result.id): held-out max ΔE2000 under A")
        }

        let byMean = results.sorted {
            $0.d65.mean + $0.a.mean < $1.d65.mean + $1.a.mean
        }
        if let best = byMean.first, let worst = byMean.last {
            print(String(format: "profile-accuracy best %@ (D65 %.3f, A %.3f) worst %@ (D65 %.3f, A %.3f)",
                         best.id, best.d65.mean, best.a.mean,
                         worst.id, worst.d65.mean, worst.a.mean))
        }
    }
}
