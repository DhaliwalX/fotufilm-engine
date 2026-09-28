#if os(macOS)
import Foundation

/// Where the plug-ins come from and where they go. The Mac app and Fotufilm Desktop both install
/// from their own bundle's resources into the places Resolve and Final Cut look; a check points
/// every destination at a temporary directory instead, and turns registration off.
public struct PluginLocations {
    /// The directory holding the plug-ins this app ships: its bundle's resources.
    public var bundled: URL?
    /// Resolve's OpenFX directory, shared by every user of the Mac.
    public var ofxPlugins: URL
    /// Where the Final Cut wrapper application goes.
    public var applications: URL
    /// Fotufilm's effect folder among this user's Motion templates, which Final Cut lists.
    public var motionTemplate: URL
    /// Whether an install launches the Final Cut wrapper so PlugInKit registers its extension.
    /// Off for a copy into a temporary directory: there is nothing there macOS should know about.
    public var registersExtensions: Bool

    public init(bundled: URL?, ofxPlugins: URL, applications: URL, motionTemplate: URL,
                registersExtensions: Bool) {
        self.bundled = bundled
        self.ofxPlugins = ofxPlugins
        self.applications = applications
        self.motionTemplate = motionTemplate
        self.registersExtensions = registersExtensions
    }

    /// This app's resources into the system's places.
    public static var standard: PluginLocations {
        PluginLocations(
            bundled: Bundle.main.resourceURL,
            ofxPlugins: URL(fileURLWithPath: "/Library/OFX/Plugins", isDirectory: true),
            applications: URL(fileURLWithPath: "/Applications", isDirectory: true),
            motionTemplate: motionTemplate(
                in: FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]),
            registersExtensions: true)
    }

    /// Every destination under `root`, as a check wants them; the plug-ins still come from
    /// `bundled`.
    public static func temporary(root: URL, bundled: URL?) -> PluginLocations {
        PluginLocations(
            bundled: bundled,
            ofxPlugins: root.appendingPathComponent("Library/OFX/Plugins", isDirectory: true),
            applications: root.appendingPathComponent("Applications", isDirectory: true),
            motionTemplate: motionTemplate(
                in: root.appendingPathComponent("Movies", isDirectory: true)),
            registersExtensions: false)
    }

    /// `Movies/Motion Templates.localized/Effects.localized/Fotufilm.localized/Fotufilm.localized`:
    /// the category and the effect Final Cut shows under Effects → Fotufilm.
    public static func motionTemplate(in movies: URL) -> URL {
        movies
            .appendingPathComponent("Motion Templates.localized", isDirectory: true)
            .appendingPathComponent("Effects.localized", isDirectory: true)
            .appendingPathComponent("Fotufilm.localized", isDirectory: true)
            .appendingPathComponent("Fotufilm.localized", isDirectory: true)
    }
}
#endif
