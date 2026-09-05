import AppKit
import UniformTypeIdentifiers

/// The Mac app's entry point. There is no scene graph here and no `App` protocol: the process
/// starts an `NSApplication`, hands it a delegate, and the delegate opens a window.
///
/// The headless verbs below run before any of that, and several of them exit the process when they
/// finish, so they are the first thing `main` does.
@main
enum FotufilmMac {
    static func main() {
        StockPacks.bootstrap()
        VerifyPausedLog.runIfRequested()
        HeadlessDevelop.verifyLogConversionIfRequested()
        HeadlessDevelop.verifyLogStillIfRequested()
        HeadlessDevelop.verifyPreviewDepthIfRequested()
        HeadlessDevelop.dumpRoadImagesIfRequested()
        HeadlessDevelop.developVideoIfRequested()
        HeadlessDevelop.developStillIfRequested()
        HeadlessDevelop.pickStockIfRequested()
        HeadlessDevelop.benchStockPickIfRequested()
        HeadlessDevelop.reportStockLearningIfRequested()
        HeadlessDevelop.verifyPeekIfRequested()
        VerifyDesktopParity.runIfRequested()
        VerifyPluginInstall.runIfRequested()
        VerifyUpdateFeed.runIfRequested()
        SnapshotPanels.runIfRequested()

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }


}

/// Opens the window, owns the menu bar, and takes delivery of a film pack opened from the Finder.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: EditorWindowController?
    private var updateCheckTimer: Timer?
    private var pendingURLs: [URL] = []
    private var didRunPluginInstallation = false
    private var finderServiceProvider: FinderServiceProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let provider = FinderServiceProvider { [weak self] urls in
            guard let self else { return }
            self.application(NSApp, open: urls)
        }
        finderServiceProvider = provider
        NSApp.servicesProvider = provider

        if ProcessInfo.processInfo.environment["FOTUFILM_DEBUG_WINDOW"] != nil {
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: nil,
                queue: .main
            ) { note in
                guard let window = note.object as? NSWindow else { return }
                print("WINDOW RESIZE -> \(window.frame)")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }

        showEditor()
        scheduleUpdateChecks()

        NSApp.activate(ignoringOtherApps: true)
    }

    deinit {
        updateCheckTimer?.invalidate()
    }

    /// One check shortly after launch — after the plug-in prompt has had
    /// the field — and then one a day while the app runs. `UpdateCheck` itself throttles to a
    /// check a day and stays silent without news, so an often-relaunched app asks the feed no
    /// more often than a long-lived one.
    @MainActor private func scheduleUpdateChecks() {
        guard UpdateCheck.isAutomaticCheckingEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.runAutomaticUpdateCheck()
        }
        updateCheckTimer = Timer.scheduledTimer(
            withTimeInterval: 24 * 60 * 60, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runAutomaticUpdateCheck() }
        }
    }

    @MainActor private func runAutomaticUpdateCheck() {
        Task { await UpdateCheck.runAutomatic() }
    }

    @MainActor private func showEditor() {
        NSApp.mainMenu = MainMenu.build()
        if windowController == nil { windowController = EditorWindowController() }
        windowController?.showWindow(nil)
        if !didRunPluginInstallation {
            didRunPluginInstallation = true
            PluginInstallation.runAtLaunch()
        }
        let urls = pendingURLs
        pendingURLs.removeAll()
        open(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool { true }

    /// Reopening from the Dock with no window puts the one window back.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showEditor() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard windowController != nil else {
            pendingURLs.append(contentsOf: files)
            return
        }
        open(urls: files)
    }

    @MainActor private func open(urls: [URL]) {
        for url in urls {
            if url.pathExtension == FilmStockPack.sealedPathExtension {
                open(pack: url)
            } else {
                windowController?.editor.model.load(url: url)
            }
        }
    }

    @MainActor private func open(pack url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let alert = NSAlert()
        do {
            let result = try CustomStockStore.importPack(from: url)
            let films = result.stockNames.count == 1
                ? result.stockNames[0]
                : "\(result.stockNames.count) films"
            alert.messageText = result.replacedExisting ? "Pack updated" : "Pack added"
            alert.informativeText = "\(result.name) — \(films)"
            // The film list is a list of what is installed, and something just was.
            windowController?.editor.reloadFilmLibrary()
        } catch {
            alert.messageText = "Pack not added"
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
        }
        alert.runModal()
    }

    // MARK: - Menu commands

    @MainActor @objc func checkForUpdates(_ sender: Any?) {
        Task { await UpdateCheck.runManual() }
    }

    @objc func toggleAutomaticUpdateChecks(_ sender: Any?) {
        UpdateCheck.setAutomaticCheckingEnabled(!UpdateCheck.isAutomaticCheckingEnabled)
    }

    /// The same delivery the Finder makes, asked for from inside the app. A pack is a file like any
    /// other and there was no way to reach one except by double-clicking it.
    @MainActor @objc func importFilmPack(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: FilmStockPack.sealedPathExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.prompt = "Add"
        panel.message = "Choose a Fotufilm film pack to add to your library."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(pack: url)
        }
    }

    @MainActor
    @objc func openRecentDocument(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL
        else { return }
        windowController?.showWindow(nil)
        windowController?.editor.model.load(url: url)
    }

    @objc func clearRecentDocuments(_ sender: Any?) { RecentFiles.clear() }

    @objc func openHelp(_ sender: Any?) { open(page: "support") }

    @objc func openNotices(_ sender: Any?) { open(page: "third-party") }

    @objc func openTerms(_ sender: Any?) { open(page: "terms") }

    @objc func openPrivacy(_ sender: Any?) { open(page: "privacy") }

    private func open(page: String) {
        guard let url = URL(string: "https://fotufilm.com/\(page).html") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// The one window: a full-size content view under a unified title bar, so the picture runs behind
/// the toolbar the way it ran behind SwiftUI's.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let editor = DesktopEditorViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Fotufilm"
        // The build's state, in words beside the document's name. A subtitle is the one way the
        // title bar carries plain text: a toolbar item, however bare its view, is given the
        // system's glass surround on the current macOS.
        window.subtitle = "Research Preview"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 720, height: 520)
        window.contentViewController = editor
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        editor.installToolbar(in: window)
        // Otherwise the keyboard opens in the film search field, and Space, Return and the rest go
        // into a text box instead of to the picture.
        window.initialFirstResponder = editor.keyboardView

        // Handing the window a content *view controller* makes it size itself from that view's
        // fitting size, and a canvas has none — left alone it opens at the minimum, which is small
        // enough that the panels stand down on the way in. So the size is stated here: the frame
        // last left behind if there is one, and a desk's worth of window if there is not.
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.setContentSize(NSSize(width: 1100, height: 760))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    private static let frameAutosaveName = NSWindow.FrameAutosaveName(
        "FotufilmEditorWindow")

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    func windowWillClose(_ notification: Notification) {
        editor.model.close()
    }
}
