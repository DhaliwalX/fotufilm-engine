import AppKit

/// The Plugins menu's items. They sit on the app delegate rather than on the editor because they
/// are about this copy of the app rather than about the open photograph. What they install and how
/// is `Sources/FotufilmPlugins`, shared with Fotufilm Desktop; the alerts are this app's.
extension AppDelegate: NSMenuItemValidation {
    @objc func installOFXPlugin(_ sender: Any?) {
        install(.resolve)
    }

    @objc func showOFXPluginInFinder(_ sender: Any?) {
        PluginSystem.reveal(EditorPlugin.resolve.installedURL())
    }

    @objc func installFxPlugPlugin(_ sender: Any?) {
        install(.finalCut)
    }

    @objc func showFxPlugPluginInFinder(_ sender: Any?) {
        PluginSystem.reveal(EditorPlugin.finalCut.installedURL())
    }

    private func install(_ plugin: EditorPlugin) {
        let alert = NSAlert()
        do {
            try plugin.install()
            alert.messageText = "Fotufilm plug-in installed"
            alert.informativeText = plugin.installedMessage(hasHost: plugin.hasHost)
        } catch {
            alert.messageText = "Fotufilm plug-in not installed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
        }
        alert.runModal()
    }

    /// One class, one `validateMenuItem`, so the Final Cut items are answered here too rather than
    /// from beside their own installer.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let (host, isInstall) = PluginHost.owning(item.action) {
            if isInstall {
                // The title carries the state, the way the SwiftUI menu did: there is nothing
                // else in a menu item to say the plug-in is already there.
                item.title = host.installTitle(reinstall: host.isInstalled)
                item.toolTip = host.installToolTip
                return host.isBundled
            }
            item.toolTip = host.showInFinderToolTip
            return host.isInstalled
        }
        switch item.action {
        case #selector(toggleAutomaticUpdateChecks(_:)):
            // The checkmark is read at the moment the menu opens, like every other state the
            // menu bar shows.
            item.state = UpdateCheck.isAutomaticCheckingEnabled ? .on : .off
            return true
        case #selector(checkForUpdates(_:)):
            return true
        default:
            return true
        }
    }
}
