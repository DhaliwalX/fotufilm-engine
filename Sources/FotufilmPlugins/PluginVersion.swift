import Foundation

/// The version stamped into a plug-in bundle. `resolve/build.sh` and `finalcut/build.sh` both write
/// it from `version.env` before signing, so the copy inside the app and the copy on disk carry the
/// same number when they came from the same build — and differ when they did not.
///
/// `CFBundleVersion` rather than the marketing string: it is the one that moves every build.
public enum PluginVersion {
    public static func of(_ bundle: URL) -> String? {
        info(bundle)?["CFBundleVersion"] as? String
    }

    /// The bundle's identifier, read from its Info.plist on every call. `Bundle(url:)` would do,
    /// except that it caches by path: a bundle replaced in place keeps answering as the old one.
    public static func identifier(of bundle: URL) -> String? {
        info(bundle)?["CFBundleIdentifier"] as? String
    }

    private static func info(_ bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil))
            as? [String: Any]
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
    public static func needsInstall(bundled: String?, installed: String?) -> Bool {
        guard let bundled else { return false }
        return installed != bundled
    }
}
