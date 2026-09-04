import XCTest
@testable import FotufilmCore

final class IlluminantTests: XCTestCase {
    private func chromaticity(of spectrum: [Float]) -> SIMD2<Float> {
        let xyz = SpectralGrid.xyz(spectrum: spectrum)
        let sum = xyz.x + xyz.y + xyz.z
        return SIMD2(xyz.x / sum, xyz.y / sum)
    }

    // MARK: Planckian

    func testPlanckianIsPositiveSmoothAndAnchoredAt560() {
        let spd = Illuminant.planckian(kelvin: 6500)
        XCTAssertEqual(spd.count, SpectralGrid.count)
        // The anchor sample is the one the normalization divided by, so it is 1 exactly up to
        // the ulp of that division.
        XCTAssertEqual(spd[Illuminant.anchorIndex], 1, accuracy: 1e-6)
        for (i, value) in spd.enumerated() {
            XCTAssertGreaterThan(value, 0, "Planck's law is positive everywhere, index \(i)")
        }
        // Planck's law is analytic, so on a 10 nm grid its second differences are small: the
        // curve's characteristic width at 6500 K is hundreds of nanometres, making the
        // relative curvature per step on the order of (10 / width)^2 ≈ 10^-3. A bound of 0.01
        // catches any tabulation or indexing mistake — a single swapped or corrupted sample
        // shows up as a second difference comparable to the sample itself.
        for i in 1..<(spd.count - 1) {
            let second = spd[i - 1] - 2 * spd[i] + spd[i + 1]
            XCTAssertLessThan(abs(second), 0.01, "second difference at index \(i)")
        }
    }

    func testPlanckianChromaticityMatchesWhiteBalanceLocus() {
        // Same Planck constants, same grid, same observer tables — the only differences are
        // the 560 nm rescale (invisible to chromaticity) and Float rounding, so the two
        // paths must agree far inside 1e-3.
        let xy = chromaticity(of: Illuminant.planckian(kelvin: 6500))
        let locus = WhiteBalance.planckianXY(6500)
        XCTAssertEqual(xy.x, locus.x, accuracy: 1e-3)
        XCTAssertEqual(xy.y, locus.y, accuracy: 1e-3)
    }

    func testIlluminantAChromaticity() {
        // CIE publishes illuminant A at (0.4476, 0.4074). The definition is exactly the
        // 2856 K Planckian radiator, so the residual is only the 10 nm grid against the
        // CIE's 1 nm/5 nm summation plus Float accumulation: 3e-3 per coordinate covers it
        // while still failing on any wrong constant or temperature.
        let xy = chromaticity(of: Illuminant.a)
        XCTAssertEqual(xy.x, 0.4476, accuracy: 3e-3)
        XCTAssertEqual(xy.y, 0.4074, accuracy: 3e-3)
    }

    // MARK: Daylight

    func testDaylight6504ChromaticityMatchesD65() {
        // The daylight series at D65's own temperature must land on D65's chromaticity. Both
        // sides are integrated on the same grid; the gap is the three-component
        // reconstruction against the measured table, which is a sub-1e-3 effect in xy.
        let xy = chromaticity(of: Illuminant.daylight(kelvin: 6504))
        let d65 = chromaticity(of: SpectralGrid.d65)
        XCTAssertEqual(xy.x, d65.x, accuracy: 2e-3)
        XCTAssertEqual(xy.y, d65.y, accuracy: 2e-3)
    }

    func testDaylight6504TracksD65Spectrum() {
        let reconstructed = Illuminant.daylight(kelvin: 6504)
        // The repo's D65 is the published table, normalized to 100 at 560 nm; the generator
        // normalizes to 1 there. Rescale by the anchor sample so the comparison is
        // shape-to-shape.
        let anchor = SpectralGrid.d65[Illuminant.anchorIndex]
        let published = SpectralGrid.d65.map { $0 / anchor }
        // Compare over 400–700 nm, where the observer has real weight and the daylight
        // components were actually fit. The published D65 is itself the component synthesis
        // evaluated at 6504 K — the CIE defined the D series that way — so the reconstruction
        // is near-exact: the residual is only the rounding of the published tables and Float
        // arithmetic, measured at 2.8e-4 worst-band. 1% keeps 35x margin over that while
        // still failing hard on any transcription error in S0/S1/S2, which shifts whole
        // spectral regions by far more.
        for i in 2...32 {
            let deviation = abs(reconstructed[i] - published[i]) / published[i]
            XCTAssertLessThan(deviation, 0.01,
                              "at \(SpectralGrid.wavelengths[i]) nm: "
                              + "\(reconstructed[i]) vs \(published[i])")
        }
        XCTAssertEqual(reconstructed[Illuminant.anchorIndex], 1, accuracy: 1e-6)
    }

    func testDaylightClampsBelowValidity() {
        // The CIE daylight locus polynomial is undefined below 4000 K; asking for less must
        // return the 4000 K spectrum rather than evaluate the polynomial off its domain.
        XCTAssertEqual(Illuminant.daylight(kelvin: 3000),
                       Illuminant.daylight(kelvin: 4000))
    }

    func testDaylightWarmsWithFallingTemperature() {
        // Physical sanity on the series as a whole: a 4500 K daylight is redder and less
        // blue than a 10000 K one. This is the sign of M1 doing its work — a wrong sign or a
        // swapped S1/S2 table inverts it.
        let warm = chromaticity(of: Illuminant.daylight(kelvin: 4500))
        let cool = chromaticity(of: Illuminant.daylight(kelvin: 10000))
        XCTAssertGreaterThan(warm.x, cool.x)
    }
}
