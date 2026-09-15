import XCTest
@testable import FotufilmCore

final class StatusADyeUnmixTests: XCTestCase {
    private var dyes: [[Float]] {
        // Synthetic overlapping absorption bands, independent of private profiles.
        [(650.0, 55.0), (545.0, 43.0), (445.0, 38.0)].map { center, width in
            SpectralGrid.wavelengths.map { wavelength in
                Float(0.015 + exp(-0.5 * pow((Double(wavelength) - center) / width, 2)))
            }
        }
    }

    func testFeasibleSpectraRoundTripIncludingClearAndDenseFilm() {
        let spectra = dyes
        let solver = StatusADyeUnmix(dyes: spectra)
        for red: Float in [0, 0.02, 0.4, 1.5, 4, 6] {
            for green: Float in [0, 0.07, 0.8, 3.5] {
                for blue: Float in [0, 0.1, 1.2, 4] {
                    let original = SIMD3(red, green, blue)
                    let target = Densitometry.statusADensity(amounts: original, dyes: spectra)
                    let amounts = solver.amounts(forStatusA: target)
                    let actual = Densitometry.statusADensity(amounts: amounts, dyes: spectra)
                    for c in 0..<3 {
                        XCTAssertGreaterThanOrEqual(amounts[c], 0)
                        XCTAssertEqual(actual[c], target[c], accuracy: 0.00002)
                    }
                }
            }
        }
        XCTAssertEqual(solver.amounts(forStatusA: .zero), .zero)
    }

    func testUnreachableTargetsMinimizeErrorWithoutNegativeAbsorption() {
        let spectra = dyes
        let solver = StatusADyeUnmix(dyes: spectra)
        for target: SIMD3<Float> in [SIMD3(0, 2, 4), SIMD3(4, 0, 3), SIMD3(4, 3, 0)] {
            let amounts = solver.amounts(forStatusA: target)
            func error(_ a: SIMD3<Float>) -> Float {
                let r = Densitometry.statusADensity(amounts: a, dyes: spectra) - target
                return r.x*r.x + r.y*r.y + r.z*r.z
            }
            for c in 0..<3 {
                XCTAssertTrue(amounts[c].isFinite && amounts[c] >= 0)
                for delta: Float in [-0.002, 0.002] {
                    var adjacent = amounts; adjacent[c] += delta
                    if adjacent[c] >= 0 {
                        XCTAssertLessThanOrEqual(error(amounts), error(adjacent) + 0.000005)
                    }
                }
            }
        }
    }

    func testTransparentReversalBasisUsesActualStatusAInversion() {
        var stock = FilmStock.presets["example-reversal-64"]!
        stock.spectralProfile.imageDyeDensity = dyes
        let basis = SpectralRuntime.neutralDensityBasis(for: stock)
        XCTAssertNotNil(basis.statusA)
        let target = Densitometry.statusADensity(amounts: SIMD3(1.2, 0.8, 1.5), dyes: dyes)
        let amounts = basis([target.x, target.y, target.z])
        let actual = Densitometry.statusADensity(amounts: SIMD3(amounts), dyes: dyes)
        for c in 0..<3 { XCTAssertEqual(actual[c], target[c], accuracy: 0.00002) }
    }

    func testDirectViewBalancesTheInterpolatedReferenceGray() {
        var stock = FilmStock.presets["example-reversal-64"]!
        stock.spectralProfile.imageDyeDensity = dyes
        stock.curves = (0..<3).map { c in
            CharacteristicCurve(dMin: 0.08 + Float(c)*0.013, gamma: 1.7,
                toe: -1.4 + Float(c)*0.017, toeWidth: 0.18,
                shoulder: 0.53 + Float(c)*0.025, shoulderWidth: 0.22)
        }
        let table = SpectralRuntime.tables(for: stock, paper: .screen).filmOutput
        let p = SIMD3<Float>((0..<3).map {
            (stock.developedDensity(layer: $0, logExposure: 0)-stock.curves[$0].dMin)
                / (stock.curves[$0].dMax-stock.curves[$0].dMin)
        })
        let rgb = table.sample(p)
        for c in 0..<3 { XCTAssertEqual(rgb[c], 0.18, accuracy: 0.000002) }
    }
}
