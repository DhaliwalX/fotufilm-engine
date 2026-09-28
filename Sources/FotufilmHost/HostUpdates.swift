import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FotufilmUpdate)
import FotufilmUpdate
#endif

/// The app's own releases as a platform supplies them: which one is running, where its update
/// feed is, and how a verified installer (or a release's notes) is opened.
protocol HostUpdateChannel {
    /// One JSON release document (`UpdateManifest`); nil when this build names no feed.
    var feedURL: URL? { get }
    /// `CFBundleShortVersionString` and `CFBundleVersion`, or the platform's equivalents.
    var version: String { get }
    var build: String { get }
    /// Hands a downloaded installer to the system, or opens a page in the browser.
    func open(_ url: URL) throws
}

/// Check for Updates, as the Mac app's `UpdateCheck` does it: read the feed, compare the release
/// with the running one, download the installer it names, verify it against the published
/// SHA-256 and open it. Checks and downloads run off the engine's queue, so the editor asks for
/// `status` while they do; the answers carry the Mac app's words.
final class HostUpdates {
    private let channel: HostUpdateChannel
    private let digest: HostFileDigest
    private let lock = NSLock()
    private var state: [String: Any] = ["state": "idle"]
    private var manifest: UpdateManifest?
    private var task: URLSessionTask?
    private var observation: NSKeyValueObservation?

    init(channel: HostUpdateChannel, digest: HostFileDigest) {
        self.channel = channel
        self.digest = digest
    }

    /// The running release, the way the alerts say it: "1.10 (build 12)".
    var currentRelease: String { "\(channel.version) (build \(channel.build))" }

    /// Where a check or download stands: `state` is idle, checking, current, available, failed,
    /// downloading, opened, cancelled or downloadFailed.
    func status() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var answer = state
        answer["current"] = currentRelease
        return answer
    }

    private func set(_ next: [String: Any]) {
        lock.lock()
        state = next
        lock.unlock()
    }

    /// Asks the feed; the answer arrives in `status`.
    func check() {
        guard let feedURL = channel.feedURL else {
            return set(["state": "failed", "message":
                "This build does not contain the Fotufilm update-feed configuration."])
        }
        set(["state": "checking"])
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                return set(["state": "failed", "message": error.localizedDescription])
            }
            // Only HTTP answers carry a status line; a file feed (local testing) has none.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return set(["state": "failed",
                            "message": "The update feed answered with status \(http.statusCode)."])
            }
            guard let data,
                  let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data),
                  (try? manifest.validate()) != nil else {
                return set(["state": "failed", "message":
                    "The update feed returned something this copy of Fotufilm cannot read."])
            }
            lock.lock()
            self.manifest = manifest
            lock.unlock()
            let newer = manifest.isNewer(thanVersion: channel.version, build: channel.build)
            var answer: [String: Any] = [
                "state": newer ? "available" : "current",
                "version": manifest.version,
                // What Skip This Version remembers: version and build both.
                "release": "\(manifest.version) (build \(manifest.build))",
            ]
            if let notes = manifest.releaseNotes { answer["notes"] = notes.absoluteString }
            set(answer)
        }
        task.resume()
    }

    /// Downloads the checked release's installer, verifies it and opens it; progress and the
    /// outcome arrive in `status`.
    func install() throws {
        lock.lock()
        let manifest = self.manifest
        let previous = state
        lock.unlock()
        guard let manifest, let url = manifest.download else {
            throw HostEngine.Failure(description: "Check for updates before installing one.")
        }
        set(["state": "downloading", "version": manifest.version, "bytes": 0, "total": 0])
        let task = URLSession.shared.downloadTask(with: url) { [weak self] location, _, error in
            guard let self else { return }
            if let error {
                let cancelled = (error as? URLError)?.code == .cancelled
                return set(cancelled ? previous : ["state": "downloadFailed",
                                                   "message": error.localizedDescription])
            }
            guard let location else { return }
            // The session deletes `location` when this returns: move it out first.
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent.isEmpty
                                        ? "Fotufilm-update" : url.lastPathComponent)
            do {
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: location, to: file)
                guard try digest.sha256(of: file) == manifest.normalizedSHA256 else {
                    try? FileManager.default.removeItem(at: file)
                    return set(["state": "downloadFailed", "verify": true, "message":
                        "The downloaded update does not match the checksum its release "
                        + "published, so it was deleted. Trying again usually answers a "
                        + "truncated download; if it keeps failing, the release may have been "
                        + "republished — check fotufilm.com."])
                }
                // From here the installer speaks for itself, including asking Fotufilm to quit.
                try channel.open(file)
                set(["state": "opened", "version": manifest.version])
            } catch {
                try? FileManager.default.removeItem(at: file)
                set(["state": "downloadFailed", "verify": true,
                     "message": error.localizedDescription])
            }
        }
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            guard let self, progress.totalUnitCount > 0 else { return }
            lock.lock()
            if state["state"] as? String == "downloading" {
                state["bytes"] = task.countOfBytesReceived
                state["total"] = task.countOfBytesExpectedToReceive
            }
            lock.unlock()
        }
        lock.lock()
        self.task = task
        lock.unlock()
        task.resume()
    }

    /// Stops a download; the offer it came from stands again.
    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    /// A release's notes, in the browser.
    func openNotes() throws {
        lock.lock()
        let notes = manifest?.releaseNotes
        lock.unlock()
        guard let notes else { throw HostEngine.Failure(description: "This release has no notes.") }
        try channel.open(notes)
    }
}
