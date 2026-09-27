import Foundation

/// Puts the editor's plug-ins for other applications in place, as the Mac app's Plugins menu does:
/// says which this build carries and what is installed, installs one, and shows an installed one.
///
/// `HostPlatform.plugins`. macOS installs the DaVinci Resolve OFX bundle and the Final Cut Pro
/// FxPlug (`HostPlugins+Apple.swift`); a Linux or Windows port supplies its own, for the plug-in
/// formats and folders its editors read.
protocol HostPluginInstaller {
    /// The plug-ins this platform knows, in the order the menu lists them, without reading the
    /// disk: an `id` for the calls and the `name` of the application it plugs into.
    var catalogue: [(id: String, name: String)] { get }
    /// Every plug-in in the catalogue as this machine has it now.
    func plugins() -> [HostPlugin]
    /// Installs, or reinstalls, the plug-in this build carries and answers what to tell the
    /// person. Blocks until it is done, which may include a password prompt from the system.
    func install(_ id: String) throws -> String
    /// Shows the installed plug-in in the platform's file manager.
    func reveal(_ id: String) throws
}

/// One plug-in's state, as the editor's plug-ins dialog and menu show it.
struct HostPlugin {
    enum State: String {
        /// This build carries no such plug-in.
        case notBundled
        case notInstalled
        /// Installed from another build: installing puts this build's back, newer or older.
        case outdated
        case installed
    }

    var id: String
    /// The application it plugs into.
    var name: String
    var state: State
    /// The version this build would install, if it carries the plug-in.
    var bundledVersion: String?
    var installedVersion: String?
    /// Whether the application it plugs into is installed. Installing without it is allowed.
    var hostInstalled: Bool
    /// Where it is, or goes, on disk.
    var location: String
    /// What to know before installing (a password prompt, say).
    var note: String?

    var json: [String: Any] {
        var json: [String: Any] = ["id": id, "name": name, "state": state.rawValue,
                                   "hostInstalled": hostInstalled, "location": location]
        json["bundledVersion"] = bundledVersion
        json["installedVersion"] = installedVersion
        json["note"] = note
        return json
    }
}

extension HostService {
    /// `plugins`, `installPlugin` and `revealPlugin` (web/src/backend/macos/host.js).
    func plugin(_ method: String, _ parameters: [String: Any]) throws -> Answer {
        guard let plugins else {
            throw HostEngine.Failure(description: "This host installs no plug-ins.")
        }
        let list = { plugins.plugins().map(\.json) }
        switch method {
        case "installPlugin":
            let message = try plugins.install(try pluginID(parameters, in: plugins))
            return try answer(["message": message, "plugins": list()])
        case "revealPlugin":
            try plugins.reveal(try pluginID(parameters, in: plugins))
            return try answer([:])
        default:
            return try answer(value: list())
        }
    }

    private func pluginID(_ parameters: [String: Any], in plugins: HostPluginInstaller) throws
        -> String
    {
        guard let id = parameters["id"] as? String,
              plugins.catalogue.contains(where: { $0.id == id }) else {
            throw HostEngine.Failure(description: "There is no such plug-in.")
        }
        return id
    }
}
