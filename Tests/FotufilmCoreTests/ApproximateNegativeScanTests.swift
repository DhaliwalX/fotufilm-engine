import XCTest
@testable import FotufilmCore

final class ApproximateNegativeScanTests: XCTestCase {
    func testRestoresBaseAndExcludesHolderWithoutChangingOtherPixels() throws {
        let stock = TestStocks.negative
        let border = SIMD3<Float>(0.4, 0.6, 0.2)
        let plan = try ApproximateNegativeScan(stock: stock, border: border)
        let image = ImageBuffer(width: 4, height: 1, planes: [
            [0.4, 0.04, 0, .nan], [0.6, 0.06, 0.2, 0.1], [0.2, 0.02, 0.1, 0.1]])
        let result = try plan.convert(image)
        XCTAssertEqual(result.invalid, [false, false, true, true])
        for channel in 0..<3 {
            XCTAssertEqual(result.density.planes[channel][0], stock.curves[channel].dMin, accuracy: 0.000001)
            XCTAssertEqual(result.density.planes[channel][1], stock.curves[channel].dMin + 1, accuracy: 0.000001)
            XCTAssertEqual(result.density.planes[channel][2], stock.curves[channel].dMin, accuracy: 0.000001)
        }
        XCTAssertEqual(image.planes[0][2], 0)
        XCTAssertTrue(image.planes[0][3].isNaN)
    }
    func testReferenceAndDimensionsAreValidated() throws {
        XCTAssertThrowsError(try ApproximateNegativeScan(stock: TestStocks.negative, border: .zero))
        XCTAssertThrowsError(try ApproximateNegativeScan(stock: TestStocks.negative, border: SIMD3(1, .infinity, 1)))
        let plan = try ApproximateNegativeScan(stock: TestStocks.negative, border: SIMD3(repeating: 1))
        var malformed = ImageBuffer(width: 2, height: 1)
        malformed.planes[0] = [1]
        XCTAssertThrowsError(try plan.convert(malformed))
    }

    func testMonochromeUsesGreenForEveryFilmRecord() throws {
        let stock = try XCTUnwrap(FilmStock.presetDefinitions["hp5plus400"]).validated().stock
        let plan = try ApproximateNegativeScan(stock: stock, border: SIMD3(0.4, 0.6, 0.2))
        let scan = ImageBuffer(width: 2, height: 1, planes: [[0.004, 0], [0.06, 0.06], [0.02, 0.02]])
        let result = try plan.convert(scan)
        XCTAssertEqual(result.invalid, [false, true])
        for c in 0..<3 {
            XCTAssertEqual(result.density.planes[c][0], stock.curves[c].dMin + 1, accuracy: 0.000001)
            XCTAssertEqual(result.density.planes[c][1], stock.curves[c].dMin, accuracy: 0.000001)
        }
    }
}
