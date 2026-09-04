import Foundation

/// The one place the share extension and the app can both reach.
enum SharedInbox {
    static let groupIdentifier = "group.com.muastudio.fotufilm"

    private struct Metadata: Codable {
        let preferredStockID: String
    }

    private static let metadataSuffix = ".fotufilm-share.json"

    private static var container: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    private static var directory: URL? {
        guard let container else { return nil }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: inbox, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        return inbox
    }

    /// Copies a file the extension has been handed onto the shared floor. The media appears in the
    /// inbox only after its optional quick-film choice has been written, so an already-running app
    /// cannot drain a half-published handoff.
    static func stage(_ url: URL, preferredStockID: String? = nil) -> URL? {
        guard let directory else { return nil }
        let filename = stagedFilename(extension: url.pathExtension)
        let destination = directory.appendingPathComponent(filename)
        let pending = directory.appendingPathComponent(".\(filename).incoming")
        do {
            try FileManager.default.copyItem(at: url, to: pending)
            return try publish(pending, as: destination,
                               preferredStockID: preferredStockID)
        } catch {
            try? FileManager.default.removeItem(at: pending)
            try? FileManager.default.removeItem(at: metadataURL(for: destination))
            return nil
        }
    }

    /// Writes bytes the extension was given in memory rather than as a file — an item provider is
    /// entitled to hand over either.
    static func stage(_ data: Data, extension pathExtension: String,
                      preferredStockID: String? = nil) -> URL? {
        guard let directory else { return nil }
        let filename = stagedFilename(extension: pathExtension)
        let destination = directory.appendingPathComponent(filename)
        let pending = directory.appendingPathComponent(".\(filename).incoming")
        do {
            try data.write(to: pending, options: .atomic)
            return try publish(pending, as: destination,
                               preferredStockID: preferredStockID)
        } catch {
            try? FileManager.default.removeItem(at: pending)
            try? FileManager.default.removeItem(at: metadataURL(for: destination))
            return nil
        }
    }

    private static func stagedFilename(extension pathExtension: String) -> String {
        let id = UUID().uuidString
        return pathExtension.isEmpty ? id : "\(id).\(pathExtension)"
    }

    private static func publish(_ pending: URL, as destination: URL,
                                preferredStockID: String?) throws -> URL {
        if let preferredStockID, !preferredStockID.isEmpty {
            let metadata = try JSONEncoder().encode(
                Metadata(preferredStockID: preferredStockID))
            try metadata.write(to: metadataURL(for: destination), options: .atomic)
        }
        try FileManager.default.moveItem(at: pending, to: destination)
        return destination
    }

    private static func metadataURL(for media: URL) -> URL {
        media.deletingLastPathComponent().appendingPathComponent(
            media.lastPathComponent + metadataSuffix)
    }

    static func preferredStockID(for media: URL) -> String? {
        guard let data = try? Data(contentsOf: metadataURL(for: media)),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data)
        else { return nil }
        return metadata.preferredStockID
    }

    /// Everything waiting, oldest first, so a share of several files opens in
    /// the order they were shared.
    static func waiting() -> [URL] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey])
        else { return [] }
        return urls.filter {
            !$0.lastPathComponent.hasPrefix(".")
                && !$0.lastPathComponent.hasSuffix(metadataSuffix)
        }.sorted { left, right in
            let l = (try? left.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate ?? .distantPast
            let r = (try? right.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate ?? .distantPast
            return l < r
        }
    }

    /// Takes a file off the shared floor once the app has its own copy.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: metadataURL(for: url))
    }
}
