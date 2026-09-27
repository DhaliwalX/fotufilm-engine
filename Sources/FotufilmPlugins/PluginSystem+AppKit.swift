#if os(macOS)
import AppKit

/// What the installers ask of Launch Services and Finder. No windows: the alerts and menus that
/// sit on top belong to each app.
public enum PluginSystem {
    /// Whether Launch Services knows an application by any of these identifiers.
    public static func hasApplication(identifiers: [String]) -> Bool {
        identifiers.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    /// Selects an installed plug-in in Finder.
    public static func reveal(_ url: URL) {
        let reveal = { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        if Thread.isMainThread { reveal() } else { DispatchQueue.main.async(execute: reveal) }
    }

    /// Launches `application` in the background with `--register` and returns its process
    /// identifier once it is running.
    static func launchForRegistration(_ application: URL) throws -> pid_t {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--register"]
        configuration.activates = false
        configuration.addsToRecentItems = false

        let group = DispatchGroup()
        group.enter()
        var failure: Error?
        var launched: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: application, configuration: configuration) {
            running, error in
            launched = running
            failure = error
            group.leave()
        }
        // The launch is the registration, so the install is not finished until it has happened.
        // Ten seconds is far longer than a wrapper that quits on launch needs, and a timeout is
        // reported rather than swallowed: an unregistered extension is an install that did not
        // work, however complete the copy looks.
        if group.wait(timeout: .now() + 10) == .timedOut {
            throw FxPlugInstaller.Failure.registrationFailed(
                "Registering the plug-in with macOS timed out.")
        }
        if let failure {
            throw FxPlugInstaller.Failure.registrationFailed(failure.localizedDescription)
        }
        guard let launched else {
            throw FxPlugInstaller.Failure.registrationFailed(
                "macOS did not report the plug-in as launched.")
        }
        return launched.processIdentifier
    }

    /// Asks an application to quit, as an Apple event.
    static func terminate(_ pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }
}
#endif
