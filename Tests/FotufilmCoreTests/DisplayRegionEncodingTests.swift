import XCTest
import FotufilmCore

final class DisplayRegionEncodingTests: XCTestCase {
    func testCompactDeliveryMatchesWholeFrameIncludingDitherAndPadding() {
        let width = 113, height = 79
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = Float(x) / Float(width) * 2 - 0.1
            pixels[i + 1] = Float(y) / Float(height)
            pixels[i + 2] = Float((x * 13 + y * 29) % 251) / 250
            pixels[i + 3] = Float((x + y) % 17) / 16
        } }
        for linear in [false, true] { for seed: UInt32 in [0, 0x46494C4D, .max] {
            var whole = [UInt8](repeating: 31, count: width * height * 4)
            pixels.withUnsafeBufferPointer { input in whole.withUnsafeMutableBytes { output in
                if linear {
                    DisplayEncoding.quantize8(linear: input, rows: 0..<height, width: width,
                        knee: 0.7, into: output.baseAddress!, rowBytes: width * 4, seed: seed)
                } else {
                    DisplayEncoding.quantize8(encoded: input, rows: 0..<height, width: width,
                        into: output.baseAddress!, rowBytes: width * 4, seed: seed)
                }
            } }
            for (x, y, w, h) in [(0, 0, 13, 7), (27, 19, 41, 31), (94, 62, 19, 17), (55, 37, 1, 1)] {
                var tile = [Float]()
                for row in y..<(y + h) {
                    tile.append(contentsOf: pixels[((row * width + x) * 4)..<((row * width + x + w) * 4)])
                }
                let stride = w * 4 + 11
                var actual = [UInt8](repeating: 31, count: stride * h + 2)
                tile.withUnsafeBufferPointer { input in actual.withUnsafeMutableBytes { output in
                    if linear {
                        DisplayEncoding.quantizeRegion8(linear: input, width: w, height: h,
                            originX: x, originY: y, frameWidth: width, knee: 0.7,
                            into: output.baseAddress! + 1, rowBytes: stride, seed: seed)
                    } else {
                        DisplayEncoding.quantizeRegion8(encoded: input, width: w, height: h,
                            originX: x, originY: y, frameWidth: width,
                            into: output.baseAddress! + 1, rowBytes: stride, seed: seed)
                    }
                } }
                XCTAssertEqual(actual.first, 31); XCTAssertEqual(actual.last, 31)
                for row in 0..<h {
                    let start = ((y + row) * width + x) * 4
                    XCTAssertEqual(Array(actual[(1 + row * stride)..<(1 + row * stride + w * 4)]),
                        Array(whole[start..<(start + w * 4)]))
                    XCTAssertTrue(actual[(1 + row * stride + w * 4)..<(1 + (row + 1) * stride)].allSatisfy { $0 == 31 })
                }
            }
        } }
    }
}
