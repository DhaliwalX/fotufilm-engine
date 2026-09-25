import XCTest
@testable import FotufilmCore

final class GrainSamplingTests: XCTestCase {
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
}
