import CoreImage
import XCTest
@testable import FotufilmCore
@testable import FotufilmImaging

final class NegativeScanFramingTests: XCTestCase {
    private let border = SIMD3<Float>(0.8, 0.45, 0.2)

    /// A 135 frame: clear rebate above and below with brighter sprocket holes, a black holder at
    /// the left, and a picture of mixed density in the middle.
    private func strip(width: Int, height: Int, picture: CGRect) -> ImageBuffer {
        var scan = ImageBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            let i = y * width + x
            let u = Double(x) / Double(width), v = Double(y) / Double(height)
            var density: Float = 0.02
            if u < 0.04 {
                density = 4
            } else if picture.contains(CGPoint(x: u, y: v)) {
                density = 0.3 + 1.2 * Float((x * 7 + y * 13) % 17) / 17
            } else if (x / 6).isMultiple(of: 3), v < 0.08 || v > 0.92 {
                density = -0.4
            }
            for c in 0..<3 { scan.planes[c][i] = border[c] * pow(10, -density) }
        } }
        return scan
    }

    func testFindsThePictureBetweenRebateAndHolder() throws {
        let picture = CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.7)
        let scan = strip(width: 300, height: 200, picture: picture)
        let found = try XCTUnwrap(NegativeFrameDetection.imageArea(of: scan, border: border))
        XCTAssertEqual(found.minX, picture.minX, accuracy: 0.02)
        XCTAssertEqual(found.maxX, picture.maxX, accuracy: 0.02)
        XCTAssertEqual(found.minY, picture.minY, accuracy: 0.02)
        XCTAssertEqual(found.maxY, picture.maxY, accuracy: 0.02)
    }

    func testAPictureFillingTheScanHasNothingToCrop() {
        let scan = strip(width: 200, height: 150, picture: CGRect(x: -1, y: -1, width: 3, height: 3))
        var filled = scan
        for c in 0..<3 { for i in 0..<filled.pixelCount {
            filled.planes[c][i] = border[c] * pow(10, -0.3 - Float(i % 11) / 10)
        } }
        XCTAssertNil(NegativeFrameDetection.imageArea(of: filled, border: border))
    }

    /// Film on a light pad that falls off towards the corners reads even once the pad's own
    /// photograph is divided out.
    func testLightFrameEvensOutAFallingLight() throws {
        let width = 240, height = 160
        func lamp(_ x: Int, _ y: Int) -> Float {
            let dx = Float(x) / Float(width) - 0.5, dy = Float(y) / Float(height) - 0.5
            return 1 - 0.9 * (dx * dx + dy * dy)
        }
        func image(_ value: (Int, Int, Int) -> Float) -> CIImage {
            var rgba = [Float](repeating: 1, count: width * height * 4)
            for y in 0..<height { for x in 0..<width { for c in 0..<3 {
                rgba[(y * width + x) * 4 + c] = value(x, y, c)
            } } }
            // Rows are stored from the top; Core Image's origin is the bottom.
            return CIImage(bitmapData: rgba.withUnsafeBufferPointer { Data(buffer: $0) },
                           bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                           format: .RGBAf, colorSpace: NegativeScanImport.linearSpace)
        }
        let pad = image { x, y, _ in lamp(x, y) }
        let film: Float = 0.3
        let scan = image { x, y, c in film * self.border[c] * lamp(x, y) }
        let light = try NegativeLightFrame(photo: pad)
        let even = try NegativeScanImport.samples(light.flatten(scan))
        for c in 0..<3 {
            let values = even.planes[c]
            let centre = values[(height / 2) * width + width / 2]
            for (x, y) in [(4, 4), (width - 5, 4), (4, height - 5), (width - 5, height - 5)] {
                XCTAssertEqual(values[y * width + x] / centre, 1, accuracy: 0.06,
                               "channel \(c) at \(x),\(y)")
            }
        }
    }
}
