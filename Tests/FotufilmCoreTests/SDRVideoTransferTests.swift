import FotufilmImaging
import XCTest

final class SDRVideoTransferTests: XCTestCase {
    func testBlackAndWhiteLandAtNeutralVideoEndpoints() {
        let black = SDRVideoTransfer.encode(.zero)
        let white = SDRVideoTransfer.encode(SIMD3(repeating: 1))

        XCTAssertEqual(black.y, 0, accuracy: 1e-7)
        XCTAssertEqual(black.u, 0, accuracy: 1e-7)
        XCTAssertEqual(black.v, 0, accuracy: 1e-7)
        XCTAssertEqual(white.y, 1, accuracy: 1e-6)
        XCTAssertEqual(white.u, 0, accuracy: 1e-6)
        XCTAssertEqual(white.v, 0, accuracy: 1e-6)
    }

    func testMatrixUsesBT709Coefficients() {
        let red = SDRVideoTransfer.encode(SIMD3(1, 0, 0))
        let green = SDRVideoTransfer.encode(SIMD3(0, 1, 0))
        let blue = SDRVideoTransfer.encode(SIMD3(0, 0, 1))

        XCTAssertEqual(red.y, 0.2126, accuracy: 1e-6)
        XCTAssertEqual(green.y, 0.7152, accuracy: 1e-6)
        XCTAssertEqual(blue.y, 0.0722, accuracy: 1e-6)
    }

    func test420ChromaIsTheAverageOfTheEncodedBlock() {
        let pixels = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
                      SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 1, 1)]
        let block = SDRVideoTransfer.encode420(
            topLeft: pixels[0], topRight: pixels[1],
            bottomLeft: pixels[2], bottomRight: pixels[3])
        let samples = pixels.map(SDRVideoTransfer.encode)

        XCTAssertEqual(block.u, samples.map { $0.u }.reduce(0, +) / 4,
                       accuracy: 1e-6)
        XCTAssertEqual(block.v, samples.map { $0.v }.reduce(0, +) / 4,
                       accuracy: 1e-6)
    }
}
