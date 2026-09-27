#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// SHA-256 with CryptoKit, read in slices so a large file is never held whole.
struct CryptoKitFileDigest: HostFileDigest {
    func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let slice = try handle.read(upToCount: 4 * 1024 * 1024), !slice.isEmpty {
            hasher.update(data: slice)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif
