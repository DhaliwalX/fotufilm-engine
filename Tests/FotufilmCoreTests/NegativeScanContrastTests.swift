import XCTest
@testable import FotufilmCore

/// A frame's tonal steps say how steep its records read against each other.
final class NegativeScanContrastTests: XCTestCase {
    private let border = SIMD3<Float>(0.5, 0.25, 0.12)

    /// A picture of square patches, each a tone on one surface colour: `tone` the green density
    /// over the border and `colour` what the surface adds to red and blue.
    private func preview(width: Int = 120, height: Int = 90, slopes: SIMD2<Float>,
                         tone: (Int, Int) -> Float,
                         colour: (Int, Int) -> SIMD2<Float> = { _, _ in .zero }) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            let green = tone(x / 6, y / 6), surface = colour(x / 18, y / 18)
            let density = SIMD3(slopes.x * green + surface.x, green, slopes.y * green + surface.y)
            for c in 0..<3 { image.planes[c][y * width + x] = border[c] * pow(10, -density[c]) }
        } }
        return image
    }

    /// Tones that differ from patch to patch, the same every run.
    private func tone(_ x: Int, _ y: Int) -> Float {
        0.3 + 0.2 * Float((x * 7 + y * 13 + (x * y) % 5) % 6)
    }

    func testTonalStepsGiveTheRisesOfRedAndBlueAgainstGreen() throws {
        let slopes = SIMD2<Float>(0.62, 1.15)
        let found = try XCTUnwrap(ApproximateNegativeScan.tonalSlopes(
            border: border, preview: preview(slopes: slopes, tone: tone)))
        XCTAssertEqual(found.x, slopes.x, accuracy: 1e-4)
        XCTAssertEqual(found.y, slopes.y, accuracy: 1e-4)
    }

    func testSurfaceColoursScatterTheStepsWithoutMovingTheirMiddle() throws {
        let slopes = SIMD2<Float>(0.62, 1.15)
        // Surfaces three patches wide, each its own colour: most steps lie inside one.
        let colour = { (x: Int, y: Int) -> SIMD2<Float> in
            SIMD2(0.12 * Float((x * 5 + y * 3) % 5 - 2) / 2, 0.15 * Float((x * 3 + y * 7) % 5 - 2) / 2)
        }
        let found = try XCTUnwrap(ApproximateNegativeScan.tonalSlopes(
            border: border, preview: preview(slopes: slopes, tone: tone, colour: colour)))
        XCTAssertEqual(found.x, slopes.x, accuracy: 0.01)
        XCTAssertEqual(found.y, slopes.y, accuracy: 0.01)
        // A cast over the whole frame is a level, which steps do not see.
        let cast = try XCTUnwrap(ApproximateNegativeScan.tonalSlopes(
            border: border,
            preview: preview(slopes: slopes, tone: tone, colour: { _, _ in SIMD2(0.2, -0.3) })))
        XCTAssertEqual(cast.x, slopes.x, accuracy: 1e-4)
        XCTAssertEqual(cast.y, slopes.y, accuracy: 1e-4)
    }

    func testAFrameWithoutStepsTellsNothing() {
        let slopes = SIMD2<Float>(0.62, 1.15)
        let flat = preview(slopes: slopes, tone: { x, _ in 0.8 + 0.01 * Float(x % 3) })
        XCTAssertNil(ApproximateNegativeScan.tonalSlopes(border: border, preview: flat))
        XCTAssertNil(ApproximateNegativeScan.tonalSlopes(
            border: border, preview: preview(width: 1, height: 1, slopes: slopes, tone: tone)))
        XCTAssertNil(ApproximateNegativeScan.tonalSlopes(
            border: SIMD3(0.5, 0, 0.12), preview: preview(slopes: slopes, tone: tone)))
        // Pixels that pass no light are left out, and the rest still tell.
        var holed = preview(slopes: slopes, tone: tone)
        for i in stride(from: 0, to: holed.pixelCount, by: 7) { holed.planes[1][i] = 0 }
        let found = ApproximateNegativeScan.tonalSlopes(border: border, preview: holed)
        XCTAssertEqual(found?.x ?? 0, slopes.x, accuracy: 1e-4)
    }

    private func stock(_ id: String) throws -> FilmStock {
        try XCTUnwrap(FilmStock.presetDefinitions[id]).validated().stock
    }

    func testContrastStaysInsideWhatARollCanBe() throws {
        let stock = try stock("gold200")
        let straight = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
        let range = ApproximateNegativeScan.contrastRange
        let steep = ApproximateNegativeScan.contrast(stock: stock, weights: straight,
                                                     slopes: SIMD2(0.1, 9))
        XCTAssertEqual(steep, SIMD3(range.upperBound, 1, range.lowerBound))
        XCTAssertNoThrow(try ApproximateNegativeScan(
            stock: stock, border: SIMD3(0.5, 0.25, 0.12), gains: steep, weights: straight))
        // A rise that reads no record, and a film with one record, keep the film's own.
        XCTAssertEqual(ApproximateNegativeScan.contrast(stock: stock, weights: straight,
                                                        slopes: SIMD2(.nan, 1)).x, 1)
        XCTAssertEqual(ApproximateNegativeScan.contrast(stock: stock, weights: straight,
                                                        slopes: SIMD2(-0.2, 1)).x, 1)
        XCTAssertEqual(ApproximateNegativeScan.contrast(
            stock: try self.stock("hp5plus400"), weights: straight, slopes: SIMD2(0.5, 2)), .one)
    }
}
