import XCTest
@testable import FotufilmCore

final class NegativeScanModelTests: XCTestCase {
    private func stock(_ id: String) throws -> FilmStock {
        try XCTUnwrap(FilmStock.presets[id])
    }

    private let camera = NegativeScanSetup(light: .white, camera: .profile("sony-ilce-7cm2"))

    func testEveryResponseSumsToOneAndTheBareLampReadsOne() throws {
        for light in NegativeScanCrosstalk.Light.allCases {
            for camera in [NegativeScanSetup.Camera.generic, .scanner, .profile("sony-ilce-7cm2")] {
                let response = NegativeScanSetup(light: light, camera: camera).response()
                XCTAssertEqual(response.count, 3)
                for row in response {
                    XCTAssertEqual(row.count, SpectralGrid.count)
                    XCTAssertEqual(row.reduce(0, +), 1, accuracy: 1e-4, "\(light) \(camera)")
                }
            }
        }
    }

    func testClearFilmReadsNoDensityAndDenserFilmReadsMore() throws {
        let stock = try stock("gold200")
        let model = NegativeScanModel(stock: stock, setup: camera)
        let clear = try XCTUnwrap(model.scannerDensity(density: model.base))
        for channel in 0..<3 { XCTAssertEqual(clear[channel], 0, accuracy: 1e-6) }
        // An orange base passes less blue than red.
        XCTAssertGreaterThan(model.clear.x, model.clear.y)
        XCTAssertGreaterThan(model.clear.y, model.clear.z)
        var last = clear
        for exposure in stride(from: Float(-1.5), through: 1.2, by: 0.3) {
            let read = try XCTUnwrap(model.scannerDensity(
                density: NegativeScanModel.density(stock: stock, logExposure: exposure)))
            for channel in 0..<3 { XCTAssertGreaterThan(read[channel], last[channel]) }
            last = read
        }
    }

    func testTheLampsAreTheColoursTheyAreNamed() {
        func distance(_ spectrum: [Float], kelvin: Float) -> Float {
            let d = Illuminant.chromaticity(spectrum)
                - Illuminant.chromaticity(Illuminant.atLocus(kelvin: kelvin))
            return (d * d).sum().squareRoot()
        }
        typealias Light = NegativeScanCrosstalk.Light
        XCTAssertLessThan(distance(Light.white.spectrum, kelvin: 5500), 0.01)
        XCTAssertLessThan(distance(Light.screen.spectrum, kelvin: 6504), 0.004)
        XCTAssertLessThan(distance(Light.rgb.spectrum, kelvin: 6504), 0.004)
        XCTAssertLessThan(distance(Light.halogen.spectrum, kelvin: 3200), 1e-5)
        for light in Light.allCases {
            XCTAssertTrue(light.spectrum.allSatisfy { $0.isFinite && $0 >= 0 }, "\(light)")
        }
    }

    func testAScannerReadsUnderItsOwnLampAndLEDsLightTheirOwnChannels() {
        let scanner = NegativeScanSetup(light: .white, camera: .scanner).response()
        XCTAssertEqual(scanner, NegativeScanSetup(light: .halogen, camera: .scanner).response())
        let leds = NegativeScanSetup(light: .rgb, camera: .generic).response()
        XCTAssertEqual(leds, NegativeScanSetup(light: .rgb, camera: .profile("sony-ilce-7cm2"))
            .response())
        // Each LED's channel peaks at its LED.
        let peaks = leds.map { row in SpectralGrid.wavelengths[row.indices.max { row[$0] < row[$1] }!] }
        XCTAssertEqual(peaks, [625, 520, 455])
    }

    func testACamerasNameIsWhatAnEditKeeps() {
        typealias Camera = NegativeScanSetup.Camera
        for camera in [Camera.generic, .scanner, .profile("nikon-d850")] {
            XCTAssertEqual(Camera(name: camera.name), camera)
        }
    }

    /// A camera whose profile the store does not hold reads as the generic camera, and a
    /// decoding white balance moves a measured camera's channels.
    func testAnUnknownProfileIsGenericAndTheDecodingWhiteMovesAMeasuredCamera() {
        XCTAssertEqual(NegativeScanSetup(camera: .profile("no-such-camera")).response(),
                       NegativeScanSetup(camera: .generic).response())
        XCTAssertNotEqual(camera.response(), NegativeScanSetup(camera: .generic).response())
        var warm = camera
        warm.kelvin = 3200
        XCTAssertNotEqual(warm.response(), camera.response())
        var same = camera
        same.kelvin = 5500
        XCTAssertEqual(same.response(), camera.response())
    }

