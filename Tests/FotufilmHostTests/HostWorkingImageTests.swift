import XCTest
@testable import FotufilmHost

/// A photograph held as a working copy, as a phone holds a camera RAW: what the copy covers is
/// reduced from it, and only a larger ask (an export) decodes the file again, without keeping it.
final class HostWorkingImageTests: XCTestCase {
    /// A 400 × 200 photograph held at 100 × 50, every pixel `level`, counting the decodes.
    private func working(level: Float = 0.25) -> (HostImage, () -> [Int]) {
        let image = HostImage(working: [Float](repeating: level, count: 100 * 50 * 4),
                              width: 100, height: 50, naturalWidth: 400, naturalHeight: 200,
                              contentHeadroom: 1)
        var asked: [Int] = []
        image.decodeLarger = { longEdge in
            asked.append(longEdge)
            let width = min(400, longEdge), height = width / 2
            return ([Float](repeating: 0.5, count: width * height * 4), width, height)
        }
        return (image, { asked })
    }

    func testTheCopyCoversPreviewsAndAMagnifiedViewStopsAtIt() {
        let (image, asked) = working()
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.workingLongEdge, 100)
        XCTAssertEqual(image.scene(width: 100, height: 50).first, 0.25)
        XCTAssertEqual(image.scene(width: 60, height: 30).count, 60 * 30 * 4)
        // A pixel over is rounding between the two sizes, not a reason to decode.
        XCTAssertEqual(image.scene(width: 101, height: 50).count, 101 * 50 * 4)
        XCTAssertEqual(asked(), [])
    }

    func testAnExportDecodesTheFileAgainEveryTime() {
        let (image, asked) = working()
        let full = image.scene(width: 400, height: 200)
        XCTAssertEqual(full.count, 400 * 200 * 4)
        XCTAssertEqual(full.first, 0.5)
        _ = image.scene(width: 400, height: 200)
        XCTAssertEqual(asked(), [400, 400])
        XCTAssertEqual(image.scene(width: 100, height: 50).first, 0.25)
    }

    func testAPhotographHeldWholeHasNoWorkingEdge() {
        let image = HostImage(rgba: [Float](repeating: 0, count: 8 * 4 * 4), width: 8, height: 4,
                              contentHeadroom: 1)
        XCTAssertNil(image.workingLongEdge)
    }
}
