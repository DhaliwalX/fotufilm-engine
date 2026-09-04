import XCTest
@testable import FotufilmCore

final class SpectralSceneLightTests: XCTestCase {
    // MARK: - Default scene illuminant

    func testDefaultIlluminantCallMatchesExplicitD65() {
        let colors: [SIMD3<Float>] = [
            SIMD3(0.25, 0.25, 0.25), SIMD3(0.25, 0.04, 0.03),
            SIMD3(0.06, 0.25, 0.09), SIMD3(0.05, 0.08, 0.25),
            SIMD3(0.25, 0.18, 0.02), SIMD3(0.11, 0.02, 0.25),
        ]
        for stock in TestStocks.all {
            for rgb in colors {
                let implicit = SpectralRuntime.spectralExposure(rgb, stock: stock)
                let explicit = SpectralRuntime.spectralExposure(
                    rgb, stock: stock, illuminant: SpectralGrid.d65)
                XCTAssertEqual(implicit, explicit,
                               "default illuminant must be the D65 path, bitwise")
            }
        }
    }

    func testCoolAnchorIsTheExplicitD65TableBitwise() {
        let stock = TestStocks.negative
        let cool = SpectralRuntime.sceneLightAnchors(for: stock).cool
        let d65 = SpectralRuntime.sceneExposure(
            for: stock, illuminant: SpectralGrid.d65)
        XCTAssertEqual(cool.dimension, d65.dimension)
        XCTAssertEqual(cool.values, d65.values,
                       "the cool anchor must be the exact explicit D65 table")
    }

    // MARK: - Physics guard: film colour balance survives

    func testFlatReflectanceRetainsRecordImbalanceUnderOtherIlluminants() {
        let greys: [Float] = [0.05, 0.18, 0.5]
        let lights: [(kelvin: Float, spectrum: [Float])] = [
            (2856, Illuminant.a),
            (3200, Illuminant.planckian(kelvin: 3200)),
            (4200, Illuminant.daylight(kelvin: 4200)),
            (5500, Illuminant.daylight(kelvin: 5500)),
        ]
        for stock in TestStocks.all {
            if stock.isMonochrome { continue }
            for grey in greys {
                let rgb = SIMD3<Float>(repeating: grey)
                for light in lights {
                    let exposure = SpectralRuntime.spectralExposure(
                        rgb, stock: stock, illuminant: light.spectrum)
                    let relative = exposure / grey
                    if light.kelvin == stock.referenceIlluminantKelvin {
                        XCTAssertLessThan(relative.max() - relative.min(), 1e-5,
                                          "native reference must expose a neutral evenly")
                    } else {
                        XCTAssertGreaterThan(relative.max() - relative.min(), 0.01,
                                             "\(stock.name) erased its colour balance")
                    }
                }
            }
        }
    }

    func testSceneTableMovesGreysAlongAStableRecordBalance() {
        let stock = TestStocks.negative
        let base = SpectralRuntime.sceneExposure(
            for: stock, cct: stock.referenceIlluminantKelvin)
        let warm = SpectralRuntime.sceneExposure(for: stock, cct: 3200)
        var referenceRatio: SIMD3<Float>?
        for grey in [Float(0.1), 0.18, 0.5, 0.9] {
            let p = SIMD3<Float>(repeating: grey)
            let a = base.sample(p), b = warm.sample(p)
            XCTAssertEqual(a.x, grey, accuracy: 1e-5)
            let ratio = b / grey
            if let referenceRatio {
                for channel in 0..<3 {
                    XCTAssertEqual(ratio[channel], referenceRatio[channel], accuracy: 2e-4)
                }
            } else {
                referenceRatio = ratio
            }
            for channel in 0..<3 {
                XCTAssertGreaterThanOrEqual(b[channel], 0)
            }
        }
        XCTAssertGreaterThan(referenceRatio!.x - referenceRatio!.z, 0.5,
                             "tungsten did not separate the daylight-balanced records")
    }

    // MARK: - The measured chromatic effect

    func testRedPatchExposureUnderAversusD65IsTheMeasuredMetamerism() {
        let stock = TestStocks.negative
        let red = SIMD3<Float>(0.25, 0.04, 0.03)
        let d65 = SpectralRuntime.spectralExposure(red, stock: stock)
        let a = SpectralRuntime.spectralExposure(red, stock: stock,
                                                 illuminant: Illuminant.a)
        let expectedD65 = SIMD3<Float>(0.39490974, 0.068814635, 0.038927667)
        let expectedA = SIMD3<Float>(0.78205204, 0.093152195, 0.01069099)
        for channel in 0..<3 {
            XCTAssertEqual(d65[channel], expectedD65[channel],
                           accuracy: abs(expectedD65[channel]) * 1e-3)
            XCTAssertEqual(a[channel], expectedA[channel],
                           accuracy: abs(expectedA[channel]) * 1e-3)
        }
        XCTAssertGreaterThan(a.x / d65.x, 1.5)
        XCTAssertLessThan(a.z / d65.z, 0.5)
    }

    func testTungstenStockUsesItsNativeReferenceDenominator() {
        var tungsten = TestStocks.negative
        tungsten.referenceIlluminantKelvin = 3200
        let grey = SIMD3<Float>(repeating: 0.18)
        let native = SpectralRuntime.spectralExposure(
            grey, stock: tungsten,
            illuminant: Illuminant.planckian(kelvin: 3200))
        for channel in 0..<3 {
            XCTAssertEqual(native[channel], grey[channel], accuracy: 2e-5)
        }

        let daylight = SpectralRuntime.spectralExposure(
            grey, stock: tungsten, illuminant: SpectralGrid.d65)
        XCTAssertGreaterThan(daylight.z, daylight.x,
                             "daylight on tungsten film must retain its blue record bias")
    }

