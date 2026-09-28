#if os(macOS)
import Foundation

/// The editors Fotufilm ships a plug-in for, named as the user knows them. The Mac app's Plugins
/// menu and Fotufilm Desktop's plug-ins dialog both list these, in this order.
public enum EditorPlugin: String, CaseIterable {
    case resolve
    case finalCut

    /// The product the plug-in is for, not the plug-in format.
    public var hostName: String {
        switch self {
        case .resolve: return "DaVinci Resolve"
        case .finalCut: return "Final Cut Pro"
        }
    }

    /// Whether the editor the plug-in is for is on this Mac.
    public var hasHost: Bool {
        switch self {
        case .resolve: return OFXPluginInstaller.hasHost
        case .finalCut: return FxPlugInstaller.hasHost
        }
    }

    /// The plug-in's installed and bundled state under `locations`.
    public func status(_ locations: PluginLocations = .standard) -> EditorPluginStatus {
        switch self {
        case .resolve:
            let installer = OFXPluginInstaller(locations: locations)
            return EditorPluginStatus(
                plugin: self, isBundled: installer.bundledURL != nil,
                bundledVersion: installer.bundledVersion,
                isInstalled: installer.isInstalled, installedVersion: installer.installedVersion,
                needsInstall: installer.needsInstall, hasHost: hasHost,
                installedURL: installer.installedURL)
        case .finalCut:
            let installer = FxPlugInstaller(locations: locations)
            return EditorPluginStatus(
                plugin: self, isBundled: installer.bundledURL != nil,
                bundledVersion: installer.bundledVersion,
                isInstalled: installer.isInstalled, installedVersion: installer.installedVersion,
                needsInstall: installer.needsInstall, hasHost: hasHost,
                installedURL: installer.installedURL)
        }
    }

    /// Whether this build carries the plug-in. Cheaper than `status`, for a menu to validate by.
    public func isBundled(_ locations: PluginLocations = .standard) -> Bool {
        switch self {
        case .resolve: return OFXPluginInstaller(locations: locations).bundledURL != nil
        case .finalCut: return FxPlugInstaller(locations: locations).bundledURL != nil
        }
    }

    /// Whether the plug-in is installed, from whichever build.
    public func isInstalled(_ locations: PluginLocations = .standard) -> Bool {
        switch self {
        case .resolve: return OFXPluginInstaller(locations: locations).isInstalled
        case .finalCut: return FxPlugInstaller(locations: locations).isInstalled
        }
    }

    /// Where the plug-in is once installed.
    public func installedURL(_ locations: PluginLocations = .standard) -> URL {
        switch self {
        case .resolve: return OFXPluginInstaller(locations: locations).installedURL
        case .finalCut: return FxPlugInstaller(locations: locations).installedURL
        }
    }

    /// Installs, or reinstalls, the plug-in this app carries. Blocks: a Final Cut install waits
    /// for macOS to register the extension, and a Resolve install may wait for a password.
    public func install(_ locations: PluginLocations = .standard) throws {
        switch self {
        case .resolve: try OFXPluginInstaller(locations: locations).install()
        case .finalCut: try FxPlugInstaller(locations: locations).install()
        }
    }

    /// What to say before an install, when there is something to know.
    public var installNote: String? {
        switch self {
        case .resolve:
            return "The DaVinci Resolve plug-in is installed for every user on this Mac, so macOS "
                + "may ask for your administrator password."
        case .finalCut:
            return nil
        }
    }

    /// What to tell the user after an install, depending on whether the editor is here to load it.
    public func installedMessage(hasHost: Bool) -> String {
        switch self {
        case .resolve:
            return "Restart DaVinci Resolve to load the new plug-in."
        case .finalCut:
            return hasHost
                ? "Restart Final Cut Pro or Motion to load the new plug-in. The effect appears "
                  + "under Effects → Fotufilm."
                : "Neither Final Cut Pro nor Motion is installed on this Mac, so there is nothing "
                  + "to load it yet. The plug-in is in place for when there is."
        }
    }
}

/// One plug-in as this machine has it.
public struct EditorPluginStatus: Equatable {
    public enum State: String {
        /// This build carries no such plug-in (a build without the FxPlug SDK, say).
        case notBundled
        case notInstalled
        /// Installed, but from another build: installing puts this app's back.
        case outdated
        case installed
    }

    public var plugin: EditorPlugin
    public var isBundled: Bool
    public var bundledVersion: String?
    public var isInstalled: Bool
    public var installedVersion: String?
    /// Whether installing would change what is on disk (`PluginVersion.needsInstall`).
    public var needsInstall: Bool
    /// Whether the editor the plug-in is for is on this Mac.
    public var hasHost: Bool
    public var installedURL: URL

    public var state: State {
        if !isBundled { return isInstalled ? .installed : .notBundled }
        if !isInstalled { return .notInstalled }
        return needsInstall ? .outdated : .installed
    }
}
#endif
