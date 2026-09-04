#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal
import Metal

final class NativeRealtimeCommandBufferTests: XCTestCase {
    func testSDREncodesWithoutSubmittingCallerCommandBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let renderer = NativeRealtimeFilmRenderer.shared else {
            throw XCTSkip("Metal renderer unavailable")
        }
        let width = 17, height = 11, byteCount = width * height * 4
        let input = try XCTUnwrap(device.makeBuffer(
            length: byteCount, options: .storageModeShared))
        let output = try XCTUnwrap(device.makeBuffer(
            length: byteCount, options: .storageModeShared))
        memset(input.contents(), 127, byteCount)

        var options = FotufilmEngine.Options()
        options.format = .super8
        let key = #function
        XCTAssertTrue(renderer.prepare(
            key: key, stock: TestStocks.negative, options: options,
            frameWidth: width, frameHeight: height))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())

        XCTAssertTrue(renderer.encodeRGBA8(
            input: input, output: output, width: width, height: height,
            key: key, frameIndex: 3, commandBuffer: commandBuffer))
        XCTAssertEqual(commandBuffer.status, .notEnqueued)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
    }

    func testHDREncodesWithoutSubmittingCallerCommandBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let renderer = NativeRealtimeHDRFilmRenderer.shared else {
            throw XCTSkip("Metal HDR renderer unavailable")
        }
        let width = 13, height = 9, byteCount = width * height * 8
        let input = try XCTUnwrap(device.makeBuffer(
            length: byteCount, options: .storageModeShared))
        let output = try XCTUnwrap(device.makeBuffer(
            length: byteCount, options: .storageModeShared))
        let pixels = input.contents().assumingMemoryBound(to: Float16.self)
        for index in 0..<(width * height) {
            pixels[index * 4] = 0.18
            pixels[index * 4 + 1] = 0.18
            pixels[index * 4 + 2] = 0.18
            pixels[index * 4 + 3] = 1
        }

        var options = FotufilmEngine.Options()
        options.format = .super8
        options.sceneHeadroom = HLGSceneTransfer.headroom
        let key = #function
        XCTAssertTrue(renderer.prepare(
            key: key, stock: TestStocks.negative, options: options,
            frameWidth: width, frameHeight: height))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())

        XCTAssertTrue(renderer.encodeLinearHalf(
            input: input, output: output, width: width, height: height,
            key: key, frameIndex: 5, commandBuffer: commandBuffer))
        XCTAssertEqual(commandBuffer.status, .notEnqueued)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
    }
}
#endif
