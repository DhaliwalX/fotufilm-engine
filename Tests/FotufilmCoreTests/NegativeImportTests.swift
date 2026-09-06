#if canImport(CoreImage)
import XCTest
import CoreImage
import FotufilmCore
import FotufilmImaging

final class NegativeImportTests: XCTestCase {
    func testCornerMovementRejectsCrossingAndRoundTrips() throws {
        let crop = QuadrilateralCrop()
        let moved = crop.movingCorner(0, to: CGPoint(x: 0.2, y: 0.15))
        XCTAssertTrue(moved.isValid)
        XCTAssertEqual(moved.topRight, crop.topRight)
        XCTAssertEqual(moved.bottomRight, crop.bottomRight)
        XCTAssertEqual(moved.bottomLeft, crop.bottomLeft)
        XCTAssertEqual(moved.movingCorner(0, to: CGPoint(x: 1, y: 1)), moved)
        XCTAssertEqual(try JSONDecoder().decode(QuadrilateralCrop.self,
            from: JSONEncoder().encode(moved)), moved)
    }

    func testTopOriginBorderSampleAndLinearFileDecode() throws {
        let top = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6,
            colorSpace: NegativeScanImport.linearSpace)!).cropped(to: CGRect(x: 0, y: 50, width: 100, height: 50))
        let bottom = CIImage(color: CIColor(red: 0.8, green: 0.6, blue: 0.4,
            colorSpace: NegativeScanImport.linearSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 50))
        let image = top.composited(over: bottom)
        let border = try NegativeScanImport.sampleBorder(image: image,
            rect: CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertEqual(border.x, 0.2, accuracy: 0.001)
        XCTAssertEqual(border.y, 0.4, accuracy: 0.001)
        XCTAssertEqual(border.z, 0.6, accuracy: 0.001)
        let data = try XCTUnwrap(CIContext().tiffRepresentation(of: image, format: .RGBA16,
            colorSpace: NegativeScanImport.linearSpace))
        let decoded = try NegativeScanImport.decode(data: data, linearSamples: true)
        let sampled = try NegativeScanImport.sampleBorder(image: decoded,
            rect: CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertEqual(sampled.x, border.x, accuracy: 0.001)
        XCTAssertThrowsError(try NegativeScanImport.sampleBorder(image: image, rect: .zero))
    }

    func testCornerCorrectionSelectsTopAndAgreesAtPreviewScale() throws {
        let top = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 50, width: 100, height: 50))
        let bottom = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 50))
        let image = top.composited(over: bottom)
        let crop = QuadrilateralCrop(rect: CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.35))
        let full = crop.applying(to: image)
        let preview = crop.applying(to: image.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)))
        XCTAssertEqual(full.extent.width, preview.extent.width * 2, accuracy: 2)
        XCTAssertEqual(full.extent.height, preview.extent.height * 2, accuracy: 2)
        let pixels = try NegativeScanImport.samples(full)
        XCTAssertGreaterThan(pixels.planes[0][pixels.pixelCount / 2], 0.9)
        XCTAssertLessThan(pixels.planes[2][pixels.pixelCount / 2], 0.01)
    }

    func testImporterPrintsAndMasksHolderWithoutChangingValidPixels() throws {
        let stock = FilmStock.named("gold200")!
        let film = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.1,
            colorSpace: NegativeScanImport.linearSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let holder = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 32))
        let bright = CIImage(color: CIColor(red: 8, green: 8, blue: 8,
            colorSpace: NegativeScanImport.linearSpace)!).cropped(to: CGRect(x: 28, y: 0, width: 4, height: 32))
        let image = bright.composited(over: holder.composited(over: film))
        let border = SIMD3<Float>(0.4, 0.6, 0.2)
        let output = try NegativeScanImport.positive(image: image, border: border, stock: stock)
        let pixels = try NegativeScanImport.samples(output)
        XCTAssertTrue(pixels.planes.flatMap { $0 }.allSatisfy(\.isFinite))
        XCTAssertEqual(pixels.planes[0][0], 0, accuracy: 0.00001)
        XCTAssertEqual(pixels.planes[0][31], 0, accuracy: 0.00001)
        let reference = try NegativeScanImport.samples(NegativeScanImport.positive(image: film, border: border, stock: stock))
        for c in 0..<3 { XCTAssertEqual(pixels.planes[c][16], reference.planes[c][16], accuracy: 0.00001) }
    }
}
#endif
