import AppKit

/// The version stamped into a plug-in bundle. `resolve/build.sh` and `finalcut/build.sh` both write
/// it from `project.yml` before signing, so the copy inside the app and the copy on disk carry the
/// same number when they came from the same build — and differ when they did not.
///
/// `CFBundleVersion` rather than the marketing string: it is the one that moves every build.
enum PluginVersion {
    static func of(_ bundle: URL) -> String? {
        guard let values = NSDictionary(
            contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return values["CFBundleVersion"] as? String
    }

    /// Whether a plug-in stamped `installed` should be replaced by one stamped `bundled`.
    ///
    /// Not a comparison of which is newer. Any difference is a reason to install: the plug-in that
    /// belongs with this app is the one inside it, and a *newer* plug-in under an older app is as
    /// wrong as the other way round — the same photograph would develop two ways depending on
    /// which door it came through. Downgrading is the right answer there.
    ///
    /// `bundled == nil` means this build carries no such plug-in, and there is nothing to install.
    /// `installed == nil` means nothing is there, or what is there has no version to read, and
    /// both of those want installing over.
    static func needsInstall(bundled: String?, installed: String?) -> Bool {
        guard let bundled else { return false }
        return installed != bundled
    }
}

/// Checks bundled OFX and FxPlug versions at launch and offers installation when they differ from
/// installed versions. Installation requires confirmation because OFX writes to `/Library`.
/// Declines are remembered per build version.
enum PluginInstallation {
    private static let declinedKey = "PluginInstallationDeclinedVersion"

    private struct Candidate {
        let host: String
        let needsInstall: Bool
        let isInstalled: Bool
        let install: () throws -> Void
    }

    private static var candidates: [Candidate] {
        [
            Candidate(host: "Final Cut Pro",
                      needsInstall: FxPlugInstaller.bundledURL != nil
                          && FxPlugInstaller.needsInstall
                          && FxPlugInstaller.hasHost,
                      isInstalled: FxPlugInstaller.isInstalled,
                      install: FxPlugInstaller.install),
            Candidate(host: "DaVinci Resolve",
                      needsInstall: OFXPluginInstaller.bundledURL != nil
                          && OFXPluginInstaller.needsInstall
                          && OFXPluginInstaller.hasHost,
                      isInstalled: OFXPluginInstaller.isInstalled,
                      install: OFXPluginInstaller.install),
        ]
    }

    private static var version: String? {
        FxPlugInstaller.bundledVersion ?? OFXPluginInstaller.bundledVersion
    }

    /// Called once from `applicationDidFinishLaunching`. Returns immediately: the check is a few
    /// property-list reads, and anything that follows waits until there is a window to sheet onto.
    static func runAtLaunch() {
        // Not under a headless verb. Several of them open a window and render through it rather
        // than exiting first, and a modal alert in front of one is a build-machine job that hangs
        // until it is killed. A Finder launch passes no arguments.
        guard !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) else {
            return
        }

        let pending = candidates.filter(\.needsInstall)
        guard !pending.isEmpty else { return }
        guard let version, UserDefaults.standard.string(forKey: declinedKey) != version else {
            return
        }

        // After the window: an alert that beats the app on screen has nothing to sit in front of,
        // and appears as though it came from nowhere.
        DispatchQueue.main.async { ask(about: pending, version: version) }
    }

    private static func ask(about pending: [Candidate], version: String) {
        // "Install" for a plug-in that was never there, "update" for one that is simply behind —
        // the same alert answers a first launch and an app update, and they are not the same news.
        let updating = pending.allSatisfy(\.isInstalled)
        let hosts = pending.map(\.host)
        let list = hosts.count == 2 ? "\(hosts[0]) and \(hosts[1])" : hosts[0]

        let alert = NSAlert()
        alert.messageText = updating
            ? "Update the Fotufilm plug-ins for \(list)?"
            : "Install the Fotufilm plug-ins for \(list)?"
        var informative = updating
            ? "The installed plug-ins are from an older version of Fotufilm. Updating them keeps "
                + "them developing the same film this app does."
            : "Fotufilm can develop film inside \(list) using the same engine this app uses."
        if pending.contains(where: { $0.host == "DaVinci Resolve" }) {
            informative += "\n\nThe DaVinci Resolve plug-in is installed for every user on this "
                + "Mac, so macOS will ask for your administrator password."
        }
        alert.informativeText = informative
        alert.addButton(withTitle: updating ? "Update" : "Install")
        alert.addButton(withTitle: "Not Now")

        guard alert.runModal() == .alertFirstButtonReturn else {
            // Remembered against this version, not for ever: a later build asks again, because a
            // later build is a different question.
            UserDefaults.standard.set(version, forKey: declinedKey)
            return
        }
        UserDefaults.standard.removeObject(forKey: declinedKey)
        perform(pending)
    }

    private static func perform(_ pending: [Candidate]) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [(String, Error)] = []
            var installed: [String] = []
            for candidate in pending {
                do {
                    try candidate.install()
                    installed.append(candidate.host)
                } catch {
                    failures.append((candidate.host, error))
                }
            }
            DispatchQueue.main.async { report(installed: installed, failures: failures) }
        }
    }

    private static func report(installed: [String], failures: [(String, Error)]) {
        let alert = NSAlert()
        if failures.isEmpty {
            alert.messageText = "Fotufilm plug-ins installed"
            alert.informativeText =
                "Restart \(installed.joined(separator: " and ")) to load them."
        } else {
            // Report partial installation instead of claiming every plugin was installed.
            alert.alertStyle = .warning
            alert.messageText = installed.isEmpty
                ? "Fotufilm plug-ins not installed"
                : "Some Fotufilm plug-ins were not installed"
            var lines = failures.map { "\($0.0): \($0.1.localizedDescription)" }
            if !installed.isEmpty {
                lines.insert("Installed for \(installed.joined(separator: " and ")).", at: 0)
            }
            lines.append("You can try again from the menu bar.")
            alert.informativeText = lines.joined(separator: "\n\n")
        }
        alert.runModal()
    }
}
