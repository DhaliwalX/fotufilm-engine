import Foundation

/// The import location shared by the Mac app and its plugins.
public enum FilmPackLibrary {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        #if FOTUFILM_SOURCE_BUILD
        return base.appendingPathComponent("FotufilmSource/CustomPacks", isDirectory: true)
        #else
        return base.appendingPathComponent("CustomPacks", isDirectory: true)
        #endif
    }

    /// Plugins read imported community packs only. Device-local films and untrusted vaults
    /// are excluded, as are packs requiring a newer release of the app and plugins.
    public static func compatibleCommunityPacks(
        in directory: URL = directory, macAppVersion: String,
        keyring: FilmPackKeyring = .shared
    ) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries.filter { url in
            guard url.pathExtension.lowercased() == FilmStockPack.sealedPathExtension,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= FilmPackContainer.fileLimit,
                  let data = try? Data(contentsOf: url),
                  let header = try? FilmPackContainer.peek(data), header.kind == .community,
                  let pack = try? FilmPackContainer.open(data, keyring: keyring,
                                                        macAppVersion: macAppVersion),
                  !pack.manifest.stocks.isEmpty else { return false }
            return (try? pack.manifest.stocks.forEach { try $0.validate() }) != nil
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
