import Foundation
#if canImport(Android)
// Foundation carries math.h onto Android but not the POSIX headers this file is written against.
import Android
#endif

/// A buffer that a large render can hold for its whole duration without spending the process's
/// memory allowance on it. iOS kills an app for the *dirty* pages it holds, not for the address
/// space it has mapped.
public final class MappedBuffer: @unchecked Sendable {
    public enum StoragePreference: Sendable {
        /// Large buffers use temporary files to limit resident memory.
        case automatic
        /// Keep a buffer in memory only within the caller's explicit allowance.
        /// Larger buffers retain automatic storage; allocation failure may use a file.
        case memory(upTo: Int)
        /// Limits anonymous memory for this allocation. Sizes above the cap must use a
        /// temporary file or fail; they never fall back to anonymous memory. A zero or
        /// negative cap requires file backing even below `mappingThreshold`.
        /// Sizes at or below the cap try memory first and may fall back to a file.
        /// This does not limit aggregate allocations or the residency of mapped pages.
        case boundedMemory(upTo: Int)
    }

    /// Above this, a buffer is worth putting on disk.
    public static let mappingThreshold = 32 << 20

    public let byteCount: Int
    /// False when this fell back to — or never left — anonymous memory.
    public let isMapped: Bool
    /// The allowance reserved by this allocation, including an explicit memory preference.
    public var residentByteCount: Int { isMapped ? 0 : byteCount }
    public let baseAddress: UnsafeMutableRawPointer
    /// The backing file, kept open for `write`; -1 when not mapped.
    private let descriptor: Int32

    /// Allocates `byteCount` bytes using the requested per-allocation storage policy.
    public convenience init?(byteCount: Int, storage: StoragePreference = .automatic) {
        self.init(byteCount: byteCount, storage: storage, allocation: .system)
    }

    /// Per-call resource factories keep allocation-failure tests independent of process globals.
    /// Successful factories must retain the standard malloc/free and mmap/munmap ownership.
    struct Allocation {
        var memory: (Int) -> UnsafeMutableRawPointer?
        var file: (Int) -> (UnsafeMutableRawPointer, Int32)?

        static var system: Self {
            Self(memory: { malloc($0) }, file: MappedBuffer.map)
        }
    }

    init?(byteCount: Int, storage: StoragePreference, allocation: Allocation) {
        guard byteCount > 0 else { return nil }
        self.byteCount = byteCount
        let prefersMemory: Bool
        let requiresMapping: Bool
        switch storage {
        case .automatic:
            prefersMemory = false; requiresMapping = false
        case .memory(let limit):
            prefersMemory = byteCount <= limit; requiresMapping = false
        case .boundedMemory(let limit):
            prefersMemory = byteCount <= max(0, limit)
            requiresMapping = !prefersMemory
        }
        if requiresMapping || (!prefersMemory && byteCount >= Self.mappingThreshold) {
            if let (mapped, descriptor) = allocation.file(byteCount) {
                baseAddress = mapped
                self.descriptor = descriptor
                isMapped = true
                return
            }
            guard !requiresMapping else { return nil }
        }
        guard let memory = allocation.memory(byteCount) else {
            guard prefersMemory, let (mapped, descriptor) = allocation.file(byteCount) else { return nil }
            baseAddress = mapped
            self.descriptor = descriptor
            isMapped = true
            return
        }
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        baseAddress = memory
        descriptor = -1
        isMapped = false
    }

    deinit {
        if isMapped {
            #if !os(WASI)
            munmap(baseAddress, byteCount)
            close(descriptor)
            #endif
        } else {
            free(baseAddress)
        }
    }

    /// Maps a temporary file, or nil if any step of it fails.
    private static func map(byteCount: Int) -> (UnsafeMutableRawPointer, Int32)? {
        #if os(WASI)
        // WebAssembly linear memory cannot map files. Policies that require mapping fail;
        // other policies retain their existing allocator fallback above.
        return nil
        #else
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fotufilm-\(UUID().uuidString)")
        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return nil }
        unlink(path)
        guard ftruncate(descriptor, off_t(byteCount)) == 0 else {
            close(descriptor)
            return nil
        }
        let mapped = mmap(nil, byteCount, PROT_READ | PROT_WRITE,
                          MAP_SHARED, descriptor, 0)
        // `MAP_FAILED` is `((void *)-1)`, a cast Swift does not import as a constant on every
        // platform, and `mmap` comes back optional on some of them and not on others. The failure
        // it reports is the same one either way.
        guard let mapped = mapped as UnsafeMutableRawPointer?,
              Int(bitPattern: mapped) != -1 else {
            close(descriptor)
            return nil
        }
        return (mapped, descriptor)
        #endif
    }

    /// Stores `count` bytes at `byteOffset` through the file rather than the mapping. Writing a
    /// large mapping dirties its pages faster than the kernel will write them back, and it
    /// answers by stalling the writer — an iPhone spent thirty seconds of a forty-second
    /// rasterise stopped that way — where the file's own write path streams them out. The
    /// mapping sees the bytes the same: it is the same page cache.
    public func write(from source: UnsafeRawPointer, byteOffset: Int, byteCount count: Int) {
        guard count > 0, byteOffset >= 0, byteOffset + count <= byteCount else { return }
        guard isMapped else {
            baseAddress.advanced(by: byteOffset).copyMemory(from: source, byteCount: count)
            return
        }
        var written = 0
        while written < count {
            let result = pwrite(descriptor, source.advanced(by: written), count - written,
                                off_t(byteOffset + written))
            if result <= 0 {
                if result < 0 && errno == EINTR { continue }
                // The mapping is still the truth of the buffer; what the file would not take
                // goes in through it.
                baseAddress.advanced(by: byteOffset + written).copyMemory(
                    from: source.advanced(by: written), byteCount: count - written)
                return
            }
            written += result
        }
    }

    /// Asks the kernel to begin writing this range back.
    public func flush(byteOffset: Int, byteCount count: Int) {
        #if !os(WASI)
        guard isMapped, count > 0, byteOffset >= 0,
              byteOffset + count <= byteCount else { return }
        let page = Int(getpagesize())
        let start = byteOffset - byteOffset % page
        msync(baseAddress.advanced(by: start), byteOffset - start + count,
              MS_ASYNC)
        #endif
    }

    /// The buffer as the one element type it holds.
    public func bound<T>(to type: T.Type) -> UnsafeMutableBufferPointer<T> {
        let count = byteCount / MemoryLayout<T>.stride
        return UnsafeMutableBufferPointer(
            start: baseAddress.bindMemory(to: type, capacity: count),
            count: count)
    }

    /// What automatic storage of this size reserves. Use `residentByteCount` for an allocation
    /// that supplies an explicit storage preference or may have fallen back to memory.
    public static func residentBytes(_ byteCount: Int) -> Int {
        #if os(WASI)
        return byteCount
        #else
        byteCount >= mappingThreshold ? 0 : byteCount
        #endif
    }
}
