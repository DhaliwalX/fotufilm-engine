import AppKit

/// Installs the signed OFX bundle shipped inside the app in the system OpenFX directory. Keeping
/// the source inside the read-only application bundle lets an installation be repaired without a
/// download. Resolve normally leaves its plug-in directory writable by administrators, so the
/// ordinary install does not ask for authorization; elevation is only the fallback when the
/// current account genuinely cannot write there.
enum OFXPluginInstaller {
    static let bundleName = "Fotufilm.ofx.bundle"
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

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedURL.path)
    }

    /// The version stamped into the bundle inside the app, and into the one on disk. `resolve/
    /// build.sh` stamps both from `version.env` before signing, so a mismatch means the installed
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
        try install(from: bundledURL, to: installedURL)
    }

    static func install(from source: URL, to destination: URL) throws {
        try PluginBundleCopy.install(from: source, to: destination)
        guard Bundle(url: destination)?.bundleIdentifier == bundleIdentifier else {
            throw Failure.installationMissing
        }
    }

    enum Failure: LocalizedError {
        case bundledPluginMissing
        case installationMissing

        var errorDescription: String? {
            switch self {
            case .bundledPluginMissing:
                return "This copy of Fotufilm does not contain the DaVinci Resolve plug-in."
            case .installationMissing:
                return "The plug-in was copied but could not be verified."

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
