import XCTest
import FotufilmCore
@testable import FotufilmEditModel
#if canImport(CoreImage)
import CoreImage
#endif

final class WebPerspectiveRequestTests: XCTestCase {
    private func input(width: Int = 120, height: Int = 80, v: Double = 8, h: Double = -5) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["kind": "perspective", "width": width, "height": height,
                                                    "vertical": v, "horizontal": h])
    }
    private func point(_ m: [Double], _ u: Double, _ v: Double) -> SIMD2<Double> {
        let d = m[6] * u + m[7] * v + 1
        return SIMD2((m[0] * u + m[1] * v + m[2]) / d, (m[3] * u + m[4] * v + m[5]) / d)
    }
    func testInverseKeepsTheEntireOutputInsideThePhotograph() throws {
        for size in [(120, 80), (80, 120), (100, 100), (4000, 100), (100, 4000)] {
            for v in [-15.0, 0, 15] { for h in [-15.0, 0, 15] {
                let data = try WebRenderRequest.prepare(input(width: size.0, height: size.1, v: v, h: h))
                let plan = try JSONDecoder().decode(WebPerspectiveRequest.Result.self, from: data)
                for x in 0...10 { for y in 0...10 {
                    let p = point(plan.inverse, Double(x) / 10, Double(y) / 10)
                    XCTAssertGreaterThanOrEqual(p.x, -1e-9); XCTAssertLessThanOrEqual(p.x, 1 + 1e-9)
                    XCTAssertGreaterThanOrEqual(p.y, -1e-9); XCTAssertLessThanOrEqual(p.y, 1 + 1e-9)
                } }
                let unit: [[Double]] = [[0, 0], [1, 0], [1, 1], [0, 1]]
                for (corner, expected) in zip(plan.corners, unit) {
                    let p = point(plan.inverse, corner[0], corner[1])
                    XCTAssertEqual(p.x, expected[0], accuracy: 1e-9)
                    XCTAssertEqual(p.y, expected[1], accuracy: 1e-9)
                }
            } }
        }
    }
    func testInvalidRequestsAndNeutralThreshold() throws {
        for data in [try input(width: 0), try input(height: -1), try input(width: 100001), try input(v: 16), try input(h: -16)] {
            XCTAssertThrowsError(try WebRenderRequest.prepare(data))
        }
        let data = try WebRenderRequest.prepare(input(v: 0.0005, h: -0.0005))
        let plan = try JSONDecoder().decode(WebPerspectiveRequest.Result.self, from: data)
        XCTAssertEqual(plan.inverse, [1, 0, 0, 0, 1, 0, 0, 0])
    }
    #if canImport(CoreImage)
    func testInverseMatchesNativeCoreImagePerspectivePixels() throws {
        let w = 120, h = 80
        var data = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            data[i] = (Float(x) + 0.5) / Float(w)
            data[i + 1] = (Float(y) + 0.5) / Float(h)
            data[i + 2] = 2.5; data[i + 3] = 1
        } }
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let source = CIImage(bitmapData: Data(bytes: data, count: data.count * 4), bytesPerRow: w * 16,
                             size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: space)
        let context = CIContext(options: [.workingColorSpace: space])
        for (v, horizontal) in [(8.0, -5.0), (-15.0, 15.0), (0, 12)] {
            let corners = PerspectiveProjection.corners(width: Double(w), height: Double(h), vertical: v, horizontal: horizontal)
            let parameters = Dictionary(uniqueKeysWithValues: zip(
                ["inputTopLeft", "inputTopRight", "inputBottomRight", "inputBottomLeft"], corners)
                .map { ($0, CIVector(x: $1.x * Double(w), y: (1 - $1.y) * Double(h))) })
            let image = source.applyingFilter("CIPerspectiveTransform", parameters: parameters)
            let inverse = PerspectiveProjection.inverse(width: Double(w), height: Double(h), vertical: v, horizontal: horizontal)
            for x in stride(from: 12, to: w, by: 24) { for y in stride(from: 12, to: h, by: 16) {
                var pixel = [Float](repeating: 0, count: 4)
                context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: space)
                let expected = point(inverse, (Double(x) + 0.5) / Double(w), 1 - (Double(y) + 0.5) / Double(h))
                XCTAssertEqual(Double(pixel[0]), expected.x, accuracy: 0.002)
                XCTAssertEqual(Double(pixel[1]), expected.y, accuracy: 0.002)
                XCTAssertEqual(pixel[2], 2.5, accuracy: 0.002)
            } }
        }
    }
    #endif
}
