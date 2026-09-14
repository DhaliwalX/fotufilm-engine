import XCTest
@testable import FotufilmCore

final class ImageBufferValidationTests: XCTestCase {
    func testCheckedEntryPointsRejectMalformedPlanes() {
        let engine = FotufilmEngine(stock: TestStocks.negative)
        var layeredOptions = FotufilmEngine.Options()
        layeredOptions.layeredTransport = TransportFixtures.mirror
        let layered = FotufilmEngine(stock: TestStocks.negative, options: layeredOptions)
        let calls: [(ImageBuffer) throws -> ImageBuffer] = [
            engine.processChecked, engine.developNegativeChecked, engine.printPositiveChecked,
            layered.processChecked, layered.developNegativeChecked, layered.printPositiveChecked,
        ]
        let valid = [Float](repeating: 0.18, count: 64)
        let invalid: [[[Float]]] = [
            [], [valid], [valid, valid, valid, valid],
            [[], valid, valid], [valid, Array(valid.dropLast()), valid],
            [valid, valid, valid + [0]],
            [Array(repeating: .nan, count: 64), valid, valid],
            [valid, valid, Array(repeating: .infinity, count: 64)],
        ]
        for planes in invalid {
            var image = ImageBuffer(width: 8, height: 8)
            image.planes = planes
            for call in calls {
                XCTAssertThrowsError(try call(image)) { error in
                    guard case TransportError.invalid = error else {
                        return XCTFail("expected invalid image, got \(error)")
                    }
                }
            }
        }
    }

    func testValidationHandlesDimensionsBeforeNativeIntegerConversion() throws {
        let empty = ImageBuffer(width: 0, height: 0)
        XCTAssertNoThrow(try empty.validate())
        for width in [-1, Int(Int32.max) + 1, Int.max] {
            let image = ImageBuffer(width: width, height: 0, planes: [[], [], []])
            XCTAssertThrowsError(try image.validate())
            XCTAssertThrowsError(try FotufilmEngine(stock: TestStocks.negative).processChecked(linearRGB: image))
        }
        var repaired = ImageBuffer(width: 2, height: 3, fill: -0.1)
        repaired.planes[1].removeLast()
        XCTAssertThrowsError(try repaired.validate())
        repaired.planes[1].append(12)
        XCTAssertNoThrow(try repaired.validate(), "finite signed HDR values remain valid")
    }
}
