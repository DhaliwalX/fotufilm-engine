#if os(macOS)
import Foundation

/// Installs the signed OFX bundle shipped inside the app in the system OpenFX directory. Keeping
/// the source inside the read-only application bundle lets an installation be repaired without a
/// download. Resolve normally leaves its plug-in directory writable by administrators, so the
/// ordinary install does not ask for authorization; elevation is only the fallback when the
/// current account genuinely cannot write there.
public struct OFXPluginInstaller {
    public static let bundleName = "Fotufilm.ofx.bundle"
    public static let bundleIdentifier = "com.fotufilm.ofx"

    public var locations: PluginLocations

    public init(locations: PluginLocations = .standard) {
        self.locations = locations
    }

    public var bundledURL: URL? {
        guard let resources = locations.bundled else { return nil }
        let url = resources.appendingPathComponent(Self.bundleName, isDirectory: true)
        guard PluginVersion.identifier(of: url) == Self.bundleIdentifier else { return nil }
        return url
    }

    public var installedURL: URL {
        locations.ofxPlugins.appendingPathComponent(Self.bundleName, isDirectory: true)
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedURL.path)
    }

    /// The version stamped into the bundle inside the app, and into the one on disk. `resolve/
    /// build.sh` stamps both from `version.env` before signing, so a mismatch means the installed
    /// plug-in came from a different build of the app than this one — which is the case that
    /// actually breaks, an app updated under a plug-in that was not.
    public var bundledVersion: String? {
        bundledURL.flatMap(PluginVersion.of)
    }

    public var installedVersion: String? {
        PluginVersion.of(installedURL)
    }

    public var needsInstall: Bool {
        PluginVersion.needsInstall(bundled: bundledVersion, installed: installedVersion)
    }

    /// Whether DaVinci Resolve is on this Mac. Resolve installs into its own folder under
    /// `/Applications` rather than beside everything else, so the path is checked as well as Launch
    /// Services — a copy that has never been opened is not registered but is certainly installed.
    public static var hasHost: Bool {
        PluginSystem.hasApplication(identifiers: ["com.blackmagic-design.DaVinciResolve"])
            || FileManager.default.fileExists(
                atPath: "/Applications/DaVinci Resolve/DaVinci Resolve.app")
    }

    public func install() throws {
        guard let bundledURL else { throw Failure.bundledPluginMissing }
        try Self.install(from: bundledURL, to: installedURL)
    }

    public static func install(from source: URL, to destination: URL) throws {
        try PluginBundleCopy.install(from: source, to: destination)
        guard PluginVersion.identifier(of: destination) == bundleIdentifier else {
            throw Failure.installationMissing
        }
    }

    public enum Failure: LocalizedError {
        case bundledPluginMissing
        case installationMissing

        public var errorDescription: String? {
            switch self {
            case .bundledPluginMissing:
                return "This copy of Fotufilm does not contain the DaVinci Resolve plug-in."
            case .installationMissing:
                return "The plug-in was copied but could not be verified."
            }
        }
    }
}
#endif
