import AppKit
import CryptoKit

/// Checks the update feed and, when there is a newer release, walks the user to it.
///
/// The feed is one JSON document per release (`UpdateManifest`), published beside the installer
/// package it points at. The package — not the bare app — is the update vehicle: it was how this
/// copy was installed, and one installer run refreshes the Resolve and Final Cut Pro plug-ins
/// along with the app. The download is verified against the manifest's SHA-256 before the
/// Installer is handed the file.
///
/// Manual checks are the "Check for Updates…" menu command and always report their answer.
/// Automatic checks run shortly after launch and then about daily; they stay silent unless
/// there is a release the user has not skipped, and they say nothing when the network is down —
/// a background check has no news, only a question.
enum UpdateCheck {
    enum UpdateCheckError: LocalizedError {
        case notConfigured
        case serverStatus(Int)
        case unreadableFeed
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "This build does not contain the Fotufilm update-feed configuration."
            case .serverStatus(let status):
                return "The update feed answered with status \(status)."
            case .unreadableFeed:
                return "The update feed returned something this copy of Fotufilm cannot read."
            case .checksumMismatch:
                return "The downloaded update does not match the checksum its release published, "
                    + "so it was deleted. Trying again usually answers a truncated download; if "
                    + "it keeps failing, the release may have been republished — check fotufilm.com."
            }
        }
    }

    private static let automaticKey = "UpdateChecksAutomatically"
    private static let lastCheckKey = "UpdateLastCheckDate"
    private static let skippedKey = "UpdateSkippedRelease"
    /// Automatic checks at most once a day, however often the app is opened.
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    static var feedURL: URL? {
        guard let endpoint = Bundle.main.object(
            forInfoDictionaryKey: "FotufilmUpdateFeedURL") as? String else { return nil }
        return URL(string: endpoint)
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    /// The running release, the way the alerts say it — "Fotufilm 1.5 (build 8)".
    static var currentRelease: String { "\(currentVersion) (build \(currentBuild))" }

    static var isAutomaticCheckingEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: automaticKey) == nil || defaults.bool(forKey: automaticKey)
    }

    static func setAutomaticCheckingEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: automaticKey)
    }

    private static func isCheckDue() -> Bool {
        guard let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(last) >= checkInterval
    }

    private static func markChecked() {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
    }

    /// The release a "Skip This Version" answer applies to, version and build both: two builds
    /// can share a marketing version, and skipping one says nothing about the other.
    private static func releaseName(_ manifest: UpdateManifest) -> String {
        "\(manifest.version) (build \(manifest.build))"
    }

    private static func isSkipped(_ manifest: UpdateManifest) -> Bool {
        UserDefaults.standard.string(forKey: skippedKey) == releaseName(manifest)
    }

    private static func rememberSkip(_ manifest: UpdateManifest) {
        UserDefaults.standard.set(releaseName(manifest), forKey: skippedKey)
    }

    // MARK: - The check

    static func fetchManifest() async throws -> UpdateManifest {
        guard let feedURL else { throw UpdateCheckError.notConfigured }
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        // Only HTTP answers carry a status line; a file feed (local testing) has none, and its
        // documents are still judged by decode and validate below.
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                throw UpdateCheckError.serverStatus(http.statusCode)
            }
        }
        guard let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data),
              (try? manifest.validate()) != nil else {
            throw UpdateCheckError.unreadableFeed
        }
        return manifest
    }

    static func isUpdateAvailable(_ manifest: UpdateManifest) -> Bool {
        manifest.isNewer(thanVersion: currentVersion, build: currentBuild)
    }

    /// The download half of "Download and Install", exposed so `--verify-update-feed
    /// --download` can walk the same road an update does: one session, progress called back,
    /// the file moved out of the session's temporary directory to outlive it.
    static func downloadPackage(
        from url: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        try await PackageDownload(onProgress: onProgress).start(from: url)
    }

    /// The launch and daily checks. Returns without a sound whenever there is nothing to say:
    /// disabled, already asked today, no newer release, one the user skipped, or the feed
    /// unreachable.
    @MainActor static func runAutomatic() async {
        // Not under a headless verb. Several of them open windows and render through them, and
        // an update alert sheeted onto one is a build job that hangs — the same guard the
        // plug-in prompt runs behind.
        guard !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }),
              isAutomaticCheckingEnabled,
              isCheckDue() else { return }
        guard let manifest = try? await fetchManifest() else { return }
        markChecked()
        guard isUpdateAvailable(manifest), !isSkipped(manifest) else { return }
        await offer(manifest, allowSkip: true)
    }

    /// The menu command. It always asks the feed and always answers, whichever way.
    @MainActor static func runManual() async {
        do {
            let manifest = try await fetchManifest()
            markChecked()
            if isUpdateAvailable(manifest) {
                await offer(manifest, allowSkip: false)
            } else {
                let alert = NSAlert()
                alert.messageText = "You're up to date"
                alert.informativeText =
                    "Fotufilm \(currentRelease) is the newest release."
                await respond(to: alert)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Fotufilm could not check for updates"
            alert.informativeText = describe(error)
            alert.alertStyle = .warning
            await respond(to: alert)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let described = error as? LocalizedError, described.errorDescription != nil {
            return described.localizedDescription
        }
        return error.localizedDescription
    }

    // MARK: - The offer

    @MainActor private static func offer(
        _ manifest: UpdateManifest, allowSkip: Bool
    ) async {
        let alert = NSAlert()
        alert.messageText = "Fotufilm \(manifest.version) is available"
        alert.informativeText = "You have Fotufilm \(currentRelease). The update arrives as the "
            + "same signed installer this copy was installed from, so it refreshes the app and "
            + "the Resolve and Final Cut Pro plug-ins in one pass. Installing asks for your "
            + "administrator password."
        alert.addButton(withTitle: "Download and Install…")
        alert.addButton(withTitle: "Not Now")
        if allowSkip { alert.addButton(withTitle: "Skip This Version") }
        if manifest.releaseNotes != nil { alert.addButton(withTitle: "Release Notes") }

        // AppKit names responses for the first three buttons and numbers the rest, so Release
        // Notes is `.alertThirdButtonReturn` when Skip is absent and one past it when present.
        let notesResponse =
            NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1
        switch await respond(to: alert) {
        case .alertFirstButtonReturn:
            await downloadAndInstall(manifest)
        case .alertThirdButtonReturn where allowSkip:
            // Remembered against this release, not for ever: a later release is a different
            // question, and it asks again.
            rememberSkip(manifest)
        case let response where response == .alertThirdButtonReturn
            || response.rawValue == notesResponse:
            if let notes = manifest.releaseNotes { NSWorkspace.shared.open(notes) }
        default:
            break
        }
    }

    @MainActor private static func downloadAndInstall(_ manifest: UpdateManifest) async {
        guard let url = manifest.download else {
            say("The update's download address is unreadable.",
                detail: UpdateCheckError.unreadableFeed.localizedDescription)
            return
        }
        let panel = UpdateDownloadPanel(manifest: manifest)
        switch await panel.run(from: url, onto: currentWindow()) {
        case .cancelled:
            break
        case .failed(let error):
            say("The update could not be downloaded.", detail: describe(error))
        case .downloaded(let file):
            do {
                let digest = try sha256Hex(of: file)
                guard digest == manifest.normalizedSHA256 else {
                    try? FileManager.default.removeItem(at: file)
                    throw UpdateCheckError.checksumMismatch
                }
                // From here the Installer speaks for itself, including its request that
                // Fotufilm quit before it installs.
                NSWorkspace.shared.open(file)
            } catch {
                try? FileManager.default.removeItem(at: file)
                say("The update could not be verified.", detail: describe(error))
            }
        }
    }

    /// An answer the menu command or a failed download owes the user, whether or not a window
    /// is around to sheet onto.
    @MainActor private static func say(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        respondNow(to: alert)
    }

    @MainActor private static func currentWindow() -> NSWindow? {
        NSApp.mainWindow ?? NSApp.keyWindow
    }

    @MainActor private static func respond(to alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = currentWindow() else {
            return respondNow(to: alert)
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }

    @MainActor @discardableResult
    private static func respondNow(to alert: NSAlert) -> NSApplication.ModalResponse {
        alert.runModal()
    }

    /// The package's digest, read in pieces: the installer is large enough that holding it in
    /// memory to hash it would be its own problem.
    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: { () -> Bool in
            let chunk = handle.readData(ofLength: 1 << 20)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One package download in a session of its own, with progress called back. Cancelling the task
/// is the only way in and the only way out early: the session exists for this transfer alone and
/// is invalidated when it settles.
private final class PackageDownload: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: @Sendable (_ bytes: Int64, _ total: Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    func start(from url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.begin(from: url, continuation: continuation)
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func begin(from url: URL, continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
    }

    func cancel() { task?.cancel() }

    private func settle(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.invalidateAndCancel()
        session = nil
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The session deletes `location` as soon as this call returns, so the file moves out
        // first, to a name that outlives the session.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fotufilm-macOS.pkg")
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            settle(.success(destination))
        } catch {
            settle(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // A completed download was already handled in `didFinishDownloadingTo`; only failures
        // arrive here, cancellation among them.
        guard let error else { return }
        settle(.failure(error))
    }
}

/// The download's own alert: a progress bar, the byte count, and Cancel.
///
/// The download runs while the panel is up, so two things can end it — the user's Cancel and
/// the download settling. Whichever lands first wins, `closedProgrammatically` keeps the
/// second from answering twice, and a finished download closes the sheet (or the modal run
/// loop) itself.
@MainActor
private final class UpdateDownloadPanel: NSObject {
    enum Outcome {
        case downloaded(URL)
        case failed(Error)
        case cancelled
    }

    private let alert = NSAlert()
    private let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 16))
    private let status = NSTextField(labelWithString: "Connecting…")
    private var download: PackageDownload?
    private var sheetWindow: NSWindow?
    private var presentedAsModal = false
    private var closedProgrammatically = false
    private var continuation: CheckedContinuation<Outcome, Never>?

    init(manifest: UpdateManifest) {
        super.init()
        alert.messageText = "Downloading Fotufilm \(manifest.version)…"
        alert.informativeText = "The installer opens once the download matches the checksum "
            + "its release published."
        alert.addButton(withTitle: "Cancel")
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let stack = NSStackView(views: [bar, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setFrameSize(NSSize(width: 260, height: 42))
        alert.accessoryView = stack
    }

    func run(from url: URL, onto window: NSWindow?) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            self.continuation = continuation
            let download = PackageDownload { [weak self] bytes, total in
                Task { @MainActor [weak self] in self?.showProgress(bytes: bytes, total: total) }
            }
            self.download = download

            Task {
                let outcome: Outcome
                do {
                    outcome = .downloaded(try await download.start(from: url))
                } catch {
                    outcome = .failed(error)
                }
                await MainActor.run { self.downloadFinished(outcome) }
            }

            if let window {
                sheetWindow = window
                alert.beginSheetModal(for: window) { [weak self] _ in
                    guard let self else { return }
                    // `endSheet` from a settled download lands here as well; only a click on
                    // Cancel answers the continuation.
                    if !closedProgrammatically {
                        download.cancel()
                        finish(.cancelled)
                    }
                }
            } else {
                presentedAsModal = true
                _ = alert.runModal()
                if !closedProgrammatically {
                    download.cancel()
                    finish(.cancelled)
                }
            }
        }
    }

    private func showProgress(bytes: Int64, total: Int64) {
        guard total > 0 else { return }
        bar.isIndeterminate = false
        bar.stopAnimation(nil)
        bar.doubleValue = Double(bytes) / Double(total)
        let formatter = ByteCountFormatter()
        status.stringValue =
            "\(formatter.string(fromByteCount: bytes)) of \(formatter.string(fromByteCount: total))"
    }

    private func downloadFinished(_ outcome: Outcome) {
        guard continuation != nil else { return }
        closedProgrammatically = true
        if case .downloaded = outcome {
            bar.stopAnimation(nil)
            status.stringValue = "Opening the installer…"
        }
        if let sheetWindow {
            sheetWindow.endSheet(alert.window)
        }
        if presentedAsModal {
            NSApp.abortModal()
        }
        finish(outcome)
    }

    private func finish(_ outcome: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: outcome)
    }
}
