import XCTest
@testable import FotufilmCore

final class GrainSamplingTests: XCTestCase {
    func testPaperPopulationConservesTheStatedSilverCoating() {
        // One Ag atom per AgCl formula unit. Reconstruct grams of Ag per square metre
        // from the crystal population, volume, density and elemental mass fraction.
        let edgeCM = Double(CrystalGrainModel.Print.crystalEdgeMM) / 10
        let agclMass = pow(edgeCM, 3) * Double(CrystalGrainModel.Print.silverChlorideDensity)
        let agMass = agclMass * 107.8682 / (107.8682 + 35.45)
        let silverPerM2 = Double(CrystalGrainModel.Print.crystalsPerMM2) * 1e6 * agMass
        XCTAssertEqual(silverPerM2, Double(CrystalGrainModel.Print.silverGramsPerM2),
                       accuracy: 1e-6)
    }

    /// A well-resolved Gaussian integrated over a unit pixel has variance sigma² + 1/12.
    /// Test the physical limit independently of the CDF expression used by the solver.
    /// Allow 1% for the renderer's finite (0.27%-tail) kernel and packed Float precision.
    func testResolvedCloudWidthDoesNotCollapseAtFineSampling() {
        for sigma: Float in [5, 10, 20, 32, 48] {
            let sampled = FilmEngineInvocation.discreteGrainSigma(
                clumpSigmaPixels: sigma, foldSigmaPixels: 0, foldKeep: 1)
            let expected = (sigma * sigma + 1 / 12).squareRoot()
            XCTAssertEqual(sampled, expected, accuracy: expected * 0.01,
                           "resolved cloud sigma \(sigma) pixels")
        }
    }

    /// Cropping at unchanged film pitch must leave paper pitch and its grain counts unchanged.
    func testPaperGrainKeepsItsScaleWhenTheFrameIsCropped() {
        var options = FotufilmEngine.Options()
        options.grainModel = .crystals
        options.paper = .enduraPremier
        let stock = TestStocks.negative
        let full = FilmEngineInvocation(stock: stock, options: options, width: 6000, height: 4000)
        options.frameCoverage = 0.25
        let crop = FilmEngineInvocation(stock: stock, options: options, width: 1500, height: 1000)
        let offset = FilmEngineInvocation.crystalPrintGrainOffset
        for channel in 0..<3 {
            XCTAssertEqual(crop.configuration[offset + channel], full.configuration[offset + channel],
                           accuracy: full.configuration[offset + channel] * 1e-5)
        }
    }

    func testContactPrintUsesFilmPitchRegardlessOfCropCoverage() {
        for coverage: Float in [0.05, 0.25, 1] {
            XCTAssertEqual(CrystalGrainModel.Print.pixelMM(
                paper: .vision2383, shortEdgePixels: 1024, pxPerMM: 200,
                frameCoverage: coverage), 1 / 200, accuracy: 1e-7)
        }
    }
}
