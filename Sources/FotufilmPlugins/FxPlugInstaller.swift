#if os(macOS)
import Foundation

/// Installs the bundled FxPlug wrapper application into `/Applications` and launches it once with
/// `--register` so PlugInKit registers the contained extension. macOS handles authorization.
public struct FxPlugInstaller {
    /// The wrapper cannot be called Fotufilm. This app is, and both want `/Applications`; the
    /// file name is also what Finder shows for an application, so it has to say which one it is.
    public static let appName = "Fotufilm for Final Cut Pro.app"
    public static let bundleIdentifier = "com.fotufilm.fxhost"
    public static let extensionIdentifier = "com.fotufilm.fxplug"
    /// The files a complete Motion template carries.
    static let motionTemplateFiles = ["Fotufilm.moef", "small.png", "large.png"]

    public var locations: PluginLocations

    public init(locations: PluginLocations = .standard) {
        self.locations = locations
    }

    public var bundledURL: URL? {
        guard let resources = locations.bundled else { return nil }
        let url = resources.appendingPathComponent(Self.appName, isDirectory: true)
        guard PluginVersion.identifier(of: url) == Self.bundleIdentifier else { return nil }
        return url
    }

    public var installedURL: URL {
        locations.applications.appendingPathComponent(Self.appName, isDirectory: true)
    }

    public var isInstalled: Bool {
        PluginVersion.identifier(of: installedURL) == Self.bundleIdentifier
    }

    /// As `OFXPluginInstaller`'s: `finalcut/build.sh` stamps the wrapper and the extension inside
    /// it from `version.env` before signing, so a mismatch means the plug-in on disk is from
    /// another build of the app.
    public var bundledVersion: String? {
        bundledURL.flatMap(PluginVersion.of)
    }

    public var installedVersion: String? {
        PluginVersion.of(installedURL)
    }

    public var needsInstall: Bool {
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
    public static var hasHost: Bool {
        let identifiers = ["com.apple.FinalCut", "com.apple.FinalCutApp", "com.apple.FinalCutTrial",
                           "com.apple.motionapp", "com.apple.motionappApp"]
        if PluginSystem.hasApplication(identifiers: identifiers) { return true }
        let applications = (try? FileManager.default.contentsOfDirectory(
            atPath: "/Applications")) ?? []
        return applications.contains {
            ($0.hasPrefix("Final Cut Pro") || $0.hasPrefix("Motion")) && $0.hasSuffix(".app")
        }
    }

    public func install() throws {
        guard let bundledURL else { throw Failure.bundledPluginMissing }
        try Self.install(from: bundledURL, to: installedURL,
                         registering: locations.registersExtensions)
        guard let template = Self.motionTemplateURL(in: installedURL) else {
            throw Failure.motionTemplateMissing
        }
        try Self.installMotionTemplate(from: template, to: locations.motionTemplate)
        if locations.registersExtensions { Self.enableExtension() }
    }

    /// Copies the wrapper and, when `registering`, launches it so macOS registers the extension.
    public static func install(from source: URL, to destination: URL,
                               registering: Bool = true) throws {
        try PluginBundleCopy.install(from: source, to: destination)
        guard PluginVersion.identifier(of: destination) == bundleIdentifier else {
            throw Failure.installationMissing
        }
        if registering { try register(at: destination) }
    }

    public var isMotionTemplateInstalled: Bool {
        let file = locations.motionTemplate
            .appendingPathComponent("Fotufilm.moef", isDirectory: false)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.contains("C4D9D06C-A2A7-48B4-830B-9AE81B970140")
            && text.contains("pluginDynamicParams=\"0\"")
            && text.contains("<publishSettings>")
    }

    public static func motionTemplateURL(in application: URL) -> URL? {
        let directory = application
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("MotionTemplate", isDirectory: true)
        return isCompleteMotionTemplate(directory) ? directory : nil
    }

    /// Motion templates are user-scoped even when the FxPlug wrapper is system-wide. Replace only
    /// Fotufilm's named effect directory and stage the copy so Final Cut never observes half of it.
    public static func installMotionTemplate(from source: URL, to destination: URL) throws {
        try PluginBundleCopy.install(from: source, to: destination)
        guard isCompleteMotionTemplate(destination) else {
            throw Failure.motionTemplateMissing
        }
    }

    private static func isCompleteMotionTemplate(_ directory: URL) -> Bool {
        motionTemplateFiles.allSatisfy {
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
                try PluginBundleCopy.run("/usr/bin/pluginkit",
                                         ["-e", "use", "-i", extensionIdentifier])
                return
            } catch {
                if Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            }
        } while Date() < deadline
        NSLog("Fotufilm: PlugInKit did not enable %@ before registration completed.",
              extensionIdentifier)
    }

    /// Runs the installed wrapper once so PlugInKit sees the extension. Without this the
    /// application is in the right place and Final Cut still does not offer the effect.
    public static func register(at application: URL) throws {
        let pid = try PluginSystem.launchForRegistration(application)

        // And then waits for it to go away again. This is not tidiness: the launch completes
        // when the wrapper has *launched*, not when it has finished, so without this a wrapper that
        // did not understand `--register` would put its window up, sit there, and still be reported
        // as installed — leaving the user a dialog from an application they never opened, after
        // every install. Quitting on its own is the observable half of the `--register` contract,
        // so it is the half worth checking.
        // Asked of the kernel rather than of `NSRunningApplication.isTerminated`. That property is
        // KVO-backed off workspace notifications, so it only refreshes while a run loop is
        // spinning — and no caller has one: the installs run on a background queue or the
        // desktop host's engine thread, and the headless check runs before `NSApplication.run()`.
        // Watching it there means watching a value that never changes, which appears as a hang
        // rather than as the mistake it is.
        guard pid > 0 else { return }
        let deadline = Date(timeIntervalSinceNow: 15)
        while kill(pid, 0) == 0 {
            if Date() >= deadline {
                // Asked politely first, and an application sitting in a modal loop is in no
                // position to answer — which is precisely the state this branch exists to handle.
                // So it is asked, given a moment, and then killed. Leaving it up is the failure
                // being reported: a window from an application the user never opened, with no
                // way to connect it to what they did.
                PluginSystem.terminate(pid)
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

    public enum Failure: LocalizedError {
        case bundledPluginMissing
        case motionTemplateMissing
        case installationMissing
        case registrationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .bundledPluginMissing:
                return "This copy of Fotufilm does not contain the Final Cut Pro plug-in."
            case .motionTemplateMissing:
                return "This copy of Fotufilm does not contain a complete Final Cut Pro effect template."
            case .installationMissing:
                return "The plug-in was copied but could not be verified."
            case let .registrationFailed(detail):
                return "The plug-in was installed but macOS did not register it. \(detail)"
            }
        }
    }
}
#endif
