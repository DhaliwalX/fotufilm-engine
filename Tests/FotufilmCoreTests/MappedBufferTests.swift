import XCTest
@testable import FotufilmCore

final class MappedBufferTests: XCTestCase {
    func testSmallBuffersAreNotMapped() throws {
        let buffer = try XCTUnwrap(MappedBuffer(byteCount: 4096))
        XCTAssertFalse(buffer.isMapped)
        XCTAssertEqual(MappedBuffer.residentBytes(4096), 4096)
    }

    func testLargeBuffersAreMappedAndCostNothing() throws {
        let byteCount = MappedBuffer.mappingThreshold + (1 << 20)
        let buffer = try XCTUnwrap(MappedBuffer(byteCount: byteCount))
        XCTAssertTrue(buffer.isMapped,
                      "a frame-sized buffer belongs in a file")
        XCTAssertEqual(MappedBuffer.residentBytes(byteCount), 0)
    }

    func testMappedBufferKeepsWhatIsWrittenToIt() throws {
        let count = (MappedBuffer.mappingThreshold + (1 << 20)) / 2
        let buffer = try XCTUnwrap(MappedBuffer(byteCount: count * 2))
        XCTAssertTrue(buffer.isMapped)
        let samples = buffer.bound(to: UInt16.self)
        XCTAssertEqual(samples.count, count)
        for index in stride(from: 0, to: count, by: 997) {
            samples[index] = UInt16(index % 65536)
        }
        samples[0] = 12345
        samples[count - 1] = 54321
        buffer.flush(byteOffset: 0, byteCount: count * 2)
        for index in stride(from: 0, to: count, by: 997) where index != 0 {
            XCTAssertEqual(samples[index], UInt16(index % 65536))
        }
        XCTAssertEqual(samples[0], 12345)
        XCTAssertEqual(samples[count - 1], 54321)
    }

    func testBuffersStartZeroed() throws {
        for byteCount in [4096, MappedBuffer.mappingThreshold + 4096] {
            let buffer = try XCTUnwrap(MappedBuffer(byteCount: byteCount))
            let bytes = buffer.bound(to: UInt8.self)
            XCTAssertEqual(bytes[0], 0)
            XCTAssertEqual(bytes[byteCount / 2], 0)
            XCTAssertEqual(bytes[byteCount - 1], 0)
        }
    }

    func testFlushIgnoresRangesItDoesNotOwn() throws {
        let byteCount = MappedBuffer.mappingThreshold + 4096
        let buffer = try XCTUnwrap(MappedBuffer(byteCount: byteCount))
        buffer.flush(byteOffset: -1, byteCount: 16)
        buffer.flush(byteOffset: byteCount - 8, byteCount: 4096)
        buffer.flush(byteOffset: 0, byteCount: byteCount)
    }

    func testEmptyBufferIsRefused() {
        XCTAssertNil(MappedBuffer(byteCount: 0))
        XCTAssertNil(MappedBuffer(byteCount: -1))
    }
}
