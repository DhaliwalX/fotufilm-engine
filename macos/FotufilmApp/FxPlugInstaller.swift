import AppKit

/// Installs the bundled FxPlug wrapper application into `/Applications` and launches it once with
/// `--register` so PlugInKit registers the contained extension. macOS handles authorization.
enum FxPlugInstaller {
    /// The wrapper cannot be called Fotufilm. This app is, and both want `/Applications`; the
    /// file name is also what Finder shows for an application, so it has to say which one it is.
    static let appName = "Fotufilm for Final Cut Pro.app"
    static let bundleIdentifier = "com.fotufilm.fxhost"
    static let extensionIdentifier = "com.fotufilm.fxplug"
    static let templateName = "Fotufilm"

    static var bundledURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent(appName, isDirectory: true)
        guard Bundle(url: url)?.bundleIdentifier == bundleIdentifier else {
            return nil
        }
        return url
    }

    static var installedURL: URL {
        URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    static var isInstalled: Bool {
        Bundle(url: installedURL)?.bundleIdentifier == bundleIdentifier
    }

    /// As `OFXPluginInstaller`'s: `finalcut/build.sh` stamps the wrapper and the extension inside
    /// it from `project.yml` before signing, so a mismatch means the plug-in on disk is from
    /// another build of the app.
    static var bundledVersion: String? {
        bundledURL.flatMap(PluginVersion.of)
    }

    static var installedVersion: String? {
        PluginVersion.of(installedURL)
    }

    static var needsInstall: Bool {
        guard bundledVersion != nil else { return false }
        return PluginVersion.needsInstall(bundled: bundledVersion, installed: installedVersion)
            || !isMotionTemplateInstalled
    }

    /// Whether Final Cut Pro or Motion is on this machine at all. Installing without one is not an
    /// error — a plug-in may be installed before the host it is for — but it is worth saying, and
    /// the launch-time offer is held back until there is something to load it.
    ///
    /// More than one identifier each, because the App Store build is not the only build: a machine
    /// can carry `com.apple.FinalCutTrial`, or one of the pre-release `…App` variants, and asking
    /// only for the shipping id answers "no Final Cut here" on a Mac with Final Cut open. The
    /// filesystem sweep is the backstop for a build whose id is none of these — Launch Services
    /// can only be asked about an identifier it is given, so a list alone can always be outrun.
    static var hasHost: Bool {
        let workspace = NSWorkspace.shared
        let identifiers = ["com.apple.FinalCut", "com.apple.FinalCutApp", "com.apple.FinalCutTrial",
                           "com.apple.motionapp", "com.apple.motionappApp"]
        if identifiers.contains(where: { workspace.urlForApplication(withBundleIdentifier: $0) != nil }) {
            return true
        }
        let applications = (try? FileManager.default.contentsOfDirectory(
            atPath: "/Applications")) ?? []
        return applications.contains {
            ($0.hasPrefix("Final Cut Pro") || $0.hasPrefix("Motion")) && $0.hasSuffix(".app")
        }
    }

    static func install() throws {
        guard let bundledURL else { throw Failure.bundledPluginMissing }
        try install(from: bundledURL, to: installedURL)
        guard let template = motionTemplateURL(in: installedURL) else {
            throw Failure.motionTemplateMissing
        }
        try installMotionTemplate(from: template, to: motionTemplateDestinationURL)
        enableExtension()
    }

    /// The install itself, over paths rather than over the two the app happens to use. Written this
    /// way so `--verify-plugin-install` can run the real copy and the real registration into a
    /// temporary directory: the part most likely to be wrong is the part that touches the disk, and
    /// a check that stops short of touching it is not checking that part.
    static func install(from source: URL, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let staged = directory.appendingPathComponent(
            ".\(appName).\(UUID().uuidString)", isDirectory: true)

        // `/Applications` is group-writable by `admin` on a stock macOS, so the ordinary case needs
        // no authorization at all. Asking for a password when none is needed teaches people to type
        // one at anything that asks, so the prompt is the fallback rather than the route.
        if FileManager.default.isWritableFile(atPath: directory.path) {
            try installWithoutAuthorization(from: source, to: destination, staging: staged)
        } else {
            try installWithAuthorization(from: source, to: destination, staging: staged)
        }

        guard Bundle(url: destination)?.bundleIdentifier == bundleIdentifier else {
            throw Failure.installationMissing
        }
        try register(at: destination)
    }

    static var motionTemplateDestinationURL: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Motion Templates.localized", isDirectory: true)
            .appendingPathComponent("Effects.localized", isDirectory: true)
            .appendingPathComponent("Fotufilm.localized", isDirectory: true)
            .appendingPathComponent("Fotufilm.localized", isDirectory: true)
    }

    static var isMotionTemplateInstalled: Bool {
        let file = motionTemplateDestinationURL
            .appendingPathComponent("Fotufilm.moef", isDirectory: false)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.contains("C4D9D06C-A2A7-48B4-830B-9AE81B970140")
            && text.contains("pluginDynamicParams=\"0\"")
            && text.contains("<publishSettings>")
    }

    static func motionTemplateURL(in application: URL) -> URL? {
        let directory = application
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("MotionTemplate", isDirectory: true)
        let required = ["Fotufilm.moef", "small.png", "large.png"]
        guard required.allSatisfy({
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0, isDirectory: false).path)
        }) else { return nil }
        return directory
    }

    /// Motion templates are user-scoped even when the FxPlug wrapper is system-wide. Replace only
    /// Fotufilm's named effect directory and stage the copy so Final Cut never observes half of it.
    static func installMotionTemplate(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(
            ".\(templateName).\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        try? manager.removeItem(at: staged)
        do {
            try run("/usr/bin/ditto", [source.path, staged.path])
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: staged, to: destination)
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
        guard motionTemplateURLContents(at: destination) else {
            throw Failure.motionTemplateMissing
        }
    }

    private static func motionTemplateURLContents(at directory: URL) -> Bool {
        ["Fotufilm.moef", "small.png", "large.png"].allSatisfy {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0, isDirectory: false).path)
        }
    }

    /// Registration is asynchronous after the wrapper launch. Enabling is therefore best effort:
    /// retry briefly, but do not report a completed copy and template install as failed merely
    /// because PlugInKit has not indexed the identifier yet.
    private static func enableExtension() {
        let deadline = Date(timeIntervalSinceNow: 5)
        repeat {
            do {
                try run("/usr/bin/pluginkit", ["-e", "use", "-i", extensionIdentifier])
                return
            } catch {
                if Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            }
        } while Date() < deadline
        NSLog("Fotufilm: PlugInKit did not enable %@ before registration completed.",
              extensionIdentifier)
    }

    private static func installWithoutAuthorization(from source: URL, to destination: URL,
                                                    staging staged: URL) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: staged)
        do {
            // ditto rather than copyItem: the wrapper carries a signed extension and two signed
            // frameworks, and the copy has to leave every one of those seals intact.
            try run("/usr/bin/ditto", [source.path, staged.path])
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: staged, to: destination)
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }

    private static func installWithAuthorization(from source: URL, to destination: URL,
                                                 staging staged: URL) throws {
        let appleScript = """
        on run argv
            set sourcePath to item 1 of argv
            set destinationPath to item 2 of argv
            set stagedPath to item 3 of argv
            set cleanupCommand to "/bin/rm -rf " & quoted form of stagedPath
            set installCommand to cleanupCommand & " && /usr/bin/ditto " & quoted form of sourcePath & " " & quoted form of stagedPath & " && /bin/rm -rf " & quoted form of destinationPath & " && /bin/mv " & quoted form of stagedPath & " " & quoted form of destinationPath & "; installStatus=$?; if [ $installStatus -ne 0 ]; then " & cleanupCommand & "; fi; exit $installStatus"
            do shell script installCommand with administrator privileges
        end run
        """

        do {
            try run("/usr/bin/osascript",
                    ["-e", appleScript, source.path, destination.path, staged.path])
        } catch let Failure.commandFailed(detail) {
            throw Failure.authorizationFailed(detail)
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

    /// Runs the installed wrapper once so PlugInKit sees the extension. Without this the
    /// application is in the right place and Final Cut still does not offer the effect.
    static func register(at application: URL) throws {
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
            throw Failure.registrationFailed("Registering the plug-in with macOS timed out.")
        }
        if let failure {
            throw Failure.registrationFailed(failure.localizedDescription)
        }
        guard let launched else {
            throw Failure.registrationFailed("macOS did not report the plug-in as launched.")
        }

        // And then waits for it to go away again. This is not tidiness: the completion above fires
        // when the wrapper has *launched*, not when it has finished, so without this a wrapper that
        // did not understand `--register` would put its window up, sit there, and still be reported
        // as installed — leaving the user a dialog from an application they never opened, after
        // every install. Quitting on its own is the observable half of the `--register` contract,
        // so it is the half worth checking.
        // Asked of the kernel rather than of `NSRunningApplication.isTerminated`. That property is
        // KVO-backed off workspace notifications, so it only refreshes while a run loop is
        // spinning — and neither caller has one: the install runs on a background queue, and the
        // headless check runs before `NSApplication.run()`. Watching it there means watching a
        // value that never changes, which appears as a hang rather than as the mistake it is.
        let pid = launched.processIdentifier
        guard pid > 0 else { return }
        let deadline = Date(timeIntervalSinceNow: 15)
        while kill(pid, 0) == 0 {
            if Date() >= deadline {
                // `terminate()` is an Apple event asking politely, and an application sitting in a
                // modal loop is in no position to answer one — which is precisely the state this
                // branch exists to handle. So it is asked, given a moment, and then killed. Leaving
                // it up is the failure being reported: a window from an application the user never
                // opened, with no way to connect it to what they did.
                launched.terminate()
                let grace = Date(timeIntervalSinceNow: 2)
                while kill(pid, 0) == 0 && Date() < grace {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                throw Failure.registrationFailed(
                    "The plug-in's helper application did not quit after registering.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    enum Failure: LocalizedError {
        case bundledPluginMissing
        case motionTemplateMissing
        case authorizationFailed(String)
        case installationMissing
        case registrationFailed(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundledPluginMissing:
                return "This copy of Fotufilm does not contain the Final Cut Pro plug-in."
            case .motionTemplateMissing:
                return "This copy of Fotufilm does not contain a complete Final Cut Pro effect template."
            case let .authorizationFailed(detail):
                return detail.isEmpty
                    ? "Administrator authorization was not granted."
                    : detail
            case .installationMissing:
                return "The plug-in was copied but could not be verified."
            case let .registrationFailed(detail):
                return "The plug-in was installed but macOS did not register it. \(detail)"
            case let .commandFailed(detail):
                return detail.isEmpty ? "The plug-in could not be copied." : detail
            }
        }
    }
}

/// The Final Cut Pro menu's two items. They sit on the app delegate rather than on the editor for
/// the same reason the Resolve ones do: they are about this copy of the app rather than about the
/// open photograph.
extension AppDelegate {
    @objc func installFxPlugPlugin(_ sender: Any?) {
        let alert = NSAlert()
        do {
            try FxPlugInstaller.install()
            alert.messageText = "Fotufilm plug-in installed"
            alert.informativeText = FxPlugInstaller.hasHost
                ? "Restart Final Cut Pro or Motion to load the new plug-in. The effect appears "
                  + "under Effects → Fotufilm."
                : "Neither Final Cut Pro nor Motion is installed on this Mac, so there is nothing "
                  + "to load it yet. The plug-in is in place for when there is."
        } catch {
            alert.messageText = "Fotufilm plug-in not installed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
        }
        alert.runModal()
    }

    @objc func showFxPlugPluginInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([FxPlugInstaller.installedURL])
    }
}