    func testReferenceBalanceChangesExposureAndCacheIdentity() {
        let daylight = TestStocks.negative
        var tungsten = daylight
        tungsten.referenceIlluminantKelvin = 3200
        XCTAssertNotEqual(SpectralRuntime.cacheIdentifier(for: daylight),
                          SpectralRuntime.cacheIdentifier(for: tungsten))
        XCTAssertNotEqual(SpectralRuntime.tables(for: daylight).exposure.values,
                          SpectralRuntime.tables(for: tungsten).exposure.values)
    }

    // MARK: - Exact locus integration

    func testBlendEndpointsReturnTheAnchorsExactly() {
        let stock = TestStocks.negative
        let anchors = SpectralRuntime.sceneLightAnchors(for: stock)
        XCTAssertEqual(SpectralRuntime.sceneExposure(
            for: stock, cct: DualIlluminantMatrices.tungstenKelvin).values,
                       anchors.warm.values)
        for cct in [Float(2000), 3200, 5600, 6504, 10000] {
            XCTAssertEqual(
                SpectralRuntime.sceneExposure(for: stock, cct: cct).values,
                SpectralRuntime.sceneExposure(
                    for: stock, illuminant: Illuminant.atLocus(kelvin: cct)).values)
        }
    }

    func testIntermediateTemperatureIsNotAnAnchorTableBlend() {
        let stock = TestStocks.negative
        let cct: Float = 3200
        let anchors = SpectralRuntime.sceneLightAnchors(for: stock)
        let weight = SpectralRuntime.sceneLightWarmWeight(cct: cct)
        let blended = SpectralRuntime.sceneExposure(for: stock, cct: cct)
        let worst = stride(from: 0, to: blended.values.count, by: 1237).map { i in
            abs(blended.values[i] - (weight * anchors.warm.values[i]
                                     + (1 - weight) * anchors.cool.values[i]))
        }.max() ?? 0
        XCTAssertGreaterThan(worst, 1e-5)
    }

    // MARK: - The gate

    func testCCTValidationDoesNotQuantizeOrSuppressDaylight() {
        XCTAssertNil(SpectralRuntime.sceneLightKelvin(nil))
        XCTAssertNil(SpectralRuntime.sceneLightKelvin(0))
        XCTAssertNil(SpectralRuntime.sceneLightKelvin(-3200))
        XCTAssertEqual(SpectralRuntime.sceneLightKelvin(5500), 5500)
        XCTAssertEqual(SpectralRuntime.sceneLightKelvin(6504), 6504)
        XCTAssertEqual(SpectralRuntime.sceneLightKelvin(3165), 3165)
        XCTAssertEqual(SpectralRuntime.sceneLightKelvin(3249), 3249)
    }

    func testCameraProfileKillSwitchDoesNotDisableFilmExposure() {
        setenv("FOTUFILM_PROFILE_OFF", "1", 1)
        defer { unsetenv("FOTUFILM_PROFILE_OFF") }
        XCTAssertEqual(SpectralRuntime.sceneLightKelvin(3200), 3200)
    }

    func testInvocationUsesEveryStatedIlluminant() {
        let stock = TestStocks.negative
        var options = FotufilmEngine.Options()
        let base = FilmEngineInvocation(stock: stock, options: options,
                                        width: 64, height: 64)

        options.sceneIlluminantKelvin = 5600
        let daylight = FilmEngineInvocation(stock: stock, options: options,
                                            width: 64, height: 64)
        XCTAssertNotEqual(daylight.spectralCacheID, base.spectralCacheID)
        XCTAssertNotEqual(daylight.spectral.exposure.values, base.spectral.exposure.values)

        options.sceneIlluminantKelvin = 3200
        setenv("FOTUFILM_PROFILE_OFF", "1", 1)
        let killed = FilmEngineInvocation(stock: stock, options: options,
                                          width: 64, height: 64)
        unsetenv("FOTUFILM_PROFILE_OFF")
        XCTAssertNotEqual(killed.spectralCacheID, base.spectralCacheID)
        XCTAssertNotEqual(killed.spectral.exposure.values, base.spectral.exposure.values)

        let warm = FilmEngineInvocation(stock: stock, options: options,
                                        width: 64, height: 64)
        XCTAssertNotEqual(warm.spectralCacheID, base.spectralCacheID,
                          "a warm scene must move the cache identity so the GPU re-uploads")
        XCTAssertNotEqual(warm.spectral.exposure.values, base.spectral.exposure.values)
        XCTAssertEqual(warm.spectral.filmOutput.values, base.spectral.filmOutput.values,
                       "development and printing happen in the dark — only exposure moves")
    }

    func testExplicitSPDOverridesCCT() {
        let stock = TestStocks.negative
        var options = FotufilmEngine.Options()
        options.sceneIlluminantKelvin = 3200
        options.sceneIlluminantSpectrum = Illuminant.daylight(kelvin: 8000)
        let invocation = FilmEngineInvocation(stock: stock, options: options,
                                              width: 64, height: 64)
        XCTAssertEqual(invocation.spectral.exposure.values,
                       SpectralRuntime.sceneExposure(
                        for: stock, illuminant: options.sceneIlluminantSpectrum).values)
    }
}
