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

    func testACameraIsResolvedFromTheEditThenTheFileThenGeneric() {
        typealias Camera = NegativeScanSetup.Camera
        let file = CameraIdentity(make: "SONY", model: "ILCE-7CM2")
        XCTAssertEqual(Camera.resolved(nil, file: file), .profile("sony-ilce-7cm2"))
        XCTAssertEqual(Camera.resolved(.scanner, file: file), .scanner)
        XCTAssertEqual(Camera.resolved(nil, file: CameraIdentity(make: "Unmeasured", model: "Camera")),
                       .generic)
        XCTAssertEqual(Camera.resolved(nil, file: nil), .generic)
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
}
