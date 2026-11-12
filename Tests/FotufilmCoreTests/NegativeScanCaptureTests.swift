import XCTest
@testable import FotufilmCore

final class NegativeScanCaptureTests: XCTestCase {
    private let sony = CameraIdentity(make: "SONY", model: "ILCE-7CM2")
    private let matrix: [Float] = [1.18, -0.09, -0.09, -0.04, 1.52, -0.48, 0.01, -0.25, 1.24]
    private var rows: [SIMD3<Float>] {
        (0..<3).map { SIMD3(matrix[3 * $0], matrix[3 * $0 + 1], matrix[3 * $0 + 2]) }
    }

    func testAFilesCameraIsMeasuredOnlyWithItsDecodersMatrix() {
        let decoded = NegativeScanCapture(camera: sony, kelvin: 5100, white: [0.343, 0.356],
                                         matrix: matrix)
        XCTAssertEqual(decoded.setup(light: .screen),
                       NegativeScanSetup(light: .screen, camera: .profile("sony-ilce-7cm2"),
                                         kelvin: 5100, white: SIMD2(0.343, 0.356), matrix: rows))
        // Without the matrix the camera's own could be far from the decoder's: generic instead.
        var unknown = decoded
        unknown.matrix = nil
        XCTAssertEqual(unknown.setup(light: .screen), NegativeScanSetup(light: .screen))
        // A camera nobody measured, and a file that names none.
        XCTAssertEqual(NegativeScanCapture(camera: CameraIdentity(make: "Unmeasured", model: "Camera"),
                                          kelvin: 5100, matrix: matrix).setup(light: .white),
                       NegativeScanSetup(light: .white))
        XCTAssertEqual(NegativeScanCapture().setup(light: .halogen),
                       NegativeScanSetup(light: .halogen))
    }

    func testAnEditsCameraIsTakenOverTheFiles() {
        let decoded = NegativeScanCapture(camera: sony, kelvin: 5100, white: [0.343, 0.356],
                                         matrix: matrix)
        // A generic camera or a scanner reads the same however the file was decoded.
        XCTAssertEqual(decoded.setup(light: .white, camera: .generic),
                       NegativeScanSetup(light: .white, camera: .generic))
        XCTAssertEqual(decoded.setup(light: .white, camera: .scanner),
                       NegativeScanSetup(light: .white, camera: .scanner))
        // A measured camera named by the edit keeps what the decoder did, with or without its
        // matrix, and one the store does not hold is the generic camera's reading.
        XCTAssertEqual(decoded.setup(light: .white, camera: .profile("nikon-d850")),
                       NegativeScanSetup(light: .white, camera: .profile("nikon-d850"),
                                         kelvin: 5100, white: SIMD2(0.343, 0.356), matrix: rows))
        XCTAssertEqual(NegativeScanCapture(kelvin: 5100).setup(light: .white,
                                                              camera: .profile("nikon-d850")),
                       NegativeScanSetup(light: .white, camera: .profile("nikon-d850"), kelvin: 5100))
        let missing = decoded.setup(light: .white, camera: .profile("no-such-camera"))
        XCTAssertEqual(missing, NegativeScanSetup(light: .white, camera: .profile("no-such-camera")))
        XCTAssertEqual(missing.response(), NegativeScanSetup(light: .white).response())
    }

    func testWhatADecoderCouldNotHaveSaidIsLeftOut() {
        let expected = NegativeScanSetup(light: .white, camera: .profile("sony-ilce-7cm2"),
                                         kelvin: 5100, matrix: rows)
        for white in [[Float.nan, 0.3], [0.3], [0, 0.3], [0.3, 0.3, 0.3]] {
            XCTAssertEqual(NegativeScanCapture(camera: sony, kelvin: 5100, white: white, matrix: matrix)
                .setup(light: .white), expected)
        }
        for kelvin in [Float.nan, 0, -5100] {
            var plain = expected
            plain.kelvin = nil
            XCTAssertEqual(NegativeScanCapture(camera: sony, kelvin: kelvin, matrix: matrix)
                .setup(light: .white), plain)
        }
        // A matrix no decoder uses is as good as none: the file's camera is not taken as measured.
        for matrix in [[Float](repeating: 0, count: 9), Array(matrix.dropLast()),
                       [0.2, 0.9, -0.1, 0, 1, 0, 0, 0, 1], matrix.map { $0 * .nan }] {
            XCTAssertEqual(NegativeScanCapture(camera: sony, kelvin: 5100, matrix: matrix)
                .setup(light: .white), NegativeScanSetup(light: .white))
        }
    }

    func testASourceNamesTheCameraItIsReadAsTakenWith() {
        let measured = NegativeScanCapture(camera: sony, kelvin: 5100, matrix: matrix).readCamera
        XCTAssertEqual(measured.id, "sony-ilce-7cm2")
        XCTAssertEqual(measured.name, "SONY ILCE-7CM2")
        // A maker's name is said once, whichever of the two the file puts it in.
        let named = NegativeScanCapture(
            camera: CameraIdentity(make: "Sony", model: "Sony ILCE-7CM2 "), matrix: matrix).readCamera
        XCTAssertEqual(named.id, "sony-ilce-7cm2")
        XCTAssertEqual(named.name, "Sony ILCE-7CM2")
        // A measured camera whose decoder's matrix is not known, one nobody measured, and a file
        // that says nothing are read as the generic camera, which has no name of its own.
        for source in [NegativeScanCapture(camera: sony),
                       NegativeScanCapture(camera: CameraIdentity(make: "Unmeasured", model: "Camera"),
                                          matrix: matrix), NegativeScanCapture()] {
            XCTAssertEqual(source.readCamera.id, "generic")
            XCTAssertNil(source.readCamera.name)
        }
    }

    func testASourceCrossesToAFrontendAndBack() throws {
        let decoded = NegativeScanCapture(camera: sony, kelvin: 5100, white: [0.343, 0.356],
                                         matrix: matrix)
        XCTAssertEqual(try JSONDecoder().decode(NegativeScanCapture.self,
                                                from: try JSONEncoder().encode(decoded)), decoded)
        // What a decoder that says nothing sends.
        XCTAssertEqual(try JSONDecoder().decode(NegativeScanCapture.self, from: Data("{}".utf8)),
                       NegativeScanCapture())
    }
}
