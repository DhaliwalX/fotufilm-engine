import Foundation
#if canImport(Android)
// Foundation carries math.h onto Android but not the POSIX headers this file is written against.
import Android
#endif

/// A buffer that a large render can hold for its whole duration without spending the process's
/// memory allowance on it. iOS kills an app for the *dirty* pages it holds, not for the address
/// space it has mapped.
public final class MappedBuffer: @unchecked Sendable {
    /// Above this, a buffer is worth putting on disk.
    public static let mappingThreshold = 32 << 20

    public let byteCount: Int
    /// False when this fell back to — or never left — anonymous memory.
    public let isMapped: Bool
    public let baseAddress: UnsafeMutableRawPointer

    /// Allocates `byteCount` bytes, mapped or not according to size.
    public init?(byteCount: Int) {
        guard byteCount > 0 else { return nil }
        self.byteCount = byteCount
        if byteCount >= Self.mappingThreshold,
           let mapped = Self.map(byteCount: byteCount) {
            baseAddress = mapped
            isMapped = true
            return
        }
        guard let memory = malloc(byteCount) else { return nil }
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        baseAddress = memory
        isMapped = false
    }

    deinit {
        if isMapped {
            munmap(baseAddress, byteCount)
        } else {
            free(baseAddress)
        }
    }

    /// Maps a temporary file, or nil if any step of it fails.
    private static func map(byteCount: Int) -> UnsafeMutableRawPointer? {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fotufilm-\(UUID().uuidString)")
        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return nil }
        unlink(path)
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(byteCount)) == 0 else { return nil }
        let mapped = mmap(nil, byteCount, PROT_READ | PROT_WRITE,
                          MAP_SHARED, descriptor, 0)
        // `MAP_FAILED` is `((void *)-1)`, a cast Swift does not import as a constant on every
        // platform, and `mmap` comes back optional on some of them and not on others. The failure
        // it reports is the same one either way.
        guard let mapped = mapped as UnsafeMutableRawPointer?,
              Int(bitPattern: mapped) != -1 else { return nil }
        return mapped
    }

    /// Asks the kernel to begin writing this range back.
    public func flush(byteOffset: Int, byteCount count: Int) {
        guard isMapped, count > 0, byteOffset >= 0,
              byteOffset + count <= byteCount else { return }
        let page = Int(getpagesize())
        let start = byteOffset - byteOffset % page
        msync(baseAddress.advanced(by: start), byteOffset - start + count,
              MS_ASYNC)
    }

    /// The buffer as the one element type it holds.
    public func bound<T>(to type: T.Type) -> UnsafeMutableBufferPointer<T> {
        let count = byteCount / MemoryLayout<T>.stride
        return UnsafeMutableBufferPointer(
            start: baseAddress.bindMemory(to: type, capacity: count),
            count: count)
    }

    /// What a buffer of this size really costs the process's allowance.
    public static func residentBytes(_ byteCount: Int) -> Int {
        byteCount >= mappingThreshold ? 0 : byteCount
    }
}
