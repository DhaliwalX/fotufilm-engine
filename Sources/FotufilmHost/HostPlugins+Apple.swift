#if os(macOS)
import Foundation
#if canImport(FotufilmPlugins)
import FotufilmPlugins
#endif

/// The Mac app's plug-ins, installed by the Mac app's own installers (`Sources/FotufilmPlugins`):
/// the DaVinci Resolve OFX bundle into `/Library/OFX/Plugins`, the Final Cut Pro FxPlug wrapper
/// into `/Applications` with its Motion template. Fotufilm Desktop carries both in its bundle's
/// resources, as the Mac app does (`cef/CMakeLists.txt`).
struct MacPluginInstaller: HostPluginInstaller {
    /// Where the plug-ins come from and go; a check points them at a temporary directory.
    var locations = PluginLocations.standard
    /// Shows a file in Finder; a check records it instead.
    var revealer: (URL) -> Void = PluginSystem.reveal

    var catalogue: [(id: String, name: String)] {
        EditorPlugin.allCases.map { ($0.rawValue, $0.hostName) }
    }

    func plugins() -> [HostPlugin] {
        EditorPlugin.allCases.map { plugin in
            let status = plugin.status(locations)
            return HostPlugin(
                id: plugin.rawValue, name: plugin.hostName,
                state: HostPlugin.State(rawValue: status.state.rawValue) ?? .notBundled,
                bundledVersion: status.bundledVersion, installedVersion: status.installedVersion,
                hostInstalled: status.hasHost, location: status.installedURL.path,
                note: plugin.installNote)
        }
    }

    func install(_ id: String) throws -> String {
        let plugin = try self.plugin(id)
        try plugin.install(locations)
        return plugin.installedMessage(hasHost: plugin.hasHost)
    }

    func reveal(_ id: String) throws {
        let plugin = try self.plugin(id)
        guard plugin.isInstalled(locations) else {
            throw HostEngine.Failure(
                description: "The \(plugin.hostName) plug-in is not installed yet.")
        }
        revealer(plugin.installedURL(locations))
    }

    private func plugin(_ id: String) throws -> EditorPlugin {
        guard let plugin = EditorPlugin(rawValue: id) else {
            throw HostEngine.Failure(description: "There is no such plug-in.")
        }
        return plugin
    }
}
#endif
