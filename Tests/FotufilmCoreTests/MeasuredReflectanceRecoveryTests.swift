import XCTest
@testable import FotufilmCore

final class MeasuredReflectanceRecoveryTests: XCTestCase {
    func testBundledPriorUsesBroadMeasuredCorpus() {
        XCTAssertTrue(SpectralRuntime.hasReconstructionModel)
        XCTAssertGreaterThanOrEqual(SpectralRuntime.reconstructionSourceCount ?? 0, 28_000)
    }

    func testAnchorRecoveryIsBoundedAndMatchesD65Colour() {
        let colours: [SIMD3<Float>] = [
            SIMD3(0.25, 0.04, 0.03),
            SIMD3(0.06, 0.25, 0.09),
            SIMD3(0.05, 0.08, 0.25),
            SIMD3(0.25, 0.18, 0.02),
            SIMD3(0.11, 0.02, 0.25),
            SIMD3(0.17, 0.25, 0.22),
        ]
        for colour in colours {
            let spectrum = SpectralRuntime.reconstructedReflectance(linearRGB: colour)
            XCTAssertEqual(spectrum.count, SpectralGrid.count)
            XCTAssertGreaterThanOrEqual(spectrum.min() ?? -1, 0)
            XCTAssertLessThanOrEqual(spectrum.max() ?? 2, 1)
            let reproduced = CameraSpectralProfile.colorimetricTarget(
                reflectance: spectrum, illuminant: SpectralGrid.d65)
            for channel in 0..<3 {
                XCTAssertEqual(reproduced[channel], colour[channel], accuracy: 2e-4,
                               "\(colour), channel \(channel)")
            }
        }
    }

    func testNeutralRecoveryRemainsSpectrallyFlat() {
        for grey: Float in [0.02, 0.18, 0.25, 0.5, 1] {
            let spectrum = SpectralRuntime.reconstructedReflectance(
                linearRGB: SIMD3(repeating: grey))
            for value in spectrum {
                XCTAssertEqual(value, grey, accuracy: 2e-6)
            }
        }
    }

    func testFaceSelectionIsContinuousAtDominantChannelTie() {
        let epsilon: Float = 1e-5
        let below = SpectralRuntime.reconstructedReflectance(
            linearRGB: SIMD3(0.25, 0.25 - epsilon, 0.08))
        let above = SpectralRuntime.reconstructedReflectance(
            linearRGB: SIMD3(0.25 - epsilon, 0.25, 0.08))
        for band in 0..<SpectralGrid.count {
            XCTAssertEqual(below[band], above[band], accuracy: 5e-4,
                           "\(SpectralGrid.wavelengths[band]) nm")
        }
    }
}
