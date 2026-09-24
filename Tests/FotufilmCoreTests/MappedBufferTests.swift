import Foundation
import XCTest
@testable import FotufilmCore

final class MappedBufferTests: XCTestCase {
    func testBoundedMemoryHonorsCapBelowAutomaticMappingThreshold() throws {
        let cap = 4096
        for count in [cap - 1, cap, cap + 1] {
            let buffer = try XCTUnwrap(MappedBuffer(byteCount: count, storage: .boundedMemory(upTo: cap)))
            XCTAssertEqual(buffer.isMapped, count > cap)
            XCTAssertEqual(buffer.residentByteCount, count > cap ? 0 : count)
            let bytes = buffer.bound(to: UInt8.self)
            XCTAssertTrue(bytes.allSatisfy { $0 == 0 })
            bytes[count - 1] = 193
            XCTAssertEqual(bytes[count - 1], 193)
        }
    }

    func testBoundedMemoryAtCapMayExceedAutomaticMappingThreshold() throws {
        let count = MappedBuffer.mappingThreshold + 1
        let buffer = try XCTUnwrap(MappedBuffer(byteCount: count, storage: .boundedMemory(upTo: count)))
        XCTAssertFalse(buffer.isMapped)
        XCTAssertEqual(buffer.residentByteCount, count)
    }

    func testNonpositiveBoundedCapRequiresFileBackingForSmallBuffers() throws {
        for cap in [0, -1, Int.min] {
            let buffer = try XCTUnwrap(MappedBuffer(byteCount: 17, storage: .boundedMemory(upTo: cap)))
            XCTAssertTrue(buffer.isMapped)
            XCTAssertEqual(buffer.residentByteCount, 0)
        }
    }

    func testBoundedMapFailureNeverAttemptsAnonymousMemoryAboveCap() {
        var fileRequests: [Int] = [], memoryRequests: [Int] = []
        var allocation = MappedBuffer.Allocation.system
        allocation.file = { fileRequests.append($0); return nil }
        allocation.memory = { memoryRequests.append($0); return nil }
        let counts = [1, 4097, MappedBuffer.mappingThreshold + 1]
        for count in counts {
            XCTAssertNil(MappedBuffer(byteCount: count,
                storage: .boundedMemory(upTo: count == 1 ? 0 : 4096), allocation: allocation))
        }
        XCTAssertEqual(fileRequests, counts)
        XCTAssertTrue(memoryRequests.isEmpty, "strict file backing must not even attempt malloc after mapping fails")
    }

    func testBoundedMemoryAllocationFailureFallsBackToFileWithinCap() throws {
        let system = MappedBuffer.Allocation.system
        var allocation = system
        var memoryRequests = 0, fileRequests = 0
        allocation.memory = { _ in memoryRequests += 1; return nil }
        allocation.file = { count in fileRequests += 1; return system.file(count) }
        let buffer = try XCTUnwrap(MappedBuffer(byteCount: 4096,
            storage: .boundedMemory(upTo: 4096), allocation: allocation))
        XCTAssertTrue(buffer.isMapped)
        XCTAssertEqual(memoryRequests, 1)
        XCTAssertEqual(fileRequests, 1)
        XCTAssertEqual(buffer.residentByteCount, 0)
    }

    func testBoundedAllocationReturnsNilWhenBothPermittedPathsFail() {
        var memoryRequests = 0, fileRequests = 0
        var allocation = MappedBuffer.Allocation.system
        allocation.memory = { _ in memoryRequests += 1; return nil }
        allocation.file = { _ in fileRequests += 1; return nil }
        XCTAssertNil(MappedBuffer(byteCount: 64,
            storage: .boundedMemory(upTo: 64), allocation: allocation))
        XCTAssertEqual(memoryRequests, 1)
        XCTAssertEqual(fileRequests, 1)
    }

    func testExistingPoliciesKeepAnonymousFallbackWhenMappingFails() throws {
        var fileRequests = 0
        var allocation = MappedBuffer.Allocation.system
        allocation.file = { _ in fileRequests += 1; return nil }
        let count = MappedBuffer.mappingThreshold + 1
        let policies: [MappedBuffer.StoragePreference] = [.automatic, .memory(upTo: 0)]
        for storage in policies {
            let buffer = try XCTUnwrap(MappedBuffer(byteCount: count, storage: storage, allocation: allocation))
            XCTAssertFalse(buffer.isMapped)
            XCTAssertEqual(buffer.residentByteCount, count)
        }
        XCTAssertEqual(fileRequests, 2)
        // The existing preference remains a hint below mappingThreshold, even with cap zero.
        let small = try XCTUnwrap(MappedBuffer(byteCount: 17, storage: .memory(upTo: 0), allocation: allocation))
        XCTAssertFalse(small.isMapped)
        XCTAssertEqual(fileRequests, 2)
    }

    func testBoundedMappedIOAndRetainedOwnerSurviveOriginalScope() throws {
        let count = 65_539
        var expected = [UInt8](repeating: 0, count: count)
        weak var owner: MappedBuffer?
        func retainedData() throws -> Data {
            let buffer = try XCTUnwrap(MappedBuffer(byteCount: count, storage: .boundedMemory(upTo: 0)))
            XCTAssertTrue(buffer.isMapped)
            owner = buffer
            for range in [4093..<4230, (count - 513)..<count] {
                let values = range.map { UInt8(truncatingIfNeeded: $0 * 37) }
                values.withUnsafeBytes {
                    buffer.write(from: $0.baseAddress!, byteOffset: range.lowerBound, byteCount: $0.count)
                }
                buffer.flush(byteOffset: range.lowerBound, byteCount: range.count)
                expected.replaceSubrange(range, with: values)
            }
            // A borrowed view must retain its owner; only MappedBuffer releases the mapping.
            return Data(bytesNoCopy: buffer.baseAddress, count: count,
                deallocator: .custom { [buffer] _, _ in withExtendedLifetime(buffer) {} })
        }
        var data: Data? = try retainedData()
        XCTAssertNotNil(owner)
        XCTAssertEqual(data, Data(expected))
        data = nil
        XCTAssertNil(owner)
    }

    func testExplicitMemoryAllowancePreservesBytesAndFallsBackAboveLimit() throws {
        let count = MappedBuffer.mappingThreshold + 4096
        let resident = try XCTUnwrap(MappedBuffer(byteCount: count, storage: .memory(upTo: count)))
        let mapped = try XCTUnwrap(MappedBuffer(byteCount: count, storage: .memory(upTo: count - 1)))
        XCTAssertFalse(resident.isMapped)
        XCTAssertTrue(mapped.isMapped)
        XCTAssertEqual(resident.residentByteCount, count)
        XCTAssertEqual(mapped.residentByteCount, 0)
        let values = (0..<4096).map { UInt8(truncatingIfNeeded: $0 * 37) }
        for buffer in [resident, mapped] {
            let bytes = buffer.bound(to: UInt8.self)
            XCTAssertEqual(bytes[0], 0)
            XCTAssertEqual(bytes[count / 2], 0)
            XCTAssertEqual(bytes[count - 1], 0)
            values.withUnsafeBytes { buffer.write(from: $0.baseAddress!, byteOffset: count - values.count, byteCount: $0.count) }
            buffer.flush(byteOffset: count - values.count, byteCount: values.count)
            XCTAssertTrue(bytes.suffix(values.count).elementsEqual(values))
        }
    }

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
