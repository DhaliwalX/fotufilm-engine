import Foundation

/// The last few prints, small enough for a home screen widget to hold.
enum RecentFrames {
    /// Four is the most any widget family shows at once, and a widget's own memory limit is the
    /// tightest in the system.
    static let limit = 4

    struct Frame: Codable, Hashable, Identifiable {
        let id: String
        let stockName: String
        let modified: Date
        /// Relative to the directory, so the manifest survives the container
        /// path changing between installs.
        let thumbName: String
    }

    private static let manifestName = "recent.json"

    private static var directory: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedInbox.groupIdentifier)
        else { return nil }
        let recents = container.appendingPathComponent("Recents", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: recents, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        return recents
    }

    /// Restates the whole manifest and its thumbnails from the shelf.
    static func publish(_ frames: [(id: String, stockName: String,
                                    modified: Date, thumbnail: URL)]) {
        guard let directory else { return }
        let fm = FileManager.default
        let wanted = Array(frames.prefix(limit))
        var manifest: [Frame] = []
        for frame in wanted {
            let name = "\(frame.id).jpg"
            let destination = directory.appendingPathComponent(name)
            try? fm.removeItem(at: destination)
            guard (try? fm.copyItem(at: frame.thumbnail, to: destination)) != nil
            else { continue }
            manifest.append(Frame(id: frame.id, stockName: frame.stockName,
                                  modified: frame.modified, thumbName: name))
        }
        let keep = Set(manifest.map(\.thumbName) + [manifestName])
        for stale in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        where !keep.contains(stale) {
            try? fm.removeItem(at: directory.appendingPathComponent(stale))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: directory.appendingPathComponent(manifestName),
                        options: .atomic)
    }

    /// What the widget shows, newest first.
    static func read() -> [(frame: Frame, url: URL)] {
        guard let directory,
              let data = try? Data(contentsOf:
                directory.appendingPathComponent(manifestName))
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode([Frame].self, from: data)
        else { return [] }
        return manifest.map {
            ($0, directory.appendingPathComponent($0.thumbName))
        }
    }
}
