#if canImport(Metal)
import Metal
import XCTest
@testable import FotufilmCore
@testable import FotufilmMetal

final class RegionStreamingTests: XCTestCase {
    func testMeteredRegionTilesMatchSinglePassAtNonzeroOrigin() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide engine required")
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let frameWidth = 1024, frameHeight = 896
        let width = 768, height = 640, originX = 97, originY = 83
        let source = (0..<(frameWidth * frameHeight * 4)).map { index -> Float in
            if index % 4 == 3 { return 1 }
            let pixel = index / 4
            return Float((pixel % frameWidth + pixel / frameWidth * 3 + index % 4 * 11) % 251) / 100
        }
        let fullInput = try XCTUnwrap(device.makeBuffer(bytes: source,
            length: source.count * 4, options: .storageModeShared))
        var options = FotufilmEngine.Options()
        options.format = .super8
        let context = try XCTUnwrap(gpu.makeLinearFloatFrameContext(input: fullInput,
            width: frameWidth, height: frameHeight, stock: TestStocks.negative, options: options))
        var crop = [Float]()
        for row in originY..<(originY + height) {
            let start = (row * frameWidth + originX) * 4
            crop.append(contentsOf: source[start..<(start + width * 4)])
        }
        let input = try XCTUnwrap(device.makeBuffer(bytes: crop,
            length: crop.count * 4, options: .storageModeShared))
        let output = try XCTUnwrap(device.makeBuffer(length: crop.count * 4, options: .storageModeShared))
        XCTAssertTrue(gpu.processLinearFloatRegion(input: input, output: output,
            regionWidth: width, regionHeight: height, originX: originX, originY: originY, context: context))
        let expected = UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: Float.self), count: crop.count)
        var actual = [Float](repeating: .nan, count: crop.count)
        var tiles = 0
        var columnStarts = Set<Int>()
        XCTAssertTrue(gpu.developRegionStreaming(width: width, height: height,
            originX: originX, originY: originY, context: context, memoryBudget: 40 << 20,
            readTile: { rows, columns, into in
                for (index, row) in rows.enumerated() {
                    for column in columns {
                        for channel in 0..<4 {
                            into[(index * columns.count + column - columns.lowerBound) * 4 + channel] =
                                crop[(row * width + column) * 4 + channel]
                        }
                    }
                }
            }, writeTile: { rows, columns, from in
                tiles += 1
                columnStarts.insert(columns.lowerBound)
                for (index, row) in rows.enumerated() {
                    for column in columns {
                        for channel in 0..<4 {
                            actual[(row * width + column) * 4 + channel] =
                                from[(index * columns.count + column - columns.lowerBound) * 4 + channel]
                        }
                    }
                }
            }))
        XCTAssertGreaterThan(tiles, 1)
        XCTAssertGreaterThan(columnStarts.count, 1)
        XCTAssertEqual(actual.map(\.bitPattern), expected.map(\.bitPattern))

        // Reject an impossible budget or cancelled request without acquiring source pixels.
        for cancelled in [false, true] {
            XCTAssertFalse(gpu.developRegionStreaming(width: width, height: height,
                originX: originX, originY: originY, context: context,
                memoryBudget: cancelled ? 40 << 20 : 1, shouldContinue: { !cancelled },
                readTile: { _, _, _ in XCTFail("Rejected render read the source") },
                writeTile: { _, _, _ in XCTFail("Rejected render delivered pixels") }))
        }
    }
}
#endif
