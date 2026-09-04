import AppKit

/// Installs the signed OFX bundle shipped inside the app in the system OpenFX directory. Keeping
/// the source inside the read-only application bundle lets an installation be repaired without a
/// download. Resolve normally leaves its plug-in directory writable by administrators, so the
/// ordinary install does not ask for authorization; elevation is only the fallback when the
/// current account genuinely cannot write there.
enum OFXPluginInstaller {
    static let bundleName = "Fotufilm.ofx.bundle"
    static let legacyBundleName = "Fotufilm.ofx.bundle"
    static let bundleIdentifier = "com.fotufilm.ofx"

    static var bundledURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent(bundleName, isDirectory: true)
        guard Bundle(url: url)?.bundleIdentifier == bundleIdentifier else {
            return nil
        }
        return url
    }

    static var installedURL: URL {
        URL(fileURLWithPath: "/Library/OFX/Plugins", isDirectory: true)
            .appendingPathComponent(bundleName, isDirectory: true)
    }

    private static var legacyInstalledURL: URL {
        installedURL.deletingLastPathComponent()
            .appendingPathComponent(legacyBundleName, isDirectory: true)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedURL.path)
    }

    /// The version stamped into the bundle inside the app, and into the one on disk. `resolve/
    /// build.sh` stamps both from `project.yml` before signing, so a mismatch means the installed
    /// plug-in came from a different build of the app than this one — which is the case that
    /// actually breaks, an app updated under a plug-in that was not.
    static var bundledVersion: String? {
        bundledURL.flatMap(PluginVersion.of)
    }

    static var installedVersion: String? {
        PluginVersion.of(installedURL)
    }

    static var needsInstall: Bool {
        PluginVersion.needsInstall(bundled: bundledVersion, installed: installedVersion)
    }

    /// Whether DaVinci Resolve is on this Mac. Resolve installs into its own folder under
    /// `/Applications` rather than beside everything else, so the path is checked as well as Launch
    /// Services — a copy that has never been opened is not registered but is certainly installed.
    static var hasHost: Bool {
        if NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.blackmagic-design.DaVinciResolve") != nil {
            return true
        }
        return FileManager.default.fileExists(
            atPath: "/Applications/DaVinci Resolve/DaVinci Resolve.app")
    }

    static func install() throws {
        guard let bundledURL else { throw Failure.bundledPluginMissing }
        try install(from: bundledURL, to: installedURL, replacing: legacyInstalledURL)
    }

    /// Path-based for the same reason as `FxPlugInstaller.install(from:to:)`: the direct-copy path
    /// can be exercised against a temporary directory without touching a user's Resolve install.
    static func install(from source: URL, to destination: URL, replacing legacy: URL) throws {
        let plugins = destination.deletingLastPathComponent()
        let staged = plugins.appendingPathComponent(
            ".\(bundleName).\(UUID().uuidString)", isDirectory: true)

        if FileManager.default.isWritableFile(atPath: plugins.path) {
            try installWithoutAuthorization(
                from: source, to: destination, replacing: legacy, staging: staged)
        } else {
            try installWithAuthorization(
                from: source, to: destination, replacing: legacy, staging: staged)
        }

        guard Bundle(url: destination)?.bundleIdentifier == bundleIdentifier else {
            throw Failure.installationMissing
        }
    }

    private static func installWithoutAuthorization(from source: URL, to destination: URL,
                                                     replacing legacy: URL, staging staged: URL) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: staged)
        do {
            try run("/usr/bin/ditto", [source.path, staged.path])
            try? manager.removeItem(at: destination)
            try? manager.removeItem(at: legacy)
            try manager.moveItem(at: staged, to: destination)
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }

    private static func installWithAuthorization(from source: URL, to destination: URL,
                                                  replacing legacy: URL, staging staged: URL) throws {
        let plugins = destination.deletingLastPathComponent()

        let appleScript = """
        on run argv
            set sourcePath to item 1 of argv
            set destinationPath to item 2 of argv
            set pluginDirectory to item 3 of argv
            set stagedPath to item 4 of argv
            set legacyPath to item 5 of argv
            set cleanupCommand to "/bin/rm -rf " & quoted form of stagedPath
            set installCommand to cleanupCommand & " && /bin/mkdir -p " & quoted form of pluginDirectory & " && /usr/bin/ditto " & quoted form of sourcePath & " " & quoted form of stagedPath & " && /bin/rm -rf " & quoted form of destinationPath & " " & quoted form of legacyPath & " && /bin/mv " & quoted form of stagedPath & " " & quoted form of destinationPath & "; installStatus=$?; if [ $installStatus -ne 0 ]; then " & cleanupCommand & "; fi; exit $installStatus"
            do shell script installCommand with administrator privileges
        end run
        """

        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript, source.path, destination.path,
                             plugins.path, staged.path, legacy.path]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.authorizationFailed(detail ?? "")
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }
        let detail = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw Failure.commandFailed(detail ?? "")
    }

    enum Failure: LocalizedError {
        case bundledPluginMissing
        case authorizationFailed(String)
        case installationMissing
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundledPluginMissing:
                return "This copy of Fotufilm does not contain the DaVinci Resolve plug-in."
            case let .authorizationFailed(detail):
                return detail.isEmpty
                    ? "Administrator authorization was not granted."
                    : detail
            case .installationMissing:
                return "The plug-in was copied but could not be verified."
            case let .commandFailed(detail):
                return detail.isEmpty ? "The plug-in could not be copied." : detail
            }
        }
    }
}

/// The Resolve menu's two items. They sit on the app delegate rather than on the editor because
/// they are about this copy of the app rather than about the open photograph.
extension AppDelegate: NSMenuItemValidation {
    @objc func installOFXPlugin(_ sender: Any?) {
        let alert = NSAlert()
        do {
            try OFXPluginInstaller.install()
            alert.messageText = "Fotufilm plug-in installed"
            alert.informativeText = "Restart DaVinci Resolve to load the new plug-in."
        } catch {
            alert.messageText = "Fotufilm plug-in not installed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
        }
        alert.runModal()
    }

    @objc func showOFXPluginInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting(
            [OFXPluginInstaller.installedURL])
    }

    /// One class, one `validateMenuItem`, so the Final Cut items are answered here too rather than
    /// from beside their own installer.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(installOFXPlugin(_:)):
            // The title carries the state, the way the SwiftUI menu did: there is nothing else in
            // a menu item to say the plug-in is already there.
            item.title = OFXPluginInstaller.isInstalled
                ? "Reinstall Fotufilm Plug-in…"
                : "Install Fotufilm Plug-in…"
            return OFXPluginInstaller.bundledURL != nil
        case #selector(showOFXPluginInFinder(_:)):
            return OFXPluginInstaller.isInstalled
        case #selector(installFxPlugPlugin(_:)):
            item.title = FxPlugInstaller.isInstalled
                ? "Reinstall Fotufilm Plug-in…"
                : "Install Fotufilm Plug-in…"
            return FxPlugInstaller.bundledURL != nil
        case #selector(showFxPlugPluginInFinder(_:)):
            return FxPlugInstaller.isInstalled
        case #selector(toggleAutomaticUpdateChecks(_:)):
            // The checkmark is read at the moment the menu opens, like every other state the
            // menu bar shows.
            item.state = UpdateCheck.isAutomaticCheckingEnabled ? .on : .off
            return true
        case #selector(checkForUpdates(_:)):
            return true
        default:
            return true
        }
    }
}
