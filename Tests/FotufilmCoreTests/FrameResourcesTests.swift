import XCTest
@testable import FotufilmImaging

final class FrameResourcesTests: XCTestCase {
    private enum Reading { case hlg, appleLog }

    private func canReuse(builtStride: Int, builtConverter: Reading?,
                          buffersReady: Bool = true,
                          stride: Int, reading: Reading = .hlg,
                          builtSize: (Int, Int) = (1920, 1080),
                          size: (Int, Int) = (1920, 1080)) -> Bool {
        FrameResources.canReuse(
            builtWidth: builtSize.0, builtHeight: builtSize.1,
            builtStride: builtStride, builtConverter: builtConverter,
            buffersReady: buffersReady,
            width: size.0, height: size.1, stride: stride, reading: reading)
    }

    func testADeepSetWithNoConverterIsNeverReused() {
        XCTAssertFalse(
            canReuse(builtStride: FrameResources.deepStride, builtConverter: nil,
                     stride: FrameResources.deepStride),
            """
            a deep set with no converter claimed it could read a deep frame — this is the \
            latch that read planar 10-bit as packed BGRA forever
            """)
    }

    func testADeepSetWithTheRightConverterIsReused() {
        XCTAssertTrue(
            canReuse(builtStride: FrameResources.deepStride, builtConverter: .hlg,
                     stride: FrameResources.deepStride, reading: .hlg))
    }

    func testADeepSetBuiltForAnotherReadingIsNotReused() {
        XCTAssertFalse(
            canReuse(builtStride: FrameResources.deepStride,
                     builtConverter: .appleLog,
                     stride: FrameResources.deepStride, reading: .hlg))
    }

    func testTheShallowRoadIsReusedOnlyWithoutAConverter() {
        XCTAssertTrue(
            canReuse(builtStride: FrameResources.shallowStride,
                     builtConverter: nil, stride: FrameResources.shallowStride))
        XCTAssertFalse(
            canReuse(builtStride: FrameResources.shallowStride,
                     builtConverter: .hlg, stride: FrameResources.shallowStride))
    }

    func testGeometryAndStrideAndBuffersAllHaveToMatch() {
        let deep = FrameResources.deepStride
        XCTAssertFalse(canReuse(builtStride: deep, builtConverter: .hlg,
                                stride: deep, builtSize: (1920, 1080),
                                size: (1280, 720)), "a different size was reused")
        XCTAssertFalse(canReuse(builtStride: FrameResources.shallowStride,
                                builtConverter: nil, stride: deep),
                       "a shallow set was reused for a deep frame")
        XCTAssertFalse(canReuse(builtStride: deep, builtConverter: .hlg,
                                buffersReady: false, stride: deep),
                       "a set with no buffers was reused")
    }

    func testAFreshDeepSetIsUsableOnlyWithItsConverter() {
        XCTAssertFalse(FrameResources.isUsable(
            stride: FrameResources.deepStride, buffersReady: true,
            hasConverter: false))
        XCTAssertTrue(FrameResources.isUsable(
            stride: FrameResources.deepStride, buffersReady: true,
            hasConverter: true))
        XCTAssertTrue(FrameResources.isUsable(
            stride: FrameResources.shallowStride, buffersReady: true,
            hasConverter: false))
        XCTAssertFalse(FrameResources.isUsable(
            stride: FrameResources.shallowStride, buffersReady: false,
            hasConverter: false))
    }

    func testOnlyTheFullPrecisionHDRStrideNeedsAConverter() {
        XCTAssertTrue(FrameResources.needsConverter(
            stride: FrameResources.deepStride))
        XCTAssertFalse(FrameResources.needsConverter(
            stride: FrameResources.shallowStride))
        XCTAssertEqual(FrameResources.deepStride, 16)
        XCTAssertEqual(FrameResources.shallowStride, 4)
    }

    func testForgottenGeometryNeverMatchesARealFrame() {
        XCTAssertFalse(canReuse(builtStride: 0, builtConverter: nil,
                                stride: FrameResources.deepStride,
                                builtSize: (0, 0), size: (1920, 1080)))
    }
}
