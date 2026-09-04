import Foundation

/// The edit shelf, optionally kept in iCloud Drive rather than on one device.
enum CloudShelf {
    /// Matches the container that would have to be registered against the app
    /// id before the entitlement means anything.
    static let containerIdentifier = "iCloud.com.muastudio.fotufilm"

    private static let settingKey = "fotufilm.icloud-shelf"

    /// The user's answer, which is only ever a request: it is what makes the app look for a
    /// container, not what makes one exist.
    nonisolated static var isRequested: Bool {
        get { UserDefaults.standard.bool(forKey: settingKey) }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }

    /// Whether this build could sync at all, asked without committing to it.
    nonisolated static var isAvailable: Bool {
        FileManager.default.url(
            forUbiquityContainerIdentifier: containerIdentifier) != nil
    }

    private static let lock = NSLock()
    /// Outer nil means unresolved; inner nil means no container is available.
    nonisolated(unsafe) private static var resolved: URL??

    /// Where the shelf lives, or nil for the local one.
    nonisolated static var root: URL? {
        lock.lock()
        defer { lock.unlock() }
        if let resolved { return resolved }
        let value = resolve()
        resolved = value
        return value
    }

    private nonisolated static func resolve() -> URL? {
        guard isRequested else { return nil }
        let fm = FileManager.default
        guard let container = fm.url(
            forUbiquityContainerIdentifier: containerIdentifier) else {
            return nil
        }
        let shelf = container.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("EditLibrary", isDirectory: true)
        guard (try? fm.createDirectory(at: shelf,
                                       withIntermediateDirectories: true)) != nil
        else { return nil }
        migrate(into: shelf)
        return shelf
    }

    /// Moves the local shelf into the container once, leaving a single authoritative copy.
    private nonisolated static func migrate(into shelf: URL) {
        let fm = FileManager.default
        let local = EditLibrary.localRoot
        guard let ids = try? fm.contentsOfDirectory(atPath: local.path) else {
            return
        }
        for id in ids {
            let source = local.appendingPathComponent(id)
            let destination = shelf.appendingPathComponent(id)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try? fm.setUbiquitous(true, itemAt: source, destinationURL: destination)
        }
    }

    /// Asks for an entry that has arrived as a placeholder to be brought down.
    nonisolated static func requestDownload(of directory: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: directory)
    }

    /// Whether a file is really here, as opposed to listed here.
    nonisolated static func isDownloaded(_ url: URL) -> Bool {
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        guard let status else { return true }
        return status == .current || status == .downloaded
    }

    private nonisolated(unsafe) static var query: NSMetadataQuery?
    private nonisolated(unsafe) static var observers: [NSObjectProtocol] = []

    @MainActor
    static func watch(_ onChange: @escaping @MainActor () -> Void) {
        guard root != nil, query == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE %@",
                                      NSMetadataItemFSNameKey, "*")
        query.notificationBatchingInterval = 1
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering,
                     NSNotification.Name.NSMetadataQueryDidUpdate] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: query, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            }
            observers.append(token)
        }
        Self.query = query
        query.start()
    }
}