    /// The white a decoder balanced on sets how much of each sensor channel its matrix mixes:
    /// one off the lamps' colours moves a measured camera's channels, one on them does not.
    func testTheDecodingWhitesChromaticityMovesAMeasuredCamera() {
        var decoded = camera
        decoded.kelvin = 5000
        let onLocus = decoded.response()
        decoded.white = Illuminant.chromaticity(Illuminant.atLocus(kelvin: 5000))
        for (row, expected) in zip(decoded.response(), onLocus) {
            for (value, other) in zip(row, expected) {
                XCTAssertEqual(value, other, accuracy: 1e-5)
            }
        }
        // A greener white takes less of the sensor's green: what the scan's blue sees changes.
        decoded.white = WhiteBalance.chromaticity(kelvin: 5000, tint: 60)
        XCTAssertNotEqual(decoded.response()[2], onLocus[2])
        XCTAssertNotEqual(decoded.response(),
                          { var other = decoded
                            other.white = WhiteBalance.chromaticity(kelvin: 5000, tint: -60)
                            return other.response() }())
        // A chromaticity that is none is left out, and only a measured camera has a white.
        for white in [SIMD2<Float>(.nan, 0.3), SIMD2(0, 0.3), SIMD2(-0.2, 0.3), SIMD2(0.3, .infinity)] {
            decoded.white = white
            XCTAssertEqual(decoded.response(), onLocus)
        }
        // One no light has is brought back to the nearest a spectrum can make.
        decoded.white = SIMD2(0.7, 0.4)
        XCTAssertTrue(decoded.response().allSatisfy { $0.allSatisfy(\.isFinite) })
        for setup in [NegativeScanSetup(camera: .generic), NegativeScanSetup(camera: .scanner),
                      NegativeScanSetup(light: .rgb, camera: .profile("sony-ilce-7cm2"))] {
            var tinted = setup
            tinted.white = WhiteBalance.chromaticity(kelvin: 5000, tint: 60)
            XCTAssertEqual(tinted.response(), setup.response())
        }
    }

    /// A decoder's own matrix sets what the scan's channels see of a measured camera, and a
    /// reading fitted for another matrix misses the film the scan was made of.
    func testADecodersMatrixSetsAMeasuredCamerasChannels() throws {
        let profile = try XCTUnwrap(CameraSpectralProfileStore.profile(id: "sony-ilce-7cm2"))
        let own = CameraProfileCorrection.matrices(for: profile).matrix(cct: 5500)
        var decoded = camera
        decoded.matrix = own
        XCTAssertEqual(decoded.response(), camera.response())
        // A decoder that takes less of the sensor's green out of its blue.
        decoded.matrix = [SIMD3(1.2, -0.1, -0.1), SIMD3(-0.05, 1.5, -0.45), SIMD3(0, -0.25, 1.25)]
        XCTAssertNotEqual(decoded.response()[2], camera.response()[2])

        let stock = try stock("gold200")
        let model = NegativeScanModel(stock: stock, setup: decoded)
        let patches = NegativeScanModel.patches(stock: stock)
        func error(_ weights: [SIMD3<Float>]) throws -> NegativeScanModel.ReadingError {
            model.error(of: try ApproximateNegativeScan(stock: stock, border: model.clear,
                                                        gains: .one, weights: weights),
                        patches: patches)
        }
        let fitted = try error(model.weights(separation: 1))
        let assumed = try error(NegativeScanModel(stock: stock, setup: camera).weights(separation: 1))
        XCTAssertLessThan(fitted.greys, 0.02)
        XCTAssertGreaterThan(assumed.greys, 2 * fitted.greys)
        XCTAssertGreaterThan(assumed.colours, 1.5 * fitted.colours)

        // A matrix no decoder could have used is left out, and only a measured camera has one.
        for matrix in [[SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0)],
                       [SIMD3(.nan, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]] {
            var invalid = camera
            invalid.matrix = matrix
            XCTAssertEqual(invalid.response(), camera.response())
        }
        for setup in [NegativeScanSetup(camera: .generic), NegativeScanSetup(camera: .scanner),
                      NegativeScanSetup(light: .rgb, camera: .profile("sony-ilce-7cm2"))] {
            var mixed = setup
            mixed.matrix = decoded.matrix
            XCTAssertEqual(mixed.response(), setup.response())
        }
    }

    /// A reading's error is how far the densities it reads lie from the film the scan was
    /// made of.
    func testAReadingsErrorIsItsDistanceFromTheFilm() throws {
        let stock = try stock("gold200")
        let model = NegativeScanModel(stock: stock, setup: camera)
        let grey = NegativeScanModel.Patch(
            density: NegativeScanModel.density(stock: stock, logExposure: 0), weight: 1,
            logExposure: 0, isNeutral: true)
        let reading = try ApproximateNegativeScan(stock: stock, border: model.clear)
        let read = try XCTUnwrap(reading.density(of: model.sample(density: grey.density)))
        let error = model.error(of: reading, patches: [grey])
        let misses = (0..<3).map { read[$0] - grey.density[$0] }
        XCTAssertEqual(error.greys, (misses.map { $0 * $0 }.reduce(0, +) / 3).squareRoot(),
                       accuracy: 1e-6)
        XCTAssertEqual(error.worst, misses.map(abs).max()!, accuracy: 1e-6)
        XCTAssertEqual(error.colours, 0)
        XCTAssertEqual(error.unread, 0)
        // A sample the reading cannot place is counted, not scored.
        var dark = grey
        dark.density = [9, 9, 9]
        XCTAssertEqual(model.error(of: reading, patches: [dark]).unread, 1)
    }

