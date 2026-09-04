import CryptoKit
import Foundation

/// Computes deterministic pre-encoder pixel digests for export-scheduling parity checks.
/// Each band or frame is hashed independently and folded by key order, so arrival order does not
/// affect the result. Enabled by `FOTUFILM_EXPORT_DIGEST=1`.
enum ExportProof {
    static let isEnabled =
        ProcessInfo.processInfo.environment["FOTUFILM_EXPORT_DIGEST"] == "1"

    private static let lock = NSLock()
    private static var pieces: [Int: SHA256Digest] = [:]
    private static var bytes = 0

    /// Forgets everything measured so far, so consecutive runs in one process do not fold into
    /// each other.
    static func reset() {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        pieces.removeAll()
        bytes = 0
    }

    /// One contiguous piece of finished output — a band of print, a developed frame — identified
    /// by `key`, which orders it in the fold. Keys must be unique within a run.
    static func add(key: Int, _ base: UnsafeRawPointer, count: Int) {
        guard isEnabled, count > 0 else { return }
        let digest = SHA256.hash(data: UnsafeRawBufferPointer(start: base,
                                                              count: count))
        lock.lock(); defer { lock.unlock() }
        pieces[key] = digest
        bytes += count
    }

    /// One image whose rows are padded — a `CVPixelBuffer` from a writer's pool, whose stride is
    /// the allocator's business and not the picture's. Only the used bytes of each row reach the
    /// digest, so the same frame hashes the same however it was allocated.
    static func addRows(key: Int, _ base: UnsafeRawPointer,
                        rowBytes: Int, usedBytesPerRow: Int, rows: Int) {
        guard isEnabled, rows > 0, usedBytesPerRow > 0 else { return }
        var hasher = SHA256()
        for row in 0..<rows {
            hasher.update(bufferPointer: UnsafeRawBufferPointer(
                start: base + row * rowBytes, count: usedBytesPerRow))
        }
        let digest = hasher.finalize()
        lock.lock(); defer { lock.unlock() }
        pieces[key] = digest
        bytes += rows * usedBytesPerRow
    }

    /// The fold over everything added, as hex, with the piece and byte counts that produced it.
    /// Both counts are part of the proof: a run that hashed fewer bands than its baseline has not
    /// matched it, however well the bands it did hash agree.
    static func summary() -> String {
        guard isEnabled else { return "digest off" }
        lock.lock()
        let ordered = pieces.sorted { $0.key < $1.key }
        let total = bytes
        lock.unlock()
        var hasher = SHA256()
        for (_, digest) in ordered {
            digest.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(hex) (\(ordered.count) pieces, \(total) bytes)"
    }
}

#if canImport(CoreVideo)
import CoreVideo

extension ExportProof {
    /// One frame exactly as it reaches the writer — every plane, and of each row only the bytes
    /// the picture occupies. A pooled buffer's stride and its planes' layout are the allocator's
    /// choices, and two runs that differ in nothing else can still differ in those.
    static func add(key: Int, pixelBuffer: CVPixelBuffer) {
        guard isEnabled else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        var hasher = SHA256()
        var counted = 0
        func fold(_ base: UnsafeRawPointer, rowBytes: Int,
                  used: Int, rows: Int) {
            for row in 0..<rows {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    start: base + row * rowBytes, count: used))
            }
            counted += rows * used
        }
        if CVPixelBufferIsPlanar(pixelBuffer) {
            for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer,
                                                                    plane)
                else { return }
                let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer,
                                                                  plane)
                let rows = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                // Every 10-bit biplanar plane is two bytes a sample; the chroma plane is half
                // the luma's height and carries two samples per pixel, so its used width is the
                // full row anyway. Deriving the used bytes from the plane's own width keeps both
                // right without naming the format.
                let bytesPerSample = rowBytes / max(1, width)
                fold(base, rowBytes: rowBytes,
                     used: min(rowBytes, width * max(1, bytesPerSample)),
                     rows: rows)
            }
        } else {
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerPixel = max(1, rowBytes / max(1, width))
            fold(base, rowBytes: rowBytes,
                 used: min(rowBytes, width * bytesPerPixel), rows: height)
        }
        let digest = hasher.finalize()
        lock.lock(); defer { lock.unlock() }
        pieces[key] = digest
        bytes += counted
    }
}
#endif
