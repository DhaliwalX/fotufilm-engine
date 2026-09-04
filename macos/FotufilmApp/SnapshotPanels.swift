import AppKit

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Renders session panels to PNG with `cacheDisplay(in:to:)`, including on locked or headless
/// systems. Usage: `Fotufilm --demo --snapshot-panels=/tmp/shots`.
enum SnapshotPanels {
    private static let columnWidth: CGFloat = 330
    private static let columnHeight: CGFloat = 1000

    @discardableResult
    @MainActor static func runIfRequested() -> Bool {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--snapshot-panels=")
        }) else { return false }
        let directory = URL(fileURLWithPath:
            String(argument.dropFirst("--snapshot-panels=".count)))

        Task { @MainActor in
            guard let editor = await editor() else {
                print("snapshot-panels: no editor window appeared")
                exit(1)
            }
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            // Let the sample develop, so the panels that read the film — the paper list, the
            // reciprocity row — are the ones a photograph really gets.
            for _ in 1...40 where editor.model.processed == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }

            var written = 0
            for panel in InspectorPanel.allCases {
                let controller = InspectorViewController(model: editor.model)
                controller.panel = panel
                if write(controller, size: CGSize(width: columnWidth,
                                                  height: columnHeight),
                         to: directory.appendingPathComponent(
                            "panel-\(panel.rawValue).png")) {
                    written += 1
                }
            }
            // And the film panel again with no film, which is a different column.
            editor.model.edit.stockID = StockPreset.noFilmID
            try? await Task.sleep(for: .milliseconds(400))
            let plain = InspectorViewController(model: editor.model)
            plain.panel = .film
            if write(plain, size: CGSize(width: columnWidth,
                                         height: columnHeight),
                     to: directory.appendingPathComponent("panel-film-normal.png")) {
                written += 1
            }

            if write(SettingsSheetController(),
                     size: CGSize(width: 520, height: 900),
                     to: directory.appendingPathComponent("settings.png")) {
                written += 1
            }

            // And the editor window whole, title bar with it: the toolbar is built by hand and the
            // panels' snapshots never show it, so a change to the bar would otherwise go unseen.
            if let window = NSApp.windows.first(where: {
                    $0.contentViewController is DesktopEditorViewController }),
               let frameView = window.contentView?.superview,
               let bitmap = frameView.bitmapImageRepForCachingDisplay(
                    in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    do {
                        try data.write(to: directory.appendingPathComponent(
                            "window.png"), options: .atomic)
                        written += 1
                    } catch {
                        print("snapshot-panels: window.png: \(error)")
                    }
                }
            }

            print("snapshot-panels: wrote \(written) to \(directory.path)")
            exit(0)
        }
        return true
    }

    @MainActor
    private static func editor() async -> DesktopEditorViewController? {
        for _ in 1...40 {
            if let found = NSApp.windows.lazy.compactMap({
                $0.contentViewController as? DesktopEditorViewController
            }).first {
                return found
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    /// Puts a controller's view in an off-screen window at the given size, lets AppKit lay it out,
    /// and draws it to a PNG.
    ///
    /// The window is real but never ordered in. It exists because a view with no window has no
    /// backing scale and no appearance to resolve its colours against — the panels are drawn in
    /// dark-mode greys, and without a window they would come out light.
    @MainActor
    private static func write(_ controller: NSViewController, size: CGSize,
                              to url: URL) -> Bool {
        // A panel paints nothing behind its rows: in the app the window's glass and the
        // photograph are back there. Drawn straight to a bitmap it lands on nothing, and
        // "nothing" appears as white — under white text, which is what the session's controls are
        // in the dark appearance they are built for. So the snapshot supplies the backdrop the
        // window would have.
        //
        // A `SessionView` rather than a bare `NSView`, because the session's views are flipped
        // and a panel hung inside an unflipped container lays out upside down — the tab strip
        // comes out along the bottom edge.
        let backdrop = SessionView(frame: CGRect(origin: .zero, size: size))
        backdrop.backingLayer.backgroundColor = NSColor(
            red: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor

        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered,
                              defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = backdrop

        // Pinned with constraints, not an autoresizing mask: the panels' roots all set
        // `translatesAutoresizingMaskIntoConstraints = false`, so a mask on one is ignored and
        // Auto Layout gives it a zero frame — a snapshot of the backdrop and nothing else.
        let view = controller.view
        view.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            view.topAnchor.constraint(equalTo: backdrop.topAnchor),
            view.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        // Twice: the first pass gives the rows their sizes, the second places the ones whose
        // height depends on how far a wrapped note ran.
        backdrop.layoutSubtreeIfNeeded()
        backdrop.layoutSubtreeIfNeeded()

        guard let bitmap = backdrop.bitmapImageRepForCachingDisplay(
            in: backdrop.bounds) else {
            print("snapshot-panels: could not make a bitmap for \(url.lastPathComponent)")
            return false
        }
        backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:])
        else {
            print("snapshot-panels: could not encode \(url.lastPathComponent)")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("snapshot-panels: \(url.lastPathComponent): \(error)")
            return false
        }
    }
}
