import XCTest
// Deliberately not `@testable`.
import FotufilmImaging
#if canImport(CoreMedia)
import CoreMedia
import CoreVideo

final class VideoDecodeDepthAccessTests: XCTestCase {

    func testARoadCanBeBuiltFromOutsideTheModule() {
        XCTAssertEqual(
            VideoDecodeDepth.Road(deepInput: true, realtimeSchedule: false)
                .pixelFormat, kCVPixelFormatType_128RGBAFloat)
        XCTAssertEqual(
            VideoDecodeDepth.Road(deepInput: false, realtimeSchedule: true)
                .pixelFormat, kCVPixelFormatType_32BGRA)
    }
}
#endif
