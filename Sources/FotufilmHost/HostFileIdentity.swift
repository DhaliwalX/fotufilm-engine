import Foundation

/// What the editor keeps a file's last edit under (`web/src/saved-edits.js`), answered with
/// `importPath` as `identity`. A still is known by the SHA-256 of its bytes, as the Mac app keys
/// its shelf, so a renamed or moved copy keeps its edit; a movie, too large to read for it, and
/// any file on a platform without a digest, by its name, size and modification date. Both forms
/// are the ones the editor gives a file it was handed itself, so a photograph dropped on the
/// window and the same one opened from the menu share their edit.
enum HostFileIdentity {
    /// Stills are read whole to decode them anyway; past this they are known by name and date.
    static let digestLimit = 256 * 1024 * 1024

    static func identity(of url: URL, isMovie: Bool,
                         digest: HostFileDigest? = HostPlatform.current.fileDigest) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else { return nil }
        if !isMovie, size <= digestLimit, let digest, let hex = try? digest.sha256(of: url) {
            return "sha256:" + hex
        }
        let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
        let milliseconds = Int((modified.timeIntervalSince1970 * 1000).rounded(.down))
        return "file:\(url.lastPathComponent)|\(size)|\(milliseconds)"
    }
}

/// Hashes a file's bytes; a port supplies one from its own crypto library.
protocol HostFileDigest {
    /// The SHA-256 of the file's bytes, lower-case hexadecimal.
    func sha256(of url: URL) throws -> String
}
