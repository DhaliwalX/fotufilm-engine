import XCTest
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class SceneIlluminantTests: XCTestCase {
    func testSpectrumAndControlWhiteAgreeIncludingTintAndCrossover() {
        for kelvin in stride(from: Float(2000), through: 12000, by: 100) {
            for tint: Float in [-100, 0, 100] {
                let light = WhiteBalance(kelvin: kelvin, tint: tint)
                let spectrum = Illuminant.spectrum(light)
                let actual = Illuminant.chromaticity(spectrum)
                let expected = WhiteBalance.chromaticity(kelvin: kelvin, tint: tint)
                XCTAssertEqual(actual.x, expected.x, accuracy: 1e-5, "\(light)")
                XCTAssertEqual(actual.y, expected.y, accuracy: 1e-5, "\(light)")
                XCTAssertTrue(spectrum.allSatisfy { $0.isFinite && $0 >= 0 })
            }
        }
    }

    func testDecoderWhiteIsCarriedWithoutConvertingTintUnits() {
        var options = FotufilmEngine.Options()
        options.sceneIlluminantKelvin = 4800
        let white = SIMD2<Float>(0.361, 0.382)
        options.sceneIlluminantChromaticity = white
        let actual = Illuminant.chromaticity(options.resolvedSceneSpectrum)
        XCTAssertEqual(actual.x, white.x, accuracy: 1e-5)
        XCTAssertEqual(actual.y, white.y, accuracy: 1e-5)
        options.whiteBalance.tint = 30
        let edited = Illuminant.chromaticity(options.resolvedSceneSpectrum)
        XCTAssertGreaterThan(WhiteBalance.uvFromXY(edited).y,
                             WhiteBalance.uvFromXY(actual).y)
    }

    func testCaptureRelativeControlExtremesStayRepresentable() {
        for capture: Float in [2000, 2856, 3200, 4300, 6504, 12000] {
            for edit: Float in [2000, 6504, 12000] {
                for tint: Float in [-100, 0, 100] {
                    var options = FotufilmEngine.Options()
                    options.sceneIlluminantKelvin = capture
                    options.whiteBalance = WhiteBalance(kelvin: edit, tint: tint)
                    XCTAssertTrue(options.resolvedSceneSpectrum.allSatisfy { $0.isFinite && $0 >= 0 })
                    options.sceneIlluminantChromaticity = WhiteBalance.chromaticity(kelvin: capture, tint: 35)
                    XCTAssertTrue(options.resolvedSceneSpectrum.allSatisfy { $0.isFinite && $0 >= 0 })
                }
            }
        }
    }

    func testLightControlsChangeSpectralExposureWithoutRGBAdaptation() {
        var options = FotufilmEngine.Options()
        let neutral = FilmEngineInvocation(stock: TestStocks.negative, options: options,
                                           width: 8, height: 8)
        options.whiteBalance = WhiteBalance(kelvin: 3200, tint: 35)
        let edited = FilmEngineInvocation(stock: TestStocks.negative, options: options,
                                          width: 8, height: 8)
        let offset = FilmEngineInvocation.whiteBalanceOffset
        XCTAssertEqual(Array(edited.configuration[offset..<(offset + 3)]), [1, 1, 1])
        XCTAssertNotEqual(edited.spectral.exposure.values, neutral.spectral.exposure.values)
        XCTAssertNotEqual(edited.spectralCacheID, neutral.spectralCacheID)
        XCTAssertEqual(edited.spectral.filmOutput.values, neutral.spectral.filmOutput.values)
        XCTAssertEqual(edited.spectral.exposure.values, SpectralRuntime.sceneExposure(
            for: TestStocks.negative, illuminant: options.resolvedSceneSpectrum).values)
    }

    /// A source with no as-shot record is already white balanced, so it is lit at the stock's
    /// own balance and a neutral renders neutral. A stated D65 still lights it at D65.
    func testUnknownSourceIsLitAtTheStockBalance() {
        let options = FotufilmEngine.Options()
        var tungsten = TestStocks.negative
        tungsten.referenceIlluminantKelvin = 3200
        let reference = SpectralRuntime.tables(for: tungsten).exposure.sample(SIMD3(repeating: 0.18))
        for channel in 0..<3 { XCTAssertEqual(reference[channel], 0.18, accuracy: 1e-4) }
        let invocation = FilmEngineInvocation(stock: tungsten, options: options, width: 8, height: 8)
        XCTAssertEqual(invocation.spectral.exposure.values, SpectralRuntime.sceneExposure(
            for: tungsten, cct: 3200).values)
        let gray = SpectralRuntime.spectralExposure(
            SIMD3(repeating: 0.18), stock: tungsten,
            illuminant: options.resolvedSceneSpectrum(
                referenceKelvin: tungsten.referenceIlluminantKelvin))
        XCTAssertEqual(gray.x, gray.y, accuracy: 2e-3)
        XCTAssertEqual(gray.z, gray.y, accuracy: 2e-3)
    }

    /// Stating the scene light keeps the physics: tungsten film under a stated D65 reads cool.
    func testStatedD65OnATungstenStockStillReadsCool() {
        var options = FotufilmEngine.Options()
        options.sceneIlluminantKelvin = 6504
        var tungsten = TestStocks.negative
        tungsten.referenceIlluminantKelvin = 3200
        let gray = SpectralRuntime.spectralExposure(
            SIMD3(repeating: 0.18), stock: tungsten,
            illuminant: options.resolvedSceneSpectrum(
                referenceKelvin: tungsten.referenceIlluminantKelvin))
        XCTAssertGreaterThan(gray.z, gray.x)
    }

    func testTemperatureEditIsRelativeToCaptureAndNeverBakedIntoDecode() {
        var options = FotufilmEngine.Options()
        options.sceneIlluminantKelvin = 5000
        XCTAssertEqual(options.resolvedSceneIlluminant.kelvin, 5000, accuracy: 0.01)
        options.whiteBalance.mired += 50
        XCTAssertEqual(options.resolvedSceneIlluminant.kelvin, 4000, accuracy: 0.01)
        XCTAssertEqual(options.sceneIlluminantKelvin, 5000)
    }

    func testSparseLampExposureIsFiniteAndIndependentOfTabularScale() {
        var light = [Float](repeating: 0, count: SpectralGrid.count)
        light[14] = 1; light[46] = 1 // 450 and 610 nm; no 560 nm energy.
        let gray = SIMD3<Float>(repeating: 0.18)
        let first = SpectralRuntime.spectralExposure(gray, stock: TestStocks.negative,
                                                    illuminant: light)
        let scaled = SpectralRuntime.spectralExposure(gray, stock: TestStocks.negative,
                                                     illuminant: light.map { $0 * 100 })
        for channel in 0..<3 {
            XCTAssertTrue(first[channel].isFinite)
            XCTAssertLessThan(first[channel], 10)
            XCTAssertEqual(first[channel], scaled[channel], accuracy: 1e-6)
        }
    }

    #if canImport(Metal)
    func testFilteredLampChangesReachMetalAndAgreeWithCPU() throws {
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let stock = TestStocks.negative
        var options = FotufilmEngine.Options()
        options.stage = .negative
        options.grainScale = 0; options.halationScale = 0; options.couplerScale = 0
        options.lensFilters = LensFilterStack([LensFilter(
            id: "test-clear", name: "Test clear",
            internalTransmittance: [Float](repeating: 1, count: SpectralGrid.count),
            substrate: .crownGlass, coating: .uncoated)])
        let width = 8, height = 8
        let rgba = [[Float]](repeating: [0.18, 0.18, 0.18, 1], count: width * height).flatMap { $0 }
        var image = ImageBuffer(width: width, height: height)
        image.planes = (0..<3).map { _ in [Float](repeating: 0.18, count: width * height) }
        var identifiers: [UInt64] = [], renders: [[Float]] = []
        for kelvin: Float in [6504, 2856, 6504] {
            options.sceneIlluminantSpectrum = Illuminant.atLocus(kelvin: kelvin)
            let invocation = FilmEngineInvocation(stock: stock, options: options,
                                                  width: width, height: height)
            identifiers.append(invocation.spectralCacheID)
            let cpu = FotufilmEngine(stock: stock, options: options).developNegative(linearRGB: image)
            let metal = try XCTUnwrap(gpu.processLinearFloat(
                rgba, width: width, height: height, stock: stock, options: options))
            renders.append(metal)
            for pixel in 0..<(width * height) {
                for channel in 0..<3 {
                    XCTAssertEqual(metal[4 * pixel + channel], cpu.planes[channel][pixel], accuracy: 2e-5)
                }
            }
        }
        XCTAssertNotEqual(identifiers[0], identifiers[1])
        XCTAssertEqual(identifiers[0], identifiers[2])
        XCTAssertNotEqual(renders[0], renders[1])
        XCTAssertEqual(renders[0], renders[2])
    }
    #endif
}