    /// Every negative film's scan model carries its record densities to the exact spectral
    /// transmission the print stage exposes through, whether its base spectrum is stored
    /// separately (`gold200`) or formed by its base record densities (`cinestill400d`,
    /// `lomocolor100`, `phoenix200`).
    func testEveryNegativeFilmsSpectrumMatchesThePrintStage() throws {
        let negatives = FilmStock.presetIDs.compactMap { id -> (String, FilmStock)? in
            guard let stock = FilmStock.presets[id],
                  !stock.isReversal, !stock.isReflectionPrint else { return nil }
            return (id, stock)
        }
        XCTAssertTrue(negatives.contains { $0.0 == "cinestill400d" })
        XCTAssertTrue(negatives.contains { $0.0 == "lomocolor100" })
        XCTAssertTrue(negatives.contains { $0.0 == "phoenix200" })

        let lamp = NegativeScanCrosstalk.Light.white.spectrum
        let response = NegativeScanSetup(light: .white, camera: .scanner).response()
        for (id, stock) in negatives {
            let model = NegativeScanModel(stock: stock, response: response)
            for logExposure in [Float(-1.2), 0, 0.8] {
                let density = logExposure == -1.2 ? model.base
                    : NegativeScanModel.density(stock: stock, logExposure: logExposure)
                let expected = SpectralRuntime.paperExposure(
                    density: density, stock: stock,
                    lamp: [Float](repeating: 1, count: SpectralGrid.count),
                    paperSensitivity: response)
                let actual = model.sample(density: density)
                for channel in 0..<3 {
                    XCTAssertEqual(actual[channel], expected[channel], accuracy: 1e-6,
                                   "\(id) @ \(logExposure) channel \(channel)")
                }
            }
            if !stock.isMonochrome, stock.curves[2].dMin > stock.curves[0].dMin + 0.2 {
                // Masked colour negatives pass less blue than red through their clear base.
                let masked = NegativeScanModel(
                    stock: stock,
                    setup: NegativeScanSetup(light: .white, camera: .profile("sony-ilce-7cm2")))
                XCTAssertGreaterThan(masked.clear.x, masked.clear.z, id)
            }
            _ = lamp
        }
    }

    /// The generic camera's median CMOS prior sits closer to measured cameras on a real colour
    /// negative than a colorimetric CIE Rec. 2020 observer would.
    func testGenericCameraCMOSPriorApproximatesMeasuredCameras() throws {
        let stock = try stock("portra400")
        let patches = NegativeScanModel.patches(stock: stock)
        let genericWeights = NegativeScanModel(
            stock: stock, setup: NegativeScanSetup(light: .white, camera: .generic))
            .weights(separation: 1)

        let cmfResponse: [[Float]] = {
            let lamp = NegativeScanCrosstalk.Light.white.spectrum
            let raw = (0..<3).map { channel in
                (0..<SpectralGrid.count).map { i in
                    SpectralGrid.linearRec2020(fromXYZ: SIMD3(
                        SpectralGrid.xBar[i], SpectralGrid.yBar[i], SpectralGrid.zBar[i]))[channel]
                        * lamp[i]
                }
            }
            return raw.map { row in
                let s = row.reduce(0, +)
                return row.map { $0 / s }
            }
        }()
        let cmfWeights = NegativeScanModel(stock: stock, response: cmfResponse).weights(separation: 1)

        var genericMiss: Float = 0, cmfMiss: Float = 0
        for cameraID in ["sony-ilce-7cm2", "nikon-d850", "canon-eos-5d-mark-iv", "fujifilm-x-t3"] {
            let realModel = NegativeScanModel(
                stock: stock, setup: NegativeScanSetup(light: .white, camera: .profile(cameraID)))
            let gErr = realModel.error(
                of: try ApproximateNegativeScan(stock: stock, border: realModel.clear,
                                                weights: genericWeights), patches: patches)
            let cErr = realModel.error(
                of: try ApproximateNegativeScan(stock: stock, border: realModel.clear,
                                                weights: cmfWeights), patches: patches)
            genericMiss += gErr.colours
            cmfMiss += cErr.colours
        }
        XCTAssertLessThan(genericMiss, cmfMiss)
    }
}
